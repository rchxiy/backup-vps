#!/bin/bash

# ===================================================================
# BACKUP TELEGRAM VPS - FULL ROBUST VERSION
# Author: Backup System
# Version: 3.0 - Production Ready
# Features: Smart Detection, Error Handling, Monitoring, Recovery
# ===================================================================

set -euo pipefail  # Strict error handling

# Konfigurasi warna untuk output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Konfigurasi global
readonly SCRIPT_VERSION="3.0"
readonly SCRIPT_NAME="backup_telegram"
readonly MIN_DISK_SPACE=1048576  # 1GB in KB
readonly MAX_BACKUP_SIZE=5368709120  # 5GB in bytes
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
readonly STATS_FILE="${SCRIPT_DIR}/stats.json"
readonly ERROR_LOG="${SCRIPT_DIR}/error.log"

# ===================================================================
# FUNGSI UTILITY DAN LOGGING
# ===================================================================

# Fungsi print dengan timestamp dan level
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
    echo "${timestamp} - [${CURRENT_USER}] [${level}] ${message}" >> "$LOG_FILE"
}

print_info() { log_with_level "INFO" "$1"; }
print_success() { log_with_level "SUCCESS" "$1"; }
print_warning() { log_with_level "WARNING" "$1"; }
print_error() { log_with_level "ERROR" "$1"; }
print_debug() { log_with_level "DEBUG" "$1"; }

# Fungsi logging dengan rotasi otomatis
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Buat direktori log jika belum ada
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Rotasi log jika lebih dari 50MB
    if [[ -f "$LOG_FILE" ]]; then
        local log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ $log_size -gt 52428800 ]]; then
            mv "$LOG_FILE" "${LOG_FILE}.$(date +%Y%m%d_%H%M%S).old"
            gzip "${LOG_FILE}.$(date +%Y%m%d_%H%M%S).old" 2>/dev/null || true
            touch "$LOG_FILE"
        fi
    fi
    
    echo "${timestamp} - [${CURRENT_USER}] ${message}" | tee -a "$LOG_FILE"
}

# Fungsi error handling dengan stack trace
handle_error() {
    local exit_code=$?
    local line_number=$1
    local command="$2"
    
    print_error "Script failed at line $line_number: $command (exit code: $exit_code)"
    
    # Log stack trace
    local frame=0
    while caller $frame; do
        ((frame++))
    done >> "$ERROR_LOG"
    
    # Kirim notifikasi error jika konfigurasi tersedia
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null || true
        if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
            send_telegram_message "🚨 <b>Script Error</b>
📍 Line: $line_number
💻 Command: $command
🔢 Exit Code: $exit_code
⏰ $(date '+%Y-%m-%d %H:%M:%S')" || true
        fi
    fi
    
    cleanup_on_exit
    exit $exit_code
}

# Set error trap
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

# ===================================================================
# FUNGSI SISTEM DAN VALIDASI
# ===================================================================

# Validasi sistem requirements
validate_system() {
    print_info "Validating system requirements..."
    
    # Cek command dependencies
    local required_commands=("curl" "zip" "find" "du" "stat" "awk" "grep" "sed")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        print_error "Missing required commands: ${missing_commands[*]}"
        print_info "Please install missing packages:"
        print_info "Ubuntu/Debian: sudo apt update && sudo apt install -y ${missing_commands[*]}"
        print_info "CentOS/RHEL: sudo yum install -y ${missing_commands[*]}"
        return 1
    fi
    
    # Cek disk space
    local available_space=$(df "$(dirname "$BACKUP_DIR")" | awk 'NR==2 {print $4}')
    if [[ $available_space -lt $MIN_DISK_SPACE ]]; then
        print_error "Insufficient disk space. Required: ${MIN_DISK_SPACE}KB, Available: ${available_space}KB"
        return 1
    fi
    
    # Cek network connectivity
    if ! curl -s --max-time 10 "https://api.telegram.org" > /dev/null; then
        print_warning "Network connectivity to Telegram API seems limited"
    fi
    
    print_success "System validation passed"
    return 0
}

# Validasi input dengan regex
validate_bot_token() {
    local token="$1"
    [[ $token =~ ^[0-9]{8,10}:[a-zA-Z0-9_-]{35}$ ]]
}

validate_chat_id() {
    local chat_id="$1"
    [[ $chat_id =~ ^-?[0-9]+$ ]]
}

validate_interval() {
    local interval="$1"
    [[ $interval =~ ^[0-9]+$ ]] && [[ $interval -ge 1 ]] && [[ $interval -le 168 ]]
}

# ===================================================================
# FUNGSI DETEKSI CLOUD PROVIDER
# ===================================================================

detect_cloud_provider_advanced() {
    local provider="Unknown"
    local backup_path=""
    local backup_type=""
    local provider_metadata=""
    
    print_debug "Detecting cloud provider..."
    
    # Deteksi Microsoft Azure
    if [[ -f /var/lib/waagent/Incarnation ]] || [[ -d /var/lib/waagent ]]; then
        provider="Microsoft Azure"
        provider_metadata=$(curl -s -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" --max-time 5 2>/dev/null || echo "")
        
        if [[ "$IS_ROOT" == "true" ]]; then
            local azure_users=($(ls /home/ 2>/dev/null | head -n 3))
            if [[ ${#azure_users[@]} -gt 0 ]]; then
                backup_path="/home/${azure_users[0]}"
                backup_type="Azure User Home (${azure_users[0]})"
            else
                backup_path="/home"
                backup_type="Azure Home Directory"
            fi
        else
            backup_path="$USER_HOME"
            backup_type="Azure User Home ($CURRENT_USER)"
        fi
    
    # Deteksi Amazon AWS
    elif [[ -n $(curl -s http://169.254.169.254/latest/meta-data/instance-id --max-time 5 2>/dev/null) ]]; then
        provider="Amazon AWS"
        provider_metadata=$(curl -s http://169.254.169.254/latest/meta-data/instance-type --max-time 5 2>/dev/null || echo "")
        
        if [[ -d "/home/ec2-user" ]]; then
            backup_path="/home/ec2-user"
            backup_type="AWS EC2 User"
        elif [[ -d "/home/ubuntu" ]]; then
            backup_path="/home/ubuntu"
            backup_type="AWS Ubuntu User"
        else
            backup_path="/root"
            backup_type="AWS Root"
        fi
    
    # Deteksi Google Cloud Platform
    elif [[ -n $(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/id --max-time 5 2>/dev/null) ]]; then
        provider="Google Cloud"
        provider_metadata=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/machine-type --max-time 5 2>/dev/null || echo "")
        
        if [[ -d "/home/ubuntu" ]]; then
            backup_path="/home/ubuntu"
            backup_type="GCP Ubuntu User"
        elif [[ -d "/home/debian" ]]; then
            backup_path="/home/debian"
            backup_type="GCP Debian User"
        else
            backup_path="/root"
            backup_type="GCP Root"
        fi
    
    # Deteksi DigitalOcean
    elif [[ -n $(curl -s http://169.254.169.254/metadata/v1/id --max-time 5 2>/dev/null) ]]; then
        provider="DigitalOcean"
        provider_metadata=$(curl -s http://169.254.169.254/metadata/v1/region --max-time 5 2>/dev/null || echo "")
        backup_path="/root"
        backup_type="DigitalOcean Root"
    
    # Deteksi Vultr
    elif [[ -f /etc/vultr ]] || [[ -n $(curl -s http://169.254.169.254/v1/instanceid --max-time 5 2>/dev/null) ]]; then
        provider="Vultr"
        provider_metadata=$(curl -s http://169.254.169.254/v1/region --max-time 5 2>/dev/null || echo "")
        backup_path="/root"
        backup_type="Vultr Root"
    
    # Deteksi Linode
    elif [[ -n $(curl -s http://169.254.169.254/linode/v1/instance --max-time 5 2>/dev/null) ]]; then
        provider="Linode"
        provider_metadata=$(curl -s http://169.254.169.254/linode/v1/region --max-time 5 2>/dev/null || echo "")
        backup_path="/root"
        backup_type="Linode Root"
    
    # Deteksi Contabo (berdasarkan hostname pattern)
    elif [[ $(hostname) =~ vmi[0-9]+ ]] || [[ $(hostname) =~ contabo ]]; then
        provider="Contabo"
        backup_path="/root"
        backup_type="Contabo Root"
    
    # Deteksi Hetzner
    elif [[ -n $(curl -s http://169.254.169.254/hetzner/v1/metadata --max-time 5 2>/dev/null) ]]; then
        provider="Hetzner"
        backup_path="/root"
        backup_type="Hetzner Root"
    
    # Default fallback
    else
        provider="Generic VPS"
        if [[ "$IS_ROOT" == "true" ]]; then
            backup_path="/root"
            backup_type="Generic Root"
        else
            backup_path="$USER_HOME"
            backup_type="Generic User Home"
        fi
    fi
    
    # Validasi backup path
    if [[ ! -d "$backup_path" ]]; then
        print_warning "Primary backup path not found: $backup_path"
        if [[ "$IS_ROOT" == "true" ]]; then
            backup_path="/root"
            backup_type="Fallback Root"
        else
            backup_path="$USER_HOME"
            backup_type="Fallback User Home"
        fi
    fi
    
    echo "$provider|$backup_path|$backup_type|$provider_metadata"
}

# ===================================================================
# FUNGSI ESTIMASI SIZE DENGAN EXCLUDE
# ===================================================================

calculate_estimated_size() {
    local target_path="$1"
    local temp_file="/tmp/size_calc_$$"
    
    print_debug "Calculating estimated size for: $target_path"
    
    # Hitung ukuran dengan exclude menggunakan find
    find "$target_path" -type f \
        ! -path "*/node_modules/*" \
        ! -path "*/__pycache__/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.npm/*" \
        ! -path "*/.yarn/*" \
        ! -path "*/.pnpm/*" \
        ! -path "*/.local/lib/python*/*" \
        ! -path "*/.local/share/virtualenvs/*" \
        ! -path "*/.local/share/pip/*" \
        ! -path "*/.vscode-server/*" \
        ! -path "*/.vscode-server-insiders/*" \
        ! -path "*/.docker/*" \
        ! -path "*/.git/*" \
        ! -path "*/.ssh/*" \
        ! -path "*/.gnupg/*" \
        ! -path "*/.ipython/*" \
        ! -path "*/.jupyter/*" \
        ! -path "*/.local/share/jupyter/*" \
        ! -path "*/.local/etc/jupyter/*" \
        ! -path "*/.local/share/Trash/*" \
        ! -path "*/tmp/*" \
        ! -path "*/temp/*" \
        ! -path "*/logs/*" \
        ! -path "*/log/*" \
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
        ! -name ".cloud-locale-test.skip" \
        ! -name ".DS_Store" \
        ! -name ".jupyter_ystore.db" \
        ! -name ".gitattributes" \
        ! -name ".gitignore" \
        ! -name ".gitmodules" \
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
# FUNGSI TELEGRAM API DENGAN RETRY MECHANISM
# ===================================================================

send_telegram_message() {
    local message="$1"
    local retry_count=0
    local response
    
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        print_debug "Sending Telegram message (attempt $((retry_count + 1))/$MAX_RETRIES)"
        
        response=$(curl -s --max-time "$API_TIMEOUT" \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="${message}" \
            -d parse_mode="HTML" 2>/dev/null)
        
        if [[ $response == *"\"ok\":true"* ]]; then
            print_debug "Telegram message sent successfully"
            return 0
        fi
        
        ((retry_count++))
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            print_warning "Telegram message failed, retrying in ${RETRY_DELAY}s... ($retry_count/$MAX_RETRIES)"
            sleep $RETRY_DELAY
        fi
    done
    
    print_error "Failed to send Telegram message after $MAX_RETRIES attempts"
    echo "$response" >> "$ERROR_LOG"
    return 1
}

send_telegram_file() {
    local file_path="$1"
    local caption="$2"
    local retry_count=0
    local response
    
    if [[ ! -f "$file_path" ]]; then
        print_error "File not found: $file_path"
        return 1
    fi
    
    local file_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    if [[ $file_size -gt 52428800 ]]; then  # 50MB limit
        print_error "File too large for Telegram: $(bytes_to_human $file_size)"
        return 1
    fi
    
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        print_debug "Uploading file to Telegram (attempt $((retry_count + 1))/$MAX_RETRIES)"
        
        response=$(curl -s --max-time "$UPLOAD_TIMEOUT" \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
            -F chat_id="${TELEGRAM_CHAT_ID}" \
            -F document=@"${file_path}" \
            -F caption="${caption}" 2>/dev/null)
        
        if [[ $response == *"\"ok\":true"* ]]; then
            print_debug "File uploaded successfully"
            return 0
        fi
        
        ((retry_count++))
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            print_warning "File upload failed, retrying in $((RETRY_DELAY * retry_count))s... ($retry_count/$MAX_RETRIES)"
            sleep $((RETRY_DELAY * retry_count))
        fi
    done
    
    print_error "Failed to upload file after $MAX_RETRIES attempts"
    echo "$response" >> "$ERROR_LOG"
    return 1
}

test_telegram_connection() {
    print_info "Testing Telegram connection..."
    
    # Test getMe API
    local me_response=$(curl -s --max-time "$API_TIMEOUT" \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null)
    
    if [[ $me_response != *"\"ok\":true"* ]]; then
        print_error "Invalid bot token!"
        return 1
    fi
    
    local bot_name=$(echo "$me_response" | grep -o '"first_name":"[^"]*"' | cut -d'"' -f4)
    print_success "Bot connected: $bot_name"
    
    # Test send message
    if send_telegram_message "🔧 <b>Connection Test</b> - Backup system ready!"; then
        print_success "Telegram connection successful!"
        return 0
    else
        print_error "Failed to send test message!"
        return 1
    fi
}

# ===================================================================
# FUNGSI BACKUP DENGAN PROGRESS MONITORING
# ===================================================================

create_backup_with_progress() {
    local backup_path="$1"
    local target_path="$2"
    local start_time=$(date +%s)
    
    print_info "Creating backup archive..."
    
    # Buat backup dengan exclude patterns yang diperluas
    {
        zip -r "$backup_path" "$target_path" \
            -x "*/node_modules/*" \
            -x "*/__pycache__/*" \
            -x "*/.cache/*" \
            -x "*/.npm/*" \
            -x "*/.yarn/*" \
            -x "*/.pnpm/*" \
            -x "*/.local/lib/python*/*" \
            -x "*/.local/share/virtualenvs/*" \
            -x "*/.local/share/pip/*" \
            -x "*/.vscode-server/*" \
            -x "*/.vscode-server-insiders/*" \
            -x "*/.docker/*" \
            -x "*/.git/*" \
            -x "*/.ssh/*" \
            -x "*/.gnupg/*" \
            -x "*/.ipython/*" \
            -x "*/.jupyter/*" \
            -x "*/.jupyter_ystore.db" \
            -x "*/.local/share/jupyter/*" \
            -x "*/.local/etc/jupyter/*" \
            -x "*/.local/bin/jupyter*" \
            -x "*/.local/bin/ipython*" \
            -x "*/.local/bin/debugpy*" \
            -x "*/.bash_history" \
            -x "*/.zsh_history" \
            -x "*/.mysql_history" \
            -x "*/.wget-hsts" \
            -x "*/.cloud-locale-test.skip" \
            -x "*/.DS_Store" \
            -x "*/.gitattributes" \
            -x "*/.gitignore" \
            -x "*/.gitmodules" \
            -x "*/.local/share/Trash/*" \
            -x "*/tmp/*" \
            -x "*/temp/*" \
            -x "*/logs/*" \
            -x "*/log/*" \
            -x "*/.log" \
            -x "*/backup-*.zip" \
            -x "*/.backup-telegram/*" \
            -x "/root/.local/*" \
            -x "/root/.rustup/*" \
            -x "/root/.cargo/*" \
            -x "/root/go/*" \
            -x "*/.ipynb_checkpoints/*" \
            2>&1 | tee -a "$LOG_FILE"
    } &
    
    local zip_pid=$!
    
    # Monitor progress
    while kill -0 $zip_pid 2>/dev/null; do
        if [[ -f "$backup_path" ]]; then
            local current_size=$(stat -c%s "$backup_path" 2>/dev/null || echo 0)
            local human_size=$(bytes_to_human $current_size)
            local elapsed=$(($(date +%s) - start_time))
            print_debug "Backup progress: $human_size (${elapsed}s elapsed)"
        fi
        sleep 10
    done
    
    wait $zip_pid
    return $?
}

# ===================================================================
# FUNGSI BACKUP UTAMA
# ===================================================================

run_smart_backup() {
    local start_time=$(date +%s)
    
    # Validasi sistem
    if ! validate_system; then
        print_error "System validation failed"
        return 1
    fi
    
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
    
    # Load konfigurasi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration not found! Run: $0 --setup"
        return 1
    fi
    
    source "$CONFIG_FILE"
    
    # Deteksi provider dan strategy
    local provider_info=$(detect_cloud_provider_advanced)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    local backup_type=$(echo "$provider_info" | cut -d'|' -f3)
    local provider_metadata=$(echo "$provider_info" | cut -d'|' -f4)
    
    log_message "=== SMART BACKUP STARTED ==="
    log_message "Provider: $provider"
    log_message "Target: $backup_target"
    log_message "Type: $backup_type"
    log_message "User: $CURRENT_USER (Root: $IS_ROOT)"
    log_message "System: $SYSTEM_OS $SYSTEM_ARCH"
    
    # Validasi backup target
    if [[ ! -d "$backup_target" ]]; then
        print_error "Backup target not found: $backup_target"
        send_telegram_message "❌ <b>Backup Failed</b> - Target path not found: $backup_target"
        return 1
    fi
    
    # Estimasi ukuran
    print_info "Calculating backup size..."
    local estimated_bytes=$(calculate_estimated_size "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    if [[ $estimated_bytes -gt $MAX_BACKUP_SIZE ]]; then
        print_error "Backup size too large: $estimated_size (max: $(bytes_to_human $MAX_BACKUP_SIZE))"
        send_telegram_message "❌ <b>Backup Failed</b> - Size too large: $estimated_size"
        return 1
    fi
    
    # Kirim notifikasi awal
    send_telegram_message "🔄 <b>Smart Backup Started</b>
☁️ Provider: ${provider}
📁 Type: ${backup_type}
📂 Path: ${backup_target}
📊 Est. Size: ${estimated_size}
📅 $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Buat direktori backup
    mkdir -p "$BACKUP_DIR"
    
    # Dapatkan IP server
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || \
                     curl -s --max-time 10 ipinfo.io/ip 2>/dev/null || \
                     curl -s --max-time 10 icanhazip.com 2>/dev/null || \
                     echo "unknown")
    
    # Generate nama file backup
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local provider_suffix=$(echo "$provider" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr '/' '-')
    local user_suffix=""
    
    if [[ "$IS_ROOT" != "true" ]]; then
        user_suffix="-${CURRENT_USER}"
    fi
    
    local backup_filename="backup-${ip_server}-${provider_suffix}${user_suffix}-${timestamp}.zip"
    local backup_full_path="${BACKUP_DIR}/${backup_filename}"
    
    log_message "Creating backup: $backup_filename"
    log_message "Target: $backup_target"
    log_message "Estimated size: $estimated_size"
    
    # Proses backup
    if create_backup_with_progress "$backup_full_path" "$backup_target"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [[ -f "$backup_full_path" ]]; then
            local file_size_bytes=$(stat -c%s "$backup_full_path" 2>/dev/null || stat -f%z "$backup_full_path" 2>/dev/null)
            local file_size=$(bytes_to_human $file_size_bytes)
            
            # Validasi ukuran minimum
            if [[ $file_size_bytes -lt 1024 ]]; then
                print_error "Backup file too small: $file_size"
                send_telegram_message "❌ <b>Backup Failed</b> - File too small: $file_size"
                rm -f "$backup_full_path"
                return 1
            fi
            
            log_message "Backup created successfully: $file_size (${duration}s)"
            
            # Hitung compression ratio
            local compression_ratio=0
            if [[ $estimated_bytes -gt 0 ]]; then
                compression_ratio=$(( (estimated_bytes - file_size_bytes) * 100 / estimated_bytes ))
            fi
            
            # Upload ke Telegram
            local caption="📦 <b>Smart Backup Complete</b>
☁️ Provider: ${provider}
📁 Type: ${backup_type}
📂 Path: ${backup_target}
📊 Size: ${file_size}
🗜️ Compression: ${compression_ratio}%
⏱️ Duration: ${duration}s
🖥️ System: ${SYSTEM_OS} ${SYSTEM_ARCH}
📅 $(date '+%Y-%m-%d %H:%M:%S')
✅ Status: Success"
            
            if send_telegram_file "$backup_full_path" "$caption"; then
                log_message "Upload successful"
                send_telegram_message "✅ <b>Backup Completed</b> - ${backup_filename} (${file_size})"
                
                # Update statistik
                update_backup_stats "$backup_filename" "$file_size_bytes" "$duration" "success"
                
                # Hapus file backup
                rm -f "$backup_full_path"
                log_message "Backup file removed: $backup_filename"
                
            else
                print_error "Upload failed"
                send_telegram_message "❌ <b>Upload Failed</b> - ${backup_filename}"
                update_backup_stats "$backup_filename" "$file_size_bytes" "$duration" "upload_failed"
            fi
            
        else
            print_error "Backup file not created"
            send_telegram_message "❌ <b>Backup Failed</b> - File not created"
            update_backup_stats "$backup_filename" "0" "$duration" "creation_failed"
        fi
        
    else
        print_error "Backup creation failed"
        send_telegram_message "❌ <b>Backup Failed</b> - Creation error"
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        update_backup_stats "$backup_filename" "0" "$duration" "failed"
    fi
    
    # Cleanup
    cleanup_old_backups
    rm -f "$LOCK_FILE"
    
    log_message "=== SMART BACKUP COMPLETED ==="
}

# ===================================================================
# FUNGSI STATISTIK DAN MONITORING
# ===================================================================

update_backup_stats() {
    local filename="$1"
    local size_bytes="$2"
    local duration="$3"
    local status="$4"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Buat atau update file statistik
    if [[ ! -f "$STATS_FILE" ]]; then
        echo '{"backups": [], "total_backups": 0, "total_size": 0, "avg_duration": 0}' > "$STATS_FILE"
    fi
    
    # Tambah entry baru (simplified JSON append)
    local stats_entry="{\"timestamp\": \"$timestamp\", \"filename\": \"$filename\", \"size\": $size_bytes, \"duration\": $duration, \"status\": \"$status\"}"
    
    # Update stats (basic implementation)
    echo "$stats_entry" >> "${STATS_FILE}.log"
}

cleanup_old_backups() {
    local max_backups=${MAX_BACKUPS:-5}
    
    # Cleanup backup files yang tertinggal
    if [[ -d "$BACKUP_DIR" ]]; then
        local backup_count=$(find "$BACKUP_DIR" -name "backup-*.zip" -type f | wc -l)
        
        if [[ $backup_count -gt $max_backups ]]; then
            print_info "Cleaning up old backup files..."
            find "$BACKUP_DIR" -name "backup-*.zip" -type f -printf '%T@ %p\n' | \
                sort -n | head -n -$max_backups | cut -d' ' -f2- | \
                xargs -r rm -f
            
            local remaining=$(find "$BACKUP_DIR" -name "backup-*.zip" -type f | wc -l)
            log_message "Cleanup completed. Remaining backups: $remaining"
        fi
    fi
    
    # Cleanup log files lama
    find "$(dirname "$LOG_FILE")" -name "*.log.*.old.gz" -type f -mtime +30 -delete 2>/dev/null || true
}

# ===================================================================
# FUNGSI SETUP DAN KONFIGURASI
# ===================================================================

setup_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     SMART BACKUP TELEGRAM VPS       ║${NC}"
    echo -e "${CYAN}║         Full Robust Version         ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Validasi sistem
    if ! validate_system; then
        print_error "System validation failed. Please fix the issues and try again."
        return 1
    fi
    
    # Deteksi provider dan strategy
    print_info "Detecting environment..."
    local provider_info=$(detect_cloud_provider_advanced)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    local backup_type=$(echo "$provider_info" | cut -d'|' -f3)
    local provider_metadata=$(echo "$provider_info" | cut -d'|' -f4)
    
    # Estimasi ukuran
    print_info "Calculating estimated backup size..."
    local estimated_bytes=$(calculate_estimated_size "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    local estimated_time="3-8 minutes"
    
    if [[ $estimated_bytes -gt 2147483648 ]]; then  # > 2GB
        estimated_time="8-15 minutes"
    elif [[ $estimated_bytes -gt 5368709120 ]]; then  # > 5GB
        estimated_time="15-30 minutes"
    fi
    
    print_success "Environment Detection Complete:"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  🔑 Root Access: $IS_ROOT"
    echo "  ☁️ Cloud Provider: $provider"
    echo "  📁 Backup Type: $backup_type"
    echo "  📂 Target Path: $backup_target"
    echo "  📊 Estimated Size: $estimated_size"
    echo "  ⏱️ Estimated Time: $estimated_time"
    echo "  🖥️ System: $SYSTEM_OS $SYSTEM_ARCH"
    echo
    
    # Buat direktori
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Input konfigurasi Telegram
    echo -e "${YELLOW}Telegram Bot Configuration:${NC}"
    echo
    
    local bot_token
    while true; do
        read -p "🤖 Telegram Bot Token: " bot_token
        if [[ -z "$bot_token" ]]; then
            print_error "Bot token cannot be empty!"
            continue
        fi
        
        if ! validate_bot_token "$bot_token"; then
            print_error "Invalid bot token format!"
            echo "   Expected format: 1234567890:ABCdefGHIjklMNOpqrsTUVwxyz"
            continue
        fi
        
        break
    done
    
    local chat_id
    while true; do
        read -p "💬 Telegram Chat ID: " chat_id
        if [[ -z "$chat_id" ]]; then
            print_error "Chat ID cannot be empty!"
            continue
        fi
        
        if ! validate_chat_id "$chat_id"; then
            print_error "Invalid chat ID format!"
            echo "   Expected format: 123456789 or -123456789"
            continue
        fi
        
        break
    done
    
    local interval
    while true; do
        read -p "⏰ Backup interval (hours) [default: 1]: " interval
        interval=${interval:-1}
        
        if ! validate_interval "$interval"; then
            print_error "Invalid interval! Must be between 1-168 hours."
            continue
        fi
        
        break
    done
    
    local max_backups
    while true; do
        read -p "🗂️ Maximum backups to keep [default: 5]: " max_backups
        max_backups=${max_backups:-5}
        
        if ! [[ "$max_backups" =~ ^[0-9]+$ ]] || [[ $max_backups -lt 1 ]] || [[ $max_backups -gt 50 ]]; then
            print_error "Invalid value! Must be between 1-50."
            continue
        fi
        
        break
    done
    
    # Simpan konfigurasi
    cat > "$CONFIG_FILE" << EOF
# Smart Backup Telegram VPS Configuration
# Generated on $(date '+%Y-%m-%d %H:%M:%S')

TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
BACKUP_INTERVAL="$interval"
MAX_BACKUPS="$max_backups"

# Environment Detection
CLOUD_PROVIDER="$provider"
BACKUP_TARGET="$backup_target"
BACKUP_TYPE="$backup_type"
PROVIDER_METADATA="$provider_metadata"

# System Information
SYSTEM_USER="$CURRENT_USER"
IS_ROOT="$IS_ROOT"
SYSTEM_OS="$SYSTEM_OS"
SYSTEM_ARCH="$SYSTEM_ARCH"
SCRIPT_VERSION="$SCRIPT_VERSION"

# Paths
SCRIPT_DIR="$SCRIPT_DIR"
LOG_FILE="$LOG_FILE"
BACKUP_DIR="$BACKUP_DIR"

# Timestamps
CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
LAST_UPDATED="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_success "Configuration saved to: $CONFIG_FILE"
    
    # Setup crontab
    setup_crontab "$interval"
    
    # Test koneksi Telegram
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    if test_telegram_connection; then
        # Kirim notifikasi setup complete
        send_telegram_message "🎉 <b>Smart Backup Setup Complete</b>
☁️ Provider: ${provider}
📁 Type: ${backup_type}
📂 Path: ${backup_target}
📊 Est. Size: ${estimated_size}
⏰ Interval: ${interval}h
🖥️ System: ${SYSTEM_OS} ${SYSTEM_ARCH}
✅ Ready for automatic backups!"
        
        print_success "Setup completed successfully!"
        echo
        echo -e "${GREEN}System is ready for automatic backups!${NC}"
        echo -e "${BLUE}Available commands:${NC}"
        echo -e "  ${GREEN}$0 --backup${NC}   - Manual backup"
        echo -e "  ${GREEN}$0 --status${NC}   - System status"
        echo -e "  ${GREEN}$0 --log${NC}      - View logs"
        echo -e "  ${GREEN}$0 --stats${NC}    - Backup statistics"
        echo -e "  ${GREEN}$0 --test${NC}     - Test connection"
        
    else
        print_error "Setup failed! Please check your Telegram configuration."
        return 1
    fi
}

setup_crontab() {
    local interval=$1
    local cron_schedule
    
    case $interval in
        1) cron_schedule="0 * * * *" ;;
        2) cron_schedule="0 */2 * * *" ;;
        3) cron_schedule="0 */3 * * *" ;;
        4) cron_schedule="0 */4 * * *" ;;
        6) cron_schedule="0 */6 * * *" ;;
        8) cron_schedule="0 */8 * * *" ;;
        12) cron_schedule="0 */12 * * *" ;;
        24) cron_schedule="0 2 * * *" ;;
        *) cron_schedule="0 * * * *" ;;
    esac
    
    # Hapus crontab lama
    crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME" | crontab -
    
    # Tambah crontab baru
    (crontab -l 2>/dev/null; echo "$cron_schedule $0 --backup >/dev/null 2>&1") | crontab -
    
    print_success "Crontab configured for backup every $interval hour(s)"
}

# ===================================================================
# FUNGSI STATUS DAN MONITORING
# ===================================================================

show_status() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         SYSTEM STATUS                ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # System Information
    echo -e "${BLUE}System Information:${NC}"
    echo "  🖥️ OS: $SYSTEM_OS $SYSTEM_ARCH"
    echo "  👤 User: $CURRENT_USER (Root: $IS_ROOT)"
    echo "  📅 Current Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  🌐 IP Address: $(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo 'Unknown')"
    echo
    
    # Environment Detection
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        
        echo -e "${BLUE}Environment Detection:${NC}"
        echo "  ☁️ Cloud Provider: $CLOUD_PROVIDER"
        echo "  📁 Backup Type: $BACKUP_TYPE"
        echo "  📂 Target Path: $BACKUP_TARGET"
        
        if [[ -d "$BACKUP_TARGET" ]]; then
            local current_size=$(calculate_estimated_size "$BACKUP_TARGET")
            local human_size=$(bytes_to_human $current_size)
            echo "  📊 Current Size: $human_size"
            print_success "Target path accessible"
        else
            print_error "Target path not accessible: $BACKUP_TARGET"
        fi
        echo
        
        # Configuration Status
        echo -e "${BLUE}Configuration:${NC}"
        echo "  📋 Config File: $CONFIG_FILE"
        echo "  🤖 Bot Token: ${TELEGRAM_BOT_TOKEN:0:10}..."
        echo "  💬 Chat ID: $TELEGRAM_CHAT_ID"
        echo "  ⏰ Interval: $BACKUP_INTERVAL hour(s)"
        echo "  🗂️ Max Backups: $MAX_BACKUPS"
        echo "  📅 Created: $CREATED_DATE"
        print_success "Configuration loaded"
        echo
        
        # Crontab Status
        echo -e "${BLUE}Automation Status:${NC}"
        if crontab -l 2>/dev/null | grep -q "$SCRIPT_NAME"; then
            local cron_entry=$(crontab -l 2>/dev/null | grep "$SCRIPT_NAME")
            echo "  📋 Crontab: Active"
            echo "  ⏰ Schedule: $cron_entry"
            print_success "Automatic backups enabled"
        else
            print_warning "Crontab not configured"
            echo "  💡 Run: $0 --setup to configure automatic backups"
        fi
        echo
        
        # Backup History
        echo -e "${BLUE}Backup History:${NC}"
        if [[ -f "$LOG_FILE" ]]; then
            local last_backup=$(tail -n 100 "$LOG_FILE" | grep "SMART BACKUP COMPLETED" | tail -n 1)
            local last_success=$(tail -n 100 "$LOG_FILE" | grep "Upload successful" | tail -n 1)
            local last_error=$(tail -n 100 "$LOG_FILE" | grep "ERROR" | tail -n 1)
            
            if [[ -n "$last_backup" ]]; then
                local backup_time=$(echo "$last_backup" | cut -d' ' -f1-2)
                echo "  📅 Last Backup: $backup_time"
            fi
            
            if [[ -n "$last_success" ]]; then
                echo "  ✅ Last Success: $(echo "$last_success" | cut -d' ' -f1-2)"
                print_success "Recent backup successful"
            elif [[ -n "$last_error" ]]; then
                echo "  ❌ Last Error: $(echo "$last_error" | cut -d' ' -f1-2)"
                print_warning "Recent backup had errors"
            fi
        else
            print_info "No backup history found"
        fi
        echo
        
        # System Health
        echo -e "${BLUE}System Health:${NC}"
        local disk_usage=$(df -h "$(dirname "$BACKUP_DIR")" | awk 'NR==2 {print $5}')
        local memory_usage=$(free -h | awk 'NR==2{printf "%.1f%%", $3/$2*100}' 2>/dev/null || echo "Unknown")
        local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
        
        echo "  💾 Disk Usage: $disk_usage"
        echo "  🧠 Memory Usage: $memory_usage"
        echo "  ⚡ Load Average: $load_avg"
        
        # Health warnings
        local disk_percent=$(echo "$disk_usage" | sed 's/%//')
        if [[ $disk_percent -gt 90 ]]; then
            print_warning "High disk usage: $disk_usage"
        elif [[ $disk_percent -gt 95 ]]; then
            print_error "Critical disk usage: $disk_usage"
        else
            print_success "System health good"
        fi
        
    else
        print_error "Configuration not found!"
        echo "  💡 Run: $0 --setup to configure the system"
    fi
}

show_backup_stats() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       BACKUP STATISTICS              ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    if [[ -f "${STATS_FILE}.log" ]]; then
        local total_backups=$(wc -l < "${STATS_FILE}.log")
        local successful_backups=$(grep -c '"status": "success"' "${STATS_FILE}.log" || echo 0)
        local failed_backups=$(grep -c '"status": "failed"' "${STATS_FILE}.log" || echo 0)
        
        echo -e "${BLUE}Backup Statistics:${NC}"
        echo "  📊 Total Backups: $total_backups"
        echo "  ✅ Successful: $successful_backups"
        echo "  ❌ Failed: $failed_backups"
        
        if [[ $total_backups -gt 0 ]]; then
            local success_rate=$(( successful_backups * 100 / total_backups ))
            echo "  📈 Success Rate: ${success_rate}%"
            
            if [[ $success_rate -gt 90 ]]; then
                print_success "Excellent success rate"
            elif [[ $success_rate -gt 75 ]]; then
                print_warning "Good success rate"
            else
                print_error "Poor success rate - check system health"
            fi
        fi
        
        echo
        echo -e "${BLUE}Recent Backups:${NC}"
        tail -n 10 "${STATS_FILE}.log" | while read -r line; do
            if [[ -n "$line" ]]; then
                echo "  📋 $line"
            fi
        done
        
    else
        print_info "No backup statistics available yet"
        echo "  💡 Statistics will be available after first backup"
    fi
}

show_logs() {
    local lines=${1:-50}
    
    if [[ -f "$LOG_FILE" ]]; then
        echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║         BACKUP LOGS                  ║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
        echo
        
        tail -n "$lines" "$LOG_FILE" | while read -r line; do
            if [[ $line == *"ERROR"* ]]; then
                echo -e "${RED}$line${NC}"
            elif [[ $line == *"SUCCESS"* ]] || [[ $line == *"successful"* ]]; then
                echo -e "${GREEN}$line${NC}"
            elif [[ $line == *"WARNING"* ]] || [[ $line == *"failed"* ]]; then
                echo -e "${YELLOW}$line${NC}"
            elif [[ $line == *"INFO"* ]]; then
                echo -e "${BLUE}$line${NC}"
            elif [[ $line == *"DEBUG"* ]]; then
                echo -e "${PURPLE}$line${NC}"
            else
                echo "$line"
            fi
        done
        
        echo
        echo -e "${BLUE}Log file: $LOG_FILE${NC}"
        echo -e "${BLUE}Error log: $ERROR_LOG${NC}"
        
    else
        print_error "Log file not found: $LOG_FILE"
    fi
}

# ===================================================================
# FUNGSI CLEANUP DAN EXIT
# ===================================================================

cleanup_on_exit() {
    print_debug "Performing cleanup..."
    
    # Remove lock file
    rm -f "$LOCK_FILE"
    
    # Kill background processes
    local script_pids=$(pgrep -f "$SCRIPT_NAME" | grep -v $$)
    if [[ -n "$script_pids" ]]; then
        echo "$script_pids" | xargs -r kill -TERM 2>/dev/null || true
    fi
    
    # Cleanup temporary files
    find /tmp -name "size_calc_*" -type f -mtime +1 -delete 2>/dev/null || true
    find /tmp -name "backup_estimate_*" -type f -mtime +1 -delete 2>/dev/null || true
}

# Set exit trap
trap cleanup_on_exit EXIT

# ===================================================================
# FUNGSI BANTUAN
# ===================================================================

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    SMART BACKUP TELEGRAM VPS         ║${NC}"
    echo -e "${CYAN}║         Full Robust Version         ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Smart Backup Features:${NC}"
    echo -e "  🔍 ${BLUE}Auto-detection${NC} of cloud providers (Azure, AWS, GCP, DO, etc.)"
    echo -e "  📊 ${BLUE}Size estimation${NC} with exclude patterns"
    echo -e "  🔄 ${BLUE}Retry mechanism${NC} for network operations"
    echo -e "  📈 ${BLUE}Progress monitoring${NC} and statistics"
    echo -e "  🛡️ ${BLUE}Error handling${NC} and recovery"
    echo -e "  📱 ${BLUE}Telegram integration${NC} with rich notifications"
    echo
    echo -e "${GREEN}Supported Cloud Providers:${NC}"
    echo -e "  ☁️ ${BLUE}Microsoft Azure${NC} → /home/[user] backup"
    echo -e "  ☁️ ${BLUE}Amazon AWS${NC} → /home/ec2-user or /root backup"
    echo -e "  ☁️ ${BLUE}Google Cloud${NC} → /home/ubuntu or /root backup"
    echo -e "  ☁️ ${BLUE}DigitalOcean${NC} → /root backup"
    echo -e "  ☁️ ${BLUE}Vultr${NC} → /root backup"
    echo -e "  ☁️ ${BLUE}Linode${NC} → /root backup"
    echo -e "  ☁️ ${BLUE}Contabo${NC} → /root backup"
    echo -e "  ☁️ ${BLUE}Hetzner${NC} → /root backup"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  ${BLUE}--setup${NC}       Initial setup and configuration"
    echo -e "  ${BLUE}--backup${NC}      Run manual backup"
    echo -e "  ${BLUE}--status${NC}      Show system status"
    echo -e "  ${BLUE}--stats${NC}       Show backup statistics"
    echo -e "  ${BLUE}--log [N]${NC}     Show logs (default: 50 lines)"
    echo -e "  ${BLUE}--test${NC}        Test Telegram connection"
    echo -e "  ${BLUE}--cleanup${NC}     Clean up old backups and logs"
    echo -e "  ${BLUE}--version${NC}     Show version information"
    echo -e "  ${BLUE}--help${NC}        Show this help message"
    echo
    echo -e "${GREEN}Examples:${NC}"
    echo -e "  $0 --setup        # First-time setup"
    echo -e "  $0 --backup       # Manual backup"
    echo -e "  $0 --status       # Check system status"
    echo -e "  $0 --log 100      # Show last 100 log lines"
    echo
    echo -e "${GREEN}Configuration Files:${NC}"
    echo -e "  📋 Config: ${BLUE}$CONFIG_FILE${NC}"
    echo -e "  📝 Logs: ${BLUE}$LOG_FILE${NC}"
    echo -e "  📊 Stats: ${BLUE}$STATS_FILE${NC}"
    echo -e "  🚨 Errors: ${BLUE}$ERROR_LOG${NC}"
    echo
    echo -e "${GREEN}Support:${NC}"
    echo -e "  📧 For issues, check the error log: ${BLUE}$ERROR_LOG${NC}"
    echo -e "  📱 Test Telegram connection: ${BLUE}$0 --test${NC}"
    echo -e "  🔧 Reconfigure system: ${BLUE}$0 --setup${NC}"
}

show_version() {
    echo -e "${CYAN}Smart Backup Telegram VPS${NC}"
    echo -e "Version: ${GREEN}$SCRIPT_VERSION${NC}"
    echo -e "System: ${BLUE}$SYSTEM_OS $SYSTEM_ARCH${NC}"
    echo -e "User: ${BLUE}$CURRENT_USER${NC} (Root: $IS_ROOT)"
    echo -e "Script: ${BLUE}$0${NC}"
    echo
    echo -e "${GREEN}Features:${NC}"
    echo -e "  ✅ Multi-cloud provider detection"
    echo -e "  ✅ Smart backup path selection"
    echo -e "  ✅ Size estimation with excludes"
    echo -e "  ✅ Retry mechanism and error handling"
    echo -e "  ✅ Progress monitoring"
    echo -e "  ✅ Telegram integration"
    echo -e "  ✅ Automatic cleanup"
    echo -e "  ✅ Statistics and monitoring"
}

# ===================================================================
# MAIN SCRIPT EXECUTION
# ===================================================================

main() {
    local command="${1:-}"
    
    # Create necessary directories
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
        --stats)
            show_backup_stats
            ;;
        --log)
            show_logs "${2:-50}"
            ;;
        --test)
            if [[ -f "$CONFIG_FILE" ]]; then
                source "$CONFIG_FILE"
                test_telegram_connection
            else
                print_error "Configuration not found! Run: $0 --setup"
                exit 1
            fi
            ;;
        --cleanup)
            cleanup_old_backups
            print_success "Cleanup completed"
            ;;
        --version)
            show_version
            ;;
        --help)
            show_help
            ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                show_status
            else
                print_info "Smart Backup Telegram VPS - Version $SCRIPT_VERSION"
                echo
                print_info "System not configured yet."
                echo
                read -p "Would you like to run the setup now? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    setup_backup
                else
                    echo
                    show_help
                fi
            fi
            ;;
    esac
}

# Execute main function with all arguments
main "$@"
