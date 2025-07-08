#!/bin/bash

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

readonly SCRIPT_VERSION="8.1"
readonly SCRIPT_NAME="backup_telegram"
readonly MAX_PROJECT_SIZE=52428800  # 50MB per project
readonly API_TIMEOUT=30
readonly UPLOAD_TIMEOUT=300
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
    echo "${timestamp} | ${message}" >> "$LOG_FILE"
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
        
        # Skip system folders
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
        
        # Check if folder contains project files
        if find "$folder" -maxdepth 3 \( -name "*.env" -o -name "package.json" -o -name "*.py" -o -name "*.js" -o -name "*.txt" \) \
            ! -path "*/node_modules/*" \
            ! -path "*/.local/*" \
            ! -path "*/.rustup/*" \
            ! -path "*/.cargo/*" \
            ! -path "*/go/*" \
            ! -path "*/.ipynb_checkpoints/*" \
            ! -path "*/__pycache__/*" \
            ! -path "*/.cache/*" \
            ! -path "*/.git/*" \
            ! -path "*/logs/*" \
            ! -path "/logs/*" \
            ! -path "*/build/*" \
            ! -path "*/dist/*" \
            ! -path "*/temp/*" \
            ! -path "*/tmp/*" \
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
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            sleep 2
        fi
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
    if [[ $file_size -gt 52428800 ]]; then
        log_message "File too large: $(bytes_to_human $file_size)"
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
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            sleep 3
        fi
    done
    
    return 1
}

backup_single_project() {
    local project_folder="$1"
    local project_name=$(basename "$project_folder")
    
    # Get server IP
    local ip_server=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")
    
    # Generate filename
    local timestamp=$(date '+%d%m%Y')
    local backup_filename="BACKUP-${project_name}_${ip_server}_${timestamp}.zip"
    local backup_path="${BACKUP_DIR}/${backup_filename}"
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    # Create ZIP for this project only
    if zip -r "$backup_path" "$project_folder" \
        -i '*.env' '*.txt' '*.py' '*.js' 'package.json' \
        -x "*/node_modules/*" \
        -x "*/.local/*" \
        -x "*/.rustup/*" \
        -x "*/.cargo/*" \
        -x "*/go/*" \
        -x "*/.ipynb_checkpoints/*" \
        -x "*/__pycache__/*" \
        -x "*/.cache/*" \
        -x "*/.npm/*" \
        -x "*/.yarn/*" \
        -x "*/.git/*" \
        -x "*/dist/*" \
        -x "*/build/*" \
        -x "*/.next/*" \
        -x "*/coverage/*" \
        -x "*/logs/*" \
        -x "/logs/*" \
        -x "*/tmp/*" \
        -x "*/temp/*" \
        -x "*/.DS_Store" \
        >> "$LOG_FILE" 2>&1; then
        
        # Check if file was created and has reasonable size
        if [[ -f "$backup_path" ]]; then
            local file_size=$(stat -c%s "$backup_path" 2>/dev/null || stat -f%z "$backup_path" 2>/dev/null)
            local human_size=$(bytes_to_human $file_size)
            
            if [[ $file_size -lt 100 ]]; then
                log_message "Project $project_name: backup too small ($human_size)"
                rm -f "$backup_path"
                return 1
            fi
            
            if [[ $file_size -gt $MAX_PROJECT_SIZE ]]; then
                log_message "Project $project_name: backup too large ($human_size)"
                rm -f "$backup_path"
                return 1
            fi
            
            # Upload to Telegram
            local caption="📦 <b>Project Backup</b>
📁 <b>Project:</b> ${project_name}
📏 <b>Size:</b> ${human_size}
📅 <b>Date:</b> $(date '+%d/%m/%Y %H:%M')
✅ <b>Status:</b> Complete"
            
            if send_telegram_file "$backup_path" "$caption"; then
                log_message "Project $project_name: uploaded successfully ($human_size)"
                rm -f "$backup_path"
                return 0
            else
                log_message "Project $project_name: upload failed"
                rm -f "$backup_path"
                return 1
            fi
        else
            log_message "Project $project_name: backup file not created"
            return 1
        fi
    else
        log_message "Project $project_name: ZIP creation failed"
        return 1
    fi
}

run_per_project_backup() {
    local start_time=$(date +%s)
    
    print_info "Starting per project backup..."
    log_message "=== PER PROJECT BACKUP STARTED ==="
    
    # Lock mechanism
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            print_error "Backup already running (PID: $pid)"
            return 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    
    # Load configuration
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration not found! Run: $0 --setup"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    source "$CONFIG_FILE"
    
    # Detect provider and path
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    if [[ ! -d "$backup_target" ]]; then
        print_error "Target directory not found: $backup_target"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Get project folders
    local project_folders=($(detect_project_folders "$backup_target"))
    local total_projects=${#project_folders[@]}
    
    if [[ $total_projects -eq 0 ]]; then
        print_warning "No project folders found"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    log_message "Found $total_projects projects to backup"
    
    # Send start notification
    send_telegram_message "🚀 <b>Per Project Backup Started</b>
☁️ <b>Provider:</b> ${provider}
📁 <b>Projects:</b> ${total_projects}
⏰ <b>Started:</b> $(date '+%H:%M:%S')"
    
    # Backup each project individually
    local success_count=0
    local failed_count=0
    local current=0
    
    for project_folder in "${project_folders[@]}"; do
        ((current++))
        local project_name=$(basename "$project_folder")
        
        print_info "Backing up project $current/$total_projects: $project_name"
        log_message "Starting backup for project: $project_name ($current/$total_projects)"
        
        # Backup this project (with error handling that doesn't stop the loop)
        if backup_single_project "$project_folder"; then
            print_success "Uploaded: $project_name"
            ((success_count++))
        else
            print_warning "Failed: $project_name"
            ((failed_count++))
        fi
        
        # Small delay between projects to avoid rate limiting
        sleep 2
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Send completion summary
    local summary_message="✅ <b>Per Project Backup Complete</b>

📊 <b>Summary:</b>
• Total Projects: ${total_projects}
• Successful: ${success_count}
• Failed: ${failed_count}
• Duration: ${duration}s

⏰ <b>Completed:</b> $(date '+%H:%M:%S')"
    
    send_telegram_message "$summary_message"
    
    log_message "Backup completed: $success_count success, $failed_count failed, ${duration}s"
    log_message "=== PER PROJECT BACKUP COMPLETED ==="
    
    # Cleanup
    rm -f "$LOCK_FILE"
    
    if [[ $success_count -gt 0 ]]; then
        print_success "Backup completed: $success_count/$total_projects projects uploaded"
        return 0
    else
        print_error "All backups failed"
        return 1
    fi
}

setup_per_project_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     PER PROJECT BACKUP TELEGRAM     ║${NC}"
    echo -e "${CYAN}║        Simple & Clean Version       ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Detect provider and path
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    # Detect project folders
    print_info "Detecting project folders..."
    local project_folders=($(detect_project_folders "$backup_target"))
    
    echo "📁 Project folders detected:"
    if [[ ${#project_folders[@]} -eq 0 ]]; then
        echo "  • No project folders found"
        return 1
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
    echo "  📁 Project Folders: ${#project_folders[@]}"
    echo "  📦 Backup Mode: One ZIP per project"
    echo "  📏 File Types: .env, .txt, .py, .js, package.json"
    echo "  🚫 Excludes: node_modules, logs, cache, build, temp"
    echo "  📝 Naming: BACKUP-PROJECTNAME_IP_DDMMYYYY.zip"
    echo
    
    # Create directories
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$BACKUP_DIR"
    
    # Input configuration
    echo "Telegram Configuration:"
    echo
    
    read -p "🤖 Bot Token: " bot_token
    read -p "💬 Chat ID: " chat_id
    read -p "⏰ Interval (hours) [24]: " interval
    interval=${interval:-24}
    
    # Save configuration
    cat > "$CONFIG_FILE" << EOF
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
BACKUP_INTERVAL="$interval"
CLOUD_PROVIDER="$provider"
BACKUP_TARGET="$backup_target"
PROJECT_COUNT="${#project_folders[@]}"
CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
SCRIPT_VERSION="$SCRIPT_VERSION"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_success "Configuration saved!"
    
    # Setup crontab
    local cron_schedule="0 2 * * *"  # Default: daily at 2 AM
    case $interval in
        1) cron_schedule="0 * * * *" ;;
        2) cron_schedule="0 */2 * * *" ;;
        3) cron_schedule="0 */3 * * *" ;;
        6) cron_schedule="0 */6 * * *" ;;
        12) cron_schedule="0 */12 * * *" ;;
        24) cron_schedule="0 2 * * *" ;;
    esac
    
    crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME" | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "$cron_schedule $0 --backup >/dev/null 2>&1") | crontab -
    print_success "Crontab configured"
    
    # Test connection
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    if send_telegram_message "🎉 <b>Per Project Backup Setup</b>
☁️ Provider: ${provider}
📁 Projects: ${#project_folders[@]}
📦 Mode: One ZIP per project
⏰ Interval: ${interval}h
✅ Ready!"; then
        print_success "Setup completed!"
        echo
        echo "Per project backup system ready!"
        echo "  📁 Projects: ${#project_folders[@]}"
        echo "  📦 Mode: One ZIP per project"
        echo "  📝 Format: BACKUP-PROJECTNAME_IP_DDMMYYYY.zip"
    else
        print_error "Setup failed! Check Telegram configuration."
        return 1
    fi
}

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     PER PROJECT BACKUP TELEGRAM     ║${NC}"
    echo -e "${CYAN}║        Simple & Clean Version       ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Features:${NC}"
    echo -e "  📦 ${BLUE}One ZIP per project${NC} - Individual project backups"
    echo -e "  📝 ${BLUE}Clean naming${NC} - BACKUP-PROJECTNAME_IP_DDMMYYYY.zip"
    echo -e "  🔄 ${BLUE}Robust loop${NC} - Continues even if one project fails"
    echo -e "  📊 ${BLUE}Progress tracking${NC} - Shows current project being backed up"
    echo -e "  ✅ ${BLUE}Summary report${NC} - Success/failure count at the end"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  ${BLUE}--setup${NC}       Setup per project backup"
    echo -e "  ${BLUE}--backup${NC}      Run per project backup"
    echo -e "  ${BLUE}--help${NC}        Show this help"
}

main() {
    case "${1:-}" in
        --setup)
            setup_per_project_backup
            ;;
        --backup)
            run_per_project_backup
            ;;
        --help)
            show_help
            ;;
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
