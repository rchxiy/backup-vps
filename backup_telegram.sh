#!/bin/bash

# ===================================================================
# BACKUP TELEGRAM VPS - OPTIMIZED VERSION
# Author: Backup System
# Version: 2.0
# ===================================================================

# Konfigurasi warna untuk output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly NC='\033[0m'

# Konfigurasi path dan file
readonly SCRIPT_DIR="/opt/backup-telegram"
readonly CONFIG_FILE="${SCRIPT_DIR}/config.conf"
readonly LOG_FILE="/var/log/backup_telegram.log"
readonly BACKUP_DIR="/tmp/backups"
readonly LOCK_FILE="/var/run/backup_telegram.lock"

# Konfigurasi default
readonly DEFAULT_INTERVAL=1
readonly DEFAULT_MAX_BACKUPS=3
readonly API_TIMEOUT=30
readonly MAX_RETRIES=3

# ===================================================================
# FUNGSI UTILITY
# ===================================================================

# Fungsi print dengan warna
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_debug() { echo -e "${PURPLE}[DEBUG]${NC} $1"; }

# Fungsi logging dengan rotasi
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Rotasi log jika lebih dari 10MB
    if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) -gt 10485760 ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
        touch "$LOG_FILE"
    fi
    
    echo "${timestamp} - ${message}" | tee -a "$LOG_FILE"
}

# Fungsi validasi input
validate_bot_token() {
    local token="$1"
    [[ $token =~ ^[0-9]{8,10}:[a-zA-Z0-9_-]{35}$ ]]
}

validate_chat_id() {
    local chat_id="$1"
    [[ $chat_id =~ ^-?[0-9]+$ ]]
}

# Fungsi lock untuk mencegah multiple instance
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            print_error "Backup sedang berjalan (PID: $pid)"
            exit 1
        else
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# Cleanup saat script exit
cleanup() {
    release_lock
    exit 0
}

trap cleanup EXIT INT TERM

# ===================================================================
# FUNGSI TELEGRAM API
# ===================================================================

# Fungsi kirim pesan dengan retry mechanism
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
        log_message "Retry kirim pesan ($retry_count/$MAX_RETRIES): $response"
        sleep $((retry_count * 2))
    done
    
    log_message "Gagal kirim pesan setelah $MAX_RETRIES percobaan"
    return 1
}

# Fungsi upload file dengan progress dan retry
send_telegram_file() {
    local file_path="$1"
    local caption="$2"
    local retry_count=0
    local response
    
    if [[ ! -f "$file_path" ]]; then
        log_message "File tidak ditemukan: $file_path"
        return 1
    fi
    
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        print_info "Upload attempt $((retry_count + 1))/$MAX_RETRIES..."
        
        response=$(curl -s --max-time 300 \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
            -F chat_id="${TELEGRAM_CHAT_ID}" \
            -F document=@"${file_path}" \
            -F caption="${caption}" 2>/dev/null)
        
        if [[ $response == *"\"ok\":true"* ]]; then
            return 0
        fi
        
        ((retry_count++))
        log_message "Retry upload ($retry_count/$MAX_RETRIES): $response"
        sleep $((retry_count * 5))
    done
    
    log_message "Gagal upload file setelah $MAX_RETRIES percobaan"
    return 1
}

# Test koneksi Telegram yang lebih robust
test_telegram_connection() {
    print_info "Testing koneksi Telegram..."
    
    # Test getMe API terlebih dahulu
    local me_response=$(curl -s --max-time "$API_TIMEOUT" \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null)
    
    if [[ $me_response != *"\"ok\":true"* ]]; then
        print_error "Bot token tidak valid!"
        return 1
    fi
    
    # Test kirim pesan
    if send_telegram_message "🔧 <b>Test Connection</b> - Backup system berhasil dikonfigurasi!"; then
        print_success "Koneksi Telegram berhasil!"
        return 0
    else
        print_error "Gagal mengirim pesan test!"
        return 1
    fi
}

# ===================================================================
# FUNGSI BACKUP
# ===================================================================

# Fungsi dapatkan IP server dengan fallback
get_server_ip() {
    local ip
    
    # Coba beberapa service untuk mendapatkan IP
    for service in "ifconfig.me" "ipinfo.io/ip" "icanhazip.com" "ident.me"; do
        ip=$(curl -s --max-time 10 "https://$service" 2>/dev/null | tr -d '\n\r ')
        if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    # Fallback ke hostname atau unknown
    hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown"
}

# Fungsi backup dengan progress dan optimasi
run_backup() {
    acquire_lock
    
    # Load konfigurasi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Konfigurasi tidak ditemukan! Jalankan: $0 --setup"
        exit 1
    fi
    
    source "$CONFIG_FILE"
    
    log_message "=== MEMULAI BACKUP ==="
    send_telegram_message "🔄 <b>Backup dimulai</b> - $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Buat direktori backup
    mkdir -p "$BACKUP_DIR"
    
    # Dapatkan IP server
    local ip_server=$(get_server_ip)
    log_message "IP Server: $ip_server"
    
    # Generate nama file backup
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_filename="backup-${ip_server}-${timestamp}.zip"
    local backup_path="${BACKUP_DIR}/${backup_filename}"
    
    log_message "Membuat backup: $backup_filename"
    
    # Hitung estimasi ukuran sebelum backup
    local estimated_size=$(du -sh ~ 2>/dev/null | cut -f1 || echo "Unknown")
    print_info "Estimasi ukuran data: $estimated_size"
    
    # Proses backup dengan exclude yang dioptimalkan
    local start_time=$(date +%s)
    
    zip -r "$backup_path" ~ \
        -x "*/node_modules/*" \
        -x "*/__pycache__/*" \
        -x "*/.cache/*" \
        -x "*/.npm/*" \
        -x "*/.yarn/*" \
        -x "*/.local/lib/python*/*" \
        -x "*/.local/share/virtualenvs/*" \
        -x "*/.ipython/*" \
        -x "*/.jupyter/*" \
        -x "*/.jupyter_ystore.db" \
        -x "*/.ssh/*" \
        -x "*/.gnupg/*" \
        -x "*/.wget-hsts" \
        -x "*/.bash_history" \
        -x "*/.zsh_history" \
        -x "*/.mysql_history" \
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
        -x "*/tmp/*" \
        -x "*/var/tmp/*" \
        -x "*/var/log/*" \
        -x "*/var/cache/*" \
        -x "*/.docker/*" \
        -x "*/snap/*" \
        -x "*/.vscode-server/*" \
        -x "*/backup-*.zip" >> "$LOG_FILE" 2>&1
    
    local backup_exit_code=$?
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Validasi hasil backup
    if [[ $backup_exit_code -eq 0 && -f "$backup_path" ]]; then
        local file_size=$(du -h "$backup_path" | cut -f1)
        local file_size_bytes=$(stat -f%z "$backup_path" 2>/dev/null || stat -c%s "$backup_path" 2>/dev/null)
        
        # Validasi ukuran file (minimal 1KB)
        if [[ $file_size_bytes -lt 1024 ]]; then
            log_message "Backup terlalu kecil, kemungkinan gagal: $file_size"
            send_telegram_message "❌ <b>Backup gagal</b> - File terlalu kecil ($file_size)"
            rm -f "$backup_path"
            return 1
        fi
        
        log_message "Backup berhasil: $backup_filename (Size: $file_size, Duration: ${duration}s)"
        
        # Upload ke Telegram
        log_message "Mengupload ke Telegram..."
        local caption="📦 <b>Backup VPS</b>
🖥️ Server: ${ip_server}
📅 $(date '+%Y-%m-%d %H:%M:%S')
📁 Size: ${file_size}
⏱️ Duration: ${duration}s
✅ Status: Berhasil"
        
        if send_telegram_file "$backup_path" "$caption"; then
            log_message "Upload berhasil"
            send_telegram_message "✅ <b>Backup berhasil</b> - ${backup_filename} (${file_size})"
            
            # Hapus file backup setelah upload berhasil
            rm -f "$backup_path"
            log_message "File backup dihapus dari VPS: $backup_filename"
            
        else
            log_message "Upload gagal"
            send_telegram_message "❌ <b>Upload gagal</b> - ${backup_filename}"
            
            # Simpan file backup jika upload gagal
            print_warning "File backup disimpan di: $backup_path"
        fi
        
    else
        log_message "Backup gagal (exit code: $backup_exit_code)"
        send_telegram_message "❌ <b>Backup gagal</b> - $(date '+%Y-%m-%d %H:%M:%S')"
        rm -f "$backup_path"
    fi
    
    # Cleanup backup lama
    cleanup_old_backups
    
    log_message "=== BACKUP SELESAI ==="
}

# Fungsi cleanup backup lama
cleanup_old_backups() {
    local backup_count=$(find "$BACKUP_DIR" -name "backup-*.zip" -type f | wc -l)
    
    if [[ $backup_count -gt ${MAX_BACKUPS:-3} ]]; then
        log_message "Membersihkan backup lama..."
        find "$BACKUP_DIR" -name "backup-*.zip" -type f -printf '%T@ %p\n' | \
            sort -n | head -n -${MAX_BACKUPS:-3} | cut -d' ' -f2- | \
            xargs -r rm -f
        
        local remaining=$(find "$BACKUP_DIR" -name "backup-*.zip" -type f | wc -l)
        log_message "Backup tersisa: $remaining file"
    fi
}

# ===================================================================
# FUNGSI SETUP DAN KONFIGURASI
# ===================================================================

# Setup dengan validasi yang lebih ketat
setup_backup() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        SETUP BACKUP TELEGRAM        ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Buat direktori
    sudo mkdir -p "$SCRIPT_DIR"
    sudo mkdir -p "$BACKUP_DIR"
    sudo mkdir -p "$(dirname "$LOG_FILE")"
    
    echo -e "${YELLOW}Silakan masukkan konfigurasi Telegram Bot:${NC}"
    echo
    
    # Input dan validasi Bot Token
    local bot_token
    while true; do
        read -p "🤖 Telegram Bot Token: " bot_token
        if [[ -z "$bot_token" ]]; then
            print_error "Bot token tidak boleh kosong!"
            continue
        fi
        
        if ! validate_bot_token "$bot_token"; then
            print_error "Format bot token tidak valid!"
            echo "   Format: 1234567890:ABCdefGHIjklMNOpqrsTUVwxyz"
            continue
        fi
        
        break
    done
    
    # Input dan validasi Chat ID
    local chat_id
    while true; do
        read -p "💬 Telegram Chat ID: " chat_id
        if [[ -z "$chat_id" ]]; then
            print_error "Chat ID tidak boleh kosong!"
            continue
        fi
        
        if ! validate_chat_id "$chat_id"; then
            print_error "Format chat ID tidak valid!"
            echo "   Format: 123456789 atau -123456789"
            continue
        fi
        
        break
    done
    
    # Input interval backup
    local interval
    read -p "⏰ Interval backup (jam) [default: $DEFAULT_INTERVAL]: " interval
    interval=${interval:-$DEFAULT_INTERVAL}
    
    # Validasi interval
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ $interval -lt 1 ]] || [[ $interval -gt 24 ]]; then
        print_warning "Interval tidak valid, menggunakan default: $DEFAULT_INTERVAL"
        interval=$DEFAULT_INTERVAL
    fi
    
    # Input maksimal backup
    local max_backups
    read -p "🗂️ Maksimal backup tersimpan [default: $DEFAULT_MAX_BACKUPS]: " max_backups
    max_backups=${max_backups:-$DEFAULT_MAX_BACKUPS}
    
    # Validasi max_backups
    if ! [[ "$max_backups" =~ ^[0-9]+$ ]] || [[ $max_backups -lt 1 ]]; then
        print_warning "Maksimal backup tidak valid, menggunakan default: $DEFAULT_MAX_BACKUPS"
        max_backups=$DEFAULT_MAX_BACKUPS
    fi
    
    # Simpan konfigurasi
    cat > "$CONFIG_FILE" << EOF
# Konfigurasi Backup Telegram VPS
TELEGRAM_BOT_TOKEN="$bot_token"
TELEGRAM_CHAT_ID="$chat_id"
BACKUP_INTERVAL="$interval"
MAX_BACKUPS="$max_backups"
CREATED_DATE="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
    
    sudo chmod 600 "$CONFIG_FILE"
    print_success "Konfigurasi tersimpan!"
    
    # Setup crontab
    setup_crontab "$interval"
    
    # Test koneksi
    TELEGRAM_BOT_TOKEN="$bot_token"
    TELEGRAM_CHAT_ID="$chat_id"
    
    if test_telegram_connection; then
        print_success "Setup berhasil! Backup akan berjalan otomatis setiap $interval jam."
    else
        print_error "Setup gagal! Periksa konfigurasi Telegram."
        return 1
    fi
    
    echo
    echo -e "${BLUE}Perintah yang tersedia:${NC}"
    echo -e "  ${GREEN}$0 --backup${NC}   - Backup manual"
    echo -e "  ${GREEN}$0 --status${NC}   - Lihat status"
    echo -e "  ${GREEN}$0 --log${NC}      - Lihat log"
    echo -e "  ${GREEN}$0 --setup${NC}    - Ubah konfigurasi"
}

# Setup crontab yang lebih fleksibel
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
    crontab -l 2>/dev/null | grep -v "backup_telegram" | crontab -
    
    # Tambah crontab baru
    (crontab -l 2>/dev/null; echo "$cron_schedule $0 --backup >/dev/null 2>&1") | crontab -
    
    print_success "Crontab diatur untuk backup setiap $interval jam"
}

# ===================================================================
# FUNGSI STATUS DAN MONITORING
# ===================================================================

# Status dengan informasi lengkap
show_status() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           STATUS BACKUP              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        
        print_success "Konfigurasi: OK"
        echo "  📁 Config: $CONFIG_FILE"
        echo "  🤖 Bot: ${TELEGRAM_BOT_TOKEN:0:10}..."
        echo "  💬 Chat: $TELEGRAM_CHAT_ID"
        echo "  ⏰ Interval: $BACKUP_INTERVAL jam"
        echo "  🗂️ Max Backup: $MAX_BACKUPS"
        echo "  📅 Dibuat: ${CREATED_DATE:-'Unknown'}"
        echo
        
        # Status crontab
        if crontab -l 2>/dev/null | grep -q "backup_telegram"; then
            print_success "Crontab: Aktif"
            local cron_entry=$(crontab -l 2>/dev/null | grep "backup_telegram")
            echo "  📋 Schedule: $cron_entry"
        else
            print_warning "Crontab: Tidak aktif"
        fi
        echo
        
        # Backup terakhir
        if [[ -f "$LOG_FILE" ]]; then
            local last_backup=$(tail -n 100 "$LOG_FILE" | grep "BACKUP SELESAI" | tail -n 1)
            if [[ -n "$last_backup" ]]; then
                local backup_time=$(echo "$last_backup" | cut -d' ' -f1-2)
                print_success "Backup terakhir: $backup_time"
            else
                print_warning "Belum ada backup yang selesai"
            fi
            
            # Status backup terakhir
            local last_success=$(tail -n 100 "$LOG_FILE" | grep "Backup berhasil" | tail -n 1)
            local last_error=$(tail -n 100 "$LOG_FILE" | grep "Backup gagal" | tail -n 1)
            
            if [[ -n "$last_success" ]]; then
                echo "  ✅ Status: $(echo "$last_success" | cut -d'-' -f4-)"
            elif [[ -n "$last_error" ]]; then
                echo "  ❌ Status: Error detected"
            fi
        else
            print_warning "Log file tidak ditemukan"
        fi
        echo
        
        # Informasi sistem
        local disk_usage=$(df -h / | awk 'NR==2 {print $5}')
        local memory_usage=$(free -h | awk 'NR==2{printf "%.1f%%", $3/$2*100}')
        local uptime=$(uptime -p 2>/dev/null || uptime | cut -d',' -f1)
        
        echo -e "${BLUE}Informasi Sistem:${NC}"
        echo "  💾 Disk Usage: $disk_usage"
        echo "  🧠 Memory Usage: $memory_usage"
        echo "  ⏱️ Uptime: $uptime"
        echo "  🌐 IP: $(get_server_ip)"
        
        # Warning jika disk hampir penuh
        local disk_percent=$(echo "$disk_usage" | sed 's/%//')
        if [[ $disk_percent -gt 90 ]]; then
            echo
            print_warning "Disk usage tinggi ($disk_usage)! Pertimbangkan untuk cleanup."
        fi
        
    else
        print_error "Belum dikonfigurasi! Jalankan: $0 --setup"
    fi
}

# Fungsi log dengan filter
show_log() {
    local lines=${1:-50}
    
    if [[ -f "$LOG_FILE" ]]; then
        echo -e "${BLUE}=== LOG BACKUP (Last $lines lines) ===${NC}"
        tail -n "$lines" "$LOG_FILE" | while read -r line; do
            if [[ $line == *"ERROR"* ]]; then
                echo -e "${RED}$line${NC}"
            elif [[ $line == *"SUCCESS"* ]] || [[ $line == *"berhasil"* ]]; then
                echo -e "${GREEN}$line${NC}"
            elif [[ $line == *"WARNING"* ]] || [[ $line == *"gagal"* ]]; then
                echo -e "${YELLOW}$line${NC}"
            else
                echo "$line"
            fi
        done
    else
        print_error "Log file tidak ditemukan: $LOG_FILE"
    fi
}

# ===================================================================
# FUNGSI BANTUAN
# ===================================================================

show_help() {
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        BACKUP TELEGRAM VPS           ║${NC}"
    echo -e "${BLUE}║           Version 2.0                ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    echo "Usage: $0 [OPTION]"
    echo
    echo "Options:"
    echo -e "  ${GREEN}--setup${NC}       Setup/ubah konfigurasi"
    echo -e "  ${GREEN}--backup${NC}      Jalankan backup manual"
    echo -e "  ${GREEN}--status${NC}      Tampilkan status sistem"
    echo -e "  ${GREEN}--log [N]${NC}     Tampilkan log (default: 50 lines)"
    echo -e "  ${GREEN}--test${NC}        Test koneksi Telegram"
    echo -e "  ${GREEN}--cleanup${NC}     Cleanup backup lama"
    echo -e "  ${GREEN}--help${NC}        Tampilkan bantuan ini"
    echo
    echo "Contoh:"
    echo "  $0 --setup       # Setup pertama kali"
    echo "  $0 --backup      # Backup manual"
    echo "  $0 --status      # Lihat status"
    echo "  $0 --log 100     # Lihat 100 baris log terakhir"
    echo
    echo -e "${YELLOW}File penting:${NC}"
    echo "  Config: $CONFIG_FILE"
    echo "  Log: $LOG_FILE"
    echo "  Backup: $BACKUP_DIR"
}

# ===================================================================
# MAIN SCRIPT
# ===================================================================

# Validasi user (harus root untuk beberapa operasi)
check_permissions() {
    if [[ $EUID -ne 0 ]] && [[ "$1" != "--help" ]] && [[ "$1" != "--status" ]]; then
        print_warning "Beberapa operasi memerlukan akses root"
        print_info "Jalankan dengan: sudo $0 $1"
    fi
}

# Main function
main() {
    local command="${1:-}"
    
    check_permissions "$command"
    
    case "$command" in
        --setup)
            setup_backup
            ;;
        --backup)
            run_backup
            ;;
        --status)
            show_status
            ;;
        --log)
            show_log "${2:-50}"
            ;;
        --test)
            if [[ -f "$CONFIG_FILE" ]]; then
                source "$CONFIG_FILE"
                test_telegram_connection
            else
                print_error "Konfigurasi tidak ditemukan! Jalankan: $0 --setup"
            fi
            ;;
        --cleanup)
            cleanup_old_backups
            ;;
        --help)
            show_help
            ;;
        *)
            if [[ -f "$CONFIG_FILE" ]]; then
                show_status
            else
                print_info "Backup Telegram VPS belum dikonfigurasi"
                echo
                read -p "Apakah Anda ingin melakukan setup sekarang? (y/n): " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    setup_backup
                else
                    show_help
                fi
            fi
            ;;
    esac
}

# Jalankan main function
main "$@"
