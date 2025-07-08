#!/bin/bash

# ===================================================================
# BACKUP TELEGRAM VPS - ULTRA ROBUST VERSION
# Author: Backup System
# Version: 3.2 - Production Ready & Error-Free
# ===================================================================

set -euo pipefail

# Konfigurasi warna untuk output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Konfigurasi global yang TIDAK akan disimpan di config
readonly SCRIPT_VERSION="3.2"
readonly SCRIPT_NAME="backup_telegram"
readonly MIN_DISK_SPACE=1048576
readonly MAX_BACKUP_SIZE=5368709120
readonly API_TIMEOUT=30
readonly UPLOAD_TIMEOUT=600
readonly MAX_RETRIES=5
readonly RETRY_DELAY=5

# Deteksi environment dan user
CURRENT_USER=$(whoami)
USER_HOME=$(eval echo ~$CURRENT_USER)
IS_ROOT=false
SYSTEM_ARCH=$(uname -m)
SYSTEM_OS=$(uname -s)

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
readonly ERROR_LOG="${SCRIPT_DIR}/error.log"

# ===================================================================
# FUNGSI UTILITY DAN LOGGING
# ===================================================================

log_with_level() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    
    case "$level" in
        "INFO") color="$BLUE" ;;
        "SUCCESS") color="$GREEN" ;;
        "WARNING") color="$YELLOW" ;;
        "ERROR") color="$RED" ;;
        "DEBUG") color="$PURPLE" ;;
        *) color="$NC" ;;
    esac
    
    echo -e "${color}[${level}]${NC} $message"
    
    # Log ke file tanpa warna
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "${timestamp} - [${CURRENT_USER}] [${level}] ${message}" >> "$LOG_FILE"
}

print_info() { log_with_level "INFO" "$1"; }
print_success() { log_with_level "SUCCESS" "$1"; }
print_warning() { log_with_level "WARNING" "$1"; }
print_error() { log_with_level "ERROR" "$1"; }
print_debug() { log_with_level "DEBUG" "$1"; }

log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "${timestamp} - [${CURRENT_USER}] ${message}" | tee -a "$LOG_FILE"
}

# Error handling yang robust
handle_error() {
    local exit_code=$?
    local line_number=$1
    local command="$2"
    
    print_error "Script failed at line $line_number: $command (exit code: $exit_code)"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Line $line_number: $command (exit code: $exit_code)" >> "$ERROR_LOG"
    
    # Cleanup
    rm -f "$LOCK_FILE" 2>/dev/null || true
    exit $exit_code
}

trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

# ===================================================================
# FUNGSI DETEKSI USER DINAMIS
# ===================================================================

detect_vps_users() {
    local users_list=()
    
    # Deteksi semua user dengan home directory
    while IFS=: read -r username _ uid _ _ home_dir _; do
        if [[ $uid -ge 1000 ]] || [[ "$username" == "root" ]]; then
            if [[ -d "$home_dir" && "$home_dir" != "/dev/null" && "$home_dir" != "/nonexistent" ]]; then
                users_list+=("$username:$home_dir")
            fi
        fi
    done < /etc/passwd
    
    # Deteksi user di /home/
    for home_dir in /home/*; do
        if [[ -d "$home_dir" ]]; then
            local username=$(basename "$home_dir")
            if id "$username" &>/dev/null; then
                users_list+=("$username:$home_dir")
            fi
        fi
    done
    
    printf '%s\n' "${users_list[@]}" | sort -u
}

get_primary_user() {
    local detected_users=($(detect_vps_users))
    local primary_user=""
    local primary_home=""
    
    # Priority order
    local priority_users=("ichiazure" "azureuser" "ubuntu" "ec2-user" "debian" "centos" "admin" "user")
    
    # Cari berdasarkan priority
    for priority in "${priority_users[@]}"; do
        for user_info in "${detected_users[@]}"; do
            local username=$(echo "$user_info" | cut -d':' -f1)
            local home_dir=$(echo "$user_info" | cut -d':' -f2)
            
            if [[ "$username" == "$priority" ]]; then
                primary_user="$username"
                primary_home="$home_dir"
                break 2
            fi
        done
    done
    
    # Fallback ke user pertama (bukan root)
    if [[ -z "$primary_user" ]]; then
        for user_info in "${detected_users[@]}"; do
            local username=$(echo "$user_info" | cut -d':' -f1)
            local home_dir=$(echo "$user_info" | cut -d':' -f2)
            
            if [[ "$username" != "root" ]]; then
                primary_user="$username"
                primary_home="$home_dir"
                break
            fi
        done
    fi
    
    # Final fallback ke root
    if [[ -z "$primary_user" ]]; then
        primary_user="root"
        primary_home="/root"
    fi
    
    echo "$primary_user:$primary_home"
}

# ===================================================================
# FUNGSI DETEKSI CLOUD PROVIDER
# ===================================================================

detect_cloud_provider_advanced() {
    local provider="Unknown"
    local backup_path=""
    local backup_type=""
    
    # Deteksi Microsoft Azure
    if [[ -f /var/lib/waagent/Incarnation ]] || [[ -d /var/lib/waagent ]]; then
        provider="Microsoft Azure"
        
        if [[ "$IS_ROOT" == "true" ]]; then
            local primary_user_info=$(get_primary_user)
            local primary_user=$(echo "$primary_user_info" | cut -d':' -f1)
            local primary_home=$(echo "$primary_user_info" | cut -d':' -f2)
            
            if [[ "$primary_user" != "root" && -d "$primary_home" ]]; then
                backup_path="$primary_home"
                backup_type="Azure User Home ($primary_user)"
            else
                backup_path="/root"
                backup_type="Azure Root"
            fi
        else
            backup_path="$USER_HOME"
            backup_type="Azure User Home ($CURRENT_USER)"
        fi
    
    # Deteksi Amazon AWS
    elif curl -s http://169.254.169.254/latest/meta-data/instance-id --max-time 3 &>/dev/null; then
        provider="Amazon AWS"
        local primary_user_info=$(get_primary_user)
        local primary_user=$(echo "$primary_user_info" | cut -d':' -f1)
        local primary_home=$(echo "$primary_user_info" | cut -d':' -f2)
        backup_path="$primary_home"
        backup_type="AWS User Home ($primary_user)"
    
    # Deteksi DigitalOcean
    elif curl -s http://169.254.169.254/metadata/v1/id --max-time 3 &>/dev/null; then
        provider="DigitalOcean"
        backup_path="/root"
        backup_type="DigitalOcean Root"
    
    # Deteksi Contabo
    elif [[ $(hostname) =~ vmi[0-9]+ ]] || [[ $(hostname) =~ contabo ]]; then
        provider="Contabo"
        backup_path="/root"
        backup_type="Contabo Root"
    
    # Default fallback
    else
        provider="Generic VPS"
        if [[ "$IS_ROOT" == "true" ]]; then
            local primary_user_info=$(get_primary_user)
            local primary_user=$(echo "$primary_user_info" | cut -d':' -f1)
            local primary_home=$(echo "$primary_user_info" | cut -d':' -f2)
            backup_path="$primary_home"
            backup_type="Generic User Home ($primary_user)"
        else
            backup_path="$USER_HOME"
            backup_type="Generic User Home ($CURRENT_USER)"
        fi
    fi
    
    # Validasi backup path dengan fallback
    if [[ ! -d "$backup_path" ]]; then
        local fallback_targets=("/home/ichiazure" "/home/azureuser" "/home/ubuntu" "/root")
        for target in "${fallback_targets[@]}"; do
            if [[ -d "$target" ]]; then
                backup_path="$target"
                backup_type="Fallback $(basename "$target") Home"
                break
            fi
        done
    fi
    
    echo "$provider|$backup_path|$backup_type"
}

# ===================================================================
# FUNGSI ESTIMASI SIZE
# ===================================================================

calculate_estimated_size() {
    local target_path="$1"
    
    if [[ ! -d "$target_path" ]]; then
        echo 0
        return
    fi
    
    find "$target_path" -type f \
        ! -path "*/node_modules/*" \
        ! -path "*/__pycache__/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.npm/*" \
        ! -path "*/.yarn/*" \
        ! -path "*/.pnpm/*" \
        ! -path "*/.local/lib/python*/*" \
        ! -path "*/.vscode-server/*" \
        ! -path "*/.docker/*" \
        ! -path "*/.git/*" \
        ! -path "*/.ssh/*" \
        ! -path "*/.gnupg/*" \
        ! -path "*/.ipython/*" \
        ! -path "*/.jupyter/*" \
        ! -path "*/.local/share/jupyter/*" \
        ! -path "*/.local/share/Trash/*" \
        ! -path "*/tmp/*" \
        ! -path "*/temp/*" \
        ! -path "*/logs/*" \
        ! -path "*/.backup-telegram/*" \
        ! -path "/root/.local/*" \
        ! -path "/root/.rustup/*" \
        ! -path "/root/.cargo/*" \
        ! -path "/root/go/*" \
        ! -path "*/.ipynb_checkpoints/*" \
        ! -name ".bash_history" \
        ! -name ".zsh_history" \
        ! -name ".mysql_history" \
        ! -name ".wget-hsts" \
        ! -name ".DS_Store" \
        ! -name "backup-*.zip" \
        -printf "%s\n" 2>/dev/null | \
        awk '{sum += $1} END {print sum+0}' 2>/dev/null || echo 0
}

bytes_to_human() {
    local bytes=$1
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    
    while [[ $bytes -gt 1024 && $unit -lt 4 ]]; do
        bytes=$((bytes / 1024))
        ((unit++))
    done
    
    echo "${bytes}${units[$unit]}"
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
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            sleep $RETRY_DELAY
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
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            sleep $((RETRY_DELAY * retry_count))
        fi
    done
    
    return 1
}

test_telegram_connection() {
    print_info "Testing Telegram connection..."
    
    local me_response=$(curl -s --max-time "$API_TIMEOUT" \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null)
    
    if [[ $me_response != *"\"ok\":true"* ]]; then
        print_error "Invalid bot token!"
        return 1
    fi
    
    if send_telegram_message "🔧 <b>Connection Test</b> - Ultra robust backup system ready!"; then
        print_success "Telegram connection successful!"
        return 0
    else
        print_error "Failed to send test message!"
        return 1
    fi
}

# ===================================================================
# FUNGSI BACKUP
# ===================================================================

create_backup_with_progress() {
    local backup_path="$1"
    local target_path="$2"
    local start_time=$(date +%s)
    
    print_info "Creating backup archive..."
    
    zip -r "$backup_path" "$target_path" \
        -x "*/node_modules/*" \
        -x "*/__pycache__/*" \
        -x "*/.cache/*" \
        -x "*/.npm/*" \
        -x "*/.yarn/*" \
        -x "*/.pnpm/*" \
        -x "*/.local/lib/python*/*" \
        -x "*/.local/share/virtualenvs/*" \
        -x "*/.vscode-server/*" \
        -x "*/.docker/*" \
        -x "*/.git/*" \
        -x "*/.ssh/*" \
        -x "*/.gnupg/*" \
        -x "*/.ipython/*" \
        -x "*/.jupyter/*" \
        -x "*/.local/share/jupyter/*" \
        -x "*/.bash_history" \
        -x "*/.zsh_history" \
        -x "*/.mysql_history" \
        -x "*/.wget-hsts" \
        -x "*/.DS_Store" \
        -x "*/.local/share/Trash/*" \
        -x "*/tmp/*" \
        -x "*/temp/*" \
        -x "*/logs/*" \
        -x "*/backup-*.zip" \
        -x "*/.backup-telegram/*" \
        -x "/root/.local/*" \
        -x "/root/.rustup/*" \
        -x "/root/.cargo/*" \
        -x "/root/go/*" \
        -x "*/.ipynb_checkpoints/*" \
        >> "$LOG_FILE" 2>&1
    
    return $?
}

# ===================================================================
# FUNGSI BACKUP UTAMA
# ===================================================================

run_smart_backup() {
    local start_time=$(date +%s)
    
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
    
    # Load konfigurasi dengan error handling
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration not found! Run: $0 --setup"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Load config dengan safe method
    source "$CONFIG_FILE" 2>/dev/null || {
        print_error "Failed to load configuration!"
        rm -f "$LOCK_FILE"
        return 1
    }
    
    log_message "=== ULTRA ROBUST BACKUP STARTED ==="
    
    # Deteksi provider
    local provider_info=$(detect_cloud_provider_advanced)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    local backup_type=$(echo "$provider_info" | cut -d'|' -f3)
    
    log_message "Provider: $provider"
    log_message "Target: $backup_target"
    log_message "Type: $backup_type"
    
    # Validasi backup target
    if [[ ! -d "$backup_target" ]]; then
        print_error "Backup target not accessible: $backup_target"
        send_telegram_message "❌ <b>Backup Failed</b> - Target not accessible: $backup_target"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Estimasi ukuran
    local estimated_bytes=$(calculate_estimated_size "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    if [[ $estimated_bytes -gt $MAX_BACKUP_SIZE ]]; then
        print_error "Backup size too large: $estimated_size"
        send_telegram_message "❌ <b>Backup Failed</b> - Size too large: $estimated_size"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Kirim notifikasi awal
    send_telegram_message "🔄 <b>Ultra Robust Backup Started</b>
☁️ Provider: ${provider}
📁 Type: ${backup_type}
📂 Path: ${backup_target}
📊 Est. Size: ${estimated_size}
👤 User: $(basename "$backup_target")
📅 $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Buat direktori backup
    mkdir -p "$BACKUP_DIR"
    
    # Dapatkan IP server
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unknown")
    
    # Generate nama file backup
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local provider_suffix=$(echo "$provider" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local user_suffix=""
    
    if [[ "$backup_target" != "/root" ]]; then
        local detected_user=$(basename "$backup_target")
        user_suffix="-${detected_user}"
    fi
    
    local backup_filename="backup-${ip_server}-${provider_suffix}${user_suffix}-${timestamp}.zip"
    local backup_full_path="${BACKUP_DIR}/${backup_filename}"
    
    log_message "Creating backup: $backup_filename"
    
    # Proses backup
    if create_backup_with_progress "$backup_full_path" "$backup_target"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [[ -f "$backup_full_path" ]]; then
            local file_size_bytes=$(stat -c%s "$backup_full_path" 2>/dev/null || stat -f%z "$backup_full_path" 2>/dev/null)
            local file_size=$(bytes_to_human $file_size_bytes)
            
            if [[ $file_size_bytes -lt 1024 ]]; then
                print_error "Backup file too small: $file_size"
                send_telegram_message "❌ <b>Backup Failed</b> - File too small: $file_size"
                rm -f "$backup_full_path"
                rm -f "$LOCK_FILE"
                return 1
            fi
            
            log_message "Backup created successfully: $file_size (${duration}s)"
            
            # Upload ke Telegram
            local caption="📦 <b>Ultra Robust Backup Complete</b>
☁️ Provider: ${provider}
📁 Type: ${backup_type}
📂 Path: ${backup_target}
👤 User: $(basename "$backup_target")
📊 Size: ${file_size}
⏱️ Duration: ${duration}s
🖥️ System: ${SYSTEM_OS} ${SYSTEM_ARCH}
📅 $(date '+%Y-%m-%d %H:%M:%S')
✅ Status: Success"
            
            if send_telegram_file "$backup_full_path" "$caption"; then
                log_message "Upload successful"
                send_telegram_message "✅ <b>Ultra Robust Backup Completed</b> - ${backup_filename} (${file_size})"
                
                # Hapus file backup
                rm -f "$backup_full_path"
                log_message "Backup file removed: $backup_filename"
                
            else
                print_error "Upload failed"
                send_telegram_message "❌ <b>Upload Failed</b> - ${backup_filename}"
            fi
            
        else
            print_error "Backup file not created"
            send_telegram_message "❌ <b>Backup Failed</b> - File not created"
        fi
        
    else
        print_error "Backup creation failed"
        send_telegram_message "❌ <b>Backup Failed</b> - Creation error"
    fi
    
    # Cleanup
    rm -f "$LOCK_FILE"
    log_message "=== ULTRA ROBUST BACKUP COMPLETED ==="
}

# ===================================================================
# FUNGSI SETUP YANG DIPERBAIKI
# ===================================================================

setup_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     ULTRA ROBUST BACKUP TELEGRAM    ║${NC}"
    echo -e "${CYAN}║        Error-Free Version            ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Hapus config lama jika ada masalah
    if [[ -f "$CONFIG_FILE" ]]; then
        print_warning "Removing old configuration..."
        rm -f "$CONFIG_FILE"
    fi
    
    # Deteksi users
    print_info "Detecting available users..."
    local detected_users=($(detect_vps_users))
    
    echo -e "${BLUE}Detected Users:${NC}"
    for user_info in "${detected_users[@]}"; do
        local username=$(echo "$user_info" | cut -d':' -f1)
        local home_dir=$(echo "$user_info" | cut -d':' -f2)
        local size=$(du -sh "$home_dir" 2>/dev/null | cut -f1 || echo "Unknown")
        echo "  👤 $username → $home_dir ($size)"
    done
    echo
    
    # Deteksi provider
    print_info "Detecting cloud provider and backup strategy..."
    local provider_info=$(detect_cloud_provider_advanced)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    local backup_type=$(echo "$provider_info" | cut -d'|' -f3)
    
    # Estimasi ukuran
    local estimated_bytes=$(calculate_estimated_size "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    print_success "Ultra Robust Detection Results:"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  🔑 Root Access: $IS_ROOT"
    echo "  ☁️ Cloud Provider: $provider"
    echo "  📁 Backup Type: $backup_type"
    echo "  📂 Target Path: $backup_target"
    echo "  👤 Target User: $(basename "$backup_target")"
    echo "  📊 Estimated Size: $estimated_size"
    echo "  🖥️ System: $SYSTEM_OS $SYSTEM_ARCH"
    echo
    
    # Buat direktori
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Input konfigurasi Telegram
    echo -e "${YELLOW}Telegram Bot Configuration:${NC}"
    echo
    
    read -p "🤖 Telegram Bot Token: " bot_token
    read -p "💬 Telegram Chat ID: " chat_id
    read -p "⏰ Backup interval (hours) [default: 1]: " interval
    interval=${interval:-1}
    read -p "🗂️ Maximum backups to keep [default: 5]: " max_backups
    max_backups=${max_backups:-5}
    
    # Simpan konfigurasi TANPA readonly variables
    cat > "$CONFIG_FILE" << EOF
# Ultra Robust Backup Telegram VPS Configuration
# Generated on $(date '+%Y-%m-%d %H:%M:%S')

# Telegram Configuration
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
BACKUP_INTERVAL="$interval"
MAX_BACKUPS="$max_backups"

# Detection Results
CLOUD_PROVIDER="$provider"
BACKUP_TARGET="$backup_target"
BACKUP_TYPE="$backup_type"
DETECTED_USER="$(basename "$backup_target")"

# System Information (non-readonly)
SYSTEM_USER="$CURRENT_USER"
USER_IS_ROOT="$IS_ROOT"
DETECTED_OS="$SYSTEM_OS"
DETECTED_ARCH="$SYSTEM_ARCH"

# Timestamps
CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
LAST_UPDATED="$(date '+%Y-%m-%d %H:%M:%S')"
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
    
    # Hapus crontab lama dan tambah yang baru
    crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME" | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "$cron_schedule $0 --backup >/dev/null 2>&1") | crontab -
    print_success "Crontab configured for backup every $interval hour(s)"
    
    # Test koneksi Telegram
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    if test_telegram_connection; then
        send_telegram_message "🎉 <b>Ultra Robust Backup Setup Complete</b>
☁️ Provider: ${provider}
📁 Type: ${backup_type}
📂 Path: ${backup_target}
👤 User: $(basename "$backup_target")
📊 Est. Size: ${estimated_size}
⏰ Interval: ${interval}h
🖥️ System: ${SYSTEM_OS} ${SYSTEM_ARCH}
✅ Error-free and ready!"
        
        print_success "Setup completed successfully!"
        echo
        echo -e "${GREEN}Ultra robust backup system is ready!${NC}"
        echo -e "  📂 Target: ${BLUE}$backup_target${NC}"
        echo -e "  👤 User: ${BLUE}$(basename "$backup_target")${NC}"
        echo -e "  📊 Size: ${BLUE}$estimated_size${NC}"
        echo -e "  🔧 Version: ${BLUE}$SCRIPT_VERSION${NC} (Error-free)"
        
    else
        print_error "Setup failed! Please check your Telegram configuration."
        return 1
    fi
}

# ===================================================================
# FUNGSI STATUS
# ===================================================================

show_status() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      ULTRA ROBUST BACKUP STATUS      ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Real-time detection
    local provider_info=$(detect_cloud_provider_advanced)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    local backup_type=$(echo "$provider_info" | cut -d'|' -f3)
    
    echo -e "${BLUE}Real-time Detection:${NC}"
    echo "  ☁️ Provider: $provider"
    echo "  📁 Backup Type: $backup_type"
    echo "  📂 Target Path: $backup_target"
    echo "  👤 Target User: $(basename "$backup_target")"
    echo "  🔧 Script Version: $SCRIPT_VERSION (Ultra Robust)"
    
    if [[ -d "$backup_target" ]]; then
        local current_size=$(calculate_estimated_size "$backup_target")
        local human_size=$(bytes_to_human $current_size)
        echo "  📊 Current Size: $human_size"
        print_success "Target path accessible"
    else
        print_error "Target path not accessible: $backup_target"
    fi
    echo
    
    # Configuration status
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null || {
            print_error "Configuration file corrupted!"
            return 1
        }
        
        echo -e "${BLUE}Configuration:${NC}"
        echo "  📋 Config File: $CONFIG_FILE"
        echo "  🤖 Bot Token: ${TELEGRAM_BOT_TOKEN:0:10}..."
        echo "  💬 Chat ID: $TELEGRAM_CHAT_ID"
        echo "  ⏰ Interval: $BACKUP_INTERVAL hour(s)"
        echo "  🗂️ Max Backups: $MAX_BACKUPS"
        echo "  👤 Configured User: ${DETECTED_USER:-'Auto-detect'}"
        echo "  📅 Created: $CREATED_DATE"
        print_success "Configuration loaded successfully"
        echo
        
        # Crontab status
        if crontab -l 2>/dev/null | grep -q "$SCRIPT_NAME"; then
            print_success "Automatic backups: Enabled"
            local cron_entry=$(crontab -l 2>/dev/null | grep "$SCRIPT_NAME")
            echo "  📋 Schedule: $cron_entry"
        else
            print_warning "Automatic backups: Disabled"
        fi
        
    else
        print_error "Configuration not found! Run: $0 --setup"
    fi
}

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    ULTRA ROBUST BACKUP TELEGRAM      ║${NC}"
    echo -e "${CYAN}║         Error-Free Version           ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Ultra Robust Features:${NC}"
    echo -e "  🛡️ ${BLUE}Error-free${NC} configuration management"
    echo -e "  🔍 ${BLUE}Dynamic user${NC} detection (ichiazure, azureuser, etc.)"
    echo -e "  ☁️ ${BLUE}Cloud provider${NC} auto-detection"
    echo -e "  📊 ${BLUE}Smart sizing${NC} with comprehensive excludes"
    echo -e "  🔄 ${BLUE}Robust retry${NC} mechanisms"
    echo -e "  📱 ${BLUE}Rich notifications${NC} with full metadata"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  ${BLUE}--setup${NC}       Setup with ultra robust detection"
    echo -e "  ${BLUE}--backup${NC}      Run error-free backup"
    echo -e "  ${BLUE}--status${NC}      Show system status"
    echo -e "  ${BLUE}--test${NC}        Test Telegram connection"
    echo -e "  ${BLUE}--help${NC}        Show this help"
}

# ===================================================================
# MAIN SCRIPT
# ===================================================================

main() {
    local command="${1:-}"
    
    mkdir -p "$SCRIPT_DIR" "$BACKUP_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || true
    
    case "$command" in
        --setup)
            setup_backup
            ;;
        --backup)
            run_smart_backup
            ;;
        --status)
            show_status
            ;;
        --test)
            if [[ -f "$CONFIG_FILE" ]]; then
                source "$CONFIG_FILE" 2>/dev/null || {
                    print_error "Configuration corrupted! Run: $0 --setup"
                    exit 1
                }
                test_telegram_connection
            else
                print_error "Configuration not found! Run: $0 --setup"
                exit 1
            fi
            ;;
        --help)
            show_help
            ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                show_status
            else
                print_info "Ultra Robust Backup Telegram VPS - Version $SCRIPT_VERSION"
                echo
                print_info "System not configured yet."
                echo
                read -p "Would you like to run the ultra robust setup now? (y/n): " -n 1 -r
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
