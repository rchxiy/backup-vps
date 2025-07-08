#!/bin/bash

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

readonly SCRIPT_VERSION="7.0"
readonly SCRIPT_NAME="backup_telegram"
readonly MAX_BACKUP_SIZE=524288000  # 500MB
readonly WARNING_SIZE=31457280      # 30MB warning threshold
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

scan_project_files() {
    local target_path="$1"
    local project_folders=($(detect_project_folders "$target_path"))
    
    local env_count=0
    local txt_count=0
    local py_count=0
    local js_count=0
    local json_count=0
    
    for folder in "${project_folders[@]}"; do
        env_count=$((env_count + $(find "$folder" -name "*.env" -type f ! -path "*/node_modules/*" ! -path "*/.local/*" ! -path "*/.rustup/*" ! -path "*/.cargo/*" ! -path "*/go/*" ! -path "*/.ipynb_checkpoints/*" ! -path "*/__pycache__/*" ! -path "*/.cache/*" ! -path "*/.npm/*" ! -path "*/.yarn/*" ! -path "*/.git/*" ! -path "*/dist/*" ! -path "*/build/*" ! -path "*/.next/*" ! -path "*/coverage/*" ! -path "*/logs/*" ! -path "/logs/*" ! -path "*/tmp/*" ! -path "*/temp/*" 2>/dev/null | wc -l)))
        txt_count=$((txt_count + $(find "$folder" -name "*.txt" -type f ! -path "*/node_modules/*" ! -path "*/.local/*" ! -path "*/.rustup/*" ! -path "*/.cargo/*" ! -path "*/go/*" ! -path "*/.ipynb_checkpoints/*" ! -path "*/__pycache__/*" ! -path "*/.cache/*" ! -path "*/.npm/*" ! -path "*/.yarn/*" ! -path "*/.git/*" ! -path "*/dist/*" ! -path "*/build/*" ! -path "*/.next/*" ! -path "*/coverage/*" ! -path "*/logs/*" ! -path "/logs/*" ! -path "*/tmp/*" ! -path "*/temp/*" 2>/dev/null | wc -l)))
        py_count=$((py_count + $(find "$folder" -name "*.py" -type f ! -path "*/node_modules/*" ! -path "*/.local/*" ! -path "*/.rustup/*" ! -path "*/.cargo/*" ! -path "*/go/*" ! -path "*/.ipynb_checkpoints/*" ! -path "*/__pycache__/*" ! -path "*/.cache/*" ! -path "*/.npm/*" ! -path "*/.yarn/*" ! -path "*/.git/*" ! -path "*/dist/*" ! -path "*/build/*" ! -path "*/.next/*" ! -path "*/coverage/*" ! -path "*/logs/*" ! -path "/logs/*" ! -path "*/tmp/*" ! -path "*/temp/*" 2>/dev/null | wc -l)))
        js_count=$((js_count + $(find "$folder" -name "*.js" -type f ! -path "*/node_modules/*" ! -path "*/.local/*" ! -path "*/.rustup/*" ! -path "*/.cargo/*" ! -path "*/go/*" ! -path "*/.ipynb_checkpoints/*" ! -path "*/__pycache__/*" ! -path "*/.cache/*" ! -path "*/.npm/*" ! -path "*/.yarn/*" ! -path "*/.git/*" ! -path "*/dist/*" ! -path "*/build/*" ! -path "*/.next/*" ! -path "*/coverage/*" ! -path "*/logs/*" ! -path "/logs/*" ! -path "*/tmp/*" ! -path "*/temp/*" 2>/dev/null | wc -l)))
        json_count=$((json_count + $(find "$folder" -name "package.json" -type f ! -path "*/node_modules/*" ! -path "*/.local/*" ! -path "*/.rustup/*" ! -path "*/.cargo/*" ! -path "*/go/*" ! -path "*/.ipynb_checkpoints/*" ! -path "*/__pycache__/*" ! -path "*/.cache/*" ! -path "*/.npm/*" ! -path "*/.yarn/*" ! -path "*/.git/*" ! -path "*/dist/*" ! -path "*/build/*" ! -path "*/.next/*" ! -path "*/coverage/*" ! -path "*/logs/*" ! -path "/logs/*" ! -path "*/tmp/*" ! -path "*/temp/*" 2>/dev/null | wc -l)))
    done
    
    local total=$((env_count + txt_count + py_count + js_count + json_count))
    
    echo "$total|$env_count|$txt_count|$py_count|$js_count|$json_count|${#project_folders[@]}"
}

calculate_project_size() {
    local target_path="$1"
    local project_folders=($(detect_project_folders "$target_path"))
    local total_size=0
    
    for folder in "${project_folders[@]}"; do
        for ext in "*.env" "*.txt" "*.py" "*.js" "package.json"; do
            local size=$(find "$folder" -name "$ext" -type f ! -path "*/node_modules/*" ! -path "*/.local/*" ! -path "*/.rustup/*" ! -path "*/.cargo/*" ! -path "*/go/*" ! -path "*/.ipynb_checkpoints/*" ! -path "*/__pycache__/*" ! -path "*/.cache/*" ! -path "*/.npm/*" ! -path "*/.yarn/*" ! -path "*/.git/*" ! -path "*/dist/*" ! -path "*/build/*" ! -path "*/.next/*" ! -path "*/coverage/*" ! -path "*/logs/*" ! -path "/logs/*" ! -path "*/tmp/*" ! -path "*/temp/*" -printf "%s\n" 2>/dev/null | awk '{sum += $1} END {print sum+0}' 2>/dev/null || echo 0)
            total_size=$((total_size + size))
        done
    done
    
    echo $total_size
}

check_large_files() {
    local target_path="$1"
    local large_files_report="${BACKUP_DIR}/large_files_report.txt"
    local project_folders=($(detect_project_folders "$target_path"))
    local has_large_files=false
    
    print_info "Checking for files larger than 30MB..."
    
    > "$large_files_report"
    echo "=== FILES LARGER THAN 30MB ===" >> "$large_files_report"
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')" >> "$large_files_report"
    echo "" >> "$large_files_report"
    
    for folder in "${project_folders[@]}"; do
        local folder_name=$(basename "$folder")
        
        while IFS= read -r -d '' file; do
            local file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
            if [[ $file_size -gt $WARNING_SIZE ]]; then
                local file_size_human=$(bytes_to_human $file_size)
                local relative_path=${file#$target_path/}
                
                echo "📁 $folder_name: $relative_path ($file_size_human)" >> "$large_files_report"
                print_warning "Large file found: $relative_path ($file_size_human)"
                has_large_files=true
            fi
        done < <(find "$folder" \( -name "*.env" -o -name "*.txt" -o -name "*.py" -o -name "*.js" -o -name "package.json" \) -type f ! -path "*/node_modules/*" ! -path "*/.local/*" ! -path "*/.rustup/*" ! -path "*/.cargo/*" ! -path "*/go/*" ! -path "*/.ipynb_checkpoints/*" ! -path "*/__pycache__/*" ! -path "*/.cache/*" ! -path "*/.npm/*" ! -path "*/.yarn/*" ! -path "*/.git/*" ! -path "*/dist/*" ! -path "*/build/*" ! -path "*/.next/*" ! -path "*/coverage/*" ! -path "*/logs/*" ! -path "/logs/*" ! -path "*/tmp/*" ! -path "*/temp/*" -print0 2>/dev/null)
    done
    
    if [[ "$has_large_files" == "true" ]]; then
        echo "" >> "$large_files_report"
        echo "⚠️ WARNING: These files are larger than 30MB" >> "$large_files_report"
        echo "💾 Consider saving them manually or optimizing file sizes" >> "$large_files_report"
        echo "📝 This report is saved at: $large_files_report" >> "$large_files_report"
        
        print_warning "Large files detected! Report saved: $large_files_report"
        echo "$large_files_report"
    else
        echo "✅ No files larger than 30MB found" >> "$large_files_report"
        rm -f "$large_files_report"
        echo ""
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

create_single_backup() {
    local backup_path="$1"
    local target_path="$2"
    local project_folders=($(detect_project_folders "$target_path"))
    
    if [[ ${#project_folders[@]} -eq 0 ]]; then
        return 1
    fi
    
    print_info "Creating single ZIP from ${#project_folders[@]} project folders..."
    
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
        >> "$LOG_FILE" 2>&1
    
    return $?
}

run_single_backup() {
    local start_time=$(date +%s)
    
    print_info "Starting single ZIP backup process..."
    log_message "Single ZIP backup started"
    
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
    
    log_message "Found $project_count projects, $total_files files, $estimated_size"
    
    if [[ $estimated_bytes -gt $MAX_BACKUP_SIZE ]]; then
        print_error "Backup size too large: $estimated_size"
        send_telegram_message "❌ <b>Backup Failed</b> - Size too large: $estimated_size (max: $(bytes_to_human $MAX_BACKUP_SIZE))"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    if [[ $total_files -eq 0 ]]; then
        print_warning "No project files found"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    mkdir -p "$BACKUP_DIR"
    
    # Check for large files and create report
    local large_files_report=$(check_large_files "$backup_target")
    
    send_telegram_message "🔄 <b>Single ZIP Backup Started</b>
☁️ ${provider}
📁 ${project_count} projects
📊 ${total_files} files
📏 ${estimated_size}
⏰ $(date '+%H:%M:%S')"
    
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unknown")
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local user_suffix=""
    
    if [[ "$backup_target" != "/root" ]]; then
        user_suffix="-$(basename "$backup_target")"
    fi
    
    local backup_filename="backup-all-projects-${ip_server}${user_suffix}-${timestamp}.zip"
    local backup_full_path="${BACKUP_DIR}/${backup_filename}"
    
    print_info "Creating single ZIP backup..."
    if create_single_backup "$backup_full_path" "$backup_target"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [[ -f "$backup_full_path" ]]; then
            local file_size_bytes=$(stat -c%s "$backup_full_path" 2>/dev/null || stat -f%z "$backup_full_path" 2>/dev/null)
            local file_size=$(bytes_to_human $file_size_bytes)
            
            if [[ $file_size_bytes -lt 100 ]]; then
                print_error "Backup file too small: $file_size"
                rm -f "$backup_full_path"
                rm -f "$LOCK_FILE"
                return 1
            fi
            
            print_success "Single ZIP backup created: $file_size"
            log_message "Single ZIP backup created: $backup_filename ($file_size, ${duration}s)"
            
            local caption="📦 <b>Single ZIP Backup Complete</b>
☁️ ${provider}
📁 ${project_count} projects
📊 ${total_files} files (.env:${env_files} .txt:${txt_files} .py:${py_files} .js:${js_files} package.json:${json_files})
📏 ${file_size}
⏱️ ${duration}s
⏰ $(date '+%H:%M:%S')"
            
            # Send large files warning if exists
            if [[ -n "$large_files_report" && -f "$large_files_report" ]]; then
                send_telegram_message "⚠️ <b>Large Files Warning</b>
📄 Files larger than 30MB detected!
💾 Consider manual backup for large files
📝 Check the report for details"
                
                # Send the report file
                send_telegram_file "$large_files_report" "📄 Large Files Report (>30MB)"
                rm -f "$large_files_report"
            fi
            
            if send_telegram_file "$backup_full_path" "$caption"; then
                print_success "Upload completed"
                send_telegram_message "✅ <b>Single ZIP Backup Success</b> - ${backup_filename} (${file_size})"
                rm -f "$backup_full_path"
                log_message "Upload completed, file cleaned up"
            else
                print_error "Upload failed"
                send_telegram_message "❌ <b>Upload Failed</b> - ${backup_filename}"
            fi
        else
            print_error "Backup file not created"
        fi
    else
        print_error "Backup creation failed"
        send_telegram_message "❌ <b>Backup Failed</b> - Creation error"
    fi
    
    rm -f "$LOCK_FILE"
    log_message "Single ZIP backup completed"
}

setup_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     SINGLE ZIP BACKUP TELEGRAM      ║${NC}"
    echo -e "${CYAN}║      All Projects in One ZIP        ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
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
        for folder in "${project_folders[@]}"; do
            local folder_name=$(basename "$folder")
            echo "  • $folder_name"
        done
    fi
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
    
    print_success "Single ZIP Backup Detection:"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  ☁️ Cloud Provider: $provider"
    echo "  📂 Target Path: $backup_target"
    echo "  📁 Project Folders: $project_count"
    echo "  📊 Files: $total_files (.env:$env_files .txt:$txt_files .py:$py_files .js:$js_files package.json:$json_files)"
    echo "  📏 Estimated Size: $estimated_size"
    echo "  📦 Max Size: $(bytes_to_human $MAX_BACKUP_SIZE)"
    echo "  ⚠️ Warning Threshold: 30MB per file"
    echo "  🎯 Mode: Single ZIP for all projects"
    echo
    
    if [[ $total_files -eq 0 ]]; then
        print_warning "No project files found"
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
PROJECT_COUNT="$project_count"
TOTAL_FILES="$total_files"
ENV_FILES="$env_files"
TXT_FILES="$txt_files"
PY_FILES="$py_files"
JS_FILES="$js_files"
JSON_FILES="$json_files"
ESTIMATED_SIZE="$estimated_size"

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
    
    if send_telegram_message "🎉 <b>Single ZIP Backup Setup</b>
☁️ ${provider}
📁 ${project_count} projects
📊 ${total_files} files
📏 ${estimated_size}
⚠️ 30MB warning enabled
🎯 Mode: Single ZIP
⏰ Every ${interval}h"; then
        print_success "Setup completed successfully!"
        echo
        echo -e "${GREEN}Single ZIP backup system ready!${NC}"
        echo -e "  📁 Projects: $project_count"
        echo -e "  📊 Files: $total_files"
        echo -e "  📏 Size: $estimated_size"
        echo -e "  🎯 Mode: Single ZIP for all projects"
        echo -e "  ⚠️ Warning: Files >30MB will be reported"
    else
        print_error "Setup failed - check Telegram configuration"
        return 1
    fi
}

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     SINGLE ZIP BACKUP TELEGRAM      ║${NC}"
    echo -e "${CYAN}║      All Projects in One ZIP        ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Features:${NC}"
    echo -e "  📦 Single ZIP containing all projects"
    echo -e "  ⚠️ 30MB file size warning system"
    echo -e "  📄 Large files report generation"
    echo -e "  🚫 Comprehensive excludes"
    echo -e "  📱 Clean Telegram notifications"
    echo
    echo -e "${GREEN}Large Files Warning:${NC}"
    echo -e "  • Scans for files >30MB before backup"
    echo -e "  • Generates report with file locations"
    echo -e "  • Sends warning message to Telegram"
    echo -e "  • Suggests manual backup for large files"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  --setup       Setup single ZIP backup"
    echo -e "  --backup      Run single ZIP backup"
    echo -e "  --help        Show help"
}

main() {
    case "${1:-}" in
        --setup) setup_backup ;;
        --backup) run_single_backup ;;
        --help) show_help ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                run_single_backup
            else
                print_info "Single ZIP Backup Telegram v$SCRIPT_VERSION"
                echo
                read -p "Setup single ZIP backup system now? (y/n): " -n 1 -r
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
