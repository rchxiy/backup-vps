#!/bin/bash

# ===================================================================
# BACKUP TELEGRAM VPS - FILE SPECIFIC VERSION
# Only backup specific file types: .env, .txt, .py, .js, package.json
# Version: 4.0 - Simple & Targeted
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
readonly SCRIPT_VERSION="4.0"
readonly SCRIPT_NAME="backup_telegram"
readonly MAX_BACKUP_SIZE=2147483648  # 2GB max
readonly API_TIMEOUT=30
readonly UPLOAD_TIMEOUT=600
readonly MAX_RETRIES=5

# File extensions yang akan di-backup (WHITELIST)
readonly BACKUP_EXTENSIONS=("*.env" "*.txt" "*.py" "*.js" "*.json" "*.md" "*.yml" "*.yaml" "*.conf" "*.config")

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
# FUNGSI ESTIMASI SIZE UNTUK FILE SPESIFIK
# ===================================================================

calculate_specific_files_size() {
    local target_path="$1"
    local total_size=0
    
    if [[ ! -d "$target_path" ]]; then
        echo 0
        return
    fi
    
    print_info "Scanning for specific file types..."
    
    # Hitung ukuran hanya untuk file extensions yang diinginkan
    for ext in "${BACKUP_EXTENSIONS[@]}"; do
        local size=$(find "$target_path" -type f -name "$ext" \
            ! -path "*/node_modules/*" \
            ! -path "*/.cache/*" \
            ! -path "*/.git/*" \
            ! -path "*/tmp/*" \
            ! -path "*/.backup-telegram/*" \
            -printf "%s\n" 2>/dev/null | \
            awk '{sum += $1} END {print sum+0}' 2>/dev/null || echo 0)
        
        total_size=$((total_size + size))
    done
    
    echo $total_size
}

count_specific_files() {
    local target_path="$1"
    local total_files=0
    
    for ext in "${BACKUP_EXTENSIONS[@]}"; do
        local count=$(find "$target_path" -type f -name "$ext" \
            ! -path "*/node_modules/*" \
            ! -path "*/.cache/*" \
            ! -path "*/.git/*" \
            ! -path "*/tmp/*" \
            ! -path "*/.backup-telegram/*" \
            2>/dev/null | wc -l)
        
        total_files=$((total_files + count))
    done
    
    echo $total_files
}

bytes_to_human() {
    local bytes=$1
    local units=("B" "KB" "MB" "GB")
    local unit=0
    
    while [[ $bytes -gt 1024 && $unit -lt 3 ]]; do
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
# FUNGSI BACKUP FILE SPESIFIK
# ===================================================================

create_specific_backup() {
    local backup_path="$1"
    local target_path="$2"
    local temp_list="/tmp/backup_files_$$"
    
    print_info "Creating file list for specific extensions..."
    
    # Buat daftar file yang akan di-backup
    > "$temp_list"
    
    for ext in "${BACKUP_EXTENSIONS[@]}"; do
        find "$target_path" -type f -name "$ext" \
            ! -path "*/node_modules/*" \
            ! -path "*/.cache/*" \
            ! -path "*/.git/*" \
            ! -path "*/tmp/*" \
            ! -path "*/.backup-telegram/*" \
            2>/dev/null >> "$temp_list"
    done
    
    local file_count=$(wc -l < "$temp_list")
    print_info "Found $file_count files to backup"
    
    if [[ $file_count -eq 0 ]]; then
        print_warning "No files found matching criteria"
        rm -f "$temp_list"
        return 1
    fi
    
    # Buat backup menggunakan file list
    print_info "Creating archive from file list..."
    
    # Gunakan tar untuk backup file spesifik (lebih efisien untuk file list)
    tar -czf "$backup_path" -T "$temp_list" 2>/dev/null || {
        # Fallback ke zip jika tar gagal
        zip -@ "$backup_path" < "$temp_list" >> "$LOG_FILE" 2>&1
    }
    
    rm -f "$temp_list"
    return $?
}

# ===================================================================
# FUNGSI BACKUP UTAMA
# ===================================================================

run_specific_backup() {
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
    
    log_message "=== FILE-SPECIFIC BACKUP STARTED ==="
    
    # Deteksi provider dan path
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    log_message "Provider: $provider"
    log_message "Target: $backup_target"
    log_message "Extensions: ${BACKUP_EXTENSIONS[*]}"
    
    # Validasi target
    if [[ ! -d "$backup_target" ]]; then
        print_error "Target directory not found: $backup_target"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Hitung ukuran dan jumlah file spesifik
    local estimated_bytes=$(calculate_specific_files_size "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    local file_count=$(count_specific_files "$backup_target")
    
    log_message "Found $file_count files, estimated size: $estimated_size"
    
    if [[ $estimated_bytes -gt $MAX_BACKUP_SIZE ]]; then
        print_error "Backup size too large: $estimated_size"
        send_telegram_message "❌ <b>Backup Failed</b> - Size too large: $estimated_size"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    if [[ $file_count -eq 0 ]]; then
        print_warning "No files found to backup"
        send_telegram_message "⚠️ <b>Backup Warning</b> - No files found matching criteria"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Kirim notifikasi awal
    send_telegram_message "🔄 <b>File-Specific Backup Started</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Extensions: .env, .txt, .py, .js, .json, .md
📊 Files: ${file_count}
📏 Est. Size: ${estimated_size}
📅 $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Buat direktori backup
    mkdir -p "$BACKUP_DIR"
    
    # Generate nama file
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unknown")
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local user_suffix=""
    
    if [[ "$backup_target" != "/root" ]]; then
        user_suffix="-$(basename "$backup_target")"
    fi
    
    local backup_filename="backup-files-${ip_server}${user_suffix}-${timestamp}.tar.gz"
    local backup_full_path="${BACKUP_DIR}/${backup_filename}"
    
    log_message "Creating backup: $backup_filename"
    
    # Proses backup
    if create_specific_backup "$backup_full_path" "$backup_target"; then
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
            
            log_message "Backup created: $file_size (${duration}s)"
            
            # Upload ke Telegram
            local caption="📦 <b>File-Specific Backup Complete</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Types: .env, .txt, .py, .js, .json, .md
📊 Files: ${file_count}
📏 Size: ${file_size}
⏱️ Duration: ${duration}s
📅 $(date '+%Y-%m-%d %H:%M:%S')
✅ Status: Success"
            
            if send_telegram_file "$backup_full_path" "$caption"; then
                log_message "Upload successful"
                send_telegram_message "✅ <b>File Backup Completed</b> - ${backup_filename} (${file_count} files, ${file_size})"
                
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
        send_telegram_message "❌ <b>Backup Failed</b> - Creation error"
    fi
    
    # Cleanup
    rm -f "$LOCK_FILE"
    log_message "=== FILE-SPECIFIC BACKUP COMPLETED ==="
}

# ===================================================================
# FUNGSI SETUP
# ===================================================================

setup_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     FILE-SPECIFIC BACKUP TELEGRAM   ║${NC}"
    echo -e "${CYAN}║        Simple & Targeted             ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Deteksi provider dan path
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    # Scan file spesifik
    print_info "Scanning for specific file types..."
    local estimated_bytes=$(calculate_specific_files_size "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    local file_count=$(count_specific_files "$backup_target")
    
    print_success "File-Specific Detection Results:"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  ☁️ Cloud Provider: $provider"
    echo "  📂 Target Path: $backup_target"
    echo "  📁 File Types: .env, .txt, .py, .js, .json, .md, .yml, .conf"
    echo "  📊 Files Found: $file_count"
    echo "  📏 Estimated Size: $estimated_size"
    echo
    
    if [[ $file_count -eq 0 ]]; then
        print_warning "No files found matching criteria in $backup_target"
        echo "Make sure you have .env, .txt, .py, .js, or .json files in the target directory."
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
# File-Specific Backup Configuration
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
BACKUP_INTERVAL="$interval"

# Detection Results
CLOUD_PROVIDER="$provider"
BACKUP_TARGET="$backup_target"
FILE_COUNT="$file_count"
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
    
    if send_telegram_message "🎉 <b>File-Specific Backup Setup</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Types: .env, .txt, .py, .js, .json
📊 Files: ${file_count}
📏 Size: ${estimated_size}
✅ Ready for targeted backups!"; then
        
        print_success "Setup completed successfully!"
        echo
        echo -e "${GREEN}File-specific backup system ready!${NC}"
        echo -e "  📁 Extensions: ${BLUE}.env, .txt, .py, .js, .json, .md${NC}"
        echo -e "  📊 Files: ${BLUE}$file_count${NC}"
        echo -e "  📏 Size: ${BLUE}$estimated_size${NC}"
        
    else
        print_error "Setup failed! Check Telegram configuration."
        return 1
    fi
}

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    FILE-SPECIFIC BACKUP TELEGRAM     ║${NC}"
    echo -e "${CYAN}║         Simple & Targeted            ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}File-Specific Features:${NC}"
    echo -e "  📁 ${BLUE}Only backup specific files${NC}: .env, .txt, .py, .js, .json, .md"
    echo -e "  📏 ${BLUE}Accurate size estimation${NC} for targeted files only"
    echo -e "  🚀 ${BLUE}Fast backup${NC} - no unnecessary files"
    echo -e "  📱 ${BLUE}File count tracking${NC} in notifications"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  ${BLUE}--setup${NC}       Setup file-specific backup"
    echo -e "  ${BLUE}--backup${NC}      Run targeted backup"
    echo -e "  ${BLUE}--help${NC}        Show this help"
}

# ===================================================================
# MAIN SCRIPT
# ===================================================================

main() {
    case "${1:-}" in
        --setup) setup_backup ;;
        --backup) run_specific_backup ;;
        --help) show_help ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                run_specific_backup
            else
                print_info "File-Specific Backup Telegram VPS - Version $SCRIPT_VERSION"
                echo
                read -p "Setup file-specific backup now? (y/n): " -n 1 -r
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
