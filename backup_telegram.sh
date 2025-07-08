#!/bin/bash

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

readonly SCRIPT_VERSION="8.0"
readonly SCRIPT_NAME="backup_telegram"
readonly MAX_BACKUP_SIZE=52428800
readonly API_TIMEOUT=30
readonly UPLOAD_TIMEOUT=600
readonly MAX_RETRIES=3

CURRENT_USER=$(whoami)
USER_HOME=$(eval echo ~$CURRENT_USER)
IS_ROOT=false

if [[ $EUID -eq 0 ]]; then
    IS_ROOT=true
    SCRIPT_DIR="/opt/backup-telegram"
    LOG_FILE="/var/log/backup_telegram.log"
    BACKUP_DIR="/tmp/backups"
    LOCK_FILE="/var/run/backup_telegram.lock"
else
    SCRIPT_DIR="$USER_HOME/.backup-telegram"
    LOG_FILE="$SCRIPT_DIR/backup.log"
    BACKUP_DIR="$SCRIPT_DIR/temp"
    LOCK_FILE="$SCRIPT_DIR/backup.lock"
fi

readonly CONFIG_FILE="${SCRIPT_DIR}/config.conf"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "${timestamp} - ${message}" >> "$LOG_FILE"
}

get_primary_user() {
    local priority_users=("ichiazure" "azureuser" "ubuntu" "ec2-user" "debian")
    for user in "${priority_users[@]}"; do
        if [[ -d "/home/$user" ]]; then
            echo "$user:/home/$user"
            return
        fi
    done
    echo "root:/root"
}

detect_cloud_provider() {
    local provider="Unknown"
    local backup_path=""
    
    if [[ -f /var/lib/waagent/Incarnation ]] || [[ -d /var/lib/waagent ]]; then
        provider="Microsoft Azure"
        if [[ "$IS_ROOT" == "true" ]]; then
            local user_info=$(get_primary_user)
            backup_path=$(echo "$user_info" | cut -d':' -f2)
        else
            backup_path="$USER_HOME"
        fi
    elif curl -s http://169.254.169.254/latest/meta-data/instance-id --max-time 3 &>/dev/null; then
        provider="Amazon AWS"
        local user_info=$(get_primary_user)
        backup_path=$(echo "$user_info" | cut -d':' -f2)
    elif curl -s http://169.254.169.254/metadata/v1/id --max-time 3 &>/dev/null; then
        provider="DigitalOcean"
        backup_path="/root"
    else
        provider="Generic VPS"
        backup_path="/root"
    fi
    
    if [[ ! -d "$backup_path" ]]; then
        backup_path="/root"
    fi
    
    echo "$provider|$backup_path"
}

detect_project_folders() {
    local target_path="$1"
    local project_folders=()
    
    while IFS= read -r -d '' folder; do
        local folder_name=$(basename "$folder")
        
        if [[ "$folder_name" =~ ^\. ]] || \
           [[ "$folder_name" == "snap" ]] || \
           [[ "$folder_name" == "tmp" ]] || \
           [[ "$folder_name" == "cache" ]] || \
           [[ "$folder_name" == "Downloads" ]] || \
           [[ "$folder_name" == "Desktop" ]] || \
           [[ "$folder_name" == "Documents" ]] || \
           [[ "$folder_name" == "Pictures" ]] || \
           [[ "$folder_name" == "Videos" ]] || \
           [[ "$folder_name" == "Music" ]]; then
            continue
        fi
        
        if find "$folder" -maxdepth 3 \( -name "*.env" -o -name "package.json" -o -name "*.py" -o -name "*.js" \) \
            ! -path "*/node_modules/*" \
            ! -path "*/.git/*" \
            ! -path "*/logs/*" \
            -type f | head -1 | grep -q . 2>/dev/null; then
            project_folders+=("$folder")
        fi
        
    done < <(find "$target_path" -maxdepth 1 -type d ! -path "$target_path" -print0 2>/dev/null)
    
    printf '%s\n' "${project_folders[@]}"
}

bytes_to_human() {
    local bytes=$1
    if [[ $bytes -gt 1048576 ]]; then
        echo "$(( bytes / 1048576 ))MB"
    elif [[ $bytes -gt 1024 ]]; then
        echo "$(( bytes / 1024 ))KB"
    else
        echo "${bytes}B"
    fi
}

send_telegram_message() {
    local message="$1"
    local retry_count=0
    
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        local response=$(curl -s --max-time "$API_TIMEOUT" \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="${message}" \
            -d parse_mode="HTML" 2>/dev/null)
        
        if [[ $response == *"\"ok\":true"* ]]; then
            return 0
        fi
        
        ((retry_count++))
        sleep 2
    done
    return 1
}

send_telegram_file() {
    local file_path="$1"
    local caption="$2"
    local retry_count=0
    
    if [[ ! -f "$file_path" ]]; then
        return 1
    fi
    
    local file_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    if [[ $file_size -gt $MAX_BACKUP_SIZE ]]; then
        print_error "File too large: $(bytes_to_human $file_size)"
        return 1
    fi
    
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        local response=$(curl -s --max-time "$UPLOAD_TIMEOUT" \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
            -F chat_id="${TELEGRAM_CHAT_ID}" \
            -F document=@"${file_path}" \
            -F caption="${caption}" 2>/dev/null)
        
        if [[ $response == *"\"ok\":true"* ]]; then
            return 0
        fi
        
        ((retry_count++))
        sleep 3
    done
    return 1
}

create_project_backup() {
    local project_folder="$1"
    local backup_path="$2"
    
    zip -9 -q -r "$backup_path" "$project_folder" \
        -i '*.env' '*.txt' '*.py' '*.js' 'package.json' \
        -x "*/node_modules/*" \
        -x "*/logs/*" \
        -x "*/log/*" \
        -x "*/cache/*" \
        -x "*/build/*" \
        -x "*/dist/*" \
        -x "*/temp/*" \
        -x "*/tmp/*" \
        -x "*/.git/*" \
        -x "*/.cache/*" \
        -x "*/__pycache__/*" \
        -x "*/.next/*" \
        -x "*/coverage/*" \
        -x "*/.vscode/*" \
        -x "*/.DS_Store" \
        >> "$LOG_FILE" 2>&1
    
    return $?
}

run_per_project_backup() {
    local start_time=$(date +%s)
    
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            print_error "Backup already running (PID: $pid)"
            return 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration not found! Run: $0 --setup"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    source "$CONFIG_FILE"
    log_message "=== PER PROJECT BACKUP STARTED ==="
    
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    if [[ ! -d "$backup_target" ]]; then
        print_error "Target directory not found: $backup_target"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    local project_folders=($(detect_project_folders "$backup_target"))
    local total_projects=${#project_folders[@]}
    
    if [[ $total_projects -eq 0 ]]; then
        print_warning "No project folders found"
        send_telegram_message "⚠️ No projects found in $backup_target"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    mkdir -p "$BACKUP_DIR"
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unknown")
    local date_stamp=$(date '+%d%m%Y')
    
    send_telegram_message "🔄 <b>Backup Started</b>
☁️ ${provider}
📁 ${total_projects} projects
📅 $(date '+%H:%M')"
    
    local success_count=0
    local fail_count=0
    
    for project_folder in "${project_folders[@]}"; do
        local project_name=$(basename "$project_folder")
        local backup_filename="BACKUP-${project_name}_${ip_server}_${date_stamp}.zip"
        local backup_full_path="${BACKUP_DIR}/${backup_filename}"
        
        print_info "Backing up project: $project_name"
        log_message "Creating backup for project: $project_name"
        
        send_telegram_message "🔄 ${project_name} backup start
📂 ${project_folder}"
        
        if create_project_backup "$project_folder" "$backup_full_path"; then
            if [[ -f "$backup_full_path" ]]; then
                local file_size_bytes=$(stat -c%s "$backup_full_path" 2>/dev/null || stat -f%z "$backup_full_path" 2>/dev/null)
                local file_size=$(bytes_to_human $file_size_bytes)
                
                if [[ $file_size_bytes -lt 100 ]]; then
                    print_warning "Backup too small for $project_name: $file_size"
                    send_telegram_message "⚠️ ${project_name} backup empty"
                    rm -f "$backup_full_path"
                    ((fail_count++))
                    continue
                fi
                
                if send_telegram_file "$backup_full_path" "✅ ${project_name} backup complete
📏 Size: ${file_size}"; then
                    print_success "Uploaded: $project_name ($file_size)"
                    log_message "Successfully backed up and uploaded: $project_name ($file_size)"
                    ((success_count++))
                else
                    print_error "Upload failed for $project_name"
                    send_telegram_message "❌ ${project_name} upload failed"
                    ((fail_count++))
                fi
                
                rm -f "$backup_full_path"
            else
                print_error "Backup file not created for $project_name"
                send_telegram_message "❌ ${project_name} backup failed"
                ((fail_count++))
            fi
        else
            print_error "Backup creation failed for $project_name"
            send_telegram_message "❌ ${project_name} backup failed"
            ((fail_count++))
        fi
        
        sleep 2
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    send_telegram_message "📊 <b>Backup Summary</b>
✅ Success: ${success_count}
❌ Failed: ${fail_count}
⏱️ Duration: ${duration}s
📅 $(date '+%Y-%m-%d %H:%M')"
    
    rm -f "$LOCK_FILE"
    log_message "=== PER PROJECT BACKUP COMPLETED ==="
    log_message "Summary: $success_count success, $fail_count failed, ${duration}s duration"
}

setup_per_project_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     PER PROJECT BACKUP TELEGRAM     ║${NC}"
    echo -e "${CYAN}║        Simple & Clean Version       ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    print_info "Detecting project folders..."
    local project_folders=($(detect_project_folders "$backup_target"))
    local total_projects=${#project_folders[@]}
    
    echo "📁 Project folders detected:"
    if [[ $total_projects -eq 0 ]]; then
        echo "  • No project folders found"
    else
        for folder in "${project_folders[@]}"; do
            local folder_name=$(basename "$folder")
            echo "  • $folder_name"
        done
    fi
    echo
    
    print_success "Per Project Backup Detection:"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  ☁️ Cloud Provider: $provider"
    echo "  📂 Target Path: $backup_target"
    echo "  📁 Project Folders: $total_projects"
    echo "  📦 Backup Mode: One ZIP per project"
    echo "  📏 File Types: .env, .txt, .py, .js, package.json"
    echo "  🚫 Excludes: node_modules, logs, cache, build, temp"
    echo "  📝 Naming: BACKUP-PROJECTNAME_IP_DDMMYYYY.zip"
    echo
    
    if [[ $total_projects -eq 0 ]]; then
        print_warning "No project folders found"
        return 1
    fi
    
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$BACKUP_DIR"
    
    echo -e "${YELLOW}Telegram Configuration:${NC}"
    echo
    
    read -p "🤖 Bot Token: " bot_token
    read -p "💬 Chat ID: " chat_id
    read -p "⏰ Interval (hours) [24]: " interval
    interval=${interval:-24}
    
    cat > "$CONFIG_FILE" << EOF
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
BACKUP_INTERVAL="$interval"
CLOUD_PROVIDER="$provider"
BACKUP_TARGET="$backup_target"
TOTAL_PROJECTS="$total_projects"
CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_success "Configuration saved!"
    
    local cron_schedule="0 3 * * *"
    case $interval in
        1) cron_schedule="0 * * * *" ;;
        2) cron_schedule="0 */2 * * *" ;;
        3) cron_schedule="0 */3 * * *" ;;
        6) cron_schedule="0 */6 * * *" ;;
        12) cron_schedule="0 */12 * * *" ;;
        24) cron_schedule="0 3 * * *" ;;
    esac
    
    crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME" | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "$cron_schedule $0 --backup >/dev/null 2>&1") | crontab -
    print_success "Crontab configured"
    
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    if send_telegram_message "🎉 <b>Per Project Backup Setup</b>
☁️ ${provider}
📁 ${total_projects} projects
📦 One ZIP per project
✅ Ready!"; then
        print_success "Setup completed!"
        echo
        echo -e "${GREEN}Per project backup system ready!${NC}"
        echo -e "  📁 Projects: ${BLUE}$total_projects${NC}"
        echo -e "  📦 Mode: ${BLUE}One ZIP per project${NC}"
        echo -e "  📝 Format: ${BLUE}BACKUP-PROJECTNAME_IP_DDMMYYYY.zip${NC}"
    else
        print_error "Setup failed!"
    fi
}

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     PER PROJECT BACKUP TELEGRAM     ║${NC}"
    echo -e "${CYAN}║        Simple & Clean Version       ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Per Project Features:${NC}"
    echo -e "  📦 ${BLUE}One ZIP per project${NC} - no size limit issues"
    echo -e "  📝 ${BLUE}Simple naming${NC} - BACKUP-PROJECTNAME_IP_DDMMYYYY.zip"
    echo -e "  💬 ${BLUE}Clean messages${NC} - short and clear"
    echo -e "  🎯 ${BLUE}Project detection${NC} - auto-find project folders"
    echo -e "  🚫 ${BLUE}Smart excludes${NC} - skip node_modules, logs, cache"
    echo -e "  📊 ${BLUE}Summary report${NC} - success/fail count"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  ${BLUE}--setup${NC}       Setup per project backup"
    echo -e "  ${BLUE}--backup${NC}      Run per project backup"
    echo -e "  ${BLUE}--help${NC}        Show help"
}

main() {
    case "${1:-}" in
        --setup) setup_per_project_backup ;;
        --backup) run_per_project_backup ;;
        --help) show_help ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                run_per_project_backup
            else
                print_info "Per Project Backup Telegram VPS - Version $SCRIPT_VERSION"
                echo
                read -p "Setup per project backup now? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    setup_per_project_backup
                else
                    show_help
                fi
            fi
            ;;
    esac
}

main "$@"
