#!/bin/bash

# ===================================================================
# BACKUP TELEGRAM VPS - PROJECT FOLDERS ONLY
# Only backup user-created project folders, not system folders
# Version: 5.0 - Project-Specific Backup
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
readonly SCRIPT_VERSION="5.0"
readonly SCRIPT_NAME="backup_telegram"
readonly MAX_BACKUP_SIZE=524288000  # 500MB max
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
# FUNGSI DETEKSI PROJECT FOLDERS
# ===================================================================

detect_project_folders() {
    local target_path="$1"
    local project_folders=()
    
    # Cari folder yang kemungkinan adalah project (bukan sistem)
    while IFS= read -r -d '' folder; do
        local folder_name=$(basename "$folder")
        
        # Skip folder sistem
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
        
        # Cek apakah folder mengandung file project
        local has_project_files=false
        
        # Cek apakah ada file .env, package.json, .py, .js di folder ini
        if find "$folder" -maxdepth 2 \( -name "*.env" -o -name "package.json" -o -name "*.py" -o -name "*.js" \) -type f | head -1 | grep -q .; then
            has_project_files=true
        fi
        
        # Jika ada file project, tambahkan ke list
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
    
    # Scan hanya di folder project
    for folder in "${project_folders[@]}"; do
        env_count=$((env_count + $(find "$folder" -name "*.env" -type f 2>/dev/null | wc -l)))
        txt_count=$((txt_count + $(find "$folder" -name "*.txt" -type f 2>/dev/null | wc -l)))
        py_count=$((py_count + $(find "$folder" -name "*.py" -type f 2>/dev/null | wc -l)))
        js_count=$((js_count + $(find "$folder" -name "*.js" -type f 2>/dev/null | wc -l)))
        json_count=$((json_count + $(find "$folder" -name "package.json" -type f 2>/dev/null | wc -l)))
    done
    
    local total=$((env_count + txt_count + py_count + js_count + json_count))
    
    echo "$total|$env_count|$txt_count|$py_count|$js_count|$json_count|${#project_folders[@]}"
}

calculate_project_size() {
    local target_path="$1"
    local project_folders=($(detect_project_folders "$target_path"))
    local total_size=0
    
    # Hitung size hanya dari folder project
    for folder in "${project_folders[@]}"; do
        for ext in "*.env" "*.txt" "*.py" "*.js" "package.json"; do
            local size=$(find "$folder" -name "$ext" -type f -printf "%s\n" 2>/dev/null | awk '{sum += $1} END {print sum+0}' 2>/dev/null || echo 0)
            total_size=$((total_size + size))
        done
    done
    
    echo $total_size
}

list_project_folders() {
    local target_path="$1"
    local project_folders=($(detect_project_folders "$target_path"))
    
    echo "📁 Project folders detected:"
    if [[ ${#project_folders[@]} -eq 0 ]]; then
        echo "  • No project folders found"
    else
        for folder in "${project_folders[@]}"; do
            local folder_name=$(basename "$folder")
            local file_count=$(find "$folder" \( -name "*.env" -o -name "*.txt" -o -name "*.py" -o -name "*.js" -o -name "package.json" \) -type f 2>/dev/null | wc -l)
            echo "  • $folder_name ($file_count files)"
        done
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
# FUNGSI BACKUP PROJECT FOLDERS
# ===================================================================

create_project_backup() {
    local backup_path="$1"
    local target_path="$2"
    local project_folders=($(detect_project_folders "$target_path"))
    
    if [[ ${#project_folders[@]} -eq 0 ]]; then
        print_warning "No project folders found"
        return 1
    fi
    
    print_info "Creating ZIP from ${#project_folders[@]} project folders..."
    
    # Buat temporary file list
    local temp_list="/tmp/project_files_$$"
    > "$temp_list"
    
    # Tambahkan file dari setiap project folder
    for folder in "${project_folders[@]}"; do
        find "$folder" \( -name "*.env" -o -name "*.txt" -o -name "*.py" -o -name "*.js" -o -name "package.json" \) -type f 2>/dev/null >> "$temp_list"
    done
    
    local file_count=$(wc -l < "$temp_list")
    print_info "Found $file_count project files to backup"
    
    if [[ $file_count -eq 0 ]]; then
        rm -f "$temp_list"
        return 1
    fi
    
    # Buat ZIP dari file list
    zip -@ "$backup_path" < "$temp_list" >> "$LOG_FILE" 2>&1
    local result=$?
    
    rm -f "$temp_list"
    return $result
}

# ===================================================================
# FUNGSI BACKUP UTAMA
# ===================================================================

run_project_backup() {
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
    
    log_message "=== PROJECT BACKUP STARTED ==="
    
    # Deteksi provider dan path
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    log_message "Provider: $provider"
    log_message "Target: $backup_target"
    log_message "Mode: Project folders only"
    
    # Validasi target
    if [[ ! -d "$backup_target" ]]; then
        print_error "Target directory not found: $backup_target"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Scan project files
    local file_info=$(scan_project_files "$backup_target")
    local total_files=$(echo "$file_info" | cut -d'|' -f1)
    local env_files=$(echo "$file_info" | cut -d'|' -f2)
    local txt_files=$(echo "$file_info" | cut -d'|' -f3)
    local py_files=$(echo "$file_info" | cut -d'|' -f4)
    local js_files=$(echo "$file_info" | cut -d'|' -f5)
    local json_files=$(echo "$file_info" | cut -d'|' -f6)
    local project_count=$(echo "$file_info" | cut -d'|' -f7)
    
    # Estimasi size
    local estimated_bytes=$(calculate_project_size "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    log_message "Found $project_count project folders with $total_files files"
    log_message "Files: .env($env_files) .txt($txt_files) .py($py_files) .js($js_files) package.json($json_files)"
    log_message "Estimated size: $estimated_size"
    
    # Validasi
    if [[ $estimated_bytes -gt $MAX_BACKUP_SIZE ]]; then
        print_error "Backup size too large: $estimated_size"
        send_telegram_message "❌ <b>Backup Failed</b> - Size too large: $estimated_size"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    if [[ $total_files -eq 0 ]]; then
        print_warning "No project files found"
        send_telegram_message "⚠️ <b>Backup Warning</b> - No project files found"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Kirim notifikasi awal
    send_telegram_message "🔄 <b>Project Backup Started</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Project Folders: ${project_count}
📊 Files: ${total_files} (.env:${env_files} .txt:${txt_files} .py:${py_files} .js:${js_files} package.json:${json_files})
📏 Est. Size: ${estimated_size}
🎯 Mode: Project folders only
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
    
    local backup_filename="backup-projects-${ip_server}${user_suffix}-${timestamp}.zip"
    local backup_full_path="${BACKUP_DIR}/${backup_filename}"
    
    log_message "Creating project backup: $backup_filename"
    
    # Proses backup
    if create_project_backup "$backup_full_path" "$backup_target"; then
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
            
            log_message "Project backup created: $file_size (${duration}s)"
            
            # Upload ke Telegram
            local caption="📦 <b>Project Backup Complete</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Project Folders: ${project_count}
📊 Files: ${total_files}
📋 Breakdown: .env(${env_files}) .txt(${txt_files}) .py(${py_files}) .js(${js_files}) package.json(${json_files})
📏 Size: ${file_size}
⏱️ Duration: ${duration}s
🎯 Mode: Project folders only (no system files)
📅 $(date '+%Y-%m-%d %H:%M:%S')
✅ Status: Success"
            
            if send_telegram_file "$backup_full_path" "$caption"; then
                log_message "Upload successful"
                send_telegram_message "✅ <b>Project Backup Completed</b> - ${backup_filename} (${project_count} folders, ${total_files} files, ${file_size})"
                
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
    log_message "=== PROJECT BACKUP COMPLETED ==="
}

# ===================================================================
# FUNGSI SETUP
# ===================================================================

setup_project_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     PROJECT BACKUP TELEGRAM VPS     ║${NC}"
    echo -e "${CYAN}║      User-Created Folders Only      ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Deteksi provider dan path
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    # Scan project folders
    print_info "Detecting project folders..."
    list_project_folders "$backup_target"
    echo
    
    # Scan project files
    local file_info=$(scan_project_files "$backup_target")
    local total_files=$(echo "$file_info" | cut -d'|' -f1)
    local env_files=$(echo "$file_info" | cut -d'|' -f2)
    local txt_files=$(echo "$file_info" | cut -d'|' -f3)
    local py_files=$(echo "$file_info" | cut -d'|' -f4)
    local js_files=$(echo "$file_info" | cut -d'|' -f5)
    local json_files=$(echo "$file_info" | cut -d'|' -f6)
    local project_count=$(echo "$file_info" | cut -d'|' -f7)
    
    # Estimasi size
    local estimated_bytes=$(calculate_project_size "$backup_target")
    local estimated_size=$(bytes_to_human $estimated_bytes)
    
    print_success "Project Backup Detection Results:"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  ☁️ Cloud Provider: $provider"
    echo "  📂 Target Path: $backup_target"
    echo "  📁 Project Folders: $project_count"
    echo "  📊 Project Files Found:"
    echo "    • .env files: $env_files"
    echo "    • .txt files: $txt_files"
    echo "    • .py files: $py_files"
    echo "    • .js files: $js_files"
    echo "    • package.json: $json_files"
    echo "  📋 Total Files: $total_files"
    echo "  📏 Estimated Size: $estimated_size"
    echo "  🎯 Mode: Project folders only (no system folders)"
    echo "  📦 Output Format: ZIP"
    echo
    
    if [[ $total_files -eq 0 ]]; then
        print_warning "No project files found in $backup_target"
        echo "Make sure you have project folders with .env, .txt, .py, .js, or package.json files."
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
# Project Backup Configuration - User Folders Only
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
BACKUP_INTERVAL="$interval"

# Detection Results
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
    
    if send_telegram_message "🎉 <b>Project Backup Setup Complete</b>
☁️ Provider: ${provider}
📂 Path: ${backup_target}
📁 Project Folders: ${project_count}
📊 Files: ${total_files}
📋 Breakdown: .env(${env_files}) .txt(${txt_files}) .py(${py_files}) .js(${js_files}) package.json(${json_files})
📏 Size: ${estimated_size}
🎯 Mode: Project folders only
📦 Format: ZIP
✅ Ready for project-specific backups!"; then
        
        print_success "Setup completed successfully!"
        echo
        echo -e "${GREEN}Project backup system ready!${NC}"
        echo -e "  📁 Target: ${BLUE}Project folders only${NC}"
        echo -e "  📊 Total Files: ${BLUE}$total_files${NC}"
        echo -e "  📏 Size: ${BLUE}$estimated_size${NC}"
        echo -e "  🎯 Mode: ${BLUE}User-created folders only${NC}"
        echo -e "  📦 Format: ${BLUE}ZIP${NC}"
        
    else
        print_error "Setup failed! Check Telegram configuration."
        return 1
    fi
}

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     PROJECT BACKUP TELEGRAM VPS     ║${NC}"
    echo -e "${CYAN}║      User-Created Folders Only      ║${NC}"
    echo -e "${CYAN}║            Version $SCRIPT_VERSION            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Project-Specific Features:${NC}"
    echo -e "  🎯 ${BLUE}Project folders only${NC} - no system folders"
    echo -e "  📁 ${BLUE}Smart detection${NC} - finds folders with .env, package.json, etc."
    echo -e "  🚫 ${BLUE}Excludes system folders${NC} - .local, .cache, Downloads, etc."
    echo -e "  📦 ${BLUE}ZIP format output${NC}"
    echo -e "  📏 ${BLUE}Small backup size${NC} - only your project files"
    echo -e "  🚀 ${BLUE}Fast backup${NC} - no unnecessary system files"
    echo
    echo -e "${GREEN}Detection Logic:${NC}"
    echo -e "  • ${BLUE}Includes${NC}: Folders containing .env, package.json, .py, .js files"
    echo -e "  • ${BLUE}Excludes${NC}: Hidden folders (.*), system folders (Downloads, Desktop, etc.)"
    echo -e "  • ${BLUE}Result${NC}: Only your actual project/work folders"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  ${BLUE}--setup${NC}       Setup project-specific backup"
    echo -e "  ${BLUE}--backup${NC}      Run project backup"
    echo -e "  ${BLUE}--help${NC}        Show this help"
}

# ===================================================================
# MAIN SCRIPT
# ===================================================================

main() {
    case "${1:-}" in
        --setup) setup_project_backup ;;
        --backup) run_project_backup ;;
        --help) show_help ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                run_project_backup
            else
                print_info "Project Backup Telegram VPS - Version $SCRIPT_VERSION"
                echo
                read -p "Setup project-specific backup now? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    setup_project_backup
                else
                    show_help
                fi
            fi
            ;;
    esac
}

main "$@"
