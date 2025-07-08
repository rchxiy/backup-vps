#!/bin/bash

# ===================================================================
# BACKUP TELEGRAM VPS - SMART PROVIDER-BASED VERSION
# Version: 2.2 - Provider-Specific Backup Strategy
# ===================================================================

# Konfigurasi warna
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
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

log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "${timestamp} - [${CURRENT_USER}] ${message}" | tee -a "$LOG_FILE"
}

# ===================================================================
# DETEKSI CLOUD PROVIDER DAN BACKUP STRATEGY
# ===================================================================

detect_cloud_provider_and_strategy() {
    local provider="Unknown"
    local backup_path=""
    local backup_type=""
    
    # Deteksi Microsoft Azure
    if [[ -f /var/lib/waagent/Incarnation ]] || [[ -d /var/lib/waagent ]] || [[ $(curl -s -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" --max-time 3 2>/dev/null) ]]; then
        provider="Microsoft Azure"
        # Azure: Backup /home/username (biasanya azureuser, ubuntu, dll)
        if [[ "$IS_ROOT" == "true" ]]; then
            # Cari default user di Azure
            local azure_user=$(ls /home/ | head -n 1 2>/dev/null)
            if [[ -n "$azure_user" && -d "/home/$azure_user" ]]; then
                backup_path="/home/$azure_user"
                backup_type="Azure User Home ($azure_user)"
            else
                backup_path="/home"
                backup_type="Azure Home Directory"
            fi
        else
            backup_path="$USER_HOME"
            backup_type="Azure User Home ($CURRENT_USER)"
        fi
    
    # Deteksi DigitalOcean
    elif [[ $(curl -s http://169.254.169.254/metadata/v1/id --max-time 3 2>/dev/null) ]]; then
        provider="DigitalOcean"
        # DigitalOcean: Backup /root
        backup_path="/root"
        backup_type="DigitalOcean Root"
    
    # Deteksi Contabo (berdasarkan hostname atau provider info)
    elif [[ $(hostname) == *"contabo"* ]] || [[ -f /etc/contabo ]] || [[ $(curl -s http://169.254.169.254/latest/meta-data/instance-id --max-time 3 2>/dev/null) == *"contabo"* ]]; then
        provider="Contabo"
        # Contabo: Backup /root
        backup_path="/root"
        backup_type="Contabo Root"
    
    # Deteksi AWS (fallback ke /home/ec2-user atau /root)
    elif [[ $(curl -s http://169.254.169.254/latest/meta-data/instance-id --max-time 3 2>/dev/null) ]]; then
        provider="Amazon AWS"
        if [[ -d "/home/ec2-user" ]]; then
            backup_path="/home/ec2-user"
            backup_type="AWS EC2 User"
        else
            backup_path="/root"
            backup_type="AWS Root"
        fi
    
    # Deteksi Google Cloud
    elif [[ $(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/id --max-time 3 2>/dev/null) ]]; then
        provider="Google Cloud"
        if [[ -d "/home/ubuntu" ]]; then
            backup_path="/home/ubuntu"
            backup_type="GCP Ubuntu User"
        else
            backup_path="/root"
            backup_type="GCP Root"
        fi
    
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
    
    echo "$provider|$backup_path|$backup_type"
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
# FUNGSI BACKUP SMART
# ===================================================================

run_smart_backup() {
    # Lock mechanism
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
    
    # Deteksi provider dan strategy
    local provider_info=$(detect_cloud_provider_and_strategy)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_path=$(echo "$provider_info" | cut -d'|' -f2)
    local backup_type=$(echo "$provider_info" | cut -d'|' -f3)
    
    log_message "=== SMART BACKUP DIMULAI ==="
    log_message "Provider: $provider"
    log_message "Backup Path: $backup_path"
    log_message "Backup Type: $backup_type"
    
    # Validasi backup path
    if [[ ! -d "$backup_path" ]]; then
        log_message "ERROR: Backup path tidak ditemukan: $backup_path"
        send_telegram_message "❌ <b>Backup gagal</b> - Path tidak ditemukan: $backup_path"
        rm -f "$LOCK_FILE"
        return 1
    fi
    
    # Kirim notifikasi awal
    send_telegram_message "🔄 <b>Smart Backup dimulai</b>
☁️ Provider: ${provider}
📁 Target: ${backup_type}
📂 Path: ${backup_path}
📅 $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Buat direktori backup
    mkdir -p "$BACKUP_DIR"
    
    # Dapatkan IP server
    local ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || echo "unknown")
    
    # Generate nama file backup
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local provider_suffix=$(echo "$provider" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local backup_filename="backup-${ip_server}-${provider_suffix}-${timestamp}.zip"
    local backup_full_path="${BACKUP_DIR}/${backup_filename}"
    
    log_message "Membuat backup: $backup_filename"
    log_message "Target path: $backup_path"
    
    # Estimasi ukuran sebelum backup
    local estimated_size=$(du -sh "$backup_path" 2>/dev/null | cut -f1 || echo "Unknown")
    print_info "Estimasi ukuran: $estimated_size"
    
    # Proses backup dengan exclude yang optimal
    local start_time=$(date +%s)
    
    log_message "Memulai kompresi..."
    zip -r "$backup_full_path" "$backup_path" \
        -x "*/node_modules/*" \
        -x "*/__pycache__/*" \
        -x "*/.cache/*" \
        -x "*/.npm/*" \
        -x "*/.yarn/*" \
        -x "*/.local/lib/python*/*" \
        -x "*/.local/share/virtualenvs/*" \
        -x "*/.vscode-server/*" \
        -x "*/.docker/*" \
        -x "*/.git/*" \
        -x "*/.ssh/*" \
        -x "*/.gnupg/*" \
        -x "*/.bash_history" \
        -x "*/.zsh_history" \
        -x "*/.mysql_history" \
        -x "*/.DS_Store" \
        -x "*/.local/share/Trash/*" \
        -x "*/tmp/*" \
        -x "*/backup-*.zip" \
        -x "*/.backup-telegram/*" >> "$LOG_FILE" 2>&1
    
    local backup_exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Validasi hasil backup
    if [[ $backup_exit_code -eq 0 && -f "$backup_full_path" ]]; then
        local file_size=$(du -h "$backup_full_path" | cut -f1)
        local file_size_bytes=$(stat -c%s "$backup_full_path" 2>/dev/null || stat -f%z "$backup_full_path" 2>/dev/null)
        
        if [[ $file_size_bytes -lt 1024 ]]; then
            log_message "Backup terlalu kecil: $file_size"
            send_telegram_message "❌ <b>Backup gagal</b> - File terlalu kecil"
            rm -f "$backup_full_path"
            rm -f "$LOCK_FILE"
            return 1
        fi
        
        log_message "Backup berhasil: $backup_filename (Size: $file_size, Duration: ${duration}s)"
        
        # Upload ke Telegram
        local caption="📦 <b>Smart Backup</b>
☁️ Provider: ${provider}
📁 Type: ${backup_type}
📂 Path: ${backup_path}
📅 $(date '+%Y-%m-%d %H:%M:%S')
📊 Size: ${file_size}
⏱️ Duration: ${duration}s
✅ Status: Berhasil"
        
        if send_telegram_file "$backup_full_path" "$caption"; then
            log_message "Upload berhasil"
            send_telegram_message "✅ <b>Smart Backup berhasil</b> - ${backup_filename} (${file_size})"
            rm -f "$backup_full_path"
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
    log_message "=== SMART BACKUP SELESAI ==="
}

# ===================================================================
# FUNGSI SETUP
# ===================================================================

setup_backup() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     SMART BACKUP TELEGRAM VPS       ║${NC}"
    echo -e "${BLUE}║      Provider-Based Strategy         ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Deteksi provider dan strategy
    local provider_info=$(detect_cloud_provider_and_strategy)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_path=$(echo "$provider_info" | cut -d'|' -f2)
    local backup_type=$(echo "$provider_info" | cut -d'|' -f3)
    
    print_info "Smart Detection Results:"
    echo "  👤 Current User: $CURRENT_USER"
    echo "  🔑 Root Access: $IS_ROOT"
    echo "  ☁️ Cloud Provider: $provider"
    echo "  📁 Backup Target: $backup_type"
    echo "  📂 Backup Path: $backup_path"
    echo "  📊 Estimated Size: $(du -sh "$backup_path" 2>/dev/null | cut -f1 || echo "Unknown")"
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
CLOUD_PROVIDER="$provider"
BACKUP_PATH="$backup_path"
BACKUP_TYPE="$backup_type"
CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    
    chmod 600 "$CONFIG_FILE"
    print_success "Konfigurasi tersimpan!"
    
    # Setup crontab
    setup_crontab "$interval"
    
    # Test koneksi
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    if send_telegram_message "🔧 <b>Smart Backup Setup</b>
☁️ Provider: ${provider}
📁 Target: ${backup_type}
📂 Path: ${backup_path}
✅ System ready!"; then
        print_success "Setup berhasil!"
    else
        print_error "Test koneksi gagal!"
    fi
    
    echo
    echo -e "${GREEN}Smart backup strategy:${NC}"
    echo -e "  ${BLUE}Azure${NC} → /home/[user] (Fast user backup)"
    echo -e "  ${BLUE}DigitalOcean${NC} → /root (Root backup)"
    echo -e "  ${BLUE}Contabo${NC} → /root (Root backup)"
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
    echo -e "${BLUE}║       SMART BACKUP STATUS            ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Deteksi provider dan strategy
    local provider_info=$(detect_cloud_provider_and_strategy)
    local provider=$(echo "$provider_info" | cut -d'|' -f1)
    local backup_path=$(echo "$provider_info" | cut -d'|' -f2)
    local backup_type=$(echo "$provider_info" | cut -d'|' -f3)
    
    echo -e "${BLUE}Smart Detection:${NC}"
    echo "  ☁️ Provider: $provider"
    echo "  📁 Backup Type: $backup_type"
    echo "  📂 Target Path: $backup_path"
    echo "  📊 Current Size: $(du -sh "$backup_path" 2>/dev/null | cut -f1 || echo "Unknown")"
    echo
    
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        print_success "Konfigurasi: OK"
        echo "  🤖 Bot: ${TELEGRAM_BOT_TOKEN:0:10}..."
        echo "  💬 Chat: $TELEGRAM_CHAT_ID"
        echo "  ⏰ Interval: $BACKUP_INTERVAL jam"
        echo
        
        # Crontab status
        if crontab -l 2>/dev/null | grep -q "backup_telegram"; then
            print_success "Crontab: Aktif"
        else
            print_warning "Crontab: Tidak aktif"
        fi
        
    else
        print_error "Belum dikonfigurasi! Jalankan: $0 --setup"
    fi
}

show_help() {
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║    SMART BACKUP TELEGRAM VPS         ║${NC}"
    echo -e "${BLUE}║      Provider-Based Strategy         ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    echo -e "${GREEN}Smart Backup Strategy:${NC}"
    echo -e "  ${BLUE}Microsoft Azure${NC} → /home/[user] (User home backup)"
    echo -e "  ${BLUE}DigitalOcean${NC} → /root (Root backup)"
    echo -e "  ${BLUE}Contabo${NC} → /root (Root backup)"
    echo -e "  ${BLUE}AWS${NC} → /home/ec2-user or /root"
    echo -e "  ${BLUE}Google Cloud${NC} → /home/ubuntu or /root"
    echo
    echo "Usage: $0 [OPTION]"
    echo "  --setup       Setup konfigurasi"
    echo "  --backup      Smart backup"
    echo "  --status      Status sistem"
    echo "  --log         Lihat log"
    echo "  --help        Bantuan"
}

# ===================================================================
# MAIN SCRIPT
# ===================================================================

main() {
    case "${1:-}" in
        --setup) setup_backup ;;
        --backup) run_smart_backup ;;
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
