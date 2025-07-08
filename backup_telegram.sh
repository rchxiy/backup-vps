#!/bin/bash

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

readonly SCRIPT_VERSION="6.2"
readonly SCRIPT_NAME="backup_telegram"
readonly MAX_BACKUP_SIZE=314572800  # 300MB per file
readonly API_TIMEOUT=30
readonly UPLOAD_TIMEOUT=600
readonly MAX_RETRIES=5

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
    
    if [[ -f "$LOG_FILE" ]]; then
        local log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ $log_size -gt 10485760 ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.old"
            gzip "${LOG_FILE}.old" 2>/dev/null || true
        fi
    fi
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
        
        local has_project_files=false
        if find "$folder" -maxdepth 2 \( -name "*.env" -o -name "package.json" -o -name "*.py" -o -name "*.js" \) \
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
            ! -path "*/dist/*" \
            ! -path "*/build/*" \
            ! -path "*/.next/*" \
            ! -path "*/coverage/*" \
            -type f | head -1 | grep -q . 2>/dev/null; then
            has_project_files=true
        fi
        
        if [[ "$has_project_files" == "true" ]]; then
            project_folders+=("$folder")
        fi
        
    done < <(find "$target_path" -maxdepth 1 -type d ! -path "$target_path" -print0 2>/dev/null)
    
    printf '%s\n' "${project_folders[@]}"
}

count_files_in_folder() {
    local folder="$1"
    
    find "$folder" \( -name "*.env" -o -name "*.txt" -o -name "*.py" -o -name "*.js" -o -name "package.json" \) -type f \
        ! -path "*/node_modules/*" \
        ! -path "*/.local/*" \
        ! -path "*/.rustup/*" \
        ! -path "*/.cargo/*" \
        ! -path "*/go/*" \
        ! -path "*/.ipynb_checkpoints/*" \
        ! -path "*/__pycache__/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.npm/*" \
        ! -path "*/.yarn/*" \
        ! -path "*/.git/*" \
        ! -path "*/dist/*" \
        ! -path "*/build/*" \
        ! -path "*/.next/*" \
        ! -path "*/coverage/*" \
        ! -path "*/logs/*" \
        ! -path "/logs/*" \
        ! -path "*/tmp/*" \
        ! -path "*/temp/*" \
        ! -path "*/public/*" \
        ! -path "*/assets/*" \
        ! -path "*/static/*" \
        2>/dev/null | wc -l
}

calculate_folder_size() {
    local folder="$1"
    
    find "$folder" \( -name "*.env" -o -name "*.txt" -o -name "*.py" -o -name "*.js" -o -name "package.json" \) -type f \
        ! -path "*/node_modules/*" \
        ! -path "*/.local/*" \
        ! -path "*/.rustup/*" \
        ! -path "*/.cargo/*" \
        ! -path "*/go/*" \
        ! -path "*/.ipynb_checkpoints/*" \
        ! -path "*/__pycache__/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.npm/*" \
        ! -path "*/.yarn/*" \
        ! -path "*/.git/*" \
        ! -path "*/dist/*" \
        ! -path "*/build/*" \
        ! -path "*/.next/*" \
        ! -path "*/coverage/*" \
        ! -path "*/logs/*" \
        ! -path "/logs/*" \
        ! -path "*/tmp/*" \
        ! -path "*/temp/*" \
        ! -path "*/public/*" \
        ! -path "*/assets/*" \
        ! -path "*/static/*" \
        -printf "%s\n" 2>/dev/null | \
        awk '{sum += $1} END {print sum+0}' 2>/dev/null || echo 0
}

bytes_to_human() {
    local bytes=$1
    
    if [[ $bytes -gt 1073741824 ]]; then
        echo "$(( bytes / 1073741824 ))GB"
    elif [[ $bytes -gt 1048576 ]]; then
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
    if [[ $file_size -gt 52428800 ]]; then
        print_error "File too large for Telegram: $(bytes_to_human $file_size)"
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
        sleep 5
    done
    
    return 1
}

create_individual_backup() {
    local project_folder="$1"
    local backup_path="$2"
    local folder_name=$(basename "$project_folder")
    
    print_info "Creating ZIP for project: $folder_name"
    
    zip -r "$backup_path" "$project_folder" \
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
        -x "*/public/*" \
        -x "*/assets/*" \
        -x "*/static/*" \
        -x "*/.DS_Store" \
        -x "*/.gitignore" \
        >> "$LOG_FILE" 2>&1
    
    return $?
}

run_individual_backup() {
    local start_time=$(date +%s)
    
    print_info "Starting individual backup process..."
    log_message "Individual backup started"
    
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
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration not found! Run: $0 --setup"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    source "$CONFIG_FILE"
    
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    if [[ ! -d "$backup_target" ]]; then
        print_error "Target directory not found: $backup_target"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    print_info "Scanning project folders..."
    local project_folders=($(detect_project_folders "$backup_target"))
    local project_count=${#project_folders[@]}
    
    if [[ $project_count -eq 0 ]]; then
        print_warning "No project folders found"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    log_message "Found $project_count project folders for individual backup"
    
    # Kirim notifikasi awal
    send_telegram_message "🔄 <b>Individual Backup Started</b>
☁️ ${provider}
📁 ${project_count} projects
🎯 Mode: Individual ZIP files
⏰ $(date '+%H:%M:%S')"
    
    mkdir -p "$BACKUP_DIR"
    
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unknown")
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    
    local successful_uploads=0
    local failed_uploads=0
    local total_size=0
    local total_files=0
    
    # Loop untuk setiap project folder
    for project_folder in "${project_folders[@]}"; do
        local folder_name=$(basename "$project_folder")
        local file_count=$(count_files_in_folder "$project_folder")
        local folder_size=$(calculate_folder_size "$project_folder")
        
        if [[ $file_count -eq 0 ]]; then
            print_warning "Skipping $folder_name (no files)"
            continue
        fi
        
        if [[ $folder_size -gt $MAX_BACKUP_SIZE ]]; then
            print_warning "Skipping $folder_name (too large: $(bytes_to_human $folder_size))"
            ((failed_uploads++))
            continue
        fi
        
        # Generate nama file untuk project ini
        local backup_filename="${folder_name}-${ip_server}-${timestamp}.zip"
        local backup_full_path="${BACKUP_DIR}/${backup_filename}"
        
        print_info "Processing: $folder_name ($file_count files)"
        
        # Buat ZIP untuk project ini
        if create_individual_backup "$project_folder" "$backup_full_path"; then
            if [[ -f "$backup_full_path" ]]; then
                local file_size_bytes=$(stat -c%s "$backup_full_path" 2>/dev/null || stat -f%z "$backup_full_path" 2>/dev/null)
                local file_size=$(bytes_to_human $file_size_bytes)
                
                if [[ $file_size_bytes -lt 100 ]]; then
                    print_warning "Skipping $folder_name (file too small: $file_size)"
                    rm -f "$backup_full_path"
                    ((failed_uploads++))
                    continue
                fi
                
                print_success "Created: $backup_filename ($file_size)"
                log_message "Created ZIP: $backup_filename ($file_size, $file_count files)"
                
                # Upload individual file ke Telegram
                local caption="📦 <b>Project: ${folder_name}</b>
☁️ ${provider}
📊 ${file_count} files
📏 ${file_size}
⏰ $(date '+%H:%M:%S')"
                
                if send_telegram_file "$backup_full_path" "$caption"; then
                    print_success "Uploaded: $folder_name"
                    log_message "Uploaded: $backup_filename"
                    ((successful_uploads++))
                    total_size=$((total_size + file_size_bytes))
                    total_files=$((total_files + file_count))
                else
                    print_error "Upload failed: $folder_name"
                    log_message "Upload failed: $backup_filename"
                    ((failed_uploads++))
                fi
                
                # Hapus file setelah upload
                rm -f "$backup_full_path"
                
            else
                print_error "Backup file not created for: $folder_name"
                ((failed_uploads++))
            fi
        else
            print_error "Backup creation failed for: $folder_name"
            ((failed_uploads++))
        fi
        
        # Small delay between uploads
        sleep 2
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local total_size_human=$(bytes_to_human $total_size)
    
    # Kirim summary
    local summary_message="✅ <b>Individual Backup Complete</b>
☁️ ${provider}
📊 Results:
• ✅ Successful: ${successful_uploads}
• ❌ Failed: ${failed_uploads}
• 📁 Total files: ${total_files}
• 📏 Total size: ${total_size_human}
⏱️ Duration: ${duration}s
⏰ Completed: $(date '+%H:%M:%S')"
    
    send_telegram_message "$summary_message"
    
    print_success "Individual backup completed!"
    print_info "Results: $successful_uploads successful, $failed_uploads failed"
    log_message "Individual backup completed: $successful_uploads successful, $failed_uploads failed"
    
    rm -f "$LOCK_FILE"
}

setup_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   INDIVIDUAL PROJECT BACKUP VPS     ║${NC}"
    echo -e "${CYAN}║      One ZIP per Project v$SCRIPT_VERSION       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    print_info "Scanning project folders..."
    local project_folders=($(detect_project_folders "$backup_target"))
    
    echo "📁 Project folders found:"
    if [[ ${#project_folders[@]} -eq 0 ]]; then
        echo "  • No project folders found"
    else
        local total_files=0
        local total_size=0
        
        for folder in "${project_folders[@]}"; do
            local folder_name=$(basename "$folder")
            local file_count=$(count_files_in_folder "$folder")
            local folder_size=$(calculate_folder_size "$folder")
            local size_human=$(bytes_to_human $folder_size)
            
            echo "  • $folder_name ($file_count files, $size_human)"
            total_files=$((total_files + file_count))
            total_size=$((total_size + folder_size))
        done
        
        echo
        print_success "Summary:"
        echo "  📁 Projects: ${#project_folders[@]}"
        echo "  📊 Total files: $total_files"
        echo "  📏 Total size: $(bytes_to_human $total_size)"
        echo "  🎯 Mode: Individual ZIP per project"
    fi
    echo
    
    if [[ ${#project_folders[@]} -eq 0 ]]; then
        print_warning "No project folders found"
        return 1
    fi
    
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$BACKUP_DIR"
    
    echo -e "${YELLOW}Telegram Configuration:${NC}"
    read -p "🤖 Bot Token: " bot_token
    read -p "💬 Chat ID: " chat_id
    read -p "⏰ Interval (hours) [1]: " interval
    interval=${interval:-1}
    
    cat > "$CONFIG_FILE" << EOF
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
BACKUP_INTERVAL="$interval"

CLOUD_PROVIDER="$provider"
BACKUP_TARGET="$backup_target"
PROJECT_COUNT="${#project_folders[@]}"

CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_success "Configuration saved"
    
    local cron_schedule="0 * * * *"
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
    
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    if send_telegram_message "🎉 <b>Individual Backup Setup</b>
☁️ ${provider}
📁 ${#project_folders[@]} projects
🎯 Mode: Individual ZIP files
⏰ Every ${interval}h"; then
        print_success "Setup completed successfully!"
        echo
        echo -e "${GREEN}System ready for individual backups!${NC}"
        echo -e "  📁 Projects: ${#project_folders[@]}"
        echo -e "  🎯 Mode: One ZIP per project"
        echo -e "  📤 Upload: Individual files"
    else
        print_error "Setup failed - check Telegram configuration"
        return 1
    fi
}

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   INDIVIDUAL PROJECT BACKUP VPS     ║${NC}"
    echo -e "${CYAN}║      One ZIP per Project v$SCRIPT_VERSION       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Features:${NC}"
    echo -e "  📁 Individual ZIP per project"
    echo -e "  📤 Upload one by one to Telegram"
    echo -e "  🚫 Comprehensive excludes"
    echo -e "  📱 Clean progress messages"
    echo -e "  📝 Simple logging"
    echo
    echo -e "${GREEN}How it works:${NC}"
    echo -e "  1. Scan project folders"
    echo -e "  2. Create individual ZIP for each project"
    echo -e "  3. Upload each ZIP separately to Telegram"
    echo -e "  4. Clean up temporary files"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  --setup       Setup individual backup system"
    echo -e "  --backup      Run individual backup"
    echo -e "  --help        Show help"
}

main() {
    case "${1:-}" in
        --setup) setup_backup ;;
        --backup) run_individual_backup ;;
        --help) show_help ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                run_individual_backup
            else
                print_info "Individual Project Backup v$SCRIPT_VERSION"
                echo
                read -p "Setup individual backup system now? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    setup_backup
                else
                    show_help
                fi
            fi
            ;;
    esac
}

main "$@"
