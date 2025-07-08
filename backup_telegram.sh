#!/bin/bash

# ===================================================================
# BACKUP TELEGRAM VPS - SPLIT ZIP VERSION
# Project folders with auto-split for Telegram 50MB limit
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
readonly MAX_BACKUP_SIZE=524288000  # 500MB max
readonly TELEGRAM_FILE_LIMIT=50331648  # 48MB untuk safety margin
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
    echo "${timestamp} - ${CURRENT_USER} - ${message}" >> "$LOG_FILE"
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
# FUNGSI DETEKSI
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

# ===================================================================
# FUNGSI SCAN PROJECT
# ===================================================================

detect_project_folders() {
    local target_path="$1"
    local project_folders=()
    
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
    
    local total=$((env_count + txt_count + py_count + js_count + json_count))
    echo "$total|$env_count|$txt_count|$py_count|$js_count|$json_count|${#project_folders[@]}"
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
    
    echo "📁 Project folders detected:"
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
        log_message "File not found: $file_path"
        return 1
    fi
    
    local file_size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    
    # Cek ukuran file sebelum upload
    if [[ $file_size -gt $TELEGRAM_FILE_LIMIT ]]; then
        print_error "File too large for Telegram: $(bytes_to_human $file_size) (max: $(bytes_to_human $TELEGRAM_FILE_LIMIT))"
        log_message "File too large: $file_path ($(bytes_to_human $file_size))"
        return 1
    fi
    
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        print_info "Uploading $(basename "$file_path") ($(bytes_to_human $file_size))..."
        
        local response=$(curl -s --max-time "$UPLOAD_TIMEOUT" \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
            -F chat_id="${TELEGRAM_CHAT_ID}" \
            -F document=@"${file_path}" \
            -F caption="${caption}" 2>/dev/null)
        
        if [[ $response == *"\"ok\":true"* ]]; then
            print_success "Uploaded: $(basename "$file_path")"
            log_message "Upload successful: $(basename "$file_path")"
            return 0
        fi
        
        ((retry_count++))
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            print_warning "Upload retry $retry_count/$MAX_RETRIES for $(basename "$file_path")"
            sleep 5
        fi
    done
    
    print_error "Upload failed: $(basename "$file_path")"
    log_message "Upload failed after $MAX_RETRIES attempts: $(basename "$file_path")"
    return 1
}

# ===================================================================
# FUNGSI BACKUP DENGAN SPLIT ZIP
# ===================================================================

create_split_backup() {
    local backup_path="$1"
    local target_path="$2"
    local project_folders=($(detect_project_folders "$target_path"))
    
    if [[ ${#project_folders[@]} -eq 0 ]]; then
        print_error "No project folders found"
        return 1
    fi
    
    print_info "Creating split ZIP backup (max 45MB per part)..."
    
    local zip_args=()
    for folder in "${project_folders[@]}"; do
        zip_args+=("$folder")
    done
    
    # Buat ZIP dengan split 45MB untuk safety margin
    zip -s 45m -r "$backup_path" "${zip_args[@]}" \
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
    
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        print_success "Split ZIP created successfully"
        log_message "Split ZIP backup created: $backup_path"
    else
        print_error "Split ZIP creation failed"
        log_message "Split ZIP creation failed with exit code: $result"
    fi
    
    return $result
}

upload_split_files() {
    local backup_base="$1"
    local caption_base="$2"
    local uploaded_count=0
    local failed_count=0
    local total_size=0
    
    # Cari semua file split (z01, z02, ..., zip)
    local split_files=()
    
    # Pattern untuk file split: backup-name.z01, backup-name.z02, ..., backup-name.zip
    local base_name=$(basename "$backup_base" .zip)
    local dir_name=$(dirname "$backup_base")
    
    # Cari file split dengan pattern
    for file in "$dir_name"/"$base_name".z* "$dir_name"/"$base_name".zip; do
        if [[ -f "$file" ]]; then
            split_files+=("$file")
        fi
    done
    
    # Sort files untuk urutan yang benar
    IFS=$'\n' split_files=($(sort <<<"${split_files[*]}"))
    unset IFS
    
    local total_parts=${#split_files[@]}
    
    if [[ $total_parts -eq 0 ]]; then
        print_error "No split files found"
        return 1
    fi
    
    print_info "Found $total_parts split parts to upload"
    
    # Upload setiap bagian
    local part_num=1
    for file in "${split_files[@]}"; do
        local file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
        total_size=$((total_size + file_size))
        
        local part_caption="$caption_base
📦 Part $part_num/$total_parts
📁 $(basename "$file")
📏 $(bytes_to_human $file_size)"
        
        if send_telegram_file "$file" "$part_caption"; then
            ((uploaded_count++))
            print_success "Uploaded part $part_num/$total_parts"
        else
            ((failed_count++))
            print_error "Failed to upload part $part_num/$total_parts"
        fi
        
        ((part_num++))
        
        # Delay antar upload untuk menghindari rate limit
        if [[ $part_num -le $total_parts ]]; then
            sleep 2
        fi
    done
    
    # Kirim summary
    local summary_msg="📊 <b>Upload Summary</b>
✅ Uploaded: $uploaded_count/$total_parts parts
❌ Failed: $failed_count parts
📏 Total Size: $(bytes_to_human $total_size)
📝 To extract: Download all parts and unzip the .zip file"
    
    send_telegram_message "$summary_msg"
    
    # Cleanup split files
    for file in "${split_files[@]}"; do
        rm -f "$file"
    done
    
    log_message "Uploaded $uploaded_count/$total_parts parts, total size: $(bytes_to_human $total_size)"
    
    if [[ $failed_count -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# ===================================================================
# FUNGSI BACKUP UTAMA
# ===================================================================

run_backup() {
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
    log_message "=== SPLIT BACKUP STARTED ==="
    
    # Deteksi provider
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    # Validasi target
    if [[ ! -d "$backup_target" ]]; then
        print_error "Target directory not found: $backup_target"
        send_telegram_message "❌ <b>Backup Failed</b> - Target not found: $backup_target"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Scan files
    print_info "Scanning project files..."
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
    
    # Validasi size
    if [[ $estimated_bytes -gt $MAX_BACKUP_SIZE ]]; then
        print_error "Backup size too large: $estimated_size (max: 500MB)"
        send_telegram_message "❌ <b>Backup Failed</b> - Size too large: $estimated_size"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    if [[ $total_files -eq 0 ]]; then
        print_warning "No project files found"
        send_telegram_message "⚠️ <b>No Files Found</b> - No project files to backup"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Kirim notifikasi start
    send_telegram_message "🔄 <b>Split Backup Started</b>
☁️ ${provider}
📁 ${project_count} projects
📊 ${total_files} files
📏 ${estimated_size}
📦 Will split if > 45MB per part
⏰ $(date '+%H:%M:%S')"
    
    # Buat backup
    mkdir -p "$BACKUP_DIR"
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unknown")
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local user_suffix=""
    
    if [[ "$backup_target" != "/root" ]]; then
        user_suffix="-$(basename "$backup_target")"
    fi
    
    local backup_filename="backup-${ip_server}${user_suffix}-${timestamp}.zip"
    local backup_full_path="${BACKUP_DIR}/${backup_filename}"
    
    print_info "Creating split backup..."
    if create_split_backup "$backup_full_path" "$backup_target"; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        # Buat caption untuk upload
        local caption="📦 <b>Split Backup Complete</b>
☁️ ${provider}
📁 ${project_count} projects
📊 ${total_files} files (.env:${env_files} .txt:${txt_files} .py:${py_files} .js:${js_files} package.json:${json_files})
⏱️ ${duration}s
📅 $(date '+%Y-%m-%d %H:%M:%S')
✅ Split into parts for Telegram limit"
        
        # Upload split files
        if upload_split_files "$backup_full_path" "$caption"; then
            print_success "Split backup completed and uploaded successfully"
            send_telegram_message "✅ <b>Split Backup Success!</b> ${backup_filename} uploaded in parts"
        else
            print_error "Some parts failed to upload"
            send_telegram_message "⚠️ <b>Partial Upload</b> - Some parts of ${backup_filename} failed to upload"
        fi
    else
        print_error "Backup creation failed"
        send_telegram_message "❌ <b>Backup Failed</b> - Creation error"
    fi
    
    rm -f "$LOCK_FILE"
    log_message "=== SPLIT BACKUP COMPLETED ==="
}

# ===================================================================
# FUNGSI SETUP
# ===================================================================

setup_backup() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     SPLIT BACKUP TELEGRAM VPS       ║${NC}"
    echo -e "${CYAN}║     Auto-Split for 50MB Limit       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Deteksi provider
    local provider_info=$(detect_cloud_provider)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_target=$(echo "$provider_info" | cut -d'|' -f2)
    
    # Scan project folders
    print_info "Detecting project folders..."
    list_project_folders "$backup_target"
    echo
    
    # Scan files
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
    
    print_success "Split Backup Detection Results:"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  ☁️ Cloud Provider: $provider"
    echo "  📂 Target Path: $backup_target"
    echo "  📁 Project Folders: $project_count"
    echo "  📊 Files: .env($env_files) .txt($txt_files) .py($py_files) .js($js_files) package.json($json_files)"
    echo "  📋 Total Files: $total_files"
    echo "  📏 Estimated Size: $estimated_size"
    echo "  📦 Max Size: 500MB"
    echo "  ✂️ Auto-split: 45MB per part for Telegram"
    echo
    
    if [[ $total_files -eq 0 ]]; then
        print_warning "No project files found"
        return 1
    fi
    
    # Buat direktori
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$BACKUP_DIR"
    
    # Input konfigurasi
    echo -e "${YELLOW}Telegram Configuration:${NC}"
    echo
    read -p "🤖 Bot Token: " bot_token
    read -p "💬 Chat ID: " chat_id
    read -p "⏰ Interval (hours) [1]: " interval
    interval=${interval:-1}
    
    # Simpan konfigurasi
    cat > "$CONFIG_FILE" << EOF
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
BACKUP_INTERVAL="$interval"
CLOUD_PROVIDER="$provider"
BACKUP_TARGET="$backup_target"
PROJECT_COUNT="$project_count"
TOTAL_FILES="$total_files"
ESTIMATED_SIZE="$estimated_size"
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
    
    crontab -l 2>/dev/null | grep -v "backup_telegram" | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "$cron_schedule $0 --backup >/dev/null 2>&1") | crontab -
    print_success "Crontab configured"
    
    # Test koneksi
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    if send_telegram_message "🎉 <b>Split Backup Setup Complete</b>
☁️ ${provider}
📁 ${project_count} projects
📊 ${total_files} files
📏 ${estimated_size}
⏰ Every ${interval}h
✂️ Auto-split for Telegram 50MB limit
✅ Ready!"; then
        print_success "Setup completed!"
        echo
        echo -e "${GREEN}Split backup system ready!${NC}"
        echo -e "  📦 Auto-split: Files > 45MB will be split into parts"
        echo -e "  📱 Telegram: Each part will be uploaded separately"
        echo -e "  📁 Extract: Download all parts and unzip the .zip file"
    else
        print_error "Setup failed!"
    fi
}

show_help() {
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     SPLIT BACKUP TELEGRAM VPS       ║${NC}"
    echo -e "${CYAN}║     Auto-Split for 50MB Limit       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Split Backup Features:${NC}"
    echo -e "  📦 ${BLUE}Auto-split ZIP files${NC} into 45MB parts"
    echo -e "  📱 ${BLUE}Telegram 50MB limit${NC} compatible"
    echo -e "  🎯 ${BLUE}Project folders only${NC}"
    echo -e "  ✂️ ${BLUE}Smart splitting${NC} - only when needed"
    echo -e "  📊 ${BLUE}Upload progress${NC} tracking"
    echo -e "  🔄 ${BLUE}Retry mechanism${NC} for failed uploads"
    echo
    echo -e "${GREEN}How Split Works:${NC}"
    echo -e "  1. Create ZIP backup of all projects"
    echo -e "  2. If ZIP > 45MB, split into parts (.z01, .z02, .zip)"
    echo -e "  3. Upload each part separately to Telegram"
    echo -e "  4. To restore: Download all parts and unzip .zip file"
    echo
    echo -e "${GREEN}Usage:${NC} $0 [OPTION]"
    echo
    echo -e "${GREEN}Options:${NC}"
    echo -e "  ${BLUE}--setup${NC}       Setup split backup"
    echo -e "  ${BLUE}--backup${NC}      Run split backup"
    echo -e "  ${BLUE}--help${NC}        Show help"
}

# ===================================================================
# MAIN SCRIPT
# ===================================================================

main() {
    case "${1:-}" in
        --setup) setup_backup ;;
        --backup) run_backup ;;
        --help) show_help ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                run_backup
            else
                print_info "Split Backup Telegram VPS"
                echo
                read -p "Setup split backup now? (y/n): " -n 1 -r
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
