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
    echo "Image app & harvester dibangun & di-tag GitHub Actions di repo source,"
    echo "installer ini cuma pull/load, tidak build apa pun."
    local GHCR_OWNER GHCR_REPO RELEASE_VERSION
    RELEASE_VERSION=$(ask_required "RELEASE_VERSION (tag rilis, mis. v0.1.0 — atau 'latest', tidak reproducible)")
    echo ""
    echo "Owner & nama repo GitHub source (HARUS SAMA PERSIS — kalau salah, docker"
    echo "compose tidak akan pernah menemukan image yang benar, baik lewat pull"
    echo "maupun setelah load bundle). Cek dengan 'git remote -v' di repo source"
    echo "kalau tidak yakin nama repo persisnya."
    GHCR_OWNER=$(ask_required "GHCR_OWNER (owner GitHub, mis. hariHK1)")
    GHCR_REPO=$(ask_required "GHCR_REPO (nama repo GitHub source, mis. inageo-kjig)")
    # Docker/GHCR MEWAJIBKAN nama image lowercase (workflow release.yml di repo
    # source sudah lowercase-kan github.repository sebelum bikin tag image) —
    # normalisasi di sini juga, supaya username GitHub asli yang mengandung
    # huruf besar (mis. "hariHK1") tidak bikin `docker pull`/`up` gagal dengan
    # error "invalid reference format".
    GHCR_OWNER=$(echo "$GHCR_OWNER" | tr '[:upper:]' '[:lower:]')
    GHCR_REPO=$(echo "$GHCR_REPO" | tr '[:upper:]' '[:lower:]')
    echo ""
    echo "Server ini nanti ambil image dengan cara: docker pull langsung dari"
    echo "ghcr.io (butuh akses internet dari server ke ghcr.io), ATAU load dari"
    echo "bundle tar.gz Release yang kamu download manual & transfer sendiri"
    echo "(cocok untuk server di jaringan internal tanpa akses ghcr.io)."
    echo ""
    echo "CATATAN: username/token GHCR SENGAJA TIDAK ditanyakan/disimpan di sini —"
    echo "kredensial itu cuma dipakai sesaat untuk 'docker login' (tidak pernah"
    echo "dibaca container yang jalan), jadi deploy.sh akan menanyakannya"
    echo "interaktif tiap kali menu Pull/Deploy dipakai (input token disembunyikan"
    echo "saat diketik), supaya tidak nongkrong di file yang bisa dibaca dev lain"
    echo "yang share akses server ini."
    local PULL_MODE
    if confirm "Server ini punya akses internet ke ghcr.io (mode pull langsung)?"; then
        PULL_MODE="true"
    else
        PULL_MODE="false"
        log_info "Mode bundle dipilih — pakai menu \"Load image dari bundle\" di deploy.sh setelah setup ini selesai. Download tar.gz dari halaman Release repo source, transfer ke server ini, baru load."
    fi

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
            # docker-compose.app-port.yml TERPISAH dari docker-compose.ports.yml
            # (lihat komentar di file itu) — cuma dimasukkan ke COMPOSE_FILE
            # kalau APP_DIRECT_PORT betul-betul diisi, supaya tidak ada
            # fallback default port yang diam-diam tetap ter-publish saat kosong.
            if [[ -n "$APP_DIRECT_PORT" ]]; then
                COMPOSE_FILE_VAL="$COMPOSE_FILE_VAL:docker-compose.app-port.yml"
            fi
        fi
    fi

    echo ""
    log_info "=== Backend geoportal (server-side only) ==="
    local API_ACCESS_TOKEN APP_ORIGIN DASHBOARD_SESSION_SECRET
    API_ACCESS_TOKEN="$(gen_password)"
    log_ok "API_ACCESS_TOKEN digenerate otomatis (dipakai bersama app & harvester)."
    DASHBOARD_SESSION_SECRET="$(gen_password)"
    log_ok "DASHBOARD_SESSION_SECRET digenerate otomatis (cookie sesi dashboard admin /admin — WAJIB ada, container app tidak akan start tanpa ini)."
    if [[ "$BEHIND_WAF" == "true" && "$TLS_MODE" == "" && -z "$WAF_TRUSTED_CIDR" ]]; then
        # Kemungkinan besar internal/dev tanpa TLS sama sekali — tawarkan http://.
        if confirm "Origin publik pakai http:// (bukan https://)? Jawab 'y' kalau server ini benar-benar tanpa TLS (internal/dev)."; then
            APP_ORIGIN="http://$DOMAIN"
        else
            APP_ORIGIN="https://$DOMAIN"
        fi
    else
        APP_ORIGIN="https://$DOMAIN"
    fi
    echo "APP_ORIGIN di-set ke: $APP_ORIGIN (dipakai cek CORS WMS + dibaca browser — sepenuhnya runtime, bisa diedit lagi kapan pun di .env tanpa rilis baru)."

    echo ""
    log_info "=== Dashboard admin (/admin) ==="
    echo "Akun login TIDAK dibuat di sini — setelah deploy selesai (menu 2 di"
    echo "deploy.sh), jalankan sekali:"
    echo "  docker compose run --rm -e INITIAL_ADMIN_USERNAME=<user> -e INITIAL_ADMIN_PASSWORD=<pass> harvester node dist/scripts/seed-admin-user.js"
    local RECAPTCHA_SITE_KEY RECAPTCHA_SECRET_KEY
    if confirm "Aktifkan reCAPTCHA di form login dashboard admin? (opsional — butuh site key + secret key dari google.com/recaptcha/admin, pilih reCAPTCHA v2 Checkbox, domain harus sama persis dengan DOMAIN di atas)"; then
        RECAPTCHA_SITE_KEY=$(ask_required "RECAPTCHA_SITE_KEY")
        RECAPTCHA_SECRET_KEY=$(ask_required "RECAPTCHA_SECRET_KEY")
    else
        RECAPTCHA_SITE_KEY=""
        RECAPTCHA_SECRET_KEY=""
        log_info "reCAPTCHA dilewati — login /admin tanpa CAPTCHA. Bisa diaktifkan kapan pun nanti dengan isi RECAPTCHA_SITE_KEY/RECAPTCHA_SECRET_KEY di .env + restart container app, tanpa rilis baru."
    fi

    echo ""
    log_info "=== Sumber data & basemap (runtime — bisa diedit lagi kapan pun di .env) ==="
    local DATA_SOURCE
    if confirm "Pakai backend harvester (PostGIS terjadwal, direkomendasikan)? 'n' = baca public/sample-csw.json bawaan image"; then
        DATA_SOURCE="backend"
    else
        DATA_SOURCE="sample"
    fi
    echo ""
    echo "Basemap kustom (opsional) — kosongkan SEMUA untuk pakai default publik"
    echo "(RBI dari BIG, citra dari ArcGIS Online)."
    local RBI_URL GRAY_URL GRAY_URL_ATTR SATELLITE_URL SATELLITE_URL_ATTR TOPO_URL TOPO_URL_ATTR
    RBI_URL=$(ask "URL basemap RBI — Rupa Bumi Indonesia, peta garis dasar dari BIG" "")
    GRAY_URL=$(ask "URL basemap abu-abu (latar netral minim warna)" "")
    GRAY_URL_ATTR=$(ask "Teks atribusi/sumber basemap abu-abu" "")
    SATELLITE_URL=$(ask "URL basemap citra satelit" "")
    SATELLITE_URL_ATTR=$(ask "Teks atribusi/sumber basemap satelit" "")
    TOPO_URL=$(ask "URL basemap topografi" "")
    TOPO_URL_ATTR=$(ask "Teks atribusi/sumber basemap topografi" "")

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
    log_info "=== Elasticsearch (fitur \"Cari Data\" — katalog + isi-data) ==="
    echo "State PERSISTEN, sama seperti Postgres — siapkan backup (snapshot ES) terpisah setelah deploy."
    local ELASTIC_PASSWORD
    ELASTIC_PASSWORD="$(gen_password)"
    log_ok "ELASTIC_PASSWORD digenerate otomatis."

    echo ""
    log_info "=== Cache tile (Redis, disposable) ==="
    local REDIS_MAXMEMORY REDIS_PASSWORD
    REDIS_MAXMEMORY=$(ask "Batas RAM cache Redis" "512mb")
    REDIS_PASSWORD="$(gen_password)"
    log_ok "REDIS_PASSWORD digenerate otomatis."

    echo ""
    log_info "=== Ringkasan ==="
    echo "GHCR                  : $GHCR_OWNER/$GHCR_REPO (versi: $RELEASE_VERSION)"
    echo "Cara ambil image      : $([ "$PULL_MODE" = "true" ] && echo "pull langsung dari ghcr.io" || echo "load dari bundle tar.gz")"
    echo "Domain/origin         : $DOMAIN ($APP_ORIGIN)"
    if [[ "$BEHIND_WAF" == "true" ]]; then
        echo "TLS                   : ditangani WAF / tanpa TLS (BEHIND_WAF=true)"
    elif [[ "$TLS_MODE" == "custom" ]]; then
        echo "TLS                   : sertifikat kustom"
    else
        echo "TLS                   : Let's Encrypt otomatis ($ACME_EMAIL)"
    fi
    echo "Jumlah replica app    : $APP_REPLICAS"
    echo "reCAPTCHA login admin : $([ -n "$RECAPTCHA_SITE_KEY" ] && echo "aktif" || echo "tidak aktif")"
    echo "Port publik           : HTTP=$HTTP_PORT HTTPS=$HTTPS_PORT"
    if [[ "$EXPOSE_PORTS" == "true" ]]; then
        echo "Port debug (exposed)  : postgres=$POSTGRES_HOST_PORT redis=$REDIS_HOST_PORT redis-queue=$REDIS_QUEUE_HOST_PORT harvester=$HARVESTER_HOST_PORT mapproxy=$MAPPROXY_HOST_PORT app=${APP_DIRECT_PORT:-(tidak)}"
    else
        echo "Port debug (exposed)  : (tidak ada, default aman)"
    fi
    echo "Sumber data harvest   : $DATA_SOURCE"
    echo "Basemap kustom        : ${RBI_URL:+RBI }${GRAY_URL:+abu-abu }${SATELLITE_URL:+satelit }${TOPO_URL:+topo }"
    echo "  (kosong semua = pakai default publik RBI BIG/ArcGIS Online)"
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
# Config publik app (APP_ORIGIN/DATA_SOURCE/basemap) SEPENUHNYA runtime —
# edit di sini kapan pun, lalu 'docker compose up -d app' cukup (TIDAK perlu
# pull/rilis baru). Lihat README.md.

# === Registry (GHCR) — username/token GHCR SENGAJA TIDAK di sini,
# deploy.sh menanyakannya interaktif tiap dibutuhkan (lihat README.md) ===
GHCR_OWNER=$GHCR_OWNER
GHCR_REPO=$GHCR_REPO
RELEASE_VERSION=$RELEASE_VERSION
# true = server ini pull langsung dari ghcr.io; false = selalu pakai menu
# "Load image dari bundle" (deploy.sh tidak akan mencoba pull otomatis).
PULL_MODE=$PULL_MODE

# === Konfigurasi backend geoportal (server-side only) ===
API_ACCESS_TOKEN=$API_ACCESS_TOKEN
# Guard proxy /apis/[...path] (POST/DELETE) — endpoint itu tidak dipakai UI
# aplikasi ini sendiri, kosong = method itu selalu ditolak (gagal-tertutup).
# Isi manual hanya kalau memang butuh memicunya dari sistem lain.
ADMIN_API_TOKEN=
# Cookie sesi dashboard admin /admin — WAJIB ada, jangan dikosongkan manual.
DASHBOARD_SESSION_SECRET=$DASHBOARD_SESSION_SECRET
# reCAPTCHA login /admin/login — opsional, dua-duanya kosong = mati.
RECAPTCHA_SITE_KEY=$RECAPTCHA_SITE_KEY
RECAPTCHA_SECRET_KEY=$RECAPTCHA_SECRET_KEY

# === Config publik app (runtime, lihat catatan di atas) ===
APP_ORIGIN=$APP_ORIGIN
DATA_SOURCE=$DATA_SOURCE
REACT_APP=production
RBI_URL=$RBI_URL
GRAY_URL=$GRAY_URL
GRAY_URL_ATTR=$GRAY_URL_ATTR
SATELLITE_URL=$SATELLITE_URL
SATELLITE_URL_ATTR=$SATELLITE_URL_ATTR
TOPO_URL=$TOPO_URL
TOPO_URL_ATTR=$TOPO_URL_ATTR

# === PostGIS + Redis khusus antrian job (backend harvester CSW) ===
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
REDIS_QUEUE_PASSWORD=$REDIS_QUEUE_PASSWORD
REDIS_QUEUE_MAXMEMORY=$REDIS_QUEUE_MAXMEMORY
HARVEST_SCAN_INTERVAL_MS=$HARVEST_SCAN_INTERVAL_MS

# === Elasticsearch (fitur "Cari Data" — katalog + isi-data) ===
ELASTIC_PASSWORD=$ELASTIC_PASSWORD

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

# ── 4. Validasi .env yang sudah ada ─────────────────────────────────────────
# Var WAJIB (stack tidak akan jalan benar tanpa ini) — dicek kalau .env sudah
# ada, supaya rilis baru yang menambah var wajib baru (mis.
# DASHBOARD_SESSION_SECRET di v0.2.0, ELASTIC_PASSWORD di v0.2.3) tidak
# diam-diam bikin instalasi LAMA gagal begitu di-deploy (app crash-loop tanpa
# penjelasan).
#
# Daftar ini DIDERIVASI OTOMATIS dari .env.example (baris "KEY=... # @wajib"
# / "# @opsional"), BUKAN hardcode di sini — dulu ada DUA tempat yang harus
# disinkron manual tiap kali ada var baru (isi .env.example DAN array ini),
# gampang lupa salah satu (nyata terjadi beberapa kali). Sekarang cukup tandai
# baris di .env.example, array ini otomatis ikut. deploy.sh's check_env()
# masih terpisah (pesan errornya spesifik per-var, tidak mekanis) — dua lapis
# validasi, bukan duplikat sia-sia (installer ini yang pertama kali
# dijalankan, deploy.sh yang terakhir sebelum stack benar-benar naik).
ENV_EXAMPLE_FILE="$SCRIPT_DIR/.env.example"
mapfile -t REQUIRED_ENV_VARS < <(
    grep -E '^[A-Z_][A-Z0-9_]*=.*#[[:space:]]*@wajib' "$ENV_EXAMPLE_FILE" |
        sed -E 's/^([A-Z_][A-Z0-9_]*)=.*/\1/'
)
mapfile -t OPTIONAL_ENV_VARS < <(
    grep -E '^[A-Z_][A-Z0-9_]*=.*#[[:space:]]*@opsional' "$ENV_EXAMPLE_FILE" |
        sed -E 's/^([A-Z_][A-Z0-9_]*)=.*/\1/'
)

# Baris "KEY=<isi tidak kosong>" ada di .env — BUKAN `source .env` (sengaja
# aman dari isi .env yang aneh-aneh/hand-edited, mirror gaya load_env_file di
# deploy.sh), cuma cek keberadaan+isi, tidak memuat nilainya ke shell. Dipakai
# untuk var WAJIB — kosong sama parahnya dengan tidak ada sama sekali.
env_var_present() {
    grep -qE "^$1=.+" "$ENV_FILE" 2>/dev/null
}

# Baris "KEY=" ada di .env APA PUN isinya (termasuk kosong) — dipakai untuk
# var OPSIONAL, karena baris kosong berarti sudah pernah diputuskan
# ("fiturnya sengaja dimatikan"), BUKAN "belum ditangani sama sekali". Kalau
# pakai env_var_present di sini, ADMIN_API_TOKEN= yang sengaja dikosongkan
# wizard akan terus-menerus dilaporkan "kurang" walau sudah benar apa adanya.
env_key_exists() {
    grep -qE "^$1=" "$ENV_FILE" 2>/dev/null
}

# Set (replace in-place kalau baris sudah ada apa pun isinya) atau tambah
# (append kalau baris benar-benar belum pernah ada) satu var — mirror pola
# ensure_secret() di deploy.sh, supaya re-run patch_missing_env tidak pernah
# bikin baris duplikat untuk key yang sama.
set_env_var() {
    local var_name="$1" value="$2"
    if env_key_exists "$var_name"; then
        sed -i "s#^${var_name}=.*#${var_name}=${value}#" "$ENV_FILE"
    else
        echo "${var_name}=${value}" >> "$ENV_FILE"
    fi
}

# Mengembalikan 0 (lewat validasi) kalau semua var wajib+opsional-baru sudah
# ada; 1 kalau ada yang kurang (sudah dicetak daftarnya duluan).
validate_existing_env() {
    local missing_required=() missing_optional=()
    for var in "${REQUIRED_ENV_VARS[@]}"; do
        env_var_present "$var" || missing_required+=("$var")
    done
    for var in "${OPTIONAL_ENV_VARS[@]}"; do
        env_key_exists "$var" || missing_optional+=("$var")
    done

    if [[ ${#missing_required[@]} -eq 0 && ${#missing_optional[@]} -eq 0 ]]; then
        log_ok ".env sudah lengkap — semua variabel yang dikenal installer ini sudah ada."
        return 0
    fi

    echo ""
    if [[ ${#missing_required[@]} -gt 0 ]]; then
        log_warn "Variabel WAJIB belum ada/kosong di .env (biasanya karena rilis versi baru menambah var baru):"
        for var in "${missing_required[@]}"; do
            echo "    - $var"
        done
    fi
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        log_info "Variabel opsional belum ada (fitur terkait tetap NONAKTIF, tidak memblokir apa pun):"
        for var in "${missing_optional[@]}"; do
            echo "    - $var"
        done
    fi
    echo ""
    return 1
}

# Nambah HANYA var yang kurang, append-only — baris yang SUDAH ADA di .env
# TIDAK disentuh sama sekali (beda dari run_wizard yang timpa seluruh file).
patch_missing_env() {
    echo ""
    log_info "Menambahkan variabel yang kurang ke .env — baris lain TIDAK diubah..."

    local var
    # Secret — auto-generate tanpa tanya, mirror ensure_secret() di deploy.sh.
    for var in API_ACCESS_TOKEN DASHBOARD_SESSION_SECRET POSTGRES_PASSWORD REDIS_QUEUE_PASSWORD REDIS_PASSWORD; do
        if ! env_var_present "$var"; then
            set_env_var "$var" "$(gen_password)"
            log_ok "$var digenerate otomatis."
        fi
    done

    # Identitas/config — tidak bisa ditebak, WAJIB tanya.
    if ! env_var_present GHCR_OWNER; then
        set_env_var GHCR_OWNER "$(ask_required "GHCR_OWNER (owner GitHub, mis. hariHK1)" | tr '[:upper:]' '[:lower:]')"
    fi
    if ! env_var_present GHCR_REPO; then
        set_env_var GHCR_REPO "$(ask_required "GHCR_REPO (nama repo GitHub source)" | tr '[:upper:]' '[:lower:]')"
    fi
    if ! env_var_present RELEASE_VERSION; then
        set_env_var RELEASE_VERSION "$(ask_required "RELEASE_VERSION (mis. v0.2.0-dev)")"
    fi
    if ! env_var_present DOMAIN; then
        set_env_var DOMAIN "$(ask_required "DOMAIN (hostname/IP server ini)")"
    fi

    # Opsional (fitur toggle) — tanya mau isi atau lewati, TIDAK auto-generate
    # (kosong itu valid & aman, bukan kondisi darurat seperti secret di atas).
    # env_key_exists (bukan env_var_present) — baris kosong yang SUDAH ADA
    # tidak boleh ditimpa ulang tiap kali installer ini dijalankan lagi.
    if ! env_key_exists ADMIN_API_TOKEN; then
        set_env_var ADMIN_API_TOKEN ""
    fi
    if ! env_key_exists RECAPTCHA_SITE_KEY || ! env_key_exists RECAPTCHA_SECRET_KEY; then
        if confirm "Aktifkan reCAPTCHA di form login dashboard admin? (opsional)"; then
            env_key_exists RECAPTCHA_SITE_KEY || set_env_var RECAPTCHA_SITE_KEY "$(ask_required "RECAPTCHA_SITE_KEY")"
            env_key_exists RECAPTCHA_SECRET_KEY || set_env_var RECAPTCHA_SECRET_KEY "$(ask_required "RECAPTCHA_SECRET_KEY")"
        else
            env_key_exists RECAPTCHA_SITE_KEY || set_env_var RECAPTCHA_SITE_KEY ""
            env_key_exists RECAPTCHA_SECRET_KEY || set_env_var RECAPTCHA_SECRET_KEY ""
        fi
    fi

    echo ""
    log_ok "Selesai — .env diperbarui. Jalankan './deploy.sh' untuk menerapkan (container yang sudah jalan perlu di-recreate supaya membaca nilai baru)."
}

# ── Main ─────────────────────────────────────────────────────────────────────
print_banner

check_or_install_docker || exit 1

if [[ -f "$ENV_FILE" ]]; then
    log_info ".env sudah ada — memvalidasi kelengkapannya dulu (bukan langsung tanya timpa atau tidak)..."
    if validate_existing_env; then
        if confirm "Semua variabel yang dikenal sudah lengkap. Tetap jalankan wizard dari awal? (menimpa SEMUA nilai yang ada)"; then
            run_wizard
        else
            log_info "Memakai .env yang sudah ada tanpa perubahan."
        fi
    else
        echo "Pilihan:"
        echo "  1) Tambahkan HANYA variabel yang kurang (nilai lain di .env TIDAK disentuh) [rekomendasi]"
        echo "  2) Jalankan wizard penuh (SEMUA nilai ditimpa ulang dari awal)"
        echo "  3) Batal — saya urus manual"
        read -rp "Pilih [1/2/3]: " choice
        case "$choice" in
            1) patch_missing_env ;;
            2) run_wizard ;;
            *) log_info "Tidak ada perubahan pada .env." ;;
        esac
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
