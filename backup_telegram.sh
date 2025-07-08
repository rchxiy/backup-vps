#!/bin/bash

# ===================================================================
# BACKUP TELEGRAM VPS - MULTI-USER VERSION
# Support untuk Root dan Non-Root VPS
# Version: 2.1
# ===================================================================

# Konfigurasi warna untuk output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Deteksi user dan environment
CURRENT_USER=$(whoami)
USER_HOME=$(eval echo ~$CURRENT_USER)
IS_ROOT=false

if [[ $EUID -eq 0 ]]; then
    IS_ROOT=true
    SCRIPT_DIR="/opt/backup-telegram"
    LOG_FILE="/var/log/backup_telegram.log"
    BACKUP_DIR="/tmp/backups"
else
    SCRIPT_DIR="$USER_HOME/.backup-telegram"
    LOG_FILE="$USER_HOME/.backup-telegram/backup.log"
    BACKUP_DIR="$USER_HOME/.backup-telegram/temp"
fi

readonly CONFIG_FILE="${SCRIPT_DIR}/config.conf"
readonly LOCK_FILE="${SCRIPT_DIR}/backup.lock"

# ===================================================================
# FUNGSI UTILITY
# ===================================================================

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Fungsi logging dengan deteksi user
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Buat direktori log jika belum ada
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Rotasi log jika lebih dari 10MB
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null) -gt 10485760 ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
        touch "$LOG_FILE"
    fi
    
    echo "${timestamp} - [${CURRENT_USER}] ${message}" | tee -a "$LOG_FILE"
}

# Fungsi deteksi environment VPS
detect_vps_environment() {
    local vps_type="Unknown"
    local cloud_provider="Unknown"
    
    # Deteksi Azure
    if [[ -f /var/lib/waagent/Incarnation ]] || [[ -d /var/lib/waagent ]] || [[ $(curl -s -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" 2>/dev/null) ]]; then
        cloud_provider="Microsoft Azure"
        vps_type="Azure VM"
    # Deteksi AWS
    elif [[ $(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null) ]]; then
        cloud_provider="Amazon AWS"
        vps_type="EC2 Instance"
    # Deteksi Google Cloud
    elif [[ $(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/id 2>/dev/null) ]]; then
        cloud_provider="Google Cloud"
        vps_type="GCE Instance"
    # Deteksi DigitalOcean
    elif [[ $(curl -s http://169.254.169.254/metadata/v1/id 2>/dev/null) ]]; then
        cloud_provider="DigitalOcean"
        vps_type="Droplet"
    # Deteksi Vultr
    elif [[ -f /etc/vultr ]] || [[ $(curl -s http://169.254.169.254/v1/instanceid 2>/dev/null) ]]; then
        cloud_provider="Vultr"
        vps_type="Vultr Instance"
    fi
    
    echo "$cloud_provider|$vps_type"
}

# Fungsi deteksi default user berdasarkan distro
detect_default_user() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu) echo "ubuntu" ;;
            debian) echo "debian" ;;
            centos|rhel) echo "centos" ;;
            fedora) echo "fedora" ;;
            arch) echo "arch" ;;
            alpine) echo "alpine" ;;
            *) echo "$CURRENT_USER" ;;
        esac
    else
        echo "$CURRENT_USER"
    fi
}

# ===================================================================
# FUNGSI TELEGRAM API
# ===================================================================

send_telegram_message() {
    local message="$1"
    local retry_count=0
    local max_retries=3
    
    while [[ $retry_count -lt $max_retries ]]; do
        local response=$(curl -s --max-time 30 \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="${message}" \
            -d parse_mode="HTML" 2>/dev/null)
        
        if [[ $response == *"\"ok\":true"* ]]; then
            return 0
        fi
        
        ((retry_count++))
        sleep $((retry_count * 2))
    done
    
    return 1
}

send_telegram_file() {
    local file_path="$1"
    local caption="$2"
    local retry_count=0
    local max_retries=3
    
    if [[ ! -f "$file_path" ]]; then
        return 1
    fi
    
    while [[ $retry_count -lt $max_retries ]]; do
        local response=$(curl -s --max-time 300 \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
            -F chat_id="${TELEGRAM_CHAT_ID}" \
            -F document=@"${file_path}" \
            -F caption="${caption}" 2>/dev/null)
        
        if [[ $response == *"\"ok\":true"* ]]; then
            return 0
        fi
        
        ((retry_count++))
        sleep $((retry_count * 5))
    done
    
    return 1
}

# ===================================================================
# FUNGSI BACKUP BERDASARKAN USER TYPE
# ===================================================================

# Backup untuk user root
backup_as_root() {
    local backup_path="$1"
    
    log_message "Backup sebagai ROOT user - Full system backup"
    
    zip -r "$backup_path" / \
        -x "*/proc/*" \
        -x "*/sys/*" \
        -x "*/dev/*" \
        -x "*/run/*" \
        -x "*/mnt/*" \
        -x "*/media/*" \
        -x "*/tmp/*" \
        -x "*/var/tmp/*" \
        -x "*/var/log/*" \
        -x "*/var/cache/*" \
        -x "*/var/lib/docker/*" \
        -x "*/snap/*" \
        -x "*/node_modules/*" \
        -x "*/__pycache__/*" \
        -x "*/.cache/*" \
        -x "*/.npm/*" \
        -x "*/.git/*" \
        -x "*/backup-*.zip" >> "$LOG_FILE" 2>&1
}

# Backup untuk user non-root
backup_as_user() {
    local backup_path="$1"
    local default_user=$(detect_default_user)
    
    log_message "Backup sebagai USER: $CURRENT_USER (Default: $default_user)"
    
    # Backup home directory user saat ini
    zip -r "$backup_path" "$USER_HOME" \
        -x "*/node_modules/*" \
        -x "*/__pycache__/*" \
        -x "*/.cache/*" \
        -x "*/.npm/*" \
        -x "*/.yarn/*" \
        -x "*/.local/lib/python*/*" \
        -x "*/.local/share/virtualenvs/*" \
        -x "*/.ipython/*" \
        -x "*/.jupyter/*" \
        -x "*/.ssh/*" \
        -x "*/.gnupg/*" \
        -x "*/.bash_history" \
        -x "*/.zsh_history" \
        -x "*/.DS_Store" \
        -x "*/.git/*" \
        -x "*/.local/share/Trash/*" \
        -x "*/.docker/*" \
        -x "*/.vscode-server/*" \
        -x "*/backup-*.zip" \
        -x "*/.backup-telegram/*" >> "$LOG_FILE" 2>&1
    
    # Jika user berbeda dengan default user, coba backup default user juga
    if [[ "$CURRENT_USER" != "$default_user" ]] && [[ -d "/home/$default_user" ]]; then
        log_message "Menambahkan backup untuk default user: $default_user"
        zip -r "$backup_path" "/home/$default_user" \
            -x "*/node_modules/*" \
            -x "*/__pycache__/*" \
            -x "*/.cache/*" \
            -x "*/.npm/*" \
            -x "*/.git/*" \
            -x "*/backup-*.zip" >> "$LOG_FILE" 2>&1
    fi
    
    # Backup konfigurasi sistem yang bisa diakses
    if [[ -r /etc ]]; then
        log_message "Menambahkan backup konfigurasi sistem"
        zip -r "$backup_path" /etc \
            -x "*/shadow*" \
            -x "*/passwd*" \
            -x "*/group*" \
            -x "*/gshadow*" >> "$LOG_FILE" 2>&1
    fi
}

# ===================================================================
# FUNGSI BACKUP UTAMA
# ===================================================================

run_backup() {
    # Buat lock file
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            print_error "Backup sedang berjalan (PID: $pid)"
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
    
    # Load konfigurasi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Konfigurasi tidak ditemukan! Jalankan: $0 --setup"
        exit 1
    fi
    
    source "$CONFIG_FILE"
    
    # Deteksi environment
    local env_info=$(detect_vps_environment)
    local cloud_provider=$(echo "$env_info" | cut -d'|' -f1)
    local vps_type=$(echo "$env_info" | cut -d'|' -f2)
    
    log_message "=== MEMULAI BACKUP ==="
    log_message "User: $CURRENT_USER (Root: $IS_ROOT)"
    log_message "Cloud Provider: $cloud_provider"
    log_message "VPS Type: $vps_type"
    
    # Kirim notifikasi awal
    local user_type_emoji="👤"
    if [[ "$IS_ROOT" == "true" ]]; then
        user_type_emoji="🔑"
    fi
    
    send_telegram_message "🔄 <b>Backup dimulai</b>
${user_type_emoji} User: ${CURRENT_USER}
☁️ Provider: ${cloud_provider}
🖥️ Type: ${vps_type}
📅 $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Buat direktori backup
    mkdir -p "$BACKUP_DIR"
    
    # Dapatkan IP server
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unknown")
    
    # Generate nama file backup
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local user_suffix=""
    if [[ "$IS_ROOT" != "true" ]]; then
        user_suffix="-${CURRENT_USER}"
    fi
    
    local backup_filename="backup-${ip_server}${user_suffix}-${timestamp}.zip"
    local backup_path="${BACKUP_DIR}/${backup_filename}"
    
    log_message "Membuat backup: $backup_filename"
    
    # Proses backup berdasarkan user type
    local start_time=$(date +%s)
    
    if [[ "$IS_ROOT" == "true" ]]; then
        backup_as_root "$backup_path"
    else
        backup_as_user "$backup_path"
    fi
    
    local backup_exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Validasi hasil backup
    if [[ $backup_exit_code -eq 0 && -f "$backup_path" ]]; then
        local file_size=$(du -h "$backup_path" | cut -f1)
        local file_size_bytes=$(stat -c%s "$backup_path" 2>/dev/null || stat -f%z "$backup_path" 2>/dev/null)
        
        if [[ $file_size_bytes -lt 1024 ]]; then
            log_message "Backup terlalu kecil: $file_size"
            send_telegram_message "❌ <b>Backup gagal</b> - File terlalu kecil"
            rm -f "$backup_path"
            rm -f "$LOCK_FILE"
            return 1
        fi
        
        log_message "Backup berhasil: $backup_filename (Size: $file_size)"
        
        # Upload ke Telegram
        local backup_type="User Backup"
        if [[ "$IS_ROOT" == "true" ]]; then
            backup_type="Full System Backup"
        fi
        
        local caption="📦 <b>${backup_type}</b>
${user_type_emoji} User: ${CURRENT_USER}
☁️ ${cloud_provider}
🖥️ ${vps_type}
📅 $(date '+%Y-%m-%d %H:%M:%S')
📁 Size: ${file_size}
⏱️ Duration: ${duration}s
✅ Status: Berhasil"
        
        if send_telegram_file "$backup_path" "$caption"; then
            log_message "Upload berhasil"
            send_telegram_message "✅ <b>Backup berhasil</b> - ${backup_filename} (${file_size})"
            rm -f "$backup_path"
            log_message "File backup dihapus: $backup_filename"
        else
            log_message "Upload gagal"
            send_telegram_message "❌ <b>Upload gagal</b> - ${backup_filename}"
        fi
        
    else
        log_message "Backup gagal (exit code: $backup_exit_code)"
        send_telegram_message "❌ <b>Backup gagal</b> - $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    
    # Cleanup
    rm -f "$LOCK_FILE"
    log_message "=== BACKUP SELESAI ==="
}

# ===================================================================
# FUNGSI SETUP
# ===================================================================

setup_backup() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     SETUP BACKUP TELEGRAM VPS       ║${NC}"
    echo -e "${BLUE}║        Multi-User Version            ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Deteksi environment
    local env_info=$(detect_vps_environment)
    local cloud_provider=$(echo "$env_info" | cut -d'|' -f1)
    local vps_type=$(echo "$env_info" | cut -d'|' -f2)
    
    print_info "Deteksi Environment:"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  🔑 Root Access: $IS_ROOT"
    echo "  ☁️ Cloud Provider: $cloud_provider"
    echo "  🖥️ VPS Type: $vps_type"
    echo "  📁 Home Directory: $USER_HOME"
    echo "  📋 Config Path: $CONFIG_FILE"
    echo "  📝 Log Path: $LOG_FILE"
    echo
    
    # Buat direktori
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Input konfigurasi Telegram
    echo -e "${YELLOW}Konfigurasi Telegram Bot:${NC}"
    echo
    
    read -p "🤖 Telegram Bot Token: " bot_token
    read -p "💬 Telegram Chat ID: " chat_id
    read -p "⏰ Interval backup (jam) [default: 1]: " interval
    interval=${interval:-1}
    read -p "🗂️ Maksimal backup tersimpan [default: 3]: " max_backups
    max_backups=${max_backups:-3}
    
    # Simpan konfigurasi
    cat > "$CONFIG_FILE" << EOF
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
BACKUP_INTERVAL="$interval"
MAX_BACKUPS="$max_backups"
USER_TYPE="$CURRENT_USER"
IS_ROOT="$IS_ROOT"
CLOUD_PROVIDER="$cloud_provider"
VPS_TYPE="$vps_type"
CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_success "Konfigurasi tersimpan!"
    
    # Setup crontab
    setup_crontab "$interval"
    
    # Test koneksi
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    if send_telegram_message "🔧 <b>Setup Complete</b>
${user_type_emoji} User: ${CURRENT_USER}
☁️ ${cloud_provider} - ${vps_type}
✅ Backup system ready!"; then
        print_success "Setup berhasil!"
    else
        print_error "Test koneksi gagal!"
    fi
}

# Setup crontab
setup_crontab() {
    local interval=$1
    local cron_schedule="0 * * * *"
    
    case $interval in
        1) cron_schedule="0 * * * *" ;;
        2) cron_schedule="0 */2 * * *" ;;
        3) cron_schedule="0 */3 * * *" ;;
        6) cron_schedule="0 */6 * * *" ;;
        12) cron_schedule="0 */12 * * *" ;;
        24) cron_schedule="0 2 * * *" ;;
    esac
    
    # Hapus crontab lama
    crontab -l 2>/dev/null | grep -v "backup_telegram" | crontab -
    
    # Tambah crontab baru
    (crontab -l 2>/dev/null; echo "$cron_schedule $0 --backup >/dev/null 2>&1") | crontab -
    
    print_success "Crontab diatur untuk backup setiap $interval jam"
}

# ===================================================================
# FUNGSI STATUS
# ===================================================================

show_status() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         STATUS BACKUP SYSTEM         ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Environment Info
    local env_info=$(detect_vps_environment)
    local cloud_provider=$(echo "$env_info" | cut -d'|' -f1)
    local vps_type=$(echo "$env_info" | cut -d'|' -f2)
    
    echo -e "${BLUE}Environment Information:${NC}"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  🔑 Root Access: $IS_ROOT"
    echo "  ☁️ Cloud Provider: $cloud_provider"
    echo "  🖥️ VPS Type: $vps_type"
    echo "  🌐 IP Address: $(curl -s ifconfig.me 2>/dev/null || echo 'Unknown')"
    echo
    
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        
        print_success "Konfigurasi: OK"
        echo "  📁 Config: $CONFIG_FILE"
        echo "  🤖 Bot: ${TELEGRAM_BOT_TOKEN:0:10}..."
        echo "  💬 Chat: $TELEGRAM_CHAT_ID"
        echo "  ⏰ Interval: $BACKUP_INTERVAL jam"
        echo "  🗂️ Max Backup: $MAX_BACKUPS"
        echo
        
        # Crontab status
        if crontab -l 2>/dev/null | grep -q "backup_telegram"; then
            print_success "Crontab: Aktif"
        else
            print_warning "Crontab: Tidak aktif"
        fi
        
        # Backup terakhir
        if [[ -f "$LOG_FILE" ]]; then
            local last_backup=$(tail -n 50 "$LOG_FILE" | grep "BACKUP SELESAI" | tail -n 1)
            if [[ -n "$last_backup" ]]; then
                local backup_time=$(echo "$last_backup" | cut -d' ' -f1-2)
                print_success "Backup terakhir: $backup_time"
            fi
        fi
        
    else
        print_error "Belum dikonfigurasi! Jalankan: $0 --setup"
    fi
}

# ===================================================================
# MAIN SCRIPT
# ===================================================================

show_help() {
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║    BACKUP TELEGRAM VPS MULTI-USER    ║${NC}"
    echo -e "${BLUE}║           Version 2.1                ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    echo "Mendukung backup untuk:"
    echo "  🔑 Root user (full system backup)"
    echo "  👤 Non-root user (user data backup)"
    echo "  ☁️ Multi-cloud provider (Azure, AWS, GCP, dll)"
    echo
    echo "Usage: $0 [OPTION]"
    echo
    echo "Options:"
    echo "  --setup       Setup konfigurasi"
    echo "  --backup      Backup manual"
    echo "  --status      Status sistem"
    echo "  --log         Lihat log"
    echo "  --help        Bantuan"
}

# Main function
main() {
    case "${1:-}" in
        --setup) setup_backup ;;
        --backup) run_backup ;;
        --status) show_status ;;
        --log) 
            if [[ -f "$LOG_FILE" ]]; then
                tail -n 50 "$LOG_FILE"
            else
                print_error "Log file tidak ditemukan"
            fi
            ;;
        --help) show_help ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                show_status
            else
                show_help
            fi
            ;;
    esac
}

main "$@"
