#!/bin/bash

# ===================================================================
# BACKUP TELEGRAM VPS - PROPER EXCLUDE PATTERNS
# ONLY: .env, .txt, .py, .js, package.json with proper excludes
# Version: 4.3 - Proper Exclude Patterns
# ===================================================================

set -euo pipefail

# Konfigurasi warna
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Konfigurasi global
readonly SCRIPT_VERSION="4.3"
readonly SCRIPT_NAME="backup_telegram"
readonly MAX_BACKUP_SIZE=1073741824  # 1GB max
readonly API_TIMEOUT=30
readonly UPLOAD_TIMEOUT=600
readonly MAX_RETRIES=5

# Deteksi environment
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

# ===================================================================
# FUNGSI UTILITY
# ===================================================================

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

# ===================================================================
# FUNGSI DETEKSI USER DAN CLOUD
# ===================================================================

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
    
    # Deteksi Azure
    if [[ -f /var/lib/waagent/Incarnation ]] || [[ -d /var/lib/waagent ]]; then
        provider="Microsoft Azure"
        if [[ "$IS_ROOT" == "true" ]]; then
            local user_info=$(get_primary_user)
            backup_path=$(echo "$user_info" | cut -d':' -f2)
        else
            backup_path="$USER_HOME"
        fi
    # Deteksi AWS
    elif curl -s http://169.254.169.254/latest/meta-data/instance-id --max-time 3 &>/dev/null; then
        provider="Amazon AWS"
        local user_info=$(get_primary_user)
        backup_path=$(echo "$user_info" | cut -d':' -f2)
    # Deteksi DigitalOcean
    elif curl -s http://169.254.169.254/metadata/v1/id --max-time 3 &>/dev/null; then
        provider="DigitalOcean"
        backup_path="/root"
    else
        provider="Generic VPS"
        backup_path="/root"
    fi
    
    # Validasi path
    if [[ ! -d "$backup_path" ]]; then
        backup_path="/root"
    fi
    
    echo "$provider|$backup_path"
}

# ===================================================================
# FUNGSI SCAN FILE DENGAN EXCLUDE YANG BENAR
# ===================================================================

count_files_with_proper_excludes() {
    local target_path="$1"
    
    print_info "Counting files with proper exclude patterns..."
    
    # Count .env files
    local env_count=$(find "$target_path" -name "*.env" \
        ! -path "*/node_modules/*" \
        ! -path "*/__pycache__/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.npm/*" \
        ! -path "*/.local/lib/python*/*" \
        ! -path "*/.ipython/*" \
        ! -path "*/.jupyter/*" \
        ! -path "*/.ssh/*" \
        ! -path "*/.local/share/jupyter/*" \
        ! -path "*/.local/etc/jupyter/*" \
        ! -path "*/.local/bin/*" \
        ! -path "*/.git/*" \
        ! -path "*/.local/share/Trash/*" \
        ! -path "*/.local/*" \
        ! -path "*/.rustup/*" \
        ! -path "*/.cargo/*" \
        ! -path "*/go/*" \
        ! -path "*/.ipynb_checkpoints/*" \
        2>/dev/null | wc -l)
    
    # Count .txt files
    local txt_count=$(find "$target_path" -name "*.txt" \
        ! -path "*/node_modules/*" \
        ! -path "*/__pycache__/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.npm/*" \
        ! -path "*/.local/lib/python*/*" \
        ! -path "*/.ipython/*" \
        ! -path "*/.jupyter/*" \
        ! -path "*/.ssh/*" \
        ! -path "*/.local/share/jupyter/*" \
        ! -path "*/.local/etc/jupyter/*" \
        ! -path "*/.local/bin/*" \
        ! -path "*/.git/*" \
        ! -path "*/.local/share/Trash/*" \
        ! -path "*/.local/*" \
        ! -path "*/.rustup/*" \
        ! -path "*/.cargo/*" \
        ! -path "*/go/*" \
        ! -path "*/.ipynb_checkpoints/*" \
        2>/dev/null | wc -l)
    
    # Count .py files
    local py_count=$(find "$target_path" -name "*.py" \
        ! -path "*/node_modules/*" \
        ! -path "*/__pycache__/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.npm/*" \
        ! -path "*/.local/lib/python*/*" \
        ! -path "*/.ipython/*" \
        ! -path "*/.jupyter/*" \
        ! -path "*/.ssh/*" \
        ! -path "*/.local/share/jupyter/*" \
        ! -path "*/.local/etc/jupyter/*" \
        ! -path "*/.local/bin/*" \
        ! -path "*/.git/*" \
        ! -path "*/.local/share/Trash/*" \
        ! -path "*/.local/*" \
        ! -path "*/.rustup/*" \
        ! -path "*/.cargo/*" \
        ! -path "*/go/*" \
        ! -path "*/.ipynb_checkpoints/*" \
        2>/dev/null | wc -l)
    
    # Count .js files
    local js_count=$(find "$target_path" -name "*.js" \
        ! -path "*/node_modules/*" \
        ! -path "*/__pycache__/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.npm/*" \
        ! -path "*/.local/lib/python*/*" \
        ! -path "*/.ipython/*" \
        ! -path "*/.jupyter/*" \
        ! -path "*/.ssh/*" \
        ! -path "*/.local/share/jupyter/*" \
        ! -path "*/.local/etc/jupyter/*" \
        ! -path "*/.local/bin/*" \
        ! -path "*/.git/*" \
        ! -path "*/.local/share/Trash/*" \
        ! -path "*/.local/*" \
        ! -path "*/.rustup/*" \
        ! -path "*/.cargo/*" \
        ! -path "*/go/*" \
        ! -path "*/.ipynb_checkpoints/*" \
        2>/dev/null | wc -l)
    
    # Count package.json files
    local json_count=$(find "$target_path" -name "package.json" \
        ! -path "*/node_modules/*" \
        ! -path "*/__pycache__/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.npm/*" \
        ! -path "*/.local/lib/python*/*" \
        ! -path "*/.ipython/*" \
        ! -path "*/.jupyter/*" \
        ! -path "*/.ssh/*" \
        ! -path "*/.local/share/jupyter/*" \
        ! -path "*/.local/etc/jupyter/*" \
        ! -path "*/.local/bin/*" \
        ! -path "*/.git/*" \
        ! -path "*/.local/share/Trash/*" \
        ! -path "*/.local/*" \
        ! -path "*/.rustup/*" \
        ! -path "*/.cargo/*" \
        ! -path "*/go/*" \
        ! -path "*/.ipynb_checkpoints/*" \
        2>/dev/null | wc -l)
    
    local total=$((env_count + txt_count + py_count + js_count + json_count))
    
    echo "$total|$env_count|$txt_count|$py_count|$js_count|$json_count"
}

calculate_files_size_with_excludes() {
    local target_path="$1"
    local total_size=0
    
    # Calculate size for each file type with proper excludes
    for ext in "*.env" "*.txt" "*.py" "*.js" "package.json"; do
        local size=$(find "$target_path" -name "$ext" \
            ! -path "*/node_modules/*" \
            ! -path "*/__pycache__/*" \
            ! -path "*/.cache/*" \
            ! -path "*/.npm/*" \
            ! -path "*/.local/lib/python*/*" \
            ! -path "*/.ipython/*" \
            ! -path "*/.jupyter/*" \
            ! -path "*/.ssh/*" \
            ! -path "*/.local/share/jupyter/*" \
            ! -path "*/.local/etc/jupyter/*" \
            ! -path "*/.local/bin/*" \
            ! -path "*/.git/*" \
            ! -path "*/.local/share/Trash/*" \
            ! -path "*/.local/*" \
            ! -path "*/.rustup/*" \
            ! -path "*/.cargo/*" \
            ! -path "*/go/*" \
            ! -path "*/.ipynb_checkpoints/*" \
            -printf "%s\n" 2>/dev/null | \
            awk '{sum += $1} END {print sum+0}' 2>/dev/null || echo 0)
        
        total_size=$((total_size + size))
    done
    
    echo $total_size
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

# ===================================================================
# FUNGSI TELEGRAM API
# ===================================================================

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

# ===================================================================
# FUNGSI BACKUP ZIP DENGAN EXCLUDE YANG BENAR
# ===================================================================

create_zip_backup_with_proper_excludes() {
    local backup_path="$1"
    local target_path="$2"
    
    print_info "Creating ZIP with proper exclude patterns..."
    
    # Gunakan zip dengan include dan exclude pattern seperti command manual Anda
    zip -r "$backup_path" "$target_path" \
        -i '*.env' '*.txt' '*.py' '*.js' 'package.json' \
        -x "*/node_modules/*" \
        -x "*/__pycache__/*" \
        -x "*/.cache/*" \
        -x "*/.npm/*" \
        -x "*/.local/lib/python*/*" \
        -x "*/.ipython/*" \
        -x "*/.jupyter/*" \
        -x "*/.jupyter_ystore.db" \
        -x "*/.ssh/*" \
        -x "*/.wget-hsts" \
        -x "*/.bash_history" \
        -x "*/.cloud-locale-test.skip" \
        -x "*/.DS_Store" \
        -x "*/.local/share/jupyter/*" \
        -x "*/.local/etc/jupyter/*" \
        -x "*/.local/bin/jupyter*" \
        -x "*/.local/bin/ipython*" \
        -x "*/.local/bin/debugpy*" \
        -x "*/.git/*" \
        -x "*/.gitattributes" \
        -x "*/.gitignore" \
        -x "*/.gitmodules" \
        -x "*/.local/share/Trash/*" \
        -x "*/.local/*" \
        -x "*/.rustup/*" \
        -x "*/.cargo/*" \
        -x "*/go/*" \
        -x "*/.ipynb_checkpoints/*" \
        >> "$LOG_FILE" 2>&1
    
    return $?
}

# ===================================================================
# FUNGSI BACKUP UTAMA
# ===================================================================

run_zip_backup() {
    local start_time=$(date +%s)
    
    # Lock mechanism
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            print_error "Backup already running (PID: $pid)"
            return 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
    
    # Load konfigurasi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration not found! Run: $0 --setup"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    source "$CONFIG_FILE"
    
    log_message "=== ZIP BACKUP WITH PROPER EXCLUDES STARTED ==="
    
    # Deteksi provider dan path
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    log_message "Provider: $provider"
    log_message "Target: $backup_target"
    log_message "Files: .env, .txt, .py, .js, package.json with proper excludes"
    
    # Validasi target
    if [[ ! -d "$backup_target" ]]; then
        print_error "Target directory not found: $backup_target"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Hitung file dan size dengan exclude yang benar
    local file_info=$(count_files_with_proper_excludes "$backup_target")
    local total_files=$(echo "$file_info" | cut -d'|' -f1)
    local env_files=$(echo "$file_info" | cut -d'|' -f2)
    local txt_files=$(echo "$file_info" | cut -d'|' -f3)
    local py_files=$(echo "$file_info" | cut -d'|' -f4)
    local js_files=$(echo "$file_info" | cut -d'|' -f5)
    local json_files=$(echo "$file_info" | cut -d'|' -f6)
    
    # Estimasi size dengan exclude
    local estimated_bytes=$(calculate_files_size_with_excludes "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    log_message "Found files with proper excludes: .env($env_files) .txt($txt_files) .py($py_files) .js($js_files) package.json($json_files)"
    log_message "Total: $total_files files, estimated size: $estimated_size"
    
    if [[ $estimated_bytes -gt $MAX_BACKUP_SIZE ]]; then
        print_error "Backup size too large: $estimated_size"
        send_telegram_message "❌ <b>Backup Failed</b> - Size too large: $estimated_size"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    if [[ $total_files -eq 0 ]]; then
        print_warning "No files found to backup"
        send_telegram_message "⚠️ <b>Backup Warning</b> - No files found (.env, .txt, .py, .js, package.json)"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Kirim notifikasi awal
    send_telegram_message "🔄 <b>ZIP Backup Started (Proper Excludes)</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Types: .env, .txt, .py, .js, package.json
📊 Files: ${total_files} (.env:${env_files} .txt:${txt_files} .py:${py_files} .js:${js_files} package.json:${json_files})
📏 Est. Size: ${estimated_size}
🚫 Excludes: .local, .cargo, .rustup, go, node_modules, __pycache__, .cache, .git
📅 $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Buat direktori backup
    mkdir -p "$BACKUP_DIR"
    
    # Generate nama file ZIP
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unknown")
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local user_suffix=""
    
    if [[ "$backup_target" != "/root" ]]; then
        user_suffix="-$(basename "$backup_target")"
    fi
    
    local backup_filename="backup-files-${ip_server}${user_suffix}-${timestamp}.zip"
    local backup_full_path="${BACKUP_DIR}/${backup_filename}"
    
    log_message "Creating ZIP backup with proper excludes: $backup_filename"
    
    # Proses backup ZIP dengan exclude yang benar
    if create_zip_backup_with_proper_excludes "$backup_full_path" "$backup_target"; then
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
            
            log_message "ZIP backup created with proper excludes: $file_size (${duration}s)"
            
            # Upload ke Telegram
            local caption="📦 <b>ZIP Backup Complete (Proper Excludes)</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Types: .env, .txt, .py, .js, package.json
📊 Files: ${total_files}
📋 Breakdown: .env(${env_files}) .txt(${txt_files}) .py(${py_files}) .js(${js_files}) package.json(${json_files})
📏 Size: ${file_size}
⏱️ Duration: ${duration}s
🚫 Excluded: .local, .cargo, .rustup, go, node_modules, cache
📅 $(date '+%Y-%m-%d %H:%M:%S')
✅ Status: Success"
            
            if send_telegram_file "$backup_full_path" "$caption"; then
                log_message "Upload successful"
                send_telegram_message "✅ <b>ZIP Backup Completed</b> - ${backup_filename} (${total_files} files, ${file_size})"
                
                # Hapus file backup
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
        send_telegram_message "❌ <b>Backup Failed</b> - ZIP creation error"
    fi
    
    # Cleanup
    rm -f "$LOCK_FILE"
    log_message "=== ZIP BACKUP WITH PROPER EXCLUDES COMPLETED ==="
}

# ===================================================================
# FUNGSI SETUP
# ===================================================================

setup_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     ZIP BACKUP WITH PROPER EXCLUDES  ║${NC}"
    echo -e "${CYAN}║  .env .txt .py .js package.json ONLY ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Deteksi provider dan path
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    # Scan file spesifik dengan exclude yang benar
    print_info "Scanning with proper exclude patterns..."
    local file_info=$(count_files_with_proper_excludes "$backup_target")
    local total_files=$(echo "$file_info" | cut -d'|' -f1)
    local env_files=$(echo "$file_info" | cut -d'|' -f2)
    local txt_files=$(echo "$file_info" | cut -d'|' -f3)
    local py_files=$(echo "$file_info" | cut -d'|' -f4)
    local js_files=$(echo "$file_info" | cut -d'|' -f5)
    local json_files=$(echo "$file_info" | cut -d'|' -f6)
    
    # Estimasi size dengan exclude
    local estimated_bytes=$(calculate_files_size_with_excludes "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    print_success "ZIP Backup with Proper Excludes Detection:"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  ☁️ Cloud Provider: $provider"
    echo "  📂 Target Path: $backup_target"
    echo "  📁 File Types: .env, .txt, .py, .js, package.json ONLY"
    echo "  📊 Files Found (with proper excludes):"
    echo "    • .env files: $env_files"
    echo "    • .txt files: $txt_files"
    echo "    • .py files: $py_files"
    echo "    • .js files: $js_files"
    echo "    • package.json: $json_files"
    echo "  📋 Total Files: $total_files"
    echo "  📏 Estimated Size: $estimated_size"
    echo "  🚫 Excludes: .local, .cargo, .rustup, go, node_modules, cache"
    echo "  📦 Output Format: ZIP"
    echo
    
    if [[ $total_files -eq 0 ]]; then
        print_warning "No files found matching criteria in $backup_target"
        echo "Make sure you have .env, .txt, .py, .js, or package.json files in the target directory."
        return 1
    fi
    
    # Buat direktori
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$BACKUP_DIR"
    
    # Input konfigurasi
    echo -e "${YELLOW}Telegram Bot Configuration:${NC}"
    echo
    
    read -p "🤖 Telegram Bot Token: " bot_token
    read -p "💬 Telegram Chat ID: " chat_id
    read -p "⏰ Backup interval (hours) [default: 1]: " interval
    interval=${interval:-1}
    
    # Simpan konfigurasi
    cat > "$CONFIG_FILE" << EOF
# ZIP Backup with Proper Excludes Configuration
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
BACKUP_INTERVAL="$interval"

# Detection Results
CLOUD_PROVIDER="$provider"
BACKUP_TARGET="$backup_target"
TOTAL_FILES="$total_files"
ENV_FILES="$env_files"
TXT_FILES="$txt_files"
PY_FILES="$py_files"
JS_FILES="$js_files"
JSON_FILES="$json_files"
ESTIMATED_SIZE="$estimated_size"

# Timestamps
CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_success "Configuration saved!"
    
    # Setup crontab
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
    
    # Test koneksi
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    if send_telegram_message "🎉 <b>ZIP Backup with Proper Excludes Setup</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Types: .env, .txt, .py, .js, package.json
📊 Files: ${total_files}
📋 Breakdown: .env(${env_files}) .txt(${txt_files}) .py(${py_files}) .js(${js_files}) package.json(${json_files})
📏 Size: ${estimated_size}
🚫 Excludes: .local, .cargo, .rustup, go, node_modules, cache
📦 Format: ZIP
✅ Proper excludes applied!"; then
        
        print_success "Setup completed successfully!"
        echo
        echo -e "${GREEN}ZIP backup with proper excludes ready!${NC}"
        echo -e "  📁 Extensions: ${BLUE}.env, .txt, .py, .js, package.json${NC}"
        echo -e "  📊 Total Files: ${BLUE}$total_files${NC}"
        echo -e "  📏 Size: ${BLUE}$estimated_size${NC}"
        echo -e "  🚫 Excludes: ${BLUE}.local, .cargo, .rustup, go, node_modules${NC}"
        echo -e "  📦 Format: ${BLUE}ZIP${NC}"
        
    else
        print_error "Setup failed! Check Telegram configuration."
        return 1
    fi
}

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     ZIP BACKUP WITH PROPER EXCLUDES  ║${NC}"
    echo -e "${CYAN}║   .env .txt .py .js package.json     ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Proper Excludes Features:${NC}"
    echo -e "  🔧 ${BLUE}Proper exclude patterns${NC} like your manual command"
    echo -e "  📦 ${BLUE}ZIP format output${NC}"
    echo -e "  📁 ${BLUE}ONLY 5 file types${NC}: .env, .txt, .py, .js, package.json"
    echo -e "  🚫 ${BLUE}Comprehensive excludes${NC}: .local, .cargo, .rustup, go, node_modules"
    echo -e "  📏 ${BLUE}Accurate file counting${NC} with excludes"
    echo -e "  🚀 ${BLUE}Fast backup${NC} - no cache/temp files"
    echo
    echo -e "${GREEN}Exclude Patterns Applied:${NC}"
    echo -e "  • ${RED}.local/*${NC} - Local user data"
    echo -e "  • ${RED}.rustup/*${NC} - Rust toolchain"
    echo -e "  • ${RED}.cargo/*${NC} - Cargo cache"
    echo -e "  • ${RED}go/*${NC} - Go workspace"
    echo -e "  • ${RED}node_modules/*${NC} - Node dependencies"
    echo -e "  • ${RED}.ipynb_checkpoints/*${NC} - Jupyter checkpoints"
    echo -e "  • ${RED}__pycache__/*${NC} - Python cache"
    echo -e "  • ${RED}.cache/*${NC} - General cache"
    echo -e "  • ${RED}.git/*${NC} - Git repositories"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  ${BLUE}--setup${NC}       Setup ZIP backup with proper excludes"
    echo -e "  ${BLUE}--backup${NC}      Run ZIP backup with proper excludes"
    echo -e "  ${BLUE}--help${NC}        Show this help"
}

# ===================================================================
# MAIN SCRIPT
# ===================================================================

main() {
    case "${1:-}" in
        --setup) setup_backup ;;
        --backup) run_zip_backup ;;
        --help) show_help ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                run_zip_backup
            else
                print_info "ZIP Backup with Proper Excludes - Version $SCRIPT_VERSION"
                echo
                read -p "Setup ZIP backup with proper excludes now? (y/n): " -n 1 -r
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
