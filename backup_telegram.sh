#!/bin/bash

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# File konfigurasi
CONFIG_FILE="/opt/backup-telegram/config.conf"
SCRIPT_DIR="/opt/backup-telegram"
LOG_FILE="/var/log/backup_telegram.log"
BACKUP_DIR="/tmp/backups"

# Fungsi print berwarna
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Fungsi logging
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Fungsi setup awal
setup_backup() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        SETUP BACKUP TELEGRAM        ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    
    # Buat direktori jika belum ada
    sudo mkdir -p "$SCRIPT_DIR"
    sudo mkdir -p "$BACKUP_DIR"
    sudo mkdir -p "$(dirname "$LOG_FILE")"
    
    # Input konfigurasi
    echo -e "${YELLOW}Silakan masukkan konfigurasi Telegram Bot:${NC}"
    echo
    
    read -p "🤖 Telegram Bot Token: " bot_token
    while [[ -z "$bot_token" ]]; do
        print_error "Bot token tidak boleh kosong!"
        read -p "🤖 Telegram Bot Token: " bot_token
    done
    
    read -p "💬 Telegram Chat ID: " chat_id
    while [[ -z "$chat_id" ]]; do
        print_error "Chat ID tidak boleh kosong!"
        read -p "💬 Telegram Chat ID: " chat_id
    done
    
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
EOF
    
    sudo chmod 600 "$CONFIG_FILE"
    print_success "Konfigurasi tersimpan!"
    
    # Setup crontab
    setup_crontab "$interval"
    
    # Test koneksi
    test_telegram_connection
    
    print_success "Setup selesai! Backup akan berjalan otomatis setiap $interval jam."
    echo
    echo -e "${BLUE}Untuk menjalankan backup manual:${NC} sudo $0 --backup"
    echo -e "${BLUE}Untuk melihat log:${NC} sudo tail -f $LOG_FILE"
    echo -e "${BLUE}Untuk mengubah konfigurasi:${NC} sudo $0 --setup"
}

# Fungsi setup crontab
setup_crontab() {
    local interval=$1
    local cron_schedule
    
    case $interval in
        1) cron_schedule="0 * * * *" ;;
        2) cron_schedule="0 */2 * * *" ;;
        3) cron_schedule="0 */3 * * *" ;;
        6) cron_schedule="0 */6 * * *" ;;
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

# Fungsi kirim pesan ke Telegram
send_telegram_message() {
    local message="$1"
    local response
    
    response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${message}" \
        -d parse_mode="HTML")
    
    if [[ $response == *"\"ok\":true"* ]]; then
        return 0
    else
        return 1
    fi
}

# Fungsi upload file ke Telegram
send_telegram_file() {
    local file_path="$1"
    local caption="$2"
    local response
    
    response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F chat_id="${TELEGRAM_CHAT_ID}" \
        -F document=@"${file_path}" \
        -F caption="${caption}")
    
    if [[ $response == *"\"ok\":true"* ]]; then
        return 0
    else
        return 1
    fi
}

# Fungsi test koneksi Telegram
test_telegram_connection() {
    print_info "Testing koneksi Telegram..."
    
    if send_telegram_message "🔧 <b>Test Connection</b> - Backup system berhasil dikonfigurasi!"; then
        print_success "Koneksi Telegram berhasil!"
    else
        print_error "Koneksi Telegram gagal! Periksa Bot Token dan Chat ID."
    fi
}

# Fungsi utama backup
run_backup() {
    # Load konfigurasi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Konfigurasi tidak ditemukan! Jalankan: $0 --setup"
        exit 1
    fi
    
    source "$CONFIG_FILE"
    
    log_message "=== MEMULAI BACKUP ==="
    send_telegram_message "🔄 <b>Backup dimulai</b> - $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Dapatkan IP server
    ip_server=$(curl -s --max-time 10 ifconfig.me 2>/dev/null || curl -s --max-time 10 ipinfo.io/ip 2>/dev/null || echo "unknown")
    
    # Nama file backup
    timestamp=$(date '+%Y%m%d_%H%M%S')
    backup_filename="backup-${ip_server}-${timestamp}.zip"
    backup_path="${BACKUP_DIR}/${backup_filename}"
    
    log_message "Membuat backup: $backup_filename"
    
    # Proses backup
    zip -r "$backup_path" ~ \
      -x "*/node_modules/*" \
      -x "*/__pycache__/*" \
      -x "*/.cache/*" \
      -x "*/.npm/*" \
      -x "*/.local/lib/python*/*" \
      -x "*/.ipython/*" \
      -x "*/.jupyter/*" \
      -x "*/.jupyter_ystore.db" \
      -x "*/.ssh/*" \
      -x "*/.wget-hsts" \
      -x "*/.bash_history" \
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
      -x "*/tmp/backups/*" \
      -x "*/var/log/*" >> "$LOG_FILE" 2>&1
    
    # Cek hasil backup
    if [[ $? -eq 0 && -f "$backup_path" ]]; then
        file_size=$(du -h "$backup_path" | cut -f1)
        log_message "Backup berhasil: $backup_filename (Size: $file_size)"
        
        # Upload ke Telegram
        log_message "Mengupload ke Telegram..."
        caption="📦 <b>Backup VPS</b>
🖥️ Server: ${ip_server}
📅 $(date '+%Y-%m-%d %H:%M:%S')
📁 Size: ${file_size}
✅ Status: Berhasil"
        
        if send_telegram_file "$backup_path" "$caption"; then
            log_message "Upload berhasil"
            send_telegram_message "✅ <b>Backup berhasil</b> - ${backup_filename} (${file_size})"
            
            # **HAPUS FILE BACKUP SETELAH UPLOAD BERHASIL**
            rm -f "$backup_path"
            log_message "File backup dihapus dari VPS: $backup_filename"
            
        else
            log_message "Upload gagal"
            send_telegram_message "❌ <b>Upload gagal</b> - ${backup_filename}"
        fi
        
    else
        log_message "Backup gagal"
        send_telegram_message "❌ <b>Backup gagal</b> - $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    
    # Bersihkan backup lama (jika ada yang tersisa)
    find "$BACKUP_DIR" -name "backup-*.zip" -type f -mtime +1 -delete 2>/dev/null
    
    log_message "=== BACKUP SELESAI ==="
}

# Fungsi tampilkan status
show_status() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           STATUS BACKUP              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        print_success "Konfigurasi: OK"
        echo "  Bot Token: ${TELEGRAM_BOT_TOKEN:0:10}..."
        echo "  Chat ID: $TELEGRAM_CHAT_ID"
        echo "  Interval: $BACKUP_INTERVAL jam"
        echo
        
        # Cek crontab
        if crontab -l 2>/dev/null | grep -q "backup_telegram"; then
            print_success "Crontab: Aktif"
        else
            print_warning "Crontab: Tidak aktif"
        fi
        
        # Backup terakhir
        if [[ -f "$LOG_FILE" ]]; then
            last_backup=$(tail -n 50 "$LOG_FILE" | grep "BACKUP SELESAI" | tail -n 1)
            if [[ -n "$last_backup" ]]; then
                backup_time=$(echo "$last_backup" | cut -d' ' -f1-2)
                print_success "Backup terakhir: $backup_time"
            else
                print_warning "Belum ada backup yang berhasil"
            fi
        fi
        
        # Disk usage
        disk_usage=$(df -h / | awk 'NR==2 {print $5}')
        echo "  Disk Usage: $disk_usage"
        
    else
        print_error "Belum dikonfigurasi! Jalankan: $0 --setup"
    fi
}

# Fungsi bantuan
show_help() {
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        BACKUP TELEGRAM VPS           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    echo "Usage: $0 [OPTION]"
    echo
    echo "Options:"
    echo "  --setup     Setup konfigurasi awal"
    echo "  --backup    Jalankan backup manual"
    echo "  --status    Tampilkan status sistem"
    echo "  --log       Tampilkan log backup"
    echo "  --help      Tampilkan bantuan ini"
    echo
    echo "Contoh:"
    echo "  $0 --setup     # Setup pertama kali"
    echo "  $0 --backup    # Backup manual"
    echo "  $0 --status    # Lihat status"
}

# Main script
case "${1:-}" in
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
        if [[ -f "$LOG_FILE" ]]; then
            tail -n 50 "$LOG_FILE"
        else
            print_error "Log file tidak ditemukan"
        fi
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
