#!/bin/bash

# ===================================================================
# BACKUP TELEGRAM VPS - DYNAMIC USER DETECTION VERSION
# Author: Backup System
# Version: 3.1 - Fixed Dynamic Detection
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

# Konfigurasi global
readonly SCRIPT_VERSION="3.1"
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
readonly STATS_FILE="${SCRIPT_DIR}/stats.json"
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

# ===================================================================
# FUNGSI DETEKSI USER DINAMIS
# ===================================================================

detect_vps_users() {
    local users_list=()
    
    # Deteksi semua user dengan home directory
    while IFS=: read -r username _ uid _ _ home_dir _; do
        # Skip system users (UID < 1000) kecuali root
        if [[ $uid -ge 1000 ]] || [[ "$username" == "root" ]]; then
            # Cek apakah home directory ada dan bukan template
            if [[ -d "$home_dir" && "$home_dir" != "/dev/null" && "$home_dir" != "/nonexistent" ]]; then
                users_list+=("$username:$home_dir")
            fi
        fi
    done < /etc/passwd
    
    # Tambahkan deteksi khusus untuk cloud providers
    local cloud_users=()
    
    # Deteksi user Azure (biasanya nama custom seperti ichiazure)
    for home_dir in /home/*; do
        if [[ -d "$home_dir" ]]; then
            local username=$(basename "$home_dir")
            # Cek apakah user ada di sistem dan punya shell
            if id "$username" &>/dev/null && getent passwd "$username" | grep -v "/bin/false\|/usr/sbin/nologin" &>/dev/null; then
                cloud_users+=("$username:$home_dir")
            fi
        fi
    done
    
    # Gabungkan dan deduplikasi
    local all_users=("${users_list[@]}" "${cloud_users[@]}")
    printf '%s\n' "${all_users[@]}" | sort -u
}

get_primary_user() {
    local detected_users=($(detect_vps_users))
    local primary_user=""
    local primary_home=""
    
    # Priority order untuk memilih primary user
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
    
    # Jika tidak ada yang match priority, ambil user pertama (bukan root)
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
    
    # Fallback ke root jika tidak ada user lain
    if [[ -z "$primary_user" ]]; then
        primary_user="root"
        primary_home="/root"
    fi
    
    echo "$primary_user:$primary_home"
}

# ===================================================================
# FUNGSI DETEKSI CLOUD PROVIDER YANG DIPERBAIKI
# ===================================================================

detect_cloud_provider_advanced() {
    local provider="Unknown"
    local backup_path=""
    local backup_type=""
    local provider_metadata=""
    
    # Deteksi Microsoft Azure
    if [[ -f /var/lib/waagent/Incarnation ]] || [[ -d /var/lib/waagent ]] || \
       [[ -n $(curl -s -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" --max-time 3 2>/dev/null) ]]; then
        
        provider="Microsoft Azure"
        provider_metadata=$(curl -s -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" --max-time 5 2>/dev/null || echo "")
        
        if [[ "$IS_ROOT" == "true" ]]; then
            # Gunakan deteksi user dinamis
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
    elif [[ -n $(curl -s http://169.254.169.254/latest/meta-data/instance-id --max-time 3 2>/dev/null) ]]; then
        provider="Amazon AWS"
        provider_metadata=$(curl -s http://169.254.169.254/latest/meta-data/instance-type --max-time 5 2>/dev/null || echo "")
        
        local primary_user_info=$(get_primary_user)
        local primary_user=$(echo "$primary_user_info" | cut -d':' -f1)
        local primary_home=$(echo "$primary_user_info" | cut -d':' -f2)
        
        backup_path="$primary_home"
        backup_type="AWS User Home ($primary_user)"
    
    # Deteksi Google Cloud Platform
    elif [[ -n $(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/id --max-time 3 2>/dev/null) ]]; then
        provider="Google Cloud"
        provider_metadata=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/machine-type --max-time 5 2>/dev/null || echo "")
        
        local primary_user_info=$(get_primary_user)
        local primary_user=$(echo "$primary_user_info" | cut -d':' -f1)
        local primary_home=$(echo "$primary_user_info" | cut -d':' -f2)
        
        backup_path="$primary_home"
        backup_type="GCP User Home ($primary_user)"
    
    # Deteksi DigitalOcean
    elif [[ -n $(curl -s http://169.254.169.254/metadata/v1/id --max-time 3 2>/dev/null) ]]; then
        provider="DigitalOcean"
        provider_metadata=$(curl -s http://169.254.169.254/metadata/v1/region --max-time 5 2>/dev/null || echo "")
        backup_path="/root"
        backup_type="DigitalOcean Root"
    
    # Deteksi Vultr
    elif [[ -f /etc/vultr ]] || [[ -n $(curl -s http://169.254.169.254/v1/instanceid --max-time 3 2>/dev/null) ]]; then
        provider="Vultr"
        provider_metadata=$(curl -s http://169.254.169.254/v1/region --max-time 5 2>/dev/null || echo "")
        backup_path="/root"
        backup_type="Vultr Root"
    
    # Deteksi Contabo
    elif [[ $(hostname) =~ vmi[0-9]+ ]] || [[ $(hostname) =~ contabo ]]; then
        provider="Contabo"
        backup_path="/root"
        backup_type="Contabo Root"
    
    # Default fallback dengan deteksi user dinamis
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
        if [[ "$IS_ROOT" == "true" ]]; then
            # Coba fallback ke user lain
            local primary_user_info=$(get_primary_user)
            local fallback_home=$(echo "$primary_user_info" | cut -d':' -f2)
            
            if [[ -d "$fallback_home" ]]; then
                backup_path="$fallback_home"
                backup_type="Fallback User Home ($(echo "$primary_user_info" | cut -d':' -f1))"
            else
                backup_path="/root"
                backup_type="Fallback Root"
            fi
        else
            backup_path="$USER_HOME"
            backup_type="Fallback User Home"
        fi
    fi
    
    # Return hasil tanpa debug output
    echo "$provider|$backup_path|$backup_type|$provider_metadata"
}

# ===================================================================
# FUNGSI ESTIMASI SIZE DENGAN EXCLUDE LENGKAP
# ===================================================================

calculate_estimated_size() {
    local target_path="$1"
    
    if [[ ! -d "$target_path" ]]; then
        echo 0
        return
    fi
    
    # Hitung ukuran dengan exclude patterns lengkap
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
# FUNGSI TELEGRAM API
# ===================================================================

send_telegram_message() {
    local message="$1"
    local retry_count=0
    local response
    
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        response=$(curl -s --max-time "$API_TIMEOUT" \
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
    local response
    
    if [[ ! -f "$file_path" ]]; then
        return 1
    fi
    
    local file_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    if [[ $file_size -gt 52428800 ]]; then
        print_error "File too large for Telegram: $(bytes_to_human $file_size)"
        return 1
    fi
    
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        response=$(curl -s --max-time "$UPLOAD_TIMEOUT" \
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
    
    local bot_name=$(echo "$me_response" | grep -o '"first_name":"[^"]*"' | cut -d'"' -f4)
    print_success "Bot connected: $bot_name"
    
    if send_telegram_message "🔧 <b>Connection Test</b> - Dynamic backup system ready!"; then
        print_success "Telegram connection successful!"
        return 0
    else
        print_error "Failed to send test message!"
        return 1
    fi
}

# ===================================================================
# FUNGSI BACKUP DENGAN PROGRESS
# ===================================================================

create_backup_with_progress() {
    local backup_path="$1"
    local target_path="$2"
    local start_time=$(date +%s)
    
    print_info "Creating backup archive..."
    
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
# FUNGSI BACKUP UTAMA YANG DIPERBAIKI
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
    
    # Load konfigurasi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration not found! Run: $0 --setup"
        return 1
    fi
    
    source "$CONFIG_FILE"
    
    log_message "=== SMART BACKUP STARTED ==="
    
    # Deteksi provider dengan error handling
    local provider_info=""
    provider_info=$(detect_cloud_provider_advanced)
    
    if [[ -z "$provider_info" || "$provider_info" == *"DEBUG"* ]]; then
        print_warning "Provider detection failed, using fallback"
        provider_info="Generic VPS|/root|Generic Root|"
    fi
    
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    local backup_type=$(echo "$provider_info" | cut -d'|' -f3)
    local provider_metadata=$(echo "$provider_info" | cut -d'|' -f4)
    
    # Log deteksi hasil
    log_message "Provider: $provider"
    log_message "Target: $backup_target"
    log_message "Type: $backup_type"
    log_message "User: $CURRENT_USER (Root: $IS_ROOT)"
    log_message "System: $SYSTEM_OS $SYSTEM_ARCH"
    
    # Validasi backup target dengan multiple fallback
    if [[ ! -d "$backup_target" ]]; then
        print_warning "Primary target not accessible: $backup_target"
        
        # Fallback sequence
        local fallback_targets=("/home/ichiazure" "/home/azureuser" "/home/ubuntu" "/home/ec2-user" "/root")
        local found_target=""
        
        for target in "${fallback_targets[@]}"; do
            if [[ -d "$target" ]]; then
                found_target="$target"
                backup_type="Fallback $(basename "$target") Home"
                break
            fi
        done
        
        if [[ -n "$found_target" ]]; then
            backup_target="$found_target"
            print_info "Using fallback target: $backup_target"
        else
            print_error "No valid backup target found"
            send_telegram_message "❌ <b>Backup Failed</b> - No accessible target directory"
            rm -f "$LOCK_FILE"
            return 1
        fi
    fi
    
    # Estimasi ukuran
    print_info "Calculating backup size for: $backup_target"
    local estimated_bytes=$(calculate_estimated_size "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    if [[ $estimated_bytes -gt $MAX_BACKUP_SIZE ]]; then
        print_error "Backup size too large: $estimated_size"
        send_telegram_message "❌ <b>Backup Failed</b> - Size too large: $estimated_size"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Kirim notifikasi awal
    send_telegram_message "🔄 <b>Dynamic Backup Started</b>
☁️ Provider: ${provider}
📁 Type: ${backup_type}
📂 Path: ${backup_target}
📊 Est. Size: ${estimated_size}
👤 Detected User: $(basename "$backup_target")
📅 $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Buat direktori backup
    mkdir -p "$BACKUP_DIR"
    
    # Dapatkan IP server
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || \
                     curl -s --max-time 10 ipinfo.io/ip 2>/dev/null || \
                     echo "unknown")
    
    # Generate nama file backup dengan user detection
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
    log_message "Target: $backup_target"
    log_message "Estimated size: $estimated_size"
    
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
            
            # Hitung compression ratio
            local compression_ratio=0
            if [[ $estimated_bytes -gt 0 ]]; then
                compression_ratio=$(( (estimated_bytes - file_size_bytes) * 100 / estimated_bytes ))
            fi
            
            # Upload ke Telegram
            local caption="📦 <b>Dynamic Backup Complete</b>
☁️ Provider: ${provider}
📁 Type: ${backup_type}
📂 Path: ${backup_target}
👤 User: $(basename "$backup_target")
📊 Size: ${file_size}
🗜️ Compression: ${compression_ratio}%
⏱️ Duration: ${duration}s
🖥️ System: ${SYSTEM_OS} ${SYSTEM_ARCH}
📅 $(date '+%Y-%m-%d %H:%M:%S')
✅ Status: Success"
            
            if send_telegram_file "$backup_full_path" "$caption"; then
                log_message "Upload successful"
                send_telegram_message "✅ <b>Dynamic Backup Completed</b> - ${backup_filename} (${file_size})"
                
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
    log_message "=== SMART BACKUP COMPLETED ==="
}

# ===================================================================
# FUNGSI SETUP DENGAN DETEKSI DINAMIS
# ===================================================================

setup_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     DYNAMIC BACKUP TELEGRAM VPS     ║${NC}"
    echo -e "${CYAN}║        Smart User Detection          ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Deteksi users yang tersedia
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
    
    # Deteksi provider dan strategy
    print_info "Detecting cloud provider and backup strategy..."
    local provider_info=$(detect_cloud_provider_advanced)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    local backup_type=$(echo "$provider_info" | cut -d'|' -f3)
    
    # Estimasi ukuran
    local estimated_bytes=$(calculate_estimated_size "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    print_success "Dynamic Detection Results:"
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
    
    # Simpan konfigurasi
    cat > "$CONFIG_FILE" << EOF
# Dynamic Backup Telegram VPS Configuration
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
BACKUP_INTERVAL="$interval"
MAX_BACKUPS="$max_backups"

# Dynamic Detection Results
CLOUD_PROVIDER="$provider"
BACKUP_TARGET="$backup_target"
BACKUP_TYPE="$backup_type"
DETECTED_USER="$(basename "$backup_target")"

# System Information
SYSTEM_USER="$CURRENT_USER"
IS_ROOT="$IS_ROOT"
SYSTEM_OS="$SYSTEM_OS"
SYSTEM_ARCH="$SYSTEM_ARCH"
SCRIPT_VERSION="$SCRIPT_VERSION"

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
    
    crontab -l 2>/dev/null | grep -v "$SCRIPT_NAME" | crontab -
    (crontab -l 2>/dev/null; echo "$cron_schedule $0 --backup >/dev/null 2>&1") | crontab -
    print_success "Crontab configured for backup every $interval hour(s)"
    
    # Test koneksi Telegram
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    if test_telegram_connection; then
        send_telegram_message "🎉 <b>Dynamic Backup Setup Complete</b>
☁️ Provider: ${provider}
📁 Type: ${backup_type}
📂 Path: ${backup_target}
👤 Detected User: $(basename "$backup_target")
📊 Est. Size: ${estimated_size}
⏰ Interval: ${interval}h
🖥️ System: ${SYSTEM_OS} ${SYSTEM_ARCH}
✅ Ready for automatic backups!"
        
        print_success "Setup completed successfully!"
        echo
        echo -e "${GREEN}Dynamic backup system is ready!${NC}"
        echo -e "  📂 Target: ${BLUE}$backup_target${NC}"
        echo -e "  👤 User: ${BLUE}$(basename "$backup_target")${NC}"
        echo -e "  📊 Size: ${BLUE}$estimated_size${NC}"
        
    else
        print_error "Setup failed! Please check your Telegram configuration."
        return 1
    fi
}

# ===================================================================
# FUNGSI STATUS DAN MONITORING
# ===================================================================

show_status() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      DYNAMIC BACKUP STATUS           ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Deteksi real-time
    print_info "Performing real-time detection..."
    local provider_info=$(detect_cloud_provider_advanced)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    local backup_type=$(echo "$provider_info" | cut -d'|' -f3)
    
    echo -e "${BLUE}Real-time Detection:${NC}"
    echo "  ☁️ Provider: $provider"
    echo "  📁 Backup Type: $backup_type"
    echo "  📂 Target Path: $backup_target"
    echo "  👤 Target User: $(basename "$backup_target")"
    
    if [[ -d "$backup_target" ]]; then
        local current_size=$(calculate_estimated_size "$backup_target")
        local human_size=$(bytes_to_human $current_size)
        echo "  📊 Current Size: $human_size"
        print_success "Target path accessible"
    else
        print_error "Target path not accessible: $backup_target"
    fi
    echo
    
    # Available users
    echo -e "${BLUE}Available Users:${NC}"
    local detected_users=($(detect_vps_users))
    for user_info in "${detected_users[@]}"; do
        local username=$(echo "$user_info" | cut -d':' -f1)
        local home_dir=$(echo "$user_info" | cut -d':' -f2)
        local size=$(du -sh "$home_dir" 2>/dev/null | cut -f1 || echo "Unknown")
        echo "  👤 $username → $home_dir ($size)"
    done
    echo
    
    # Configuration status
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        
        echo -e "${BLUE}Configuration:${NC}"
        echo "  📋 Config File: $CONFIG_FILE"
        echo "  🤖 Bot Token: ${TELEGRAM_BOT_TOKEN:0:10}..."
        echo "  💬 Chat ID: $TELEGRAM_CHAT_ID"
        echo "  ⏰ Interval: $BACKUP_INTERVAL hour(s)"
        echo "  🗂️ Max Backups: $MAX_BACKUPS"
        echo "  👤 Configured User: ${DETECTED_USER:-'Auto-detect'}"
        echo "  📅 Created: $CREATED_DATE"
        print_success "Configuration loaded"
        echo
        
        # Crontab status
        if crontab -l 2>/dev/null | grep -q "$SCRIPT_NAME"; then
            print_success "Automatic backups: Enabled"
        else
            print_warning "Automatic backups: Disabled"
        fi
        
    else
        print_error "Configuration not found! Run: $0 --setup"
    fi
}

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    DYNAMIC BACKUP TELEGRAM VPS       ║${NC}"
    echo -e "${CYAN}║        Smart User Detection          ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Dynamic Features:${NC}"
    echo -e "  🔍 ${BLUE}Auto-detection${NC} of VPS users (ichiazure, azureuser, ubuntu, etc.)"
    echo -e "  ☁️ ${BLUE}Cloud provider${NC} detection with user-specific paths"
    echo -e "  📊 ${BLUE}Smart sizing${NC} with comprehensive exclude patterns"
    echo -e "  🛡️ ${BLUE}Fallback system${NC} for maximum reliability"
    echo -e "  📱 ${BLUE}Rich notifications${NC} with user and provider info"
    echo
    echo -e "${GREEN}Supported Scenarios:${NC}"
    echo -e "  ☁️ ${BLUE}Azure VM${NC} → Auto-detect user (ichiazure, azureuser, etc.)"
    echo -e "  ☁️ ${BLUE}AWS EC2${NC} → Auto-detect user (ec2-user, ubuntu, etc.)"
    echo -e "  ☁️ ${BLUE}Google Cloud${NC} → Auto-detect user (ubuntu, debian, etc.)"
    echo -e "  ☁️ ${BLUE}DigitalOcean${NC} → Root backup"
    echo -e "  ☁️ ${BLUE}Other VPS${NC} → Smart fallback detection"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  ${BLUE}--setup${NC}       Setup with dynamic detection"
    echo -e "  ${BLUE}--backup${NC}      Run smart backup"
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
                source "$CONFIG_FILE"
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
                print_info "Dynamic Backup Telegram VPS - Version $SCRIPT_VERSION"
                echo
                print_info "System not configured yet."
                echo
                read -p "Would you like to run the dynamic setup now? (y/n): " -n 1 -r
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
