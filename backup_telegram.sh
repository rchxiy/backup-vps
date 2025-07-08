#!/bin/bash

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

readonly SCRIPT_NAME="backup_telegram"
readonly MAX_BACKUP_SIZE=304857600
readonly API_TIMEOUT=30
readonly UPLOAD_TIMEOUT=1200
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
    local level="${2:-INFO}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "${timestamp} | ${level:0:4} | ${message}" >> "$LOG_FILE"
    
    if [[ -f "$LOG_FILE" ]]; then
        local log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ $log_size -gt 10485760 ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d).old"
            gzip "${LOG_FILE}.$(date +%Y%m%d).old" 2>/dev/null || true
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
        if find "$folder" -maxdepth 3 \( -name "*.env" -o -name "package.json" -o -name "*.py" -o -name "*.js" \) \
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
            -type f | head -1 | grep -q . 2>/dev/null; then
            has_project_files=true
        fi
        
        if [[ "$has_project_files" == "true" ]]; then
            project_folders+=("$folder")
        fi
        
    done < <(find "$target_path" -maxdepth 1 -type d ! -path "$target_path" -print0 2>/dev/null)
    
    printf '%s\n' "${project_folders[@]}"
}

count_files_with_excludes() {
    local folder="$1"
    local pattern="$2"
    
    find "$folder" -name "$pattern" -type f \
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
        2>/dev/null | wc -l
}

scan_project_files() {
    local target_path="$1"
    local project_folders=($(detect_project_folders "$target_path"))
    
    local env_count=0
    local txt_count=0
    local py_count=0
    local js_count=0
    local json_count=0
    
    for folder in "${project_folders[@]}"; do
        env_count=$((env_count + $(count_files_with_excludes "$folder" "*.env")))
        txt_count=$((txt_count + $(count_files_with_excludes "$folder" "*.txt")))
        py_count=$((py_count + $(count_files_with_excludes "$folder" "*.py")))
        js_count=$((js_count + $(count_files_with_excludes "$folder" "*.js")))
        json_count=$((json_count + $(count_files_with_excludes "$folder" "package.json")))
    done
    
    local total_files=$((env_count + txt_count + py_count + js_count + json_count))
    
    echo "$total_files|$env_count|$txt_count|$py_count|$js_count|$json_count|${#project_folders[@]}"
}

calculate_project_size() {
    local target_path="$1"
    local project_folders=($(detect_project_folders "$target_path"))
    local total_size=0
    
    for folder in "${project_folders[@]}"; do
        for ext in "*.env" "*.txt" "*.py" "*.js" "package.json"; do
            local size=$(find "$folder" -name "$ext" -type f \
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
                -printf "%s\n" 2>/dev/null | \
                awk '{sum += $1} END {print sum+0}' 2>/dev/null || echo 0)
            total_size=$((total_size + size))
        done
    done
    
    echo $total_size
}

list_project_folders() {
    local target_path="$1"
    local project_folders=($(detect_project_folders "$target_path"))
    
    echo "📁 Project folders:"
    if [[ ${#project_folders[@]} -eq 0 ]]; then
        echo "  • No project folders found"
    else
        for folder in "${project_folders[@]}"; do
            local folder_name=$(basename "$folder")
            local file_count=0
            for ext in "*.env" "*.txt" "*.py" "*.js" "package.json"; do
                local count=$(count_files_with_excludes "$folder" "$ext")
                file_count=$((file_count + count))
            done
            echo "  • $folder_name ($file_count files)"
        done
    fi
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
            log_message "Telegram message sent" "SUCC"
            return 0
        fi
        
        ((retry_count++))
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            sleep 2
        fi
    done
    
    log_message "Failed to send Telegram message" "ERRO"
    return 1
}

send_telegram_file() {
    local file_path="$1"
    local caption="$2"
    local retry_count=0
    
    if [[ ! -f "$file_path" ]]; then
        log_message "File not found: $file_path" "ERRO"
        return 1
    fi
    
    local file_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    if [[ $file_size -gt 52428800 ]]; then
        log_message "File too large: $(bytes_to_human $file_size)" "ERRO"
        return 1
    fi
    
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        local response=$(curl -s --max-time "$UPLOAD_TIMEOUT" \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
            -F chat_id="${TELEGRAM_CHAT_ID}" \
            -F document=@"${file_path}" \
            -F caption="${caption}" 2>/dev/null)
        
        if [[ $response == *"\"ok\":true"* ]]; then
            log_message "File uploaded: $(basename "$file_path")" "SUCC"
            return 0
        fi
        
        ((retry_count++))
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            sleep 5
        fi
    done
    
    log_message "Failed to upload file" "ERRO"
    return 1
}

create_start_message() {
    local provider="$1"
    local backup_target="$2"
    local project_count="$3"
    local total_files="$4"
    local env_files="$5"
    local txt_files="$6"
    local py_files="$7"
    local js_files="$8"
    local json_files="$9"
    local estimated_size="${10}"
    
    cat << EOF
🔄 <b>Backup Started</b>

☁️ <b>Provider:</b> ${provider}
📂 <b>Path:</b> <code>${backup_target}</code>
📁 <b>Projects:</b> ${project_count}

📊 <b>Files:</b>
• .env: ${env_files}
• .txt: ${txt_files}
• .py: ${py_files}
• .js: ${js_files}
• package.json: ${json_files}

📈 <b>Total:</b> ${total_files} files
📏 <b>Size:</b> ${estimated_size}
⏰ <b>Time:</b> $(date '+%H:%M:%S')
EOF
}

create_success_message() {
    local provider="$1"
    local backup_target="$2"
    local project_count="$3"
    local total_files="$4"
    local env_files="$5"
    local txt_files="$6"
    local py_files="$7"
    local js_files="$8"
    local json_files="$9"
    local file_size="${10}"
    local duration="${11}"
    
    cat << EOF
✅ <b>Backup Complete</b>

☁️ <b>Provider:</b> ${provider}
📁 <b>Projects:</b> ${project_count}

📊 <b>Files:</b>
• .env: ${env_files}
• .txt: ${txt_files}
• .py: ${py_files}
• .js: ${js_files}
• package.json: ${json_files}

📈 <b>Total:</b> ${total_files} files
📏 <b>Size:</b> ${file_size}
⏱️ <b>Duration:</b> ${duration}s
⏰ <b>Time:</b> $(date '+%H:%M:%S')
EOF
}

create_error_message() {
    local error_type="$1"
    local details="$2"
    
    cat << EOF
❌ <b>Backup Failed</b>

🚨 <b>Error:</b> ${error_type}
📝 <b>Details:</b> ${details}
⏰ <b>Time:</b> $(date '+%H:%M:%S')
EOF
}

create_project_backup() {
    local backup_path="$1"
    local target_path="$2"
    local project_folders=($(detect_project_folders "$target_path"))
    
    if [[ ${#project_folders[@]} -eq 0 ]]; then
        log_message "No project folders found" "ERRO"
        return 1
    fi
    
    print_info "Creating ZIP from ${#project_folders[@]} project folders..."
    log_message "Creating ZIP with ${#project_folders[@]} folders" "INFO"
    
    local zip_args=()
    for folder in "${project_folders[@]}"; do
        zip_args+=("$folder")
    done
    
    zip -r "$backup_path" "${zip_args[@]}" \
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
        -x "*/.gitignore" \
        -x "*/.gitattributes" \
        >> "$LOG_FILE" 2>&1
    
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_message "ZIP created successfully" "SUCC"
    else
        log_message "ZIP creation failed: exit code $result" "ERRO"
    fi
    
    return $result
}

run_backup() {
    local start_time=$(date +%s)
    
    print_info "Starting backup process..."
    log_message "=== BACKUP STARTED ===" "INFO"
    
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            print_error "Backup already running (PID: $pid)"
            log_message "Backup already running: PID $pid" "ERRO"
            return 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration not found! Run: $0 --setup"
        log_message "Configuration file not found" "ERRO"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    source "$CONFIG_FILE"
    log_message "Configuration loaded" "INFO"
    
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    log_message "Provider: $provider, Target: $backup_target" "INFO"
    
    if [[ ! -d "$backup_target" ]]; then
        print_error "Target directory not found: $backup_target"
        log_message "Target not found: $backup_target" "ERRO"
        
        local error_msg=$(create_error_message "Target Not Found" "$backup_target does not exist")
        send_telegram_message "$error_msg"
        
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    print_info "Scanning project files..."
    local file_info=$(scan_project_files "$backup_target")
    local total_files=$(echo "$file_info" | cut -d'|' -f1)
    local env_files=$(echo "$file_info" | cut -d'|' -f2)
    local txt_files=$(echo "$file_info" | cut -d'|' -f3)
    local py_files=$(echo "$file_info" | cut -d'|' -f4)
    local js_files=$(echo "$file_info" | cut -d'|' -f5)
    local json_files=$(echo "$file_info" | cut -d'|' -f6)
    local project_count=$(echo "$file_info" | cut -d'|' -f7)
    
    local estimated_bytes=$(calculate_project_size "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    log_message "Found $project_count projects, $total_files files, $estimated_size" "INFO"
    
    if [[ $estimated_bytes -gt $MAX_BACKUP_SIZE ]]; then
        print_error "Backup size too large: $estimated_size"
        log_message "Size exceeds limit: $estimated_size" "ERRO"
        
        local error_msg=$(create_error_message "Size Too Large" "$estimated_size exceeds $(bytes_to_human $MAX_BACKUP_SIZE)")
        send_telegram_message "$error_msg"
        
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    if [[ $total_files -eq 0 ]]; then
        print_warning "No project files found"
        log_message "No project files found" "WARN"
        
        local error_msg=$(create_error_message "No Files Found" "No project files found in target directory")
        send_telegram_message "$error_msg"
        
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    local start_msg=$(create_start_message "$provider" "$backup_target" "$project_count" "$total_files" "$env_files" "$txt_files" "$py_files" "$js_files" "$json_files" "$estimated_size")
    send_telegram_message "$start_msg"
    
    mkdir -p "$BACKUP_DIR"
    log_message "Backup directory ready: $BACKUP_DIR" "INFO"
    
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unknown")
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local user_suffix=""
    
    if [[ "$backup_target" != "/root" ]]; then
        user_suffix="-$(basename "$backup_target")"
    fi
    
    local backup_filename="backup-projects-${ip_server}${user_suffix}-${timestamp}.zip"
    local backup_full_path="${BACKUP_DIR}/${backup_filename}"
    
    log_message "Creating: $backup_filename" "INFO"
    
    if create_project_backup "$backup_full_path" "$backup_target"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [[ -f "$backup_full_path" ]]; then
            local file_size_bytes=$(stat -c%s "$backup_full_path" 2>/dev/null || stat -f%z "$backup_full_path" 2>/dev/null)
            local file_size=$(bytes_to_human $file_size_bytes)
            
            if [[ $file_size_bytes -lt 100 ]]; then
                print_error "Backup file too small: $file_size"
                log_message "File too small: $file_size" "ERRO"
                
                local error_msg=$(create_error_message "File Too Small" "Generated file is only $file_size")
                send_telegram_message "$error_msg"
                
                rm -f "$backup_full_path"
                rm -f "$LOCK_FILE"
                return 1
            fi
            
            print_success "Backup created: $file_size"
            log_message "Backup created: $backup_filename ($file_size, ${duration}s)" "SUCC"
            
            local success_caption=$(create_success_message "$provider" "$backup_target" "$project_count" "$total_files" "$env_files" "$txt_files" "$py_files" "$js_files" "$json_files" "$file_size" "$duration")
            
            if send_telegram_file "$backup_full_path" "$success_caption"; then
                print_success "Upload completed"
                log_message "Upload completed successfully" "SUCC"
                
                send_telegram_message "🎉 <b>Backup Complete!</b> ${backup_filename} (${project_count} projects, ${total_files} files, ${file_size})"
                
                rm -f "$backup_full_path"
                log_message "Backup file cleaned up" "INFO"
                
            else
                print_error "Upload failed"
                log_message "Upload failed" "ERRO"
                
                local error_msg=$(create_error_message "Upload Failed" "Failed to upload $backup_filename")
                send_telegram_message "$error_msg"
            fi
            
        else
            print_error "Backup file not created"
            log_message "Backup file not created" "ERRO"
            
            local error_msg=$(create_error_message "File Creation Failed" "Backup file was not generated")
            send_telegram_message "$error_msg"
        fi
        
    else
        print_error "Backup creation failed"
        log_message "Backup creation failed" "ERRO"
        
        local error_msg=$(create_error_message "Backup Failed" "ZIP creation process failed")
        send_telegram_message "$error_msg"
    fi
    
    rm -f "$LOCK_FILE"
    log_message "=== BACKUP COMPLETED ===" "INFO"
}

setup_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     PROJECT BACKUP TELEGRAM VPS     ║${NC}"
    echo -e "${CYAN}║        Simple & Clean Version       ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    print_info "Detecting environment..."
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    print_info "Scanning project folders..."
    list_project_folders "$backup_target"
    echo
    
    local file_info=$(scan_project_files "$backup_target")
    local total_files=$(echo "$file_info" | cut -d'|' -f1)
    local env_files=$(echo "$file_info" | cut -d'|' -f2)
    local txt_files=$(echo "$file_info" | cut -d'|' -f3)
    local py_files=$(echo "$file_info" | cut -d'|' -f4)
    local js_files=$(echo "$file_info" | cut -d'|' -f5)
    local json_files=$(echo "$file_info" | cut -d'|' -f6)
    local project_count=$(echo "$file_info" | cut -d'|' -f7)
    
    local estimated_bytes=$(calculate_project_size "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    print_success "Detection Results:"
    echo "  👤 User: $CURRENT_USER"
    echo "  ☁️ Provider: $provider"
    echo "  📂 Target: $backup_target"
    echo "  📁 Projects: $project_count"
    echo
    echo "  📊 Files:"
    echo "    • .env: $env_files"
    echo "    • .txt: $txt_files"
    echo "    • .py: $py_files"
    echo "    • .js: $js_files"
    echo "    • package.json: $json_files"
    echo
    echo "  📋 Total: $total_files files"
    echo "  📏 Size: $estimated_size"
    echo "  🚫 Excludes: node_modules, .local, .cargo, .rustup, go, logs, cache"
    echo
    
    if [[ $total_files -eq 0 ]]; then
        print_warning "No project files found in $backup_target"
        return 1
    fi
    
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$BACKUP_DIR"
    
    echo -e "${YELLOW}Telegram Configuration:${NC}"
    echo
    
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
PROJECT_COUNT="$project_count"
TOTAL_FILES="$total_files"
ENV_FILES="$env_files"
TXT_FILES="$txt_files"
PY_FILES="$py_files"
JS_FILES="$js_files"
JSON_FILES="$json_files"
ESTIMATED_SIZE="$estimated_size"
CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
SCRIPT_VERSION="$SCRIPT_VERSION"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_success "Configuration saved!"
    log_message "Configuration saved" "SUCC"
    
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
    log_message "Crontab configured: $cron_schedule" "SUCC"
    
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    local setup_message=$(cat << EOF
🎉 <b>Setup Complete</b>

☁️ <b>Provider:</b> ${provider}
📂 <b>Path:</b> <code>${backup_target}</code>
📁 <b>Projects:</b> ${project_count}

📊 <b>Files:</b>
• .env: ${env_files}
• .txt: ${txt_files}
• .py: ${py_files}
• .js: ${js_files}
• package.json: ${json_files}

📈 <b>Total:</b> ${total_files} files
📏 <b>Size:</b> ${estimated_size}
⏰ <b>Interval:</b> ${interval}h

✅ <b>Ready for automatic backups!</b>
EOF
)
    
    if send_telegram_message "$setup_message"; then
        print_success "Setup completed!"
        log_message "Setup completed successfully" "SUCC"
        echo
        echo -e "${GREEN}System ready!${NC}"
        echo -e "  📁 Target: Project folders only"
        echo -e "  📊 Files: $total_files"
        echo -e "  📏 Size: $estimated_size"
        echo -e "  ⏰ Schedule: Every $interval hour(s)"
        echo
        
    else
        print_error "Setup failed! Check Telegram configuration."
        log_message "Setup failed - Telegram test failed" "ERRO"
        return 1
    fi
}

show_help() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     PROJECT BACKUP TELEGRAM VPS     ║${NC}"
    echo -e "${CYAN}║        Simple & Clean Version       ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Features:${NC}"
    echo -e "  📦 Project-only backup"
    echo -e "  🚫 Comprehensive excludes"
    echo -e "  📱 Clean Telegram messages"
    echo -e "  📝 Simple logging"
    echo -e "  ⚡ Fast & efficient"
    echo
    echo -e "${GREEN}Excludes:${NC}"
    echo -e "  • node_modules, .local, .cargo, .rustup"
    echo -e "  • go, logs, cache, dist, build"
    echo -e "  • .next, coverage, tmp, temp"
    echo -e "  • .git, __pycache__, .ipynb_checkpoints"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  --setup       Setup backup system"
    echo -e "  --backup      Run backup"
    echo -e "  --help        Show help"
    echo
    echo -e "${GREEN}Files:${NC}"
    echo -e "  📝 Log: $LOG_FILE"
    echo -e "  ⚙️ Config: $CONFIG_FILE"
    echo -e "  📦 Backups: $BACKUP_DIR"
}

main() {
    case "${1:-}" in
        --setup)
            setup_backup
            ;;
        --backup)
            run_backup
            ;;
        --help)
            show_help
            ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                run_backup
            else
                print_info "Project Backup Telegram VPS - Version $SCRIPT_VERSION"
                echo
                read -p "Setup backup system now? (y/n): " -n 1 -r
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
