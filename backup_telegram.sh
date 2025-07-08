#!/bin/bash

# ===================================================================
# BACKUP TELEGRAM VPS - ZIP VERSION WITH SPECIFIC FILES
# Only backup: .env, .txt, .py, .js, package.json (not all .json)
# Version: 4.1 - ZIP Format & Package.json Filter
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
readonly SCRIPT_VERSION="4.1"
readonly SCRIPT_NAME="backup_telegram"
readonly MAX_BACKUP_SIZE=2147483648  # 2GB max
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
# FUNGSI SCAN FILE SPESIFIK
# ===================================================================

scan_specific_files() {
    local target_path="$1"
    local temp_list="/tmp/backup_files_$$"
    
    > "$temp_list"
    
    print_info "Scanning for specific files..."
    
    # Scan .env files
    find "$target_path" -type f -name "*.env" \
        ! -path "*/node_modules/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.git/*" \
        ! -path "*/tmp/*" \
        ! -path "*/.backup-telegram/*" \
        2>/dev/null >> "$temp_list"
    
    # Scan .txt files
    find "$target_path" -type f -name "*.txt" \
        ! -path "*/node_modules/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.git/*" \
        ! -path "*/tmp/*" \
        ! -path "*/.backup-telegram/*" \
        2>/dev/null >> "$temp_list"
    
    # Scan .py files
    find "$target_path" -type f -name "*.py" \
        ! -path "*/node_modules/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.git/*" \
        ! -path "*/tmp/*" \
        ! -path "*/.backup-telegram/*" \
        2>/dev/null >> "$temp_list"
    
    # Scan .js files
    find "$target_path" -type f -name "*.js" \
        ! -path "*/node_modules/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.git/*" \
        ! -path "*/tmp/*" \
        ! -path "*/.backup-telegram/*" \
        2>/dev/null >> "$temp_list"
    
    # Scan ONLY package.json files (not all .json)
    find "$target_path" -type f -name "package.json" \
        ! -path "*/node_modules/*" \
        ! -path "*/.cache/*" \
        ! -path "*/.git/*" \
        ! -path "*/tmp/*" \
        ! -path "*/.backup-telegram/*" \
        2>/dev/null >> "$temp_list"
    
    echo "$temp_list"
}

calculate_files_size() {
    local file_list="$1"
    local total_size=0
    
    if [[ -f "$file_list" ]]; then
        while IFS= read -r file; do
            if [[ -f "$file" ]]; then
                local size=$(stat -c%s "$file" 2>/dev/null || echo 0)
                total_size=$((total_size + size))
            fi
        done < "$file_list"
    fi
    
    echo $total_size
}

count_files_by_type() {
    local target_path="$1"
    
    local env_count=$(find "$target_path" -name "*.env" ! -path "*/node_modules/*" ! -path "*/.cache/*" ! -path "*/.git/*" ! -path "*/tmp/*" 2>/dev/null | wc -l)
    local txt_count=$(find "$target_path" -name "*.txt" ! -path "*/node_modules/*" ! -path "*/.cache/*" ! -path "*/.git/*" ! -path "*/tmp/*" 2>/dev/null | wc -l)
    local py_count=$(find "$target_path" -name "*.py" ! -path "*/node_modules/*" ! -path "*/.cache/*" ! -path "*/.git/*" ! -path "*/tmp/*" 2>/dev/null | wc -l)
    local js_count=$(find "$target_path" -name "*.js" ! -path "*/node_modules/*" ! -path "*/.cache/*" ! -path "*/.git/*" ! -path "*/tmp/*" 2>/dev/null | wc -l)
    local json_count=$(find "$target_path" -name "package.json" ! -path "*/node_modules/*" ! -path "*/.cache/*" ! -path "*/.git/*" ! -path "*/tmp/*" 2>/dev/null | wc -l)
    
    local total=$((env_count + txt_count + py_count + js_count + json_count))
    
    echo "$total|$env_count|$txt_count|$py_count|$js_count|$json_count"
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
# FUNGSI BACKUP ZIP
# ===================================================================

create_zip_backup() {
    local backup_path="$1"
    local target_path="$2"
    local temp_list=$(scan_specific_files "$target_path")
    
    local file_count=$(wc -l < "$temp_list" 2>/dev/null || echo 0)
    
    if [[ $file_count -eq 0 ]]; then
        print_warning "No files found matching criteria"
        rm -f "$temp_list"
        return 1
    fi
    
    print_info "Creating ZIP archive with $file_count files..."
    
    # Buat ZIP menggunakan file list
    # Gunakan @ untuk membaca file list dari stdin
    zip -@ "$backup_path" < "$temp_list" >> "$LOG_FILE" 2>&1
    local zip_result=$?
    
    rm -f "$temp_list"
    return $zip_result
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
    
    log_message "=== ZIP BACKUP STARTED ==="
    
    # Deteksi provider dan path
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    log_message "Provider: $provider"
    log_message "Target: $backup_target"
    log_message "Files: .env, .txt, .py, .js, package.json"
    
    # Validasi target
    if [[ ! -d "$backup_target" ]]; then
        print_error "Target directory not found: $backup_target"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Hitung file dan size
    local file_info=$(count_files_by_type "$backup_target")
    local total_files=$(echo "$file_info" | cut -d'|' -f1)
    local env_files=$(echo "$file_info" | cut -d'|' -f2)
    local txt_files=$(echo "$file_info" | cut -d'|' -f3)
    local py_files=$(echo "$file_info" | cut -d'|' -f4)
    local js_files=$(echo "$file_info" | cut -d'|' -f5)
    local json_files=$(echo "$file_info" | cut -d'|' -f6)
    
    # Estimasi size
    local temp_list=$(scan_specific_files "$backup_target")
    local estimated_bytes=$(calculate_files_size "$temp_list")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    rm -f "$temp_list"
    
    log_message "Found files: .env($env_files) .txt($txt_files) .py($py_files) .js($js_files) package.json($json_files)"
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
    send_telegram_message "🔄 <b>ZIP Backup Started</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Types: .env, .txt, .py, .js, package.json
📊 Files: ${total_files} (.env:${env_files} .txt:${txt_files} .py:${py_files} .js:${js_files} package.json:${json_files})
📏 Est. Size: ${estimated_size}
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
    
    log_message "Creating ZIP backup: $backup_filename"
    
    # Proses backup ZIP
    if create_zip_backup "$backup_full_path" "$backup_target"; then
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
            
            log_message "ZIP backup created: $file_size (${duration}s)"
            
            # Upload ke Telegram
            local caption="📦 <b>ZIP Backup Complete</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Types: .env, .txt, .py, .js, package.json
📊 Files: ${total_files}
📋 Breakdown: .env(${env_files}) .txt(${txt_files}) .py(${py_files}) .js(${js_files}) package.json(${json_files})
📏 Size: ${file_size}
⏱️ Duration: ${duration}s
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
    log_message "=== ZIP BACKUP COMPLETED ==="
}

# ===================================================================
# FUNGSI SETUP
# ===================================================================

setup_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     ZIP BACKUP TELEGRAM VPS         ║${NC}"
    echo -e "${CYAN}║    .env .txt .py .js package.json    ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Deteksi provider dan path
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    # Scan file spesifik
    print_info "Scanning for specific file types..."
    local file_info=$(count_files_by_type "$backup_target")
    local total_files=$(echo "$file_info" | cut -d'|' -f1)
    local env_files=$(echo "$file_info" | cut -d'|' -f2)
    local txt_files=$(echo "$file_info" | cut -d'|' -f3)
    local py_files=$(echo "$file_info" | cut -d'|' -f4)
    local js_files=$(echo "$file_info" | cut -d'|' -f5)
    local json_files=$(echo "$file_info" | cut -d'|' -f6)
    
    # Estimasi size
    local temp_list=$(scan_specific_files "$backup_target")
    local estimated_bytes=$(calculate_files_size "$temp_list")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    rm -f "$temp_list"
    
    print_success "ZIP Backup Detection Results:"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  ☁️ Cloud Provider: $provider"
    echo "  📂 Target Path: $backup_target"
    echo "  📁 File Types: .env, .txt, .py, .js, package.json ONLY"
    echo "  📊 Files Found:"
    echo "    • .env files: $env_files"
    echo "    • .txt files: $txt_files"
    echo "    • .py files: $py_files"
    echo "    • .js files: $js_files"
    echo "    • package.json: $json_files"
    echo "  📋 Total Files: $total_files"
    echo "  📏 Estimated Size: $estimated_size"
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
# ZIP Backup Configuration - Specific Files Only
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
    
    if send_telegram_message "🎉 <b>ZIP Backup Setup Complete</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Types: .env, .txt, .py, .js, package.json
📊 Files: ${total_files}
📋 Breakdown: .env(${env_files}) .txt(${txt_files}) .py(${py_files}) .js(${js_files}) package.json(${json_files})
📏 Size: ${estimated_size}
📦 Format: ZIP
✅ Ready for targeted ZIP backups!"; then
        
        print_success "Setup completed successfully!"
        echo
        echo -e "${GREEN}ZIP backup system ready!${NC}"
        echo -e "  📁 Extensions: ${BLUE}.env, .txt, .py, .js, package.json${NC}"
        echo -e "  📊 Total Files: ${BLUE}$total_files${NC}"
        echo -e "  📏 Size: ${BLUE}$estimated_size${NC}"
        echo -e "  📦 Format: ${BLUE}ZIP${NC}"
        
    else
        print_error "Setup failed! Check Telegram configuration."
        return 1
    fi
}

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     ZIP BACKUP TELEGRAM VPS         ║${NC}"
    echo -e "${CYAN}║   Specific Files Only - ZIP Format   ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}ZIP Backup Features:${NC}"
    echo -e "  📦 ${BLUE}ZIP format output${NC} (not tar.gz)"
    echo -e "  📁 ${BLUE}Specific files only${NC}: .env, .txt, .py, .js, package.json"
    echo -e "  🎯 ${BLUE}package.json filter${NC} - not all .json files"
    echo -e "  📏 ${BLUE}Accurate size estimation${NC} for targeted files"
    echo -e "  🚀 ${BLUE}Fast backup${NC} - only essential files"
    echo -e "  📊 ${BLUE}File type breakdown${NC} in notifications"
    echo
    echo -e "${GREEN}File Types Included:${NC}"
    echo -e "  • ${BLUE}.env${NC} - Environment files"
    echo -e "  • ${BLUE}.txt${NC} - Text files"
    echo -e "  • ${BLUE}.py${NC} - Python files"
    echo -e "  • ${BLUE}.js${NC} - JavaScript files"
    echo -e "  • ${BLUE}package.json${NC} - NPM package files (NOT all .json)"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  ${BLUE}--setup${NC}       Setup ZIP backup"
    echo -e "  ${BLUE}--backup${NC}      Run ZIP backup"
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
                print_info "ZIP Backup Telegram VPS - Version $SCRIPT_VERSION"
                echo
                read -p "Setup ZIP backup for specific files now? (y/n): " -n 1 -r
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
