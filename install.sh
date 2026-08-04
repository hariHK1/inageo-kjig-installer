#!/usr/bin/env bash
# Installer awal inageo-mapviewer (mode PULL — repo ini TIDAK punya source
# code aplikasi, cuma compose + config, image di-pull dari GHCR). Dijalankan
# SEKALI di server target sebelum deploy.sh. Tugasnya: (1) cek/pasang Docker,
# (2) bangun .env lewat wizard interaktif, (3) siapkan direktori yang
# dibutuhkan compose (certbot/, mapproxy/, nginx/conf.d/), (4) serahkan ke
# deploy.sh.
#
# Aman dijalankan ulang (idempoten) — kalau Docker sudah ada, langkah 1
# dilewati; kalau .env sudah ada, ditanya dulu sebelum ditimpa.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# WAJIB ke stderr (>&2) — beberapa fungsi (ask, ask_required) dipanggil lewat
# command substitution `$(...)`, apa pun yang ditulis ke stdout di dalamnya
# ikut tertangkap masuk ke nilai variabel hasil.
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

confirm() {
    read -rp "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

print_banner() {
    echo ""
    echo "==================================================="
    echo "  inageo-mapviewer — Installer (mode pull GHCR)"
    echo "==================================================="
    echo ""
}

# ── 1. Prasyarat: Docker + Compose plugin ───────────────────────────────────
check_or_install_docker() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        log_ok "Docker + Compose plugin sudah terpasang ($(docker --version))."
        return 0
    fi

    log_warn "Docker/Docker Compose plugin belum lengkap terpasang."
    local sudo_cmd=""
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo_cmd="sudo"
        else
            log_error "Perlu root atau sudo untuk memasang Docker. Jalankan ulang installer ini sebagai root, atau instal Docker manual lalu jalankan lagi."
            return 1
        fi
    fi

    confirm "Pasang Docker sekarang via skrip resmi get.docker.com?" || {
        log_error "Docker wajib terpasang sebelum lanjut. Instal manual (https://docs.docker.com/engine/install/) lalu jalankan ulang installer ini."
        return 1
    }

    log_info "Mengunduh skrip resmi Docker ke /tmp (diunduh dulu baru dijalankan, bisa diperiksa — bukan pipe langsung)..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || { log_error "Gagal mengunduh skrip Docker."; return 1; }
    log_info "Menjalankan installer Docker resmi..."
    $sudo_cmd sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh

    if ! command -v docker >/dev/null 2>&1; then
        log_error "Instalasi Docker tampaknya gagal. Cek manual: https://docs.docker.com/engine/install/"
        return 1
    fi
    log_ok "Docker terpasang: $(docker --version)"

    if [[ "$(id -u)" -ne 0 ]] && ! groups "$USER" 2>/dev/null | grep -q '\bdocker\b'; then
        log_warn "User '$USER' belum di grup 'docker' — menambahkan..."
        $sudo_cmd usermod -aG docker "$USER"
        log_warn "Perlu logout/login ulang (atau jalankan 'newgrp docker') supaya perintah docker tidak perlu sudo. Jalankan ulang installer ini setelahnya."
        return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose plugin tidak terdeteksi meski Docker terpasang. Cek instalasi manual."
        return 1
    fi
}

# ── 2. Wizard .env ───────────────────────────────────────────────────────────
ask() {
    local prompt="$1" default="${2:-}" ans
    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " ans
        echo "${ans:-$default}"
    else
        read -rp "$prompt: " ans
        echo "$ans"
    fi
}

ask_required() {
    local prompt="$1" val=""
    while [[ -z "$val" ]]; do
        read -rp "$prompt (wajib diisi): " val
        [[ -z "$val" ]] && log_warn "Tidak boleh kosong."
    done
    echo "$val"
}

ask_port() {
    local prompt="$1" default="$2" val
    while true; do
        val=$(ask "$prompt" "$default")
        if [[ "$val" =~ ^[0-9]+$ && "$val" -ge 1 && "$val" -le 65535 ]]; then
            echo "$val"
            return 0
        fi
        log_warn "Harus angka port valid (1-65535)."
    done
}

ask_file() {
    local prompt="$1" required="$2" val=""
    while true; do
        read -rp "$prompt: " val
        if [[ -z "$val" ]]; then
            [[ "$required" == "true" ]] && { log_warn "Tidak boleh kosong."; continue; }
            echo ""
            return 0
        fi
        if [[ -f "$val" ]]; then
            echo "$val"
            return 0
        fi
        log_warn "File '$val' tidak ditemukan. Pastikan path-nya benar (relatif terhadap direktori kerja saat ini, atau absolut)."
    done
}

gen_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 | tr -d '\n/+='
    else
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32
    fi
}

# Validasi sertifikat/key kustom sebelum dipakai — tanpa ini, file yang salah
# format atau pasangan cert/key yang tidak cocok baru ketahuan gagal saat
# nginx start, jauh setelah wizard selesai.
validate_cert_pair() {
    local cert="$1" key="$2" domain="$3"

    if ! command -v openssl >/dev/null 2>&1; then
        log_warn "openssl tidak ditemukan di host ini — validasi sertifikat dilewati, pastikan filenya benar secara manual."
        return 0
    fi

    if ! openssl x509 -in "$cert" -noout 2>/dev/null; then
        log_error "File '$cert' bukan sertifikat PEM X.509 yang valid (kalau ini file .pfx/.p12/DER, konversi dulu ke PEM: openssl pkcs12 -in file.pfx -out cert.pem -clcerts -nokeys)."
        return 1
    fi
    if ! openssl pkey -in "$key" -noout 2>/dev/null; then
        log_error "File '$key' bukan private key PEM yang valid."
        return 1
    fi

    local pub_from_cert pub_from_key
    pub_from_cert="$(openssl x509 -pubkey -noout -in "$cert" 2>/dev/null | openssl md5 2>/dev/null)"
    pub_from_key="$(openssl pkey -pubout -in "$key" 2>/dev/null | openssl md5 2>/dev/null)"
    if [[ -z "$pub_from_cert" || -z "$pub_from_key" || "$pub_from_cert" != "$pub_from_key" ]]; then
        log_error "Private key TIDAK COCOK dengan sertifikat ini (public key berbeda) — pastikan pasangan file yang benar."
        return 1
    fi

    local sans cn
    sans="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null)"
    if [[ -n "$sans" ]]; then
        if ! echo "$sans" | grep -qi "$domain"; then
            log_warn "Domain '$domain' tidak ditemukan di daftar SAN sertifikat ini. Kalau ini sertifikat wildcard atau domain lain yang memang disengaja, boleh dilanjutkan — kalau tidak, cek lagi filenya."
        fi
    else
        cn="$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | grep -o 'CN *= *[^,/]*' | sed 's/CN *= *//')"
        if [[ -n "$cn" && "$cn" != "$domain" ]]; then
            log_warn "Domain '$domain' tidak cocok dengan CN sertifikat ('$cn'). Pastikan ini file yang benar."
        fi
    fi

    log_ok "Sertifikat & private key valid dan saling cocok."
    return 0
}

install_custom_cert() {
    local domain="$1" cert_path="$2" key_path="$3" chain_path="$4"
    local live_dir="$SCRIPT_DIR/certbot/conf/live/$domain"

    mkdir -p "$live_dir"
    cp "$cert_path" "$live_dir/fullchain.pem" || { log_error "Gagal menyalin file sertifikat."; return 1; }
    cp "$key_path" "$live_dir/privkey.pem" || { log_error "Gagal menyalin file private key."; return 1; }
    chmod 600 "$live_dir/privkey.pem"

    if [[ -n "$chain_path" ]]; then
        cp "$chain_path" "$live_dir/chain.pem" || { log_error "Gagal menyalin file chain."; return 1; }
    else
        cp "$live_dir/fullchain.pem" "$live_dir/chain.pem"
        log_warn "Tidak ada file chain terpisah — fullchain dipakai juga sebagai chain (OCSP stapling mungkin kurang optimal, TLS tetap normal)."
    fi

    log_ok "Sertifikat kustom terpasang di certbot/conf/live/$domain/ — deploy.sh tidak akan menjalankan certbot untuk domain ini."
}

run_wizard() {
    echo ""
    log_info "=== Registry (GHCR) ==="
    echo "Image app & harvester dibangun & di-tag GitHub Actions di repo source"
    echo "(inageo-mapviewer) — installer ini cuma pull, tidak build apa pun."
    local GHCR_OWNER GHCR_USERNAME GHCR_TOKEN RELEASE_VERSION
    GHCR_OWNER=$(ask_required "GHCR_OWNER (owner GitHub tempat image di-publish, mis. hariHK1)")
    GHCR_USERNAME=$(ask_required "GHCR_USERNAME (username GitHub kamu, untuk docker login)")
    echo "Buat Personal Access Token BARU khusus ini (scope read:packages saja) —"
    echo "JANGAN reuse token yang pernah ditempel di chat/tempat lain, anggap itu sudah bocor."
    GHCR_TOKEN=$(ask_required "GHCR_TOKEN (PAT scope read:packages)")
    RELEASE_VERSION=$(ask_required "RELEASE_VERSION (tag rilis, mis. v0.1.0 — atau 'latest', tidak reproducible)")

    echo ""
    log_info "=== Domain & TLS ==="
    local DOMAIN ACME_EMAIL BEHIND_WAF WAF_TRUSTED_CIDR TLS_MODE
    local CUSTOM_CERT_PATH="" CUSTOM_KEY_PATH="" CUSTOM_CHAIN_PATH=""
    DOMAIN=$(ask_required "Domain publik atau IP server ini (mis. mapviewer.instansi.go.id, atau 192.168.x.x untuk internal/dev — DNS-nya harus sudah menunjuk ke server ini kalau pakai domain)")

    echo ""
    echo "Kalau server ini sudah berada di belakang WAF (dikelola tim jaringan/BSSN/cloud"
    echo "provider) — ATAU ini server internal/dev tanpa TLS publik sama sekali (mis. IP"
    echo "internal) — TLS publik tidak perlu diurus di sini, nginx cukup HTTP biasa."
    if confirm "Server ini di belakang WAF, atau internal/dev tanpa TLS?"; then
        BEHIND_WAF="true"
        TLS_MODE=""
        ACME_EMAIL=""
        echo ""
        echo "Opsional: rentang IP (CIDR, dipisah koma) milik WAF, supaya nginx bisa"
        echo "membaca IP klien asli dengan aman. Kosongkan kalau tidak relevan (mis. IP"
        echo "internal/dev) — tetap aman, cuma rate-limiting kurang presisi."
        WAF_TRUSTED_CIDR=$(ask "Rentang IP WAF (mis. 10.20.0.0/16,192.168.100.0/24)" "")
    else
        BEHIND_WAF="false"
        WAF_TRUSTED_CIDR=""
        echo ""
        if confirm "Sudah punya file sertifikat TLS sendiri (fullchain/cert + private key)?"; then
            TLS_MODE="custom"
            ACME_EMAIL=""
            echo ""
            echo "Masukkan path file di server ini (upload dulu via scp sebelum menjawab ini)."
            while true; do
                CUSTOM_CERT_PATH=$(ask_file "Path file sertifikat (fullchain.pem / cert.pem)" "true")
                CUSTOM_KEY_PATH=$(ask_file "Path file private key (privkey.pem / key.pem)" "true")
                if validate_cert_pair "$CUSTOM_CERT_PATH" "$CUSTOM_KEY_PATH" "$DOMAIN"; then
                    break
                fi
                confirm "Coba masukkan path lain?" || { log_error "Setup dibatalkan."; return 1; }
            done
            echo ""
            CUSTOM_CHAIN_PATH=$(ask_file "Path file chain/intermediate (opsional)" "false")
        else
            TLS_MODE="letsencrypt"
            ACME_EMAIL=$(ask_required "Email untuk notifikasi kedaluwarsa sertifikat Let's Encrypt")
        fi
    fi

    echo ""
    log_info "=== Skala ==="
    local APP_REPLICAS
    APP_REPLICAS=$(ask "Jumlah replica app di belakang nginx" "2")
    while [[ ! "$APP_REPLICAS" =~ ^[0-9]+$ || "$APP_REPLICAS" -lt 1 ]]; do
        log_warn "Harus angka >= 1."
        APP_REPLICAS=$(ask "Jumlah replica app" "2")
    done

    echo ""
    log_info "=== Port ==="
    local HTTP_PORT HTTPS_PORT
    HTTP_PORT=$(ask_port "Port publik HTTP nginx" "80")
    HTTPS_PORT=$(ask_port "Port publik HTTPS nginx" "443")

    local EXPOSE_PORTS="false"
    local POSTGRES_HOST_PORT="" REDIS_HOST_PORT="" REDIS_QUEUE_HOST_PORT=""
    local HARVESTER_HOST_PORT="" MAPPROXY_HOST_PORT="" APP_DIRECT_PORT=""
    local COMPOSE_FILE_VAL=""
    echo ""
    echo "Postgres/Redis/Redis-queue/harvester/mapproxy/app SECARA DEFAULT tidak"
    echo "bisa diakses langsung dari luar Docker (cuma antar-container) — ini postur"
    echo "aman, TIDAK disarankan diubah di server produksi."
    if confirm "Expose sebagian/semua port itu langsung ke host untuk debug (psql/redis-cli/dst dari luar)?"; then
        EXPOSE_PORTS="true"
        COMPOSE_FILE_VAL="docker-compose.yml:docker-compose.ports.yml"
        echo "Kosongkan satu per satu kalau TIDAK mau service itu ter-expose (Enter tanpa isi = pakai default, tetap ter-expose di port itu)."
        POSTGRES_HOST_PORT=$(ask "Port host untuk Postgres" "5432")
        REDIS_HOST_PORT=$(ask "Port host untuk Redis cache" "6379")
        REDIS_QUEUE_HOST_PORT=$(ask "Port host untuk Redis queue" "6380")
        HARVESTER_HOST_PORT=$(ask "Port host untuk harvester API" "4000")
        MAPPROXY_HOST_PORT=$(ask "Port host untuk MapProxy" "8081")
        if [[ "$APP_REPLICAS" -gt 1 ]]; then
            log_warn "APP_REPLICAS=$APP_REPLICAS (>1) — akses langsung ke app (bypass nginx) TIDAK bisa dipakai bersamaan dengan multi-replica. Dikosongkan."
        else
            APP_DIRECT_PORT=$(ask "Port host untuk akses app langsung (bypass nginx, kosongkan kalau tidak perlu)" "")
        fi
    fi

    echo ""
    log_info "=== Backend geoportal (server-side only) ==="
    local API_ACCESS_TOKEN NEXT_PUBLIC_APP_ORIGIN
    API_ACCESS_TOKEN="$(gen_password)"
    log_ok "API_ACCESS_TOKEN digenerate otomatis (dipakai bersama app & harvester)."
    if [[ "$BEHIND_WAF" == "true" && "$TLS_MODE" == "" && -z "$WAF_TRUSTED_CIDR" ]]; then
        # Kemungkinan besar internal/dev tanpa TLS sama sekali — tawarkan http://.
        if confirm "Origin publik pakai http:// (bukan https://)? Jawab 'y' kalau server ini benar-benar tanpa TLS (internal/dev)."; then
            NEXT_PUBLIC_APP_ORIGIN="http://$DOMAIN"
        else
            NEXT_PUBLIC_APP_ORIGIN="https://$DOMAIN"
        fi
    else
        NEXT_PUBLIC_APP_ORIGIN="https://$DOMAIN"
    fi
    echo "NEXT_PUBLIC_APP_ORIGIN runtime di-set ke: $NEXT_PUBLIC_APP_ORIGIN"
    echo "(Ingat: ini CUMA dipakai cek CORS server-side. Nilai yang di-bake ke bundle"
    echo "JS klien ditentukan repo Variables saat build di GitHub Actions — pastikan"
    echo "keduanya sama, lihat README.md.)"

    echo ""
    log_info "=== Object storage MinIO (opsional) ==="
    echo "Kosongkan MINIO_ENDPOINT kalau tidak dipakai — preview dokumen nonaktif graceful (503), tidak crash."
    local MINIO_ENDPOINT MINIO_REGION MINIO_ACCESS_KEY MINIO_SECRET_KEY ALLOWED_BUCKETS
    MINIO_ENDPOINT=$(ask "MINIO_ENDPOINT" "")
    if [[ -n "$MINIO_ENDPOINT" ]]; then
        MINIO_REGION=$(ask "MINIO_REGION" "us-east-1")
        MINIO_ACCESS_KEY=$(ask_required "MINIO_ACCESS_KEY")
        MINIO_SECRET_KEY=$(ask_required "MINIO_SECRET_KEY")
        ALLOWED_BUCKETS=$(ask_required "ALLOWED_BUCKETS (dipisah koma)")
    else
        MINIO_REGION="us-east-1"; MINIO_ACCESS_KEY=""; MINIO_SECRET_KEY=""; ALLOWED_BUCKETS=""
    fi

    echo ""
    log_info "=== Database & antrian job harvester (PostGIS + Redis khusus queue) ==="
    echo "State PERSISTEN pertama di stack ini — siapkan backup (pg_dump terjadwal) terpisah setelah deploy."
    local POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB REDIS_QUEUE_PASSWORD REDIS_QUEUE_MAXMEMORY HARVEST_SCAN_INTERVAL_MS
    POSTGRES_USER=$(ask "POSTGRES_USER" "harvester")
    POSTGRES_DB=$(ask "POSTGRES_DB" "harvester")
    POSTGRES_PASSWORD="$(gen_password)"
    REDIS_QUEUE_PASSWORD="$(gen_password)"
    REDIS_QUEUE_MAXMEMORY=$(ask "Batas RAM redis-queue" "256mb")
    HARVEST_SCAN_INTERVAL_MS=$(ask "Interval scan simpul due di-harvest (ms)" "3600000")
    log_ok "POSTGRES_PASSWORD & REDIS_QUEUE_PASSWORD digenerate otomatis."

    echo ""
    log_info "=== Cache tile (Redis, disposable) ==="
    local REDIS_MAXMEMORY REDIS_PASSWORD
    REDIS_MAXMEMORY=$(ask "Batas RAM cache Redis" "512mb")
    REDIS_PASSWORD="$(gen_password)"
    log_ok "REDIS_PASSWORD digenerate otomatis."

    echo ""
    log_info "=== Ringkasan ==="
    echo "GHCR                  : $GHCR_OWNER (versi: $RELEASE_VERSION)"
    echo "Domain/origin         : $DOMAIN ($NEXT_PUBLIC_APP_ORIGIN)"
    if [[ "$BEHIND_WAF" == "true" ]]; then
        echo "TLS                   : ditangani WAF / tanpa TLS (BEHIND_WAF=true)"
    elif [[ "$TLS_MODE" == "custom" ]]; then
        echo "TLS                   : sertifikat kustom"
    else
        echo "TLS                   : Let's Encrypt otomatis ($ACME_EMAIL)"
    fi
    echo "Jumlah replica app    : $APP_REPLICAS"
    echo "Port publik           : HTTP=$HTTP_PORT HTTPS=$HTTPS_PORT"
    if [[ "$EXPOSE_PORTS" == "true" ]]; then
        echo "Port debug (exposed)  : postgres=$POSTGRES_HOST_PORT redis=$REDIS_HOST_PORT redis-queue=$REDIS_QUEUE_HOST_PORT harvester=$HARVESTER_HOST_PORT mapproxy=$MAPPROXY_HOST_PORT app=${APP_DIRECT_PORT:-(tidak)}"
    else
        echo "Port debug (exposed)  : (tidak ada, default aman)"
    fi
    echo "PostGIS               : user=$POSTGRES_USER db=$POSTGRES_DB (password digenerate)"
    echo "MinIO                 : ${MINIO_ENDPOINT:-(tidak dipakai)}"
    echo ""
    if ! confirm "Simpan konfigurasi ini ke .env?"; then
        log_warn "Dibatalkan — .env TIDAK ditulis. Jalankan ./install.sh lagi untuk mengulang."
        return 1
    fi

    if [[ "$TLS_MODE" == "custom" ]]; then
        install_custom_cert "$DOMAIN" "$CUSTOM_CERT_PATH" "$CUSTOM_KEY_PATH" "$CUSTOM_CHAIN_PATH" || return 1
    fi

    cat > "$ENV_FILE" <<EOF
# Dibuat otomatis oleh install.sh pada $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Aman diedit manual kapan pun — installer tidak menimpa file ini kecuali
# kamu pilih "timpa" saat menjalankan install.sh lagi.
#
# CATATAN: NEXT_PUBLIC_* (origin bundle JS, basemap, sumber data) TIDAK ada
# di sini — sudah di-bake saat build di GitHub Actions (repo source, repo
# Variables). Lihat README.md.

# === Registry (GHCR) ===
GHCR_OWNER=$GHCR_OWNER
GHCR_USERNAME=$GHCR_USERNAME
GHCR_TOKEN=$GHCR_TOKEN
RELEASE_VERSION=$RELEASE_VERSION

# === Konfigurasi backend geoportal (server-side only) ===
API_ACCESS_TOKEN=$API_ACCESS_TOKEN
NEXT_PUBLIC_APP_ORIGIN=$NEXT_PUBLIC_APP_ORIGIN

# === PostGIS + Redis khusus antrian job (backend harvester CSW) ===
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
REDIS_QUEUE_PASSWORD=$REDIS_QUEUE_PASSWORD
REDIS_QUEUE_MAXMEMORY=$REDIS_QUEUE_MAXMEMORY
HARVEST_SCAN_INTERVAL_MS=$HARVEST_SCAN_INTERVAL_MS

# === Object storage untuk preview dokumen harvest (opsional) ===
MINIO_ENDPOINT=$MINIO_ENDPOINT
MINIO_REGION=$MINIO_REGION
MINIO_ACCESS_KEY=$MINIO_ACCESS_KEY
MINIO_SECRET_KEY=$MINIO_SECRET_KEY
ALLOWED_BUCKETS=$ALLOWED_BUCKETS

# === Docker Compose / nginx (+ certbot kalau tidak di belakang WAF) ===
DOMAIN=$DOMAIN
BEHIND_WAF=$BEHIND_WAF
WAF_TRUSTED_CIDR=$WAF_TRUSTED_CIDR
TLS_MODE=$TLS_MODE
ACME_EMAIL=$ACME_EMAIL
APP_REPLICAS=$APP_REPLICAS

# === Port ===
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT
POSTGRES_HOST_PORT=$POSTGRES_HOST_PORT
REDIS_HOST_PORT=$REDIS_HOST_PORT
REDIS_QUEUE_HOST_PORT=$REDIS_QUEUE_HOST_PORT
HARVESTER_HOST_PORT=$HARVESTER_HOST_PORT
MAPPROXY_HOST_PORT=$MAPPROXY_HOST_PORT
APP_DIRECT_PORT=$APP_DIRECT_PORT
COMPOSE_FILE=$COMPOSE_FILE_VAL

# === Cache tile (Redis, disposable) ===
REDIS_MAXMEMORY=$REDIS_MAXMEMORY
REDIS_PASSWORD=$REDIS_PASSWORD
EOF
    chmod 600 "$ENV_FILE"
    log_ok ".env dibuat (permission 600)."
}

# ── 3. Direktori yang dibutuhkan compose ────────────────────────────────────
prepare_dirs() {
    mkdir -p "$SCRIPT_DIR/certbot/conf" "$SCRIPT_DIR/certbot/www" \
             "$SCRIPT_DIR/mapproxy" "$SCRIPT_DIR/nginx/conf.d"
    log_ok "Direktori certbot/, mapproxy/, nginx/conf.d/ siap."
    if [[ ! -f "$SCRIPT_DIR/mapproxy/mapproxy.yaml" ]]; then
        log_warn "mapproxy/mapproxy.yaml belum ada — service mapproxy tidak akan bisa start sampai file ini disalin manual dari hasil sync di repo source. Lihat README.md."
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
print_banner

check_or_install_docker || exit 1

if [[ -f "$ENV_FILE" ]]; then
    log_warn ".env sudah ada."
    if confirm "Timpa dengan wizard baru? (pilih 'n' untuk pakai .env yang sudah ada apa adanya)"; then
        run_wizard
    else
        log_info "Memakai .env yang sudah ada tanpa perubahan."
    fi
else
    run_wizard
fi

prepare_dirs

echo ""
log_ok "Setup awal selesai."
echo ""
if confirm "Lanjut ke menu deploy sekarang (./deploy.sh)?"; then
    exec "$SCRIPT_DIR/deploy.sh"
else
    log_info "Jalankan './deploy.sh' kapan pun siap untuk pull & deploy."
fi
