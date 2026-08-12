#!/usr/bin/env bash
# Menu interaktif untuk deployment inageo-mapviewer via Docker Compose — mode
# PULL (image dari GHCR, dibangun GitHub Actions di repo source, repo ini
# tidak build apa pun). Belum pernah setup di server ini? Jalankan
# ./install.sh dulu.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
CERTBOT_DIR="$SCRIPT_DIR/certbot"
NGINX_CONF_DIR="$SCRIPT_DIR/nginx/conf.d"
NGINX_CONF="$NGINX_CONF_DIR/default.conf"
NGINX_CONF_EXAMPLE="$NGINX_CONF_DIR/default.conf.example"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

confirm() {
    read -rp "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

load_env_file() {
    local file="$1" key value
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # Lucuti tanda kutip pembungkus (KEY="val" atau KEY='val') kalau ada —
        # loader ini SENGAJA bukan shell-parser penuh (supaya aman dari
        # injection lewat .env), jadi kutip tidak otomatis hilang seperti
        # `source` biasa. Tanpa ini, nilai seperti RELEASE_VERSION="v0.1.0"
        # ikut kebawa literal ke docker-compose.yml dan bikin tag image
        # invalid (mis. ghcr.io/x/y-app:"v0.1.0" — perhatikan kutipnya).
        if [[ "$value" =~ ^\"(.*)\"$ ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        export "$key=$value"
    done < "$file"
}

# ── Prasyarat ─────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker tidak ditemukan. Jalankan ./install.sh dulu."
    exit 1
fi

if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    log_error "Docker Compose tidak ditemukan."
    exit 1
fi

# ── Validasi .env ─────────────────────────────────────────────────────────
check_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        log_warn ".env belum ada."
        if confirm "Salin dari .env.example sekarang?"; then
            cp "$ENV_EXAMPLE" "$ENV_FILE"
            log_ok ".env dibuat dari .env.example. Isi nilainya dulu, atau jalankan ./install.sh untuk wizard interaktif."
        fi
        return 1
    fi

    load_env_file "$ENV_FILE"

    local missing=0
    # GHCR_OWNER/GHCR_REPO WAJIB di kedua mode (pull ATAU bundle) — dua-duanya
    # dipakai membentuk string image di docker-compose.yml
    # (ghcr.io/$GHCR_OWNER/$GHCR_REPO-app:$RELEASE_VERSION). Di mode bundle,
    # `docker load` memuat image dengan tag PERSIS seperti yang dipakai CI
    # (dari nama repo GitHub yang sebenarnya) — kalau dua var ini di .env
    # tidak sama persis dengan itu, compose tidak akan menemukan image yang
    # sudah dimuat sama sekali, walau tidak butuh pull.
    if [[ -z "${GHCR_OWNER:-}" || -z "${GHCR_REPO:-}" ]]; then
        log_error "GHCR_OWNER/GHCR_REPO kosong di .env — wajib diisi (harus sama persis dengan owner/nama repo GitHub source), dipakai membentuk nama image walau di mode bundle sekalipun."
        missing=1
    else
        # Docker/GHCR mewajibkan nama image lowercase — normalisasi di sini
        # juga (bukan cuma install.sh) supaya .env yang diedit manual/dibuat
        # sebelum fix ini tetap aman dipakai.
        GHCR_OWNER="$(echo "$GHCR_OWNER" | tr '[:upper:]' '[:lower:]')"
        GHCR_REPO="$(echo "$GHCR_REPO" | tr '[:upper:]' '[:lower:]')"
        export GHCR_OWNER GHCR_REPO
    fi
    # GHCR_USERNAME/GHCR_TOKEN SENGAJA TIDAK PERNAH ada di .env (lihat
    # install.sh) — cuma dipakai sesaat untuk `docker login`, tidak pernah
    # dibaca container yang jalan, jadi ditanyakan interaktif langsung di
    # action_pull tiap kali dibutuhkan. Supaya tidak nongkrong di file yang
    # bisa dibaca dev lain yang share akses server ini.
    if [[ -z "${RELEASE_VERSION:-}" ]]; then
        log_error "RELEASE_VERSION kosong di .env — wajib diisi (mis. v0.1.0, atau 'latest')."
        missing=1
    fi
    if [[ -z "${DOMAIN:-}" ]]; then
        log_error "DOMAIN kosong di .env — wajib diisi untuk server_name nginx (boleh IP internal)."
        missing=1
    elif [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]; then
        log_error "DOMAIN='${DOMAIN}' bukan format hostname/IP yang valid."
        missing=1
    fi
    if [[ "${BEHIND_WAF:-false}" != "true" && "${TLS_MODE:-letsencrypt}" == "letsencrypt" && -z "${ACME_EMAIL:-}" ]]; then
        log_error "ACME_EMAIL kosong — wajib untuk Let's Encrypt (atau set TLS_MODE=custom / BEHIND_WAF=true)."
        missing=1
    fi
    if [[ "${BEHIND_WAF:-false}" != "true" && "${TLS_MODE:-letsencrypt}" == "custom" && ! -f "$CERTBOT_DIR/conf/live/${DOMAIN:-_}/fullchain.pem" ]]; then
        log_error "TLS_MODE=custom tapi certbot/conf/live/${DOMAIN:-<DOMAIN>}/fullchain.pem tidak ditemukan."
        missing=1
    fi
    if [[ -n "${APP_REPLICAS:-}" && ! "${APP_REPLICAS}" =~ ^[0-9]+$ ]]; then
        log_error "APP_REPLICAS='${APP_REPLICAS}' bukan angka."
        missing=1
    fi

    # Tiga secret disamakan pola cek/generate-nya (mirror source repo).
    ensure_secret() {
        local var_name="$1" label="$2"
        local current="${!var_name:-}"
        if [[ -n "$current" ]]; then
            return 0
        fi
        log_warn "$var_name kosong — $label."
        if confirm "Generate password acak sekarang dan simpan ke .env?"; then
            local genpw
            genpw="$(openssl rand -base64 32 | tr -d '\n/+=')"
            if grep -q "^${var_name}=" "$ENV_FILE"; then
                sed -i "s#^${var_name}=.*#${var_name}=$genpw#" "$ENV_FILE"
            else
                echo "${var_name}=$genpw" >> "$ENV_FILE"
            fi
            export "$var_name=$genpw"
            log_ok "$var_name digenerate dan disimpan ke .env."
            return 0
        fi
        return 1
    }

    ensure_secret REDIS_PASSWORD "Redis cache tanpa password hanya dilindungi isolasi network" || missing=1
    ensure_secret POSTGRES_PASSWORD "PostGIS tanpa password tidak akan bisa start" || missing=1
    ensure_secret REDIS_QUEUE_PASSWORD "Redis queue tanpa password tidak akan bisa start" || missing=1
    ensure_secret ELASTIC_PASSWORD "Elasticsearch tanpa password tidak akan bisa start (fitur \"Cari Data\")" || missing=1
    ensure_secret API_ACCESS_TOKEN "tanpa ini SEMUA endpoint harvester menolak permintaan (gagal-tertutup) — app tidak akan bisa baca data harvest sama sekali" || missing=1
    ensure_secret DASHBOARD_SESSION_SECRET "tanpa ini container app GAGAL START total (dashboard admin /admin wajib butuh secret ini)" || missing=1
    ensure_secret GLITCHTIP_DB_PASSWORD "Postgres GlitchTip tanpa password tidak akan bisa start" || missing=1
    ensure_secret GLITCHTIP_VALKEY_PASSWORD "Valkey GlitchTip tanpa password tidak akan bisa start" || missing=1
    ensure_secret GLITCHTIP_SECRET_KEY "tanpa ini container GlitchTip GAGAL START total (Django wajib butuh secret key)" || missing=1

    if [[ $missing -eq 1 ]]; then
        return 1
    fi

    if [[ -z "${MINIO_ENDPOINT:-}" ]]; then
        log_info "MINIO_ENDPOINT kosong — preview dokumen via MinIO nonaktif (503, sudah di-handle app)."
    fi
    if [[ -n "${COMPOSE_FILE:-}" ]]; then
        log_warn "COMPOSE_FILE aktif ('$COMPOSE_FILE') — port infra/app langsung ke host TEREXPOSE. Pastikan ini memang disengaja (bukan server produksi publik)."
    fi

    log_ok "Validasi .env selesai."
    return 0
}

ensure_nginx_conf() {
    if [[ -f "$NGINX_CONF" ]]; then
        return 0
    fi

    local template="$NGINX_CONF_EXAMPLE"
    if [[ "${BEHIND_WAF:-false}" == "true" ]]; then
        template="$NGINX_CONF_DIR/default-waf.conf.example"
    fi

    sed "s/__DOMAIN__/$DOMAIN/g" "$template" > "$NGINX_CONF"

    if [[ "${BEHIND_WAF:-false}" == "true" ]]; then
        if [[ -n "${WAF_TRUSTED_CIDR:-}" ]]; then
            local realip_lines="" cidr_regex='^[0-9a-fA-F:.]+/[0-9]{1,3}$'
            IFS=',' read -ra cidrs <<< "$WAF_TRUSTED_CIDR"
            for cidr in "${cidrs[@]}"; do
                cidr="$(echo "$cidr" | xargs)"
                if [[ -z "$cidr" ]]; then
                    continue
                elif [[ ! "$cidr" =~ $cidr_regex ]]; then
                    log_warn "WAF_TRUSTED_CIDR: '$cidr' bukan format CIDR yang valid, dilewati."
                    continue
                fi
                realip_lines+="    set_real_ip_from $cidr;"$'\n'
            done
            if [[ -n "$realip_lines" ]]; then
                local realip_tmp
                realip_tmp="$(mktemp)"
                printf '%s' "$realip_lines" > "$realip_tmp"
                sed -i "/__REAL_IP_TRUST__/r $realip_tmp" "$NGINX_CONF"
                rm -f "$realip_tmp"
                log_ok "set_real_ip_from disisipkan untuk: $WAF_TRUSTED_CIDR"
            fi
        else
            log_warn "WAF_TRUSTED_CIDR kosong — rate-limiting nginx akan menganggap semua traffic sebagai satu IP (tetap aman, kurang presisi)."
        fi
        sed -i "/__REAL_IP_TRUST__/d" "$NGINX_CONF"
        log_ok "nginx/conf.d/default.conf dibuat (mode WAF/tanpa-TLS, HTTP-only) untuk $DOMAIN."
    else
        log_ok "nginx/conf.d/default.conf dibuat (TLS + certbot) untuk domain $DOMAIN."
    fi
}

# .env.infra-display (gitignored) - subset TER-FILTER dari .env, di-mount
# read-only ke harvester sbg /compose/.env (lihat docker-compose.yml) utk
# Skema Teknologi/Kesehatan Sistem dinamis (composeParser.ts baca ini +
# docker-compose.yml lain utk resolve ${VAR} di dalamnya). ALLOWLIST eksplisit
# (bukan .env penuh) - .env ASLI berisi secret sungguhan (DASHBOARD_SESSION_
# SECRET dkk, penandatangan cookie sesi admin APP Next.js) yang TIDAK BOLEH
# bocor ke harvester (proses/permukaan-serang berbeda; kompromi di harvester
# TIDAK BOLEH bisa memalsukan sesi admin app). Filter regex penolak
# (_PASSWORD/_SECRET/_TOKEN/_KEY di akhir nama) sbg lapis kedua - jaga-jaga
# ada var secret baru di masa depan yang lupa dikecualikan manual dari
# allowlist di bawah. SELALU ditulis ulang tiap dipanggil (bukan cuma kalau
# belum ada), sama pola dgn ensure_nginx_conf. WAJIB dipanggil sebelum
# `docker compose up` (bind-mount ke file yang belum ada bikin Docker diam-
# diam bikin DIREKTORI kosong).
ensure_infra_display_env() {
    local allowlist=(
        APP_CPU_LIMIT APP_MEMORY_LIMIT APP_CPU_RESERVATION APP_MEMORY_RESERVATION APP_REPLICAS
        HARVESTER_CPU_LIMIT HARVESTER_MEMORY_LIMIT HARVESTER_REPLICAS
        ELASTICSEARCH_CPU_LIMIT ELASTICSEARCH_MEMORY_LIMIT
        HTTP_PORT HTTPS_PORT POSTGRES_HOST_PORT REDIS_HOST_PORT REDIS_QUEUE_HOST_PORT
        HARVESTER_HOST_PORT MAPPROXY_HOST_PORT ELASTICSEARCH_HOST_PORT APP_DIRECT_PORT
        DOMAIN BEHIND_WAF COMPOSE_FILE
    )
    local out="$SCRIPT_DIR/.env.infra-display"
    : > "$out"
    local name value
    for name in "${allowlist[@]}"; do
        # Lapis kedua - tolak APA PUN yang cocok pola nama var secret, walau
        # sudah lolos allowlist di atas (jaga-jaga typo/kesalahan manual).
        if [[ "$name" =~ (_PASSWORD|_SECRET|_TOKEN|_KEY)$ ]]; then
            log_warn "ensure_infra_display_env: '$name' dilewati (cocok pola nama var secret, cek allowlist)."
            continue
        fi
        value="${!name:-}"
        [[ -n "$value" ]] && printf '%s=%s\n' "$name" "$value" >> "$out"
    done
    log_ok ".env.infra-display dibuat/diperbarui - dibaca harvester utk Skema Teknologi/Kesehatan Sistem dinamis."
}

# Bootstrap TLS chicken-and-egg — identik dengan source repo.
bootstrap_tls() {
    local live="$CERTBOT_DIR/conf/live/$DOMAIN"

    if [[ -f "$live/fullchain.pem" ]]; then
        log_ok "Sertifikat untuk $DOMAIN sudah ada — bootstrap TLS dilewati."
        return 0
    fi

    mkdir -p "$CERTBOT_DIR/conf" "$CERTBOT_DIR/www"

    log_info "1/5 Membuat sertifikat dummy sementara (supaya nginx bisa start)..."
    $COMPOSE_CMD run --rm --entrypoint sh certbot -c '
        d="$1"
        mkdir -p "/etc/letsencrypt/live/$d" &&
        openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
          -keyout "/etc/letsencrypt/live/$d/privkey.pem" \
          -out    "/etc/letsencrypt/live/$d/fullchain.pem" \
          -subj "/CN=localhost" &&
        cp "/etc/letsencrypt/live/$d/fullchain.pem" "/etc/letsencrypt/live/$d/chain.pem" &&
        chmod 600 "/etc/letsencrypt/live/$d/privkey.pem"' _ "$DOMAIN" \
        || { log_error "Gagal membuat sertifikat dummy."; return 1; }

    log_info "2/5 Menyalakan nginx..."
    $COMPOSE_CMD up -d nginx
    sleep 3

    log_info "3/5 Menghapus dummy sebelum meminta sertifikat asli..."
    $COMPOSE_CMD run --rm --entrypoint sh certbot -c '
        d="$1"
        rm -rf "/etc/letsencrypt/live/$d" \
               "/etc/letsencrypt/archive/$d" \
               "/etc/letsencrypt/renewal/$d.conf"' _ "$DOMAIN"

    log_info "4/5 Meminta sertifikat Let's Encrypt (webroot)..."
    local staging_arg=""
    if confirm "Pakai server STAGING dulu (disarankan untuk uji coba, tidak kena rate-limit)?"; then
        staging_arg="--staging"
    fi
    # shellcheck disable=SC2086
    $COMPOSE_CMD run --rm certbot certonly --webroot -w /var/www/certbot \
        $staging_arg --email "$ACME_EMAIL" -d "$DOMAIN" \
        --rsa-key-size 2048 --agree-tos --no-eff-email --non-interactive \
        || { log_error "Certbot gagal. Cek: DNS $DOMAIN sudah menunjuk ke IP server ini, port 80 terbuka, tidak ada web server lain di :80."; return 1; }

    log_info "5/5 Reload nginx supaya membaca sertifikat asli..."
    $COMPOSE_CMD exec nginx nginx -s reload
    log_ok "TLS aktif untuk https://$DOMAIN"
}

# ── Aksi ──────────────────────────────────────────────────────────────────
action_pull() {
    if [[ -z "${GHCR_OWNER:-}" || -z "${GHCR_REPO:-}" ]]; then
        log_error "GHCR_OWNER/GHCR_REPO kosong di .env — tidak bisa pull. Kalau server ini tidak punya akses ke ghcr.io, pakai menu \"Load image dari bundle\" (tar.gz dari GitHub Release) sebagai gantinya."
        return 1
    fi

    # GHCR_USERNAME/GHCR_TOKEN SENGAJA ditanyakan di sini, BUKAN dibaca dari
    # .env — kredensial ini cuma dipakai sesaat untuk login, tidak pernah
    # disimpan ke disk, jadi tidak nongkrong di file yang bisa dibaca dev lain
    # yang share akses server ini. Ditanya ulang tiap kali menu ini dipakai.
    local ghcr_username ghcr_token
    read -rp "GHCR_USERNAME (username GitHub untuk docker login): " ghcr_username
    if [[ -z "$ghcr_username" ]]; then
        log_error "GHCR_USERNAME tidak boleh kosong."
        return 1
    fi
    # -s: input tidak ditampilkan di terminal (mirip prompt password sudo).
    read -rsp "GHCR_TOKEN (PAT scope read:packages, tidak akan ditampilkan): " ghcr_token
    echo ""
    if [[ -z "$ghcr_token" ]]; then
        log_error "GHCR_TOKEN tidak boleh kosong."
        return 1
    fi

    log_info "Login ke ghcr.io sebagai $ghcr_username..."
    echo "$ghcr_token" | docker login ghcr.io -u "$ghcr_username" --password-stdin \
        || { log_error "Docker login gagal — cek username/token yang barusan diketik."; unset ghcr_token; return 1; }
    unset ghcr_token ghcr_username
    log_info "Pull image versi $RELEASE_VERSION..."
    $COMPOSE_CMD pull app harvester harvester-seed \
        || { log_error "Pull gagal — cek RELEASE_VERSION di .env memang sudah dirilis (lihat tab Releases repo source)."; return 1; }
    log_ok "Image ter-pull."
}

# Alternatif action_pull — untuk server TANPA akses ke ghcr.io sama sekali
# (mis. jaringan internal tertutup). Bundle (.tar.gz, berisi image app +
# harvester sekaligus) diambil dari asset GitHub Release (dibuat otomatis
# oleh .github/workflows/release.yml di repo source), didownload manual di
# mesin yang punya internet, ditransfer ke server ini (scp/rsync/USB/dsb).
# Setelah dimuat, `docker compose up -d` TIDAK akan mencoba pull ulang
# selama tag RELEASE_VERSION di .env sudah cocok dengan yang ada di image
# lokal — jadi urutan yang benar: load bundle DULU, baru isi/cocokkan
# RELEASE_VERSION di .env, baru "Deploy".
action_load_bundle() {
    read -rp "Path file bundle image (.tar.gz, hasil download dari GitHub Release): " bundle_path
    if [[ ! -f "$bundle_path" ]]; then
        log_error "File '$bundle_path' tidak ditemukan."
        return 1
    fi
    log_info "Memuat image dari $bundle_path (bisa beberapa menit tergantung ukuran)..."
    if [[ "$bundle_path" == *.gz ]]; then
        gunzip -c "$bundle_path" | docker load || { log_error "Gagal load image."; return 1; }
    else
        docker load -i "$bundle_path" || { log_error "Gagal load image."; return 1; }
    fi
    log_ok "Image dimuat. Pastikan RELEASE_VERSION di .env SAMA dengan tag bundle ini (lihat nama file/tag Release-nya), baru lanjut menu \"Deploy\" — image tidak akan di-pull ulang selama tag itu sudah ada lokal."
    docker images --filter "reference=ghcr.io/*"
}

action_deploy() {
    if [[ "${PULL_MODE:-true}" == "true" ]]; then
        action_pull || return 1
    else
        log_warn "PULL_MODE=false — melewati pull, asumsi image sudah dimuat lewat \"Load image dari bundle\". Kalau belum, batalkan dan jalankan menu itu dulu."
        confirm "Lanjut deploy dengan image yang sudah ada secara lokal?" || return 1
    fi
    ensure_nginx_conf
    ensure_infra_display_env
    if [[ "${BEHIND_WAF:-false}" == "true" ]]; then
        log_info "BEHIND_WAF=true — melewati bootstrap TLS/certbot."
    else
        bootstrap_tls || return 1
    fi
    log_info "Deploying (up -d)..."
    $COMPOSE_CMD up -d
    $COMPOSE_CMD ps
    # postgres tidak punya healthcheck (lihat docker-compose.yml) — jeda
    # singkat sebelum migrasi supaya tidak race dgn startup-nya. Kalau
    # tetap gagal (postgres lambat start di server ini), bukan fatal utk
    # deploy — app/harvester sudah naik, operator tinggal jalankan menu 14
    # manual setelah postgres benar-benar siap.
    sleep 3
    action_harvester_migrate || log_warn "Migrasi otomatis gagal — kemungkinan postgres belum siap. Jalankan manual lewat menu 14 setelah memastikan service 'postgres' sehat."
}

# Ganti versi (upgrade ATAU rollback — tinggal isi nomor lebih baru/lama).
# Cuma app+harvester yang di-recreate; postgres/redis/nginx/certbot tidak
# disentuh, supaya data & TLS tidak terganggu.
action_set_version() {
    local current="${RELEASE_VERSION:-(belum diset)}"
    log_info "Versi saat ini: $current"
    read -rp "Versi baru (mis. v0.2.0, atau versi lama untuk rollback): " new_version
    if [[ -z "$new_version" ]]; then
        log_warn "Dibatalkan — versi kosong."
        return 1
    fi
    if grep -q '^RELEASE_VERSION=' "$ENV_FILE"; then
        sed -i "s/^RELEASE_VERSION=.*/RELEASE_VERSION=$new_version/" "$ENV_FILE"
    else
        echo "RELEASE_VERSION=$new_version" >> "$ENV_FILE"
    fi
    export RELEASE_VERSION="$new_version"
    log_info "Pindah ke versi $new_version..."
    if [[ "${PULL_MODE:-true}" == "true" ]]; then
        action_pull || return 1
    else
        log_warn "PULL_MODE=false — pastikan sudah 'Load image dari bundle' untuk tag $new_version SEBELUM lanjut, kalau belum batalkan dulu."
        confirm "Image untuk versi $new_version sudah dimuat lokal, lanjutkan?" || return 1
    fi
    $COMPOSE_CMD up -d --no-deps --force-recreate app harvester
    $COMPOSE_CMD ps
    action_harvester_migrate || log_warn "Migrasi otomatis gagal — jalankan manual lewat menu 14."
    log_ok "Selesai — app & harvester sekarang di versi $new_version."
}

action_down() {
    $COMPOSE_CMD down
}

action_restart() {
    $COMPOSE_CMD restart
}

action_logs() {
    echo "1) app  2) nginx  3) certbot  4) mapproxy  5) redis  6) postgres  7) redis-queue  8) harvester  9) semua"
    read -rp "Pilih service log: " sel
    case "$sel" in
        1) $COMPOSE_CMD logs -f --tail=200 app ;;
        2) $COMPOSE_CMD logs -f --tail=200 nginx ;;
        3) $COMPOSE_CMD logs -f --tail=200 certbot ;;
        4) $COMPOSE_CMD logs -f --tail=200 mapproxy ;;
        5) $COMPOSE_CMD logs -f --tail=200 redis ;;
        6) $COMPOSE_CMD logs -f --tail=200 postgres ;;
        7) $COMPOSE_CMD logs -f --tail=200 redis-queue ;;
        8) $COMPOSE_CMD logs -f --tail=200 harvester ;;
        *) $COMPOSE_CMD logs -f --tail=200 ;;
    esac
}

action_status() {
    $COMPOSE_CMD ps
}

action_prune() {
    docker image prune -f
}

action_scale() {
    read -rp "Jumlah replica app [saat ini: ${APP_REPLICAS:-2}]: " n
    if [[ ! "$n" =~ ^[0-9]+$ || "$n" -lt 1 ]]; then
        log_error "Masukkan angka >= 1."
        return 1
    fi
    if [[ "$n" -gt 1 && -n "${APP_DIRECT_PORT:-}" ]]; then
        log_warn "APP_DIRECT_PORT masih diisi (${APP_DIRECT_PORT}) tapi replica > 1 — akses langsung bypass nginx TIDAK akan bisa start bersamaan. Kosongkan APP_DIRECT_PORT di .env dulu, atau tetap di 1 replica."
    fi
    if grep -q '^APP_REPLICAS=' "$ENV_FILE" 2>/dev/null; then
        sed -i "s/^APP_REPLICAS=.*/APP_REPLICAS=$n/" "$ENV_FILE"
    else
        echo "APP_REPLICAS=$n" >> "$ENV_FILE"
    fi
    log_info "Menerapkan APP_REPLICAS=$n..."
    $COMPOSE_CMD up -d app
    log_ok "Nginx akan otomatis menyesuaikan (resolver DNS, ≤10 detik) tanpa perlu direstart."
    $COMPOSE_CMD ps
}

# Sengaja terpisah dari action_scale (bukan digabung jadi satu fungsi generik)
# — worker BullMQ harvester TIDAK di belakang nginx (beda dari app), jadi
# tidak ada peringatan resolver DNS di sini, tapi ADA peringatan
# HARVESTER_HOST_PORT yang analog dgn APP_DIRECT_PORT.
action_scale_harvester() {
    read -rp "Jumlah replica harvester [saat ini: ${HARVESTER_REPLICAS:-1}]: " n
    if [[ ! "$n" =~ ^[0-9]+$ || "$n" -lt 1 ]]; then
        log_error "Masukkan angka >= 1."
        return 1
    fi
    if [[ "$n" -gt 1 && -n "${HARVESTER_HOST_PORT:-}" ]]; then
        log_warn "HARVESTER_HOST_PORT masih diisi (${HARVESTER_HOST_PORT}) tapi replica > 1 — semua replica akan rebutan 1 port host yang sama, replica ke-2 dst GAGAL START. Kosongkan HARVESTER_HOST_PORT di .env dulu (lihat docker-compose.ports.yml), atau tetap di 1 replica."
    fi
    log_warn "Batas resource (HARVESTER_CPU_LIMIT/HARVESTER_MEMORY_LIMIT) berlaku PER REPLIKA — menaikkan replica × mengalikan juga total pemakaian CPU/RAM. Cek 'Total budget resource stack' di docker-compose.yml sebelum menaikkan jauh."
    if grep -q '^HARVESTER_REPLICAS=' "$ENV_FILE" 2>/dev/null; then
        sed -i "s/^HARVESTER_REPLICAS=.*/HARVESTER_REPLICAS=$n/" "$ENV_FILE"
    else
        echo "HARVESTER_REPLICAS=$n" >> "$ENV_FILE"
    fi
    log_info "Menerapkan HARVESTER_REPLICAS=$n..."
    $COMPOSE_CMD up -d harvester
    log_ok "Selesai — worker BullMQ aman multi-replica (lock Redis per-simpul, dedup jobId), tidak perlu langkah tambahan."
    $COMPOSE_CMD ps
}

action_harvester_migrate() {
    log_info "Menjalankan migrasi database harvester (node-pg-migrate up)..."
    $COMPOSE_CMD run --rm harvester npx node-pg-migrate up \
        && log_ok "Migrasi selesai." \
        || { log_error "Migrasi gagal — pastikan service 'postgres' sudah jalan (menu 2/Deploy dulu)."; return 1; }
}

action_harvester_seed() {
    log_info "Menjalankan seed awal simpul_jaringan (sudah dibake ke image harvester)..."
    $COMPOSE_CMD --profile tools run --rm harvester-seed \
        && log_ok "Seed selesai." \
        || { log_error "Seed gagal — pastikan migrasi (menu 15) sudah dijalankan lebih dulu."; return 1; }
}

action_seed_admin() {
    # INITIAL_ADMIN_USERNAME/INITIAL_ADMIN_PASSWORD SENGAJA ditanyakan di
    # sini, BUKAN dibaca dari .env — pola sama persis dengan GHCR_TOKEN di
    # action_pull: kredensial ini cuma dipakai sesaat untuk seed/reset satu
    # baris di tabel admin_users, tidak pernah disimpan ke disk.
    local admin_username admin_password admin_password_confirm
    read -rp "Email admin dashboard (dipakai sebagai username): " admin_username
    if [[ -z "$admin_username" ]]; then
        log_error "Email tidak boleh kosong."
        return 1
    fi
    if ! [[ "$admin_username" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        log_error "Username harus berupa email yang valid (mis. nama@instansi.go.id)."
        return 1
    fi
    read -rsp "Password (minimal 8 karakter, tidak akan ditampilkan): " admin_password
    echo ""
    if [[ ${#admin_password} -lt 8 ]]; then
        log_error "Password minimal 8 karakter."
        unset admin_password
        return 1
    fi
    read -rsp "Ulangi password: " admin_password_confirm
    echo ""
    if [[ "$admin_password" != "$admin_password_confirm" ]]; then
        log_error "Password tidak sama."
        unset admin_password admin_password_confirm
        return 1
    fi
    unset admin_password_confirm

    local admin_role role_sel
    echo "1) Superadmin (akses penuh)  2) Admin (dibatasi — tanpa Riwayat Login, Skema Infrastruktur, Log Perubahan, & link Ops)"
    read -rp "Role akun [default 1]: " role_sel
    case "$role_sel" in
        2) admin_role="admin" ;;
        *) admin_role="superadmin" ;;
    esac

    log_info "Membuat/reset akun admin \"$admin_username\" (role: $admin_role)..."
    $COMPOSE_CMD run --rm -e INITIAL_ADMIN_USERNAME="$admin_username" -e INITIAL_ADMIN_PASSWORD="$admin_password" -e INITIAL_ADMIN_ROLE="$admin_role" harvester node dist/scripts/seed-admin-user.js
    local result=$?
    unset admin_password admin_username admin_role
    if [[ $result -eq 0 ]]; then
        log_ok "Akun admin siap dipakai login dashboard."
    else
        log_error "Seed admin gagal — pastikan migrasi (menu 14) sudah dijalankan lebih dulu."
        return 1
    fi
}

action_renew_tls() {
    if [[ "${BEHIND_WAF:-false}" == "true" ]]; then
        log_warn "BEHIND_WAF=true — TLS ditangani WAF atau tidak dipakai, tidak ada sertifikat lokal untuk diperbarui."
        return 0
    fi
    if [[ "${TLS_MODE:-letsencrypt}" == "custom" ]]; then
        log_warn "TLS_MODE=custom — sertifikat dipasang manual, pembaruan jadi tanggung jawabmu sendiri."
        return 0
    fi
    $COMPOSE_CMD run --rm certbot renew --webroot -w /var/www/certbot --force-renewal \
        && $COMPOSE_CMD exec nginx nginx -s reload \
        && log_ok "Sertifikat diperbarui dan nginx sudah reload."
}

action_test_nginx() {
    $COMPOSE_CMD exec nginx nginx -t
}

action_reload_nginx() {
    $COMPOSE_CMD exec nginx nginx -s reload && log_ok "Nginx reload."
}

# Cek cepat port apa saja yang benar-benar listening di host ini. Ini CUMA
# self-check LOKAL (dari dalam server) — bukan pengganti verifikasi dari
# LUAR (nmap/curl dari device lain), karena firewall/security-group cloud
# di depan server tidak ikut teruji dari sini.
action_check_exposed_ports() {
    log_info "Port yang listening di host ini:"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp 2>/dev/null || ss -tln
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null || netstat -tln
    else
        log_warn "Tidak ada 'ss'/'netstat' di sistem ini — tidak bisa cek dari sini."
        return 1
    fi
    echo ""
    log_warn "Ini cuma cek LOKAL. Verifikasi FINAL tetap wajib dari LUAR server (device lain, mis. 'nmap <domain>' atau 'curl https://<domain>:8443' yang seharusnya gagal/timeout) — supaya firewall/security-group cloud di depan server ikut teruji, bukan cuma binding Docker di host ini."
}

# ── Menu ──────────────────────────────────────────────────────────────────
print_banner() {
    echo ""
    echo "==================================================="
    echo "  inageo-mapviewer — Deployment Menu (pull GHCR / bundle)"
    echo "==================================================="
}

main_menu() {
    while true; do
        print_banner
        echo "1)  Pull image terbaru sesuai RELEASE_VERSION (butuh akses ghcr.io)"
        echo "2)  Deploy (pull/bundle + up -d + migrasi otomatis)"
        echo "3)  Ganti versi (upgrade / rollback, + migrasi otomatis)"
        echo "4)  Stop (down)"
        echo "5)  Restart"
        echo "6)  Lihat log (follow)"
        echo "7)  Status (ps)"
        echo "8)  Validasi .env"
        echo "9)  Bersihkan image lama (docker image prune)"
        echo "10) Scale app (ganti jumlah replica)"
        echo "11) Perbarui sertifikat TLS (manual)"
        echo "12) Uji config nginx (nginx -t)"
        echo "13) Reload nginx"
        echo "14) Migrasi database harvester (manual/fallback — sudah otomatis di menu 2/3)"
        echo "15) Seed awal simpul_jaringan"
        echo "16) Load image dari bundle (tar.gz Release, tanpa akses ghcr.io)"
        echo "17) Buat/reset akun admin dashboard"
        echo "18) Scale harvester (ganti jumlah replica)"
        echo "19) Cek port yang listening di host (self-check lokal)"
        echo "0)  Keluar"
        read -rp "Pilih menu: " choice
        case "$choice" in
            1) check_env && action_pull ;;
            2) check_env && action_deploy ;;
            3) check_env && action_set_version ;;
            4) confirm "Yakin ingin menghentikan semua service?" && action_down ;;
            5) confirm "Yakin ingin restart semua service?" && action_restart ;;
            6) action_logs ;;
            7) action_status ;;
            8) check_env ;;
            9) confirm "Hapus image docker lama yang tidak terpakai (dangling)?" && action_prune ;;
            10) check_env && action_scale ;;
            11) check_env && action_renew_tls ;;
            12) action_test_nginx ;;
            13) confirm "Reload nginx sekarang?" && action_reload_nginx ;;
            14) check_env && action_harvester_migrate ;;
            15) check_env && action_harvester_seed ;;
            16) action_load_bundle ;;
            17) check_env && action_seed_admin ;;
            18) check_env && action_scale_harvester ;;
            19) action_check_exposed_ports ;;
            0) exit 0 ;;
            *) log_warn "Pilihan tidak valid." ;;
        esac
    done
}

main_menu
