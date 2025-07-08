#!/bin/bash

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

readonly SCRIPT_VERSION="5.3"
readonly SCRIPT_NAME="backup_telegram"
readonly MAX_BACKUP_SIZE=104857600
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
    echo "${timestamp} - [${CURRENT_USER}] ${message}" | tee -a "$LOG_FILE"
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
           [[ "$folder_name" == "logs" ]] || \
           [[ "$folder_name" == "log" ]] || \
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
            ! -path "*/log/*" \
            ! -path "/logs/*" \
            ! -path "/log/*" \
            -type f | head -1 | grep -q .; then
            has_project_files=true
        fi
        
        if [[ "$has_project_files" == "true" ]]; then
            project_folders+=("$folder")
        fi
        
    done < <(find "$target_path" -maxdepth 1 -type d ! -path "$target_path" -print0 2>/dev/null)
    
    printf '%s\n' "${project_folders[@]}"
}

count_files_with_max_excludes() {
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
        ! -path "*/.git/*" \
        ! -path "*/dist/*" \
        ! -path "*/build/*" \
        ! -path "*/.next/*" \
        ! -path "*/coverage/*" \
        ! -path "*/logs/*" \
        ! -path "*/log/*" \
        ! -path "/logs/*" \
        ! -path "/log/*" \
        ! -path "*/temp/*" \
        ! -path "*/tmp/*" \
        ! -path "*/.vscode/*" \
        ! -path "*/public/uploads/*" \
        ! -path "*/storage/logs/*" \
        ! -path "*/var/log/*" \
        ! -path "*/test/*" \
        ! -path "*/tests/*" \
        ! -path "*/docs/*" \
        ! -path "*/documentation/*" \
        ! -path "*/examples/*" \
        ! -path "*/demo/*" \
        ! -path "*/sample/*" \
        2>/dev/null | wc -l
}

scan_project_files_max_excludes() {
    local target_path="$1"
    local project_folders=($(detect_project_folders "$target_path"))
    
    local env_count=0
    local txt_count=0
    local py_count=0
    local js_count=0
    local json_count=0
    
    for folder in "${project_folders[@]}"; do
        env_count=$((env_count + $(count_files_with_max_excludes "$folder" "*.env")))
        txt_count=$((txt_count + $(count_files_with_max_excludes "$folder" "*.txt")))
        py_count=$((py_count + $(count_files_with_max_excludes "$folder" "*.py")))
        js_count=$((js_count + $(count_files_with_max_excludes "$folder" "*.js")))
        json_count=$((json_count + $(count_files_with_max_excludes "$folder" "package.json")))
    done
    
    local total=$((env_count + txt_count + py_count + js_count + json_count))
    echo "$total|$env_count|$txt_count|$py_count|$js_count|$json_count|${#project_folders[@]}"
}

calculate_project_size_max_excludes() {
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
                ! -path "*/.git/*" \
                ! -path "*/dist/*" \
                ! -path "*/build/*" \
                ! -path "*/.next/*" \
                ! -path "*/coverage/*" \
                ! -path "*/logs/*" \
                ! -path "*/log/*" \
                ! -path "/logs/*" \
                ! -path "/log/*" \
                ! -path "*/temp/*" \
                ! -path "*/tmp/*" \
                ! -path "*/.vscode/*" \
                ! -path "*/public/uploads/*" \
                ! -path "*/storage/logs/*" \
                ! -path "*/var/log/*" \
                ! -path "*/test/*" \
                ! -path "*/tests/*" \
                ! -path "*/docs/*" \
                ! -path "*/documentation/*" \
                ! -path "*/examples/*" \
                ! -path "*/demo/*" \
                ! -path "*/sample/*" \
                -printf "%s\n" 2>/dev/null | \
                awk '{sum += $1} END {print sum+0}' 2>/dev/null || echo 0)
            total_size=$((total_size + size))
        done
    done
    
    echo $total_size
}

list_project_folders_max_excludes() {
    local target_path="$1"
    local project_folders=($(detect_project_folders "$target_path"))
    
    echo "📁 Project folders detected:"
    if [[ ${#project_folders[@]} -eq 0 ]]; then
        echo "  • No project folders found"
    else
        for folder in "${project_folders[@]}"; do
            local folder_name=$(basename "$folder")
            local file_count=0
            for ext in "*.env" "*.txt" "*.py" "*.js" "package.json"; do
                local count=$(count_files_with_max_excludes "$folder" "$ext")
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

create_max_compressed_backup() {
    local backup_path="$1"
    local target_path="$2"
    local project_folders=($(detect_project_folders "$target_path"))
    
    if [[ ${#project_folders[@]} -eq 0 ]]; then
        print_warning "No project folders found"
        return 1
    fi
    
    print_info "Creating maximum compressed ZIP from ${#project_folders[@]} project folders..."
    
    local zip_args=()
    for folder in "${project_folders[@]}"; do
        zip_args+=("$folder")
    done
    
    zip -9 -r "$backup_path" "${zip_args[@]}" \
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
        -x "*/log/*" \
        -x "/logs/*" \
        -x "/log/*" \
        -x "*/temp/*" \
        -x "*/tmp/*" \
        -x "*/.vscode/*" \
        -x "*/public/uploads/*" \
        -x "*/storage/logs/*" \
        -x "*/var/log/*" \
        -x "*/test/*" \
        -x "*/tests/*" \
        -x "*/docs/*" \
        -x "*/documentation/*" \
        -x "*/examples/*" \
        -x "*/demo/*" \
        -x "*/sample/*" \
        -x "*/.DS_Store" \
        -x "*/.gitignore" \
        -x "*/.gitattributes" \
        -x "*/README.md" \
        -x "*/LICENSE" \
        -x "*/*.log" \
        -x "*/*.tmp" \
        -x "*/*.bak" \
        -x "*/*.old" \
        -x "*/*.lock" \
        >> "$LOG_FILE" 2>&1
    
    return $?
}

run_max_compressed_backup() {
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
    log_message "=== MAXIMUM COMPRESSED BACKUP STARTED ==="
    
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    log_message "Provider: $provider"
    log_message "Target: $backup_target"
    log_message "Mode: Maximum compression with comprehensive excludes"
    
    if [[ ! -d "$backup_target" ]]; then
        print_error "Target directory not found: $backup_target"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    local file_info=$(scan_project_files_max_excludes "$backup_target")
    local total_files=$(echo "$file_info" | cut -d'|' -f1)
    local env_files=$(echo "$file_info" | cut -d'|' -f2)
    local txt_files=$(echo "$file_info" | cut -d'|' -f3)
    local py_files=$(echo "$file_info" | cut -d'|' -f4)
    local js_files=$(echo "$file_info" | cut -d'|' -f5)
    local json_files=$(echo "$file_info" | cut -d'|' -f6)
    local project_count=$(echo "$file_info" | cut -d'|' -f7)
    
    local estimated_bytes=$(calculate_project_size_max_excludes "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    local compressed_bytes=$((estimated_bytes * 20 / 100))
    local compressed_size=$(bytes_to_human $compressed_bytes)
    
    log_message "Found $project_count project folders with maximum excludes"
    log_message "Files: .env($env_files) .txt($txt_files) .py($py_files) .js($js_files) package.json($json_files)"
    log_message "Total: $total_files files"
    log_message "Estimated size before compression: $estimated_size"
    log_message "Estimated size after max compression: $compressed_size"
    
    if [[ $compressed_bytes -gt $MAX_BACKUP_SIZE ]]; then
        print_error "Estimated compressed size too large: $compressed_size (max: $(bytes_to_human $MAX_BACKUP_SIZE))"
        send_telegram_message "❌ <b>Backup Failed</b> - Estimated compressed size too large: $compressed_size"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    if [[ $total_files -eq 0 ]]; then
        print_warning "No project files found"
        send_telegram_message "⚠️ <b>Backup Warning</b> - No project files found"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    send_telegram_message "🔄 <b>Maximum Compressed Backup Started</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Project Folders: ${project_count}
📊 Files: ${total_files} (.env:${env_files} .txt:${txt_files} .py:${py_files} .js:${js_files} package.json:${json_files})
📏 Size Before: ${estimated_size}
🗜️ Est. After Compression: ${compressed_size}
🚫 Max Excludes: node_modules, logs, cache, build, temp
⚡ Compression: Maximum (-9)
📅 $(date '+%Y-%m-%d %H:%M:%S')"
    
    mkdir -p "$BACKUP_DIR"
    
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unknown")
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local user_suffix=""
    
    if [[ "$backup_target" != "/root" ]]; then
        user_suffix="-$(basename "$backup_target")"
    fi
    
    local backup_filename="backup-maxcomp-${ip_server}${user_suffix}-${timestamp}.zip"
    local backup_full_path="${BACKUP_DIR}/${backup_filename}"
    
    log_message "Creating maximum compressed backup: $backup_filename"
    
    if create_max_compressed_backup "$backup_full_path" "$backup_target"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [[ -f "$backup_full_path" ]]; then
            local file_size_bytes=$(stat -c%s "$backup_full_path" 2>/dev/null || stat -f%z "$backup_full_path" 2>/dev/null)
            local file_size=$(bytes_to_human $file_size_bytes)
            
            local compression_ratio=0
            if [[ $estimated_bytes -gt 0 ]]; then
                compression_ratio=$(( (estimated_bytes - file_size_bytes) * 100 / estimated_bytes ))
            fi
            
            if [[ $file_size_bytes -lt 100 ]]; then
                print_error "Backup file too small: $file_size"
                rm -f "$backup_full_path"
                rm -f "$LOCK_FILE"
                return 1
            fi
            
            log_message "Maximum compressed backup created: $file_size (${duration}s, ${compression_ratio}% compression)"
            
            local caption="📦 <b>Maximum Compressed Backup Complete</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Project Folders: ${project_count}
📊 Files: ${total_files}
📋 Breakdown: .env(${env_files}) .txt(${txt_files}) .py(${py_files}) .js(${js_files}) package.json(${json_files})
📏 Original Size: ${estimated_size}
🗜️ Compressed Size: ${file_size}
📉 Compression Ratio: ${compression_ratio}%
⏱️ Duration: ${duration}s
🚫 Max Excludes: node_modules, logs, cache, build, temp, .git
⚡ Compression Level: Maximum (-9)
📅 $(date '+%Y-%m-%d %H:%M:%S')
✅ Status: Success"
            
            if send_telegram_file "$backup_full_path" "$caption"; then
                log_message "Upload successful"
                send_telegram_message "✅ <b>Max Compressed Backup Completed</b> - ${backup_filename}
📊 ${total_files} files from ${project_count} folders
📏 ${estimated_size} → ${file_size} (${compression_ratio}% compression)"
                
                rm -f "$backup_full_path"
                log_message "Backup file removed: $backup_filename"
                
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
    log_message "=== MAXIMUM COMPRESSED BACKUP COMPLETED ==="
}

setup_max_compressed_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   MAXIMUM COMPRESSED BACKUP VPS     ║${NC}"
    echo -e "${CYAN}║     Ultra Compression + Max Excludes ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    print_info "Detecting project folders with maximum excludes..."
    list_project_folders_max_excludes "$backup_target"
    echo
    
    local file_info=$(scan_project_files_max_excludes "$backup_target")
    local total_files=$(echo "$file_info" | cut -d'|' -f1)
    local env_files=$(echo "$file_info" | cut -d'|' -f2)
    local txt_files=$(echo "$file_info" | cut -d'|' -f3)
    local py_files=$(echo "$file_info" | cut -d'|' -f4)
    local js_files=$(echo "$file_info" | cut -d'|' -f5)
    local json_files=$(echo "$file_info" | cut -d'|' -f6)
    local project_count=$(echo "$file_info" | cut -d'|' -f7)
    
    local estimated_bytes=$(calculate_project_size_max_excludes "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    local compressed_bytes=$((estimated_bytes * 20 / 100))
    local compressed_size=$(bytes_to_human $compressed_bytes)
    
    print_success "Maximum Compressed Backup Detection:"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  ☁️ Cloud Provider: $provider"
    echo "  📂 Target Path: $backup_target"
    echo "  📁 Project Folders: $project_count"
    echo "  📊 Project Files Found (max excludes):"
    echo "    • .env files: $env_files"
    echo "    • .txt files: $txt_files"
    echo "    • .py files: $py_files"
    echo "    • .js files: $js_files"
    echo "    • package.json: $json_files"
    echo "  📋 Total Files: $total_files"
    echo "  📏 Original Size: $estimated_size"
    echo "  🗜️ Estimated Compressed: $compressed_size (80% reduction)"
    echo "  📦 Max Size: $(bytes_to_human $MAX_BACKUP_SIZE)"
    echo "  🚫 Maximum Excludes: node_modules, logs, cache, build, temp, .git"
    echo "  ⚡ Compression Level: Maximum (-9)"
    echo "  📦 Output Format: ZIP"
    echo
    
    if [[ $total_files -eq 0 ]]; then
        print_warning "No project files found in $backup_target"
        echo "Make sure you have project folders with .env, .txt, .py, .js, or package.json files."
        return 1
    fi
    
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$BACKUP_DIR"
    
    echo -e "${YELLOW}Telegram Bot Configuration:${NC}"
    echo
    
    read -p "🤖 Telegram Bot Token: " bot_token
    read -p "💬 Telegram Chat ID: " chat_id
    read -p "⏰ Backup interval (hours) [default: 1]: " interval
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
COMPRESSED_SIZE="$compressed_size"
CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_success "Configuration saved!"
    
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
    
    if send_telegram_message "🎉 <b>Maximum Compressed Backup Setup</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Project Folders: ${project_count}
📊 Files: ${total_files}
📋 Breakdown: .env(${env_files}) .txt(${txt_files}) .py(${py_files}) .js(${js_files}) package.json(${json_files})
📏 Original: ${estimated_size}
🗜️ Compressed: ${compressed_size}
🚫 Max Excludes: node_modules, logs, cache, build, temp
⚡ Compression: Maximum (-9)
📦 Format: ZIP
✅ Ultra compression ready!"; then
        
        print_success "Setup completed successfully!"
        echo
        echo -e "${GREEN}Maximum compressed backup system ready!${NC}"
        echo -e "  📁 Target: ${BLUE}Project folders only${NC}"
        echo -e "  📊 Total Files: ${BLUE}$total_files${NC}"
        echo -e "  📏 Original Size: ${BLUE}$estimated_size${NC}"
        echo -e "  🗜️ Compressed Size: ${BLUE}$compressed_size${NC}"
        echo -e "  🚫 Excludes: ${BLUE}node_modules, logs, cache, build, temp${NC}"
        echo -e "  ⚡ Compression: ${BLUE}Maximum (-9)${NC}"
        echo -e "  📦 Format: ${BLUE}ZIP${NC}"
        
    else
        print_error "Setup failed! Check Telegram configuration."
        return 1
    fi
}

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   MAXIMUM COMPRESSED BACKUP VPS     ║${NC}"
    echo -e "${CYAN}║     Ultra Compression + Max Excludes ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Maximum Compression Features:${NC}"
    echo -e "  🗜️ ${BLUE}Maximum compression (-9)${NC} - 70-85% size reduction"
    echo -e "  🎯 ${BLUE}Project folders only${NC} - no system folders"
    echo -e "  🚫 ${BLUE}Ultra excludes${NC} - comprehensive exclusions"
    echo -e "  📦 ${BLUE}ZIP format output${NC}"
    echo -e "  📏 ${BLUE}Ultra-small backup${NC} - maximum compression"
    echo -e "  🚀 ${BLUE}Fast upload${NC} - smaller files"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  ${BLUE}--setup${NC}       Setup maximum compressed backup"
    echo -e "  ${BLUE}--backup${NC}      Run maximum compressed backup"
    echo -e "  ${BLUE}--help${NC}        Show this help"
}

main() {
    case "${1:-}" in
        --setup) setup_max_compressed_backup ;;
        --backup) run_max_compressed_backup ;;
        --help) show_help ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                run_max_compressed_backup
            else
                print_info "Maximum Compressed Backup VPS - Version $SCRIPT_VERSION"
                echo
                read -p "Setup maximum compressed backup now? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    setup_max_compressed_backup
                else
                    show_help
                fi
            fi
            ;;
    esac
}

main "$@"
