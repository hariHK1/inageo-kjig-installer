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
        # COMPOSE_FILE yang KOSONG harus benar-benar tidak ada, bukan diexport
        # sebagai string kosong.
        #
        # Docker Compose memperlakukan COMPOSE_FILE="" sebagai daftar berisi
        # SATU path kosong, dan path kosong itu diterjemahkan jadi direktori
        # proyek. Akibatnya `docker compose pull` gagal dgn:
        #
        #     read /home/<user>/inageo-kjig-installer: is a directory
        #
        # Pesan itu tidak menyebut COMPOSE_FILE sama sekali, jadi terbaca
        # seolah image atau kredensialnya yang bermasalah — `docker pull`
        # manual untuk image yang sama justru berhasil. Terjadi nyata di
        # server produksi, dan baru ketahuan setelah COMPOSE_FILE DIISI
        # ternyata malah membuatnya normal.
        #
        # Meng-unset membuatnya berperilaku seperti variabel yang memang tidak
        # pernah ada: Compose memakai penemuan berkas bawaannya
        # (docker-compose.yml + docker-compose.override.yml kalau ada).
        if [[ "$key" == "COMPOSE_FILE" && -z "$value" ]]; then
            unset COMPOSE_FILE
            continue
        fi
        export "$key=$value"
    done < "$file"
}

# ── Prasyarat ─────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker tidak ditemukan. Jalankan ./install.sh dulu."
    exit 1
fi

# COMPOSE_FILE yang KOSONG tapi terdefinisi harus dibuang SEBELUM perintah
# compose mana pun dijalankan.
#
# Compose memperlakukan COMPOSE_FILE="" sebagai daftar berisi satu path kosong,
# dan path kosong itu jadi direktori proyek — setiap perintah compose gagal dgn
# "read <dir>: is a directory", pesan yang tidak menyebut COMPOSE_FILE sama
# sekali.
#
# Pembersihan di load_env() saja TIDAK CUKUP: itu hanya berjalan kalau .env
# memang memuat kunci COMPOSE_FILE. Kalau nilai kosong itu diwarisi dari
# ENVIRONMENT SHELL — profil login, /etc/environment, atau export manual di
# sesi sebelumnya — loader tidak pernah melihatnya, sementara Compose tetap
# terpengaruh. Terjadi nyata di server produksi: `docker compose exec` yang
# diketik langsung di shell pun ikut gagal, di luar skrip ini.
if [[ -v COMPOSE_FILE && -z "${COMPOSE_FILE}" ]]; then
    unset COMPOSE_FILE
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

    # APP_BASE_PATH — sub-path tempat aplikasi dipasang, mis. /peta untuk
    # https://tanahair.indonesia.go.id/peta/. Kosong = dipasang di root.
    #
    # Formatnya ketat karena nilainya masuk ke DUA tempat yang harus sepakat:
    # blok location nginx, dan tag image yang ditarik. Garis miring penutup
    # akan menghasilkan `location /peta//` yang tidak pernah cocok; tanpa
    # garis miring pembuka, `location peta/` bukan path sama sekali.
    if [[ -n "${APP_BASE_PATH:-}" ]]; then
        if [[ ! "$APP_BASE_PATH" =~ ^/[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]]; then
            log_error "APP_BASE_PATH='${APP_BASE_PATH}' tidak valid — harus diawali '/' dan TANPA '/' di akhir, mis. /peta"
            missing=1
        fi
    fi

    # Sufiks tag image DITURUNKAN dari APP_BASE_PATH, tidak pernah diisi
    # manual di .env. Keduanya WAJIB sepakat: image varian /peta yang dilayani
    # nginx root menjawab 404 di mana-mana, dan image root yang dilayani nginx
    # /peta juga. Menurunkannya di sini membuat keduanya mustahil melenceng.
    #
    # Nama tag-nya dipilih CI (lihat .github/workflows/release.yml di repo
    # source): <versi>-peta untuk build ber-basePath. Karena itu sub-path
    # selain /peta belum punya image di registry — ditolak terang-terangan di
    # sini daripada gagal sebagai "manifest unknown" saat pull.
    if [[ "${APP_BASE_PATH:-}" == "/peta" ]]; then
        export APP_IMAGE_TAG_SUFFIX="-peta"
    elif [[ -n "${APP_BASE_PATH:-}" ]]; then
        log_error "APP_BASE_PATH='${APP_BASE_PATH}' belum punya varian image. CI baru membangun varian untuk '/peta' — tambahkan build baru di .github/workflows/release.yml (repo source) kalau butuh sub-path lain."
        missing=1
        # Tetap didefinisikan walau nilainya tidak akan dipakai: `set -u`
        # aktif di skrip ini (baris 6), dan rujukan di bawah akan
        # menghentikan SELURUH skrip dgn "unbound variable" kalau cabang
        # ini yang jalan.
        export APP_IMAGE_TAG_SUFFIX=""
    else
        export APP_IMAGE_TAG_SUFFIX=""
    fi

    # DITULIS JUGA KE .env, bukan cuma diexport ke proses ini.
    #
    # docker-compose.yml membaca ${APP_IMAGE_TAG_SUFFIX:-} untuk menyusun tag
    # image app. Kalau nilainya hanya hidup di environment deploy.sh, maka
    # `docker compose up/pull/ps` yang dijalankan LANGSUNG — hal biasa saat
    # menelusuri masalah — melihatnya kosong dan diam-diam memakai varian
    # ROOT pada instalasi sub-path. Terjadi nyata di dev: `docker compose up
    # -d --force-recreate app` mencoba menarik <versi> polos, bukan
    # <versi>-peta. Kebetulan registry menolak karena belum login, jadi
    # ketahuan; kalau sudah login, container akan naik dgn image SALAH tanpa
    # satu pun peringatan, dan gejalanya cuma 404 di mana-mana.
    #
    # Tetap DITURUNKAN dari APP_BASE_PATH, tidak pernah diisi manual —
    # menuliskannya di sini membuat keduanya sinkron ulang setiap kali
    # deploy.sh jalan, sekaligus bisa dibaca compose langsung.
    if [[ -z "${APP_BASE_PATH:-}" || "${APP_BASE_PATH:-}" == "/peta" ]] &&
       [[ "${APP_IMAGE_TAG_SUFFIX:-}" != "$(grep -m1 '^APP_IMAGE_TAG_SUFFIX=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)" ]]; then
        env_set_kv APP_IMAGE_TAG_SUFFIX "$APP_IMAGE_TAG_SUFFIX"
        log_info "APP_IMAGE_TAG_SUFFIX di .env disamakan jadi '${APP_IMAGE_TAG_SUFFIX:-<kosong>}' (diturunkan dari APP_BASE_PATH)."
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
    # Kosong sudah di-unset di load_env (lihat catatan di sana), jadi begitu
    # blok ini tercapai COMPOSE_FILE pasti berisi sesuatu yang nyata.
    if [[ -n "${COMPOSE_FILE:-}" ]]; then
        log_warn "COMPOSE_FILE aktif ('$COMPOSE_FILE') — port infra/app langsung ke host TEREXPOSE. Pastikan ini memang disengaja (bukan server produksi publik)."

        # Tiap entri WAJIB berkas yang benar-benar ada. Kalau salah satunya
        # ternyata DIREKTORI (mis. tanpa sengaja diisi path folder installer),
        # docker compose gagal dgn "read <path>: is a directory" — pesan yang
        # tidak menyebut COMPOSE_FILE sama sekali, sehingga terbaca seolah
        # image-nya yang bermasalah. Terjadi nyata di lapangan.
        local pemisah="${COMPOSE_PATH_SEPARATOR:-:}"
        local berkas rusak=0
        local IFS_LAMA="$IFS"
        IFS="$pemisah"
        for berkas in $COMPOSE_FILE; do
            [[ -z "$berkas" ]] && continue
            if [[ -d "$berkas" ]]; then
                log_error "COMPOSE_FILE memuat DIREKTORI, bukan berkas: '$berkas'"
                rusak=1
            elif [[ ! -f "$berkas" ]]; then
                log_error "COMPOSE_FILE menunjuk berkas yang tidak ada: '$berkas'"
                rusak=1
            fi
        done
        IFS="$IFS_LAMA"
        if [[ "$rusak" == "1" ]]; then
            log_error "Perbaiki COMPOSE_FILE di .env — isinya daftar NAMA BERKAS dipisah '$pemisah', mis:"
            log_error "  COMPOSE_FILE=docker-compose.yml${pemisah}docker-compose.ports.yml"
            return 1
        fi
    fi

    log_ok "Validasi .env selesai."
    return 0
}

# Diisi ensure_nginx_conf kalau ia benar-benar menulis ulang default.conf,
# supaya pemanggilnya tahu nginx perlu dimuat ulang. Tanpa penanda ini,
# `up -d` biasa TIDAK memuat ulang nginx — berkas config-nya bind-mount, jadi
# definisi service-nya tidak berubah dan Compose menganggap tidak ada apa-apa.
NGINX_CONF_BERUBAH=0
NGINX_CONF_BACKUP=""

ensure_nginx_conf() {
    # Cap APP_BASE_PATH yang dipakai saat default.conf ini DIHASILKAN.
    #
    # KENAPA PERLU DICAP, tidak cukup "kalau berkasnya ada, biarkan". nginx dan
    # image app WAJIB sepakat soal sub-path: nginx melayani di root sementara
    # image varian /peta = 404 di mana-mana. Menu "Ganti versi" hanya
    # me-recreate app+harvester dan tidak pernah menyentuh nginx, jadi tanpa
    # pemeriksaan ini mengubah APP_BASE_PATH lalu upgrade akan MEMATIKAN situs
    # tanpa satu pun peringatan.
    #
    # Config yang dihasilkan SEBELUM fitur sub-path ada tidak punya baris cap
    # sama sekali; itu terbaca sebagai cap kosong, yang memang sama artinya
    # dgn "dipasang di root". Instalasi lama karena itu tidak tersentuh.
    local cap_diminta="${APP_BASE_PATH:-}"
    local cap_terpasang=""
    if [[ -f "$NGINX_CONF" ]]; then
        cap_terpasang="$(sed -n 's/^# deploy\.sh:APP_BASE_PATH=\(.*\)$//p' "$NGINX_CONF" | head -1)"
        if [[ "$cap_terpasang" == "$cap_diminta" ]]; then
            return 0
        fi
        # Selalu dicadangkan dulu — berkas ini boleh saja sudah disunting
        # tangan (blok tambahan, tuning). Menulis ulang tanpa cadangan berarti
        # menghapus pekerjaan orang lain diam-diam.
        NGINX_CONF_BACKUP="${NGINX_CONF}.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$NGINX_CONF" "$NGINX_CONF_BACKUP"
        log_warn "APP_BASE_PATH berubah: '${cap_terpasang:-<root>}' -> '${cap_diminta:-<root>}'. nginx/conf.d/default.conf ditulis ulang."
        log_warn "Config lama dicadangkan ke: $NGINX_CONF_BACKUP"
        log_warn "Kalau berkas lama itu pernah disunting tangan, pindahkan suntingannya ke config baru."
    fi

    local template="$NGINX_CONF_EXAMPLE"
    if [[ "${BEHIND_WAF:-false}" == "true" ]]; then
        template="$NGINX_CONF_DIR/default-waf.conf.example"
    fi

    sed "s/__DOMAIN__/$DOMAIN/g" "$template" > "$NGINX_CONF"
    NGINX_CONF_BERUBAH=1

    # Cap di baris PERTAMA, dibaca lagi di pemanggilan berikutnya (lihat awal
    # fungsi). Sengaja berupa komentar nginx supaya tidak mempengaruhi apa pun.
    sed -i "1i # deploy.sh:APP_BASE_PATH=${APP_BASE_PATH:-}" "$NGINX_CONF"

    # __BASE_PATH__ dipakai '|' sebagai pemisah sed, BUKAN '/' — nilainya
    # sendiri memuat garis miring ('/peta'), yang akan mengakhiri perintah sed
    # lebih awal kalau pemisahnya '/'.
    sed -i "s|__BASE_PATH__|${APP_BASE_PATH:-}|g" "$NGINX_CONF"

    if [[ -n "${APP_BASE_PATH:-}" ]]; then
        # Blok exact untuk '/peta' polos — alasannya panjang, ada di komentar
        # penanda pada template. Ditulis lewat file sementara + `sed r` (pola
        # sama persis dgn __REAL_IP_TRUST__ di bawah) karena isinya banyak
        # baris; `sed s` hanya nyaman untuk satu baris.
        local exact_tmp
        exact_tmp="$(mktemp)"
        {
            printf '    location = %s {
' "$APP_BASE_PATH"
            printf '        proxy_pass $app_up$request_uri;
'
            if [[ "${BEHIND_WAF:-false}" == "true" ]]; then
                printf '        include /etc/nginx/snippets/proxy-common-waf.conf;
'
            else
                printf '        include /etc/nginx/snippets/proxy-common.conf;
'
            fi
            printf '    }
'
        } > "$exact_tmp"
        sed -i "/__BASE_PATH_EXACT__/r $exact_tmp" "$NGINX_CONF"
        rm -f "$exact_tmp"

        # Penjaga root — tolak apa pun di luar sub-path kita. Alasannya ada di
        # komentar penanda pada template.
        local guard_tmp
        guard_tmp="$(mktemp)"
        {
            printf '    location / {
'
            printf '        return 404;
'
            printf '    }
'
        } > "$guard_tmp"
        sed -i "/__ROOT_GUARD__/r $guard_tmp" "$NGINX_CONF"
        rm -f "$guard_tmp"

        log_ok "nginx dikonfigurasi untuk sub-path ${APP_BASE_PATH}/ — path di luar itu dijawab 404."
    fi
    sed -i "/__BASE_PATH_EXACT__/d" "$NGINX_CONF"
    sed -i "/__ROOT_GUARD__/d" "$NGINX_CONF"

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
# Lengkapi kredensial MinIO di .env kalau belum ada — service `minio` baru
# ditambahkan ke stack (v0.2.23-dev), jadi instalasi LAMA punya .env tanpa
# var-var ini. Tanpa helper ini, operator harus menjalankan ulang install.sh
# (yang menimpa seluruh .env) hanya untuk menghidupkan cache thumbnail.
#
# Digenerate, bukan ditanyakan interaktif: deploy.sh sering dijalankan
# non-interaktif, dan nilai ini murni internal (MinIO tidak pernah terekspos
# ke luar network `cache`). MINIO_ACCESS_KEY/SECRET dibuat SAMA dgn root
# credential supaya tidak perlu langkah manual bikin service-account dulu.
#
# HANYA menambah var yang benar-benar HILANG — nilai yang sudah diisi
# operator (mis. menunjuk ke S3 eksternal) tidak pernah ditimpa.
ensure_minio_credentials() {
    local env_file="$SCRIPT_DIR/.env"
    [[ -f "$env_file" ]] || return 0

    local added=0 genpw
    # Menangani DUA kondisi, bukan cuma satu: baris belum ada SAMA SEKALI
    # (instalasi lama sebelum var ini diperkenalkan) DAN baris ada tapi
    # NILAINYA KOSONG (mis. `MINIO_ACCESS_KEY=` yang sudah lama ada di
    # .env.example versi lama). Kalau yang kedua tidak ditangani, app dapat
    # kredensial kosong dan gagal autentikasi ke MinIO — cache diam-diam
    # tidak pernah aktif tanpa error yang kelihatan. Nilai yang SUDAH diisi
    # operator tidak pernah ditimpa.
    _set_env_if_blank() {
        local name="$1" value="$2"
        if grep -qE "^${name}=.+" "$env_file"; then
            return 0                                  # sudah terisi, hormati
        elif grep -qE "^${name}=" "$env_file"; then
            sed -i "s|^${name}=.*|${name}=${value}|" "$env_file"   # ada tapi kosong
        else
            printf '%s=%s\n' "$name" "$value" >> "$env_file"       # belum ada
        fi
        added=1
    }

    # Password digenerate hanya kalau belum ada nilainya; kalau sudah ada,
    # dipakai ulang supaya MINIO_SECRET_KEY konsisten dgn MINIO_ROOT_PASSWORD.
    # Karakternya dibatasi alfanumerik (tr -d '/+=') — aman dipakai di sed
    # tanpa perlu escaping.
    if grep -qE '^MINIO_ROOT_PASSWORD=.+' "$env_file"; then
        genpw="$(grep -E '^MINIO_ROOT_PASSWORD=' "$env_file" | head -1 | cut -d= -f2-)"
    else
        genpw="$(openssl rand -base64 32 | tr -d '\n/+=')"
    fi

    # Blok penanda hanya kalau var-nya memang belum pernah ada di file.
    if ! grep -qE '^MINIO_ROOT_USER=' "$env_file"; then
        printf '\n# === Object storage MinIO (ditambahkan otomatis oleh deploy.sh) ===\n' >> "$env_file"
    fi
    _set_env_if_blank MINIO_ROOT_USER "inageo"
    _set_env_if_blank MINIO_ROOT_PASSWORD "$genpw"
    _set_env_if_blank MINIO_ACCESS_KEY "inageo"
    _set_env_if_blank MINIO_SECRET_KEY "$genpw"
    _set_env_if_blank THUMBNAIL_BUCKET "catalog-thumbnails"
    _set_env_if_blank THUMBNAIL_TTL_DAYS "30"
    unset -f _set_env_if_blank

    if [[ "$added" == "1" ]]; then
        log_ok "Kredensial MinIO dilengkapi otomatis di .env (cache thumbnail katalog aktif)."
        # Muat ulang supaya `docker compose` di proses ini ikut melihatnya —
        # tanpa ini service minio start dgn root credential KOSONG dan menolak
        # semua koneksi sampai deploy berikutnya.
        load_env_file "$SCRIPT_DIR/.env"
    fi
}

ensure_infra_display_env() {
    local allowlist=(
        APP_CPU_LIMIT APP_MEMORY_LIMIT APP_CPU_RESERVATION APP_MEMORY_RESERVATION APP_REPLICAS
        HARVESTER_CPU_LIMIT HARVESTER_MEMORY_LIMIT HARVESTER_REPLICAS
        ELASTICSEARCH_CPU_LIMIT ELASTICSEARCH_MEMORY_LIMIT
        HTTP_PORT HTTPS_PORT POSTGRES_HOST_PORT REDIS_HOST_PORT REDIS_QUEUE_HOST_PORT
        HARVESTER_HOST_PORT MAPPROXY_HOST_PORT ELASTICSEARCH_HOST_PORT APP_DIRECT_PORT
        DOMAIN BEHIND_WAF COMPOSE_FILE APP_BASE_PATH
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
    local pull_rc=0
    $COMPOSE_CMD pull app harvester harvester-seed || pull_rc=1

    # Logout SELALU dijalankan, sukses maupun gagal. `docker login` di atas
    # menuliskan kredensial ke ~/.docker/config.json sebagai base64 — itu
    # PENYANDIAN, bukan pengamanan: siapa pun yang bisa membaca berkas itu
    # (root, atau backup yang menyertakannya) langsung memperoleh tokennya.
    # Prompt di atas sengaja tidak pernah menyimpan token ke .env justru untuk
    # menghindari itu; membiarkannya mengendap di config.json membatalkan
    # maksud tersebut. Token hanya dibutuhkan selama pull berlangsung.
    docker logout ghcr.io >/dev/null 2>&1 || true

    if [[ "$pull_rc" != "0" ]]; then
        log_error "Pull gagal. Baca pesan Docker di atas — sebab tersering:"
        log_error "  • RELEASE_VERSION belum dirilis (cek tab Releases repo source)"
        log_error "  • COMPOSE_FILE memuat entri yang bukan berkas ('is a directory')"
        log_error "  • token GitHub tidak berhak membaca package (butuh scope read:packages)"
        log_error "Kalau server ini memang tanpa akses ghcr.io, pakai menu \"Load image dari bundle\"."
        return 1
    fi
    log_ok "Image ter-pull. Kredensial ghcr.io sudah dihapus lagi dari server."
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
    # Bundle DICARI OTOMATIS, tidak lagi menuntut pengguna mengetik path.
    # Sebelumnya satu-satunya cara adalah mengetik path lengkap berkas yang
    # baru saja diunduh — membingungkan, dan gampang salah ketik justru saat
    # sedang memulihkan sistem. Sekarang folder yang lazim dipakai disisir,
    # hasilnya ditampilkan bernomor, dan mengetik path tetap tersedia sebagai
    # jalan keluar kalau berkasnya ada di tempat lain.
    # Pola DIPERSEMPIT ke nama bundle kita sendiri. Menyisir '*.tar.gz' polos
    # ikut memunguti arsip tak terkait di folder unduhan — diuji nyata: 3 dari
    # 5 hasilnya milik aplikasi lain. Daftar penuh berkas asing membuat
    # pengguna harus memilah, persis beban yang ingin dihilangkan menu ini.
    local pola="${GHCR_REPO:-inageo-kjig}-*.tar.gz"
    local -a temuan=()
    local d f
    # $HOME saja TIDAK CUKUP: skrip ini lazim dijalankan sebagai root (lihat
    # menu deploy), dan bagi root $HOME adalah /root — sementara berkas yang
    # baru di-scp biasanya mendarat di home user biasa (/home/devkjig). Jadi
    # home user asli ikut disisir: lewat $SUDO_USER kalau lewat sudo, dan
    # /home/* sebagai jaring terakhir.
    local -a folder=("." "$SCRIPT_DIR" "$HOME" "$HOME/Downloads" "/tmp" "/opt")
    [[ -n "${SUDO_USER:-}" && -d "/home/$SUDO_USER" ]] && folder+=("/home/$SUDO_USER" "/home/$SUDO_USER/Downloads")
    for d in /home/*; do [[ -d "$d" ]] && folder+=("$d"); done
    for d in "${folder[@]}"; do
        [[ -d "$d" ]] || continue
        # -maxdepth 1: sengaja TIDAK menyisir seluruh isi disk — pada server
        # dgn volume data besar itu bisa memakan waktu lama tanpa alasan.
        while IFS= read -r f; do
            [[ -n "$f" ]] && temuan+=("$f")
        done < <(find "$d" -maxdepth 1 -name "$pola" -type f 2>/dev/null | head -20)
    done

    # Buang duplikat (mis. "." dan $SCRIPT_DIR menunjuk folder yang sama).
    local -a unik=()
    local t u ada
    for t in "${temuan[@]}"; do
        ada=0
        for u in "${unik[@]}"; do [[ "$(readlink -f "$t")" == "$(readlink -f "$u")" ]] && ada=1 && break; done
        [[ $ada -eq 0 ]] && unik+=("$t")
    done

    local bundle_path=""
    if [[ ${#unik[@]} -gt 0 ]]; then
        echo ""
        echo "Bundle yang ditemukan:"
        local i=1 ukuran_kb tanda
        for t in "${unik[@]}"; do
            # Bundle sungguhan berukuran ratusan MB. Yang jauh lebih kecil hampir
            # pasti unduhan terputus — ditemukan nyata saat menguji ini (berkas
            # 3,1 MB untuk bundle yang seharusnya ~137 MB). Ditandai supaya tidak
            # terlanjur dipilih lalu gagal di tengah docker load.
            ukuran_kb=$(du -k "$t" 2>/dev/null | cut -f1)
            tanda=""
            [[ -n "$ukuran_kb" && "$ukuran_kb" -lt 51200 ]] && tanda="  <- terlalu kecil, kemungkinan unduhan terputus"
            printf "  %d) %s  (%s)%s\n" "$i" "$t" "$(du -h "$t" 2>/dev/null | cut -f1)" "$tanda"
            i=$((i + 1))
        done
        echo "  0) Ketik path sendiri"
        local pilih
        read -rp "Pilih bundle [default 1]: " pilih
        pilih="${pilih:-1}"
        if [[ "$pilih" =~ ^[0-9]+$ ]] && [[ "$pilih" -ge 1 ]] && [[ "$pilih" -le ${#unik[@]} ]]; then
            bundle_path="${unik[$((pilih - 1))]}"
        fi
    fi

    if [[ -z "$bundle_path" ]]; then
        read -rp "Path file bundle (.tar.gz dari halaman GitHub Release): " bundle_path
    fi

    if [[ ! -f "$bundle_path" ]]; then
        log_error "File '$bundle_path' tidak ditemukan."
        return 1
    fi

    log_info "Memuat image dari $bundle_path (bisa beberapa menit tergantung ukuran)..."
    local out
    if [[ "$bundle_path" == *.gz ]]; then
        out=$(gunzip -c "$bundle_path" | docker load 2>&1) || { log_error "Gagal load image:"; echo "$out"; return 1; }
    else
        out=$(docker load -i "$bundle_path" 2>&1) || { log_error "Gagal load image:"; echo "$out"; return 1; }
    fi
    echo "$out"

    # Versi diambil dari keluaran `docker load` ("Loaded image: ...:v0.2.68-dev")
    # — bukan dari nama berkas, yang bisa saja diganti orang saat mentransfer.
    # Ini menutup jebakan kedua jalur ini: RELEASE_VERSION di .env yang tidak
    # sama dgn tag bundle membuat compose diam-diam mencoba menarik dari
    # ghcr.io, dan di server tanpa internet itu gagal tanpa sebab yang jelas.
    local tag_versi
    tag_versi=$(echo "$out" | grep -oE 'Loaded image: [^ ]+:[^ ]+' | head -1 | sed 's/.*://')
    if [[ -n "$tag_versi" ]]; then
        log_ok "Image dimuat — versi: $tag_versi"
        if [[ "${RELEASE_VERSION:-}" != "$tag_versi" ]]; then
            log_warn "RELEASE_VERSION di .env saat ini: '${RELEASE_VERSION:-kosong}' — BEDA dgn bundle."
            if confirm "Samakan RELEASE_VERSION ke $tag_versi sekarang?"; then
                env_set_kv RELEASE_VERSION "$tag_versi"
                export RELEASE_VERSION="$tag_versi"
                log_ok "RELEASE_VERSION diatur ke $tag_versi."
            else
                log_warn "Dibiarkan berbeda — deploy akan mencoba menarik image dari ghcr.io, dan itu gagal di server tanpa internet."
            fi
        fi
    else
        log_warn "Tidak bisa membaca versi dari keluaran docker load — samakan RELEASE_VERSION di .env secara manual."
    fi

    log_info "Selanjutnya: menu \"Deploy\" (image tidak akan ditarik ulang selama tag itu sudah ada lokal)."
    # Pola "ghcr.io/*" TIDAK PERNAH cocok: tanda * pada filter reference Docker
    # tidak melintasi garis miring, sedangkan nama image kita dua segmen
    # (ghcr.io/<owner>/<repo>-app). Akibatnya tabelnya selalu kosong — terlihat
    # seperti image gagal dimuat padahal berhasil (dilaporkan pengguna).
    #
    # --format eksplisit dipakai supaya kolomnya tetap sama di Docker 28+, yang
    # mengubah keluaran bawaan `docker images` (kolom DISK USAGE/CONTENT SIZE).
    echo ""
    # Dibatasi 4 baris = 2 VERSI utuh. Tiap versi terdiri dari 2 image
    # (app + harvester), jadi angka genap dipakai supaya baris terakhir
    # tidak menggantung menampilkan separuh pasangan.
    #
    # Server yang sudah lama berjalan bisa menyimpan
    # puluhan versi (38 saat ini di server pengguna), dan menumpahkan
    # semuanya di sini menenggelamkan baris yang justru penting: dua
    # "Loaded image:" tepat di atasnya. Ini konfirmasi, bukan inventaris —
    # daftar lengkap & pembersihannya urusan menu 9.
    local total_img
    total_img=$(docker images --filter "reference=ghcr.io/*/*" --format "x" 2>/dev/null | wc -l)
    echo "Image aplikasi di lokal (2 versi terbaru, dari ${total_img} image):"
    docker images --filter "reference=ghcr.io/*/*" --format "  {{.Repository}}:{{.Tag}}  ({{.Size}})" 2>/dev/null | head -4
    if [[ "$total_img" -gt 4 ]]; then
        echo "  … dan $((total_img - 4)) lainnya — pakai menu 9 untuk membersihkan yang lama."
    fi
}

# Pastikan image untuk $1 (versi) siap dipakai. $2="app" = app saja.
#
# KEPUTUSANNYA DARI KENYATAAN, bukan dari flag. Sebelumnya jalur ini dipilih
# lewat PULL_MODE di .env — dan itu sumber kebingungan yang nyata: pengguna
# sudah memuat bundle secara offline, tapi Deploy tetap meminta token GitHub
# karena PULL_MODE bawaannya `true`. Seluruh kerja memindahkan bundle 139 MB
# jadi sia-sia, dan sebabnya tidak terlihat di mana pun.
#
# Sekarang skrip memeriksa sendiri apakah image versi itu SUDAH ADA di daemon:
#   ada    -> tawarkan dua pilihan, offline sebagai bawaan
#   belum  -> tidak ada yang bisa ditawarkan, langsung tarik dari ghcr.io
#
# Tidak ada lagi yang perlu diatur di .env untuk ini.
siapkan_image() {
    local versi="$1" cakupan="${2:-semua}"
    local dasar="ghcr.io/${GHCR_OWNER}/${GHCR_REPO}"
    local -a butuh=("${dasar}-app:${versi}")
    [[ "$cakupan" != "app" ]] && butuh+=("${dasar}-harvester:${versi}")

    local ref lengkap=true
    for ref in "${butuh[@]}"; do
        docker image inspect "$ref" >/dev/null 2>&1 || lengkap=false
    done

    if [[ "$lengkap" != "true" ]]; then
        log_info "Image versi $versi belum ada di server ini — menarik dari ghcr.io."
        if [[ "$cakupan" == "app" ]]; then action_pull_app; else action_pull; fi
        return $?
    fi

    echo ""
    echo "Image versi $versi SUDAH ADA di server ini."
    echo "  1) Offline — pakai image yang sudah ada (tanpa ghcr.io, tanpa token)"
    echo "  2) Tarik ulang dari ghcr.io (butuh akses internet & token GitHub)"
    local pilih
    read -rp "Pilih [default 1]: " pilih
    if [[ "$pilih" == "2" ]]; then
        if [[ "$cakupan" == "app" ]]; then action_pull_app; else action_pull; fi
        return $?
    fi
    log_ok "Mode offline — memakai image lokal versi $versi."
    return 0
}

action_deploy() {
    siapkan_image "${RELEASE_VERSION}" || return 1
    ensure_nginx_conf
    # Deploy penuh berarti harvester kembali jadi milik stack ini — cabut
    # penanda "dikelola pihak lain" supaya keterangan di halaman admin tidak
    # tertinggal menyesatkan setelah peralihan balik.
    env_set_kv HARVESTER_EXTERNAL false
    export HARVESTER_EXTERNAL=false
    # WAJIB sebelum `up -d` — service minio membaca MINIO_ROOT_USER/PASSWORD
    # saat start; kalau kosong ia menolak semua koneksi sampai deploy
    # berikutnya (lihat ensure_minio_credentials).
    ensure_minio_credentials
    ensure_infra_display_env
    # Overlay extra-hosts ditulis ulang dari extra-hosts.conf tiap deploy —
    # konf adalah sumber kebenaran, YAML-nya cuma turunan. Tanpa ini, daftar
    # yang disunting tangan di konf tidak akan pernah sampai ke container.
    eh_tulis_yml
    if [[ "${BEHIND_WAF:-false}" == "true" ]]; then
        log_info "BEHIND_WAF=true — melewati bootstrap TLS/certbot."
    else
        bootstrap_tls || return 1
    fi
    log_info "Deploying (up -d)..."
    $COMPOSE_CMD up -d
    muat_ulang_nginx_kalau_perlu || log_warn "nginx belum memakai config baru — lihat pesan di atas."
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
# Layanan yang membentuk "app saja" — TANPA harvester dan tanpa tumpukan
# datanya (postgres, redis-queue, elasticsearch, postgres-backup,
# docker-socket-proxy, harvester-seed).
#
# Perhatikan yang TETAP ikut: app BUKAN frontend statis. Ia merender thumbnail
# peta (sharp) lalu menyimpannya ke MinIO, mem-proxy WMS/ArcGIS dgn cache
# Redis, dan menyajikan tile lewat MapProxy. Melepas salah satu dari itu
# bukan "meringankan" — itu mematikan fitur.
APP_ONLY_SERVICES="nginx app redis mapproxy minio minio-init"

# Deploy hanya sisi app, menunjuk ke harvester yang dikelola pihak lain.
# Dipakai saat harvester di server ini diturunkan dan digantikan milik pihak
# lain (stack compose terpisah / host lain) — lihat API_BACKEND di .env.
# Tulis/ubah satu pasangan KEY=VALUE di .env, apa pun kondisi awalnya
# (baris belum ada, atau ada tapi kosong). Delimiter sed sengaja "|" karena
# nilainya kerap berupa URL yang penuh "/"; "|" dan "&" di dalam nilai
# di-escape supaya tidak diartikan sed ("&" berarti "seluruh yang cocok").
env_set_kv() {
    local key="$1" val="$2" esc
    esc=${val//\/\\}; esc=${esc//|/\|}; esc=${esc//&/\&}
    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
    fi
}

# Tampilkan rahasia TANPA membocorkannya: sebagian karakter + sidik jari
# (8 hex pertama SHA-256). Sidik jari inilah yang dipakai mencocokkan token
# dgn pengelola harvester tujuan — kedua pihak cukup membandingkan hash,
# tidak perlu ada yang menyebutkan tokennya.
mask_secret() {
    # DIPISAH per baris, BUKAN `local v="$1" n=${#v}` — pada `local`, SEMUA
    # ekspansi dievaluasi sebelum penugasan berlaku, jadi ${#v} membaca `v`
    # yang masih kosong dan n selalu 0. Akibatnya token yang jelas terisi
    # dilaporkan "(KOSONG)" (ditemukan lewat uji, bukan tinjauan kode).
    local v="$1"
    local n=${#v}
    local fp
    if [[ $n -eq 0 ]]; then
        echo "(KOSONG)"
        return
    fi
    fp="$(printf '%s' "$v" | sha256sum | cut -c1-8)"
    if [[ $n -le 8 ]]; then
        echo "**** ($n karakter, sidik jari: $fp)"
    else
        echo "${v:0:4}…${v: -4} ($n karakter, sidik jari: $fp)"
    fi
}

# Konfirmasi & perbaiki .env sebelum deploy app-saja. Dua nilai ini yang
# menentukan app bicara ke harvester yang BENAR: salah satu meleset, app
# hidup tapi tidak punya data (atau ditolak 401) — gejala yang membingungkan
# kalau baru ketahuan setelah deploy.
verify_app_only_env() {
    while :; do
        echo ""
        log_info "=== Verifikasi sambungan ke harvester ==="
        echo "  API_BACKEND      : ${API_BACKEND:-(kosong -> pakai default http://harvester:4000)}"
        echo "  API_ACCESS_TOKEN : $(mask_secret "${API_ACCESS_TOKEN:-}")"
        echo ""

        if [[ -z "${API_BACKEND:-}" || "${API_BACKEND:-}" == "http://harvester:4000" ]]; then
            log_warn "API_BACKEND menunjuk harvester stack INI, padahal mode ini tidak menyalakannya."
        fi
        if [[ -z "${API_ACCESS_TOKEN:-}" ]]; then
            log_warn "API_ACCESS_TOKEN kosong — harvester menolak SEMUA permintaan tanpa token."
        fi
        echo "  Catatan: token di atas harus SAMA dgn milik harvester tujuan. Cocokkan"
        echo "  sidik jarinya dgn pengelola harvester itu — tidak perlu saling menyebut token."

        echo ""
        if confirm "Kedua nilai di atas sudah sesuai?"; then
            return 0
        fi

        echo ""
        log_info "Kosongkan input (tekan Enter) untuk MEMPERTAHANKAN nilai sekarang."
        local new_backend new_token
        read -rp "  API_BACKEND baru: " new_backend
        if [[ -n "$new_backend" ]]; then
            if [[ ! "$new_backend" =~ ^https?://[^[:space:]]+$ ]]; then
                log_error "'$new_backend' bukan URL http(s) yang valid — perubahan dibatalkan."
                continue
            fi
            # Buang garis miring di ujung; app menyusun path sendiri di
            # belakangnya, "//search/..." ditolak sebagian reverse proxy.
            new_backend="${new_backend%/}"
            env_set_kv API_BACKEND "$new_backend"
            export API_BACKEND="$new_backend"
            log_ok "API_BACKEND diperbarui."
        fi

        # -s: token tidak ditampilkan saat diketik, sama seperti prompt GHCR.
        read -rsp "  API_ACCESS_TOKEN baru: " new_token
        echo ""
        if [[ -n "$new_token" ]]; then
            env_set_kv API_ACCESS_TOKEN "$new_token"
            export API_ACCESS_TOKEN="$new_token"
            unset new_token
            log_ok "API_ACCESS_TOKEN diperbarui."
        fi
        log_ok ".env disimpan. Nilai ditampilkan ulang untuk dicek."
    done
}


action_deploy_app_only() {
    # Verifikasi + perbaiki .env DULU — dua nilai inilah yang menentukan app
    # bicara ke harvester yang benar. Kalau meleset, gejalanya baru muncul
    # setelah deploy sebagai "data kosong" atau 401, yang jauh lebih sulit
    # ditelusuri daripada dicegah di sini.
    verify_app_only_env || return 1

    siapkan_image "${RELEASE_VERSION}" app || return 1

    ensure_nginx_conf
    ensure_minio_credentials
    if [[ "${BEHIND_WAF:-false}" == "true" ]]; then
        log_info "BEHIND_WAF=true — melewati bootstrap TLS/certbot."
    else
        bootstrap_tls || return 1
        APP_ONLY_SERVICES="$APP_ONLY_SERVICES certbot"
    fi

    # Tandai bahwa harvester bukan milik stack ini — dibaca halaman admin
    # Kesehatan Sistem & Skema Infrastruktur untuk menyatakan asal datanya.
    env_set_kv HARVESTER_EXTERNAL true
    export HARVESTER_EXTERNAL=true

    log_info "Menyalakan service: $APP_ONLY_SERVICES"
    # SENGAJA tanpa migrasi database — skema Postgres itu milik harvester,
    # dan di mode ini harvester bukan tanggung jawab stack ini lagi.
    $COMPOSE_CMD up -d $APP_ONLY_SERVICES || return 1
    muat_ulang_nginx_kalau_perlu || log_warn "nginx belum memakai config baru — lihat pesan di atas."
    $COMPOSE_CMD ps
    log_ok "App aktif. Harvester TIDAK disentuh oleh menu ini."
    log_info "Kalau harvester lama masih jalan di server ini, matikan lewat menu 21."
}

# Pull image app saja — harvester tidak ikut ditarik supaya tidak sia-sia
# mengunduh image yang memang tidak akan dijalankan.
action_pull_app() {
    if [[ -z "${GHCR_OWNER:-}" || -z "${GHCR_REPO:-}" ]]; then
        log_error "GHCR_OWNER/GHCR_REPO kosong di .env — tidak bisa pull."
        return 1
    fi
    local ghcr_username ghcr_token
    read -rp "GHCR_USERNAME (username GitHub untuk docker login): " ghcr_username
    [[ -n "$ghcr_username" ]] || { log_error "GHCR_USERNAME tidak boleh kosong."; return 1; }
    read -rsp "GHCR_TOKEN (PAT scope read:packages, tidak akan ditampilkan): " ghcr_token
    echo ""
    [[ -n "$ghcr_token" ]] || { log_error "GHCR_TOKEN tidak boleh kosong."; return 1; }

    log_info "Login ke ghcr.io sebagai $ghcr_username..."
    echo "$ghcr_token" | docker login ghcr.io -u "$ghcr_username" --password-stdin         || { log_error "Docker login gagal."; unset ghcr_token; return 1; }
    unset ghcr_token ghcr_username

    log_info "Pull image app versi $RELEASE_VERSION..."
    local rc=0
    $COMPOSE_CMD pull app || rc=1
    # Lihat alasan lengkapnya di action_pull — token tidak boleh mengendap.
    docker logout ghcr.io >/dev/null 2>&1 || true
    if [[ "$rc" != "0" ]]; then
        log_error "Pull gagal — cek RELEASE_VERSION di .env memang sudah dirilis."
        return 1
    fi
    log_ok "Image app ter-pull. Kredensial ghcr.io sudah dihapus lagi dari server."
}

# Turunkan harvester + tumpukan datanya, tanpa mengganggu app yang sedang
# melayani pengguna. Dipakai saat peran harvester dialihkan ke pihak lain.
action_down_harvester() {
    local svcs="harvester harvester-seed postgres postgres-backup redis-queue elasticsearch docker-socket-proxy"
    log_warn "Service berikut akan DIHENTIKAN: $svcs"
    echo "  Volume data (postgres_data, es_data) TIDAK dihapus — data tetap aman"
    echo "  dan service bisa dinyalakan lagi kapan pun lewat menu 2."
    confirm "Lanjutkan?" || return 1
    $COMPOSE_CMD stop $svcs || return 1
    log_ok "Harvester & tumpukan datanya dihentikan. App tetap berjalan."
}


# Service yang punya `profiles:` di docker-compose.yml — harvester-seed
# (tools) & geoserver/geoserver-db. Mereka memang HANYA jalan kalau profilnya
# diaktifkan, jadi "tidak ada containernya" adalah keadaan normal dan tidak
# boleh ikut dilaporkan hilang. Dibaca dari berkasnya, bukan didaftar keras di
# sini, supaya service ber-profile yang ditambahkan kelak ikut terkecualikan
# sendiri tanpa ada yang perlu ingat memperbarui daftar.
service_ber_profile() {
    awk '
        /^  [a-z][a-z0-9_-]*:[[:space:]]*$/ { nama = $1; sub(/:$/, "", nama) }
        /^    profiles:/                    { if (nama != "") print nama }
    ' "$SCRIPT_DIR/docker-compose.yml" 2>/dev/null | tr -d '\r'
}

# Peringatkan kalau ada service yang SEHARUSNYA ada tapi containernya tidak
# pernah dibuat.
#
# KENAPA ADA. Menu "Ganti versi" memakai `--no-deps` dan menyebut app+harvester
# saja — itu memang disengaja (postgres/redis/nginx tidak ikut di-recreate,
# supaya data & TLS tidak terganggu). Efek sampingnya: kalau stack pernah
# di-`down`, menu itu TIDAK akan menghidupkan sisanya kembali, lalu tetap
# melaporkan "Selesai". Terjadi nyata di produksi: 10 service (redis,
# mapproxy, minio, glitchtip, uptime-kuma, ...) mati berjam-jam tanpa satu pun
# peringatan. Gejalanya cuma "[redis-cache] connect ETIMEDOUT" di log app —
# yang ditelan diam-diam karena lapisan cache memang fail-soft.
#
# Dibandingkan dgn `ps --services --all`, BUKAN yang sedang berjalan: service
# sekali-jalan seperti minio-init memang berstatus Exited(0) setelah tugasnya
# selesai, dan itu normal. Yang jadi masalah adalah service yang containernya
# TIDAK ADA sama sekali.
periksa_service_hilang() {
    local harus ada hilang
    harus="$($COMPOSE_CMD config --services 2>/dev/null | sort)"
    if [[ -z "$harus" ]]; then
        return 0   # tidak bisa dibaca — jangan menghalangi, sekadar lewat
    fi
    ada="$($COMPOSE_CMD ps --services --all 2>/dev/null | sort)"
    hilang="$(comm -23 <(printf '%s
' "$harus") <(printf '%s
' "$ada")               | comm -23 - <(service_ber_profile | sort))"

    [[ -z "$hilang" ]] && return 0

    log_warn "Service berikut TIDAK punya container sama sekali:"
    printf '           %s
' $hilang
    log_warn "Menu ini memakai --no-deps, jadi ia TIDAK akan menghidupkannya."
    log_warn "Jalankan menu 2 (Deploy) lebih dulu untuk memulihkan stack."
    return 1
}

# Muat ulang nginx HANYA kalau ensure_nginx_conf benar-benar menulis ulang
# config. `up -d` biasa tidak cukup: default.conf itu bind-mount, definisi
# service-nya tidak berubah, jadi Compose membiarkan container lama jalan
# dengan config lama di memori.
muat_ulang_nginx_kalau_perlu() {
    [[ "$NGINX_CONF_BERUBAH" == "1" ]] || return 0

    if ! $COMPOSE_CMD ps --services --filter status=running 2>/dev/null | grep -qx nginx; then
        $COMPOSE_CMD up -d --no-deps nginx
        return 0
    fi

    # Diuji DULU, baru dimuat ulang. Kalau config baru ternyata tidak valid,
    # `nginx -s reload` akan ditolak dan proses lama tetap jalan — tapi
    # operatornya tidak akan tahu ada yang salah. Menguji lebih dulu membuat
    # kegagalan itu terucap, dan situsnya tetap hidup dgn config lama.
    if $COMPOSE_CMD exec -T nginx nginx -t; then
        $COMPOSE_CMD exec -T nginx nginx -s reload
        log_ok "nginx dimuat ulang dengan konfigurasi baru."
    else
        log_error "Konfigurasi nginx baru TIDAK valid — TIDAK dimuat ulang, nginx tetap jalan dgn config lama."
        [[ -n "$NGINX_CONF_BACKUP" ]] && log_error "Cadangan config sebelumnya: $NGINX_CONF_BACKUP"
        return 1
    fi
}

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
    # Diperiksa SEBELUM apa pun diubah — termasuk sebelum RELEASE_VERSION di
    # .env ditulis ulang di atas sudah terlanjur, jadi setidaknya jangan sampai
    # image ditarik & container di-recreate di atas stack yang tidak utuh.
    if ! periksa_service_hilang; then
        if ! confirm "Tetap lanjutkan ganti versi walau stack tidak utuh?"; then
            log_warn "Dibatalkan — jalankan menu 2 (Deploy) dulu."
            return 1
        fi
    fi

    log_info "Pindah ke versi $new_version..."
    siapkan_image "$new_version" || return 1

    # nginx ikut diperiksa DI SINI, bukan cuma di action_deploy. Menu ini dulu
    # hanya menyentuh app+harvester, sehingga mengubah APP_BASE_PATH lalu
    # upgrade lewat menu ini akan menghasilkan nginx yang melayani di root
    # sementara image-nya varian sub-path — situs mati total, tanpa peringatan.
    ensure_nginx_conf
    $COMPOSE_CMD up -d --no-deps --force-recreate app harvester
    muat_ulang_nginx_kalau_perlu || log_warn "nginx belum memakai config baru — lihat pesan di atas."
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
    # `docker image prune -f` saja TIDAK CUKUP: ia hanya membuang image TANPA
    # TAG (dangling). Versi lama aplikasi ini semuanya BERTAG
    # (…-app:v0.2.12-dev dst), jadi tidak pernah tersentuh — terkumpul 38 versi
    # di server sebelum ketahuan. Menu ini bernama "Bersihkan image lama" tapi
    # tidak bisa membersihkan yang benar-benar menumpuk.
    #
    # Sekarang: tampilkan pemakaian sesungguhnya, lalu tawarkan membuang versi
    # lama aplikasi ini sambil MENYISAKAN beberapa yang terbaru untuk rollback.
    echo ""
    echo "Pemakaian disk Docker:"
    docker system df

    local pola="ghcr.io/${GHCR_OWNER:-*}/${GHCR_REPO:-*}"
    local -a tag_urut=()
    # Diurutkan Docker sendiri menurut waktu pembuatan (terbaru dulu) — bukan
    # menurut nomor versi. Urutan nomor tidak bisa diandalkan: v0.2.9 dan
    # v0.2.10 salah urut kalau dibandingkan sebagai teks.
    #
    # Yang dikumpulkan REFERENSI PENUH (repo:tag), bukan cuma nomor versinya.
    # Itu yang nanti diberikan apa adanya ke `docker rmi`. Merangkai ulang nama
    # dari pola adalah bug yang baru saja diperbaiki: `docker images --filter`
    # menerima glob `*`, sedangkan `docker rmi` TIDAK — ia memperlakukan `*`
    # sebagai nama harfiah, sehingga setiap penghapusan gagal dan dilaporkan
    # keliru sebagai "sedang dipakai container".
    while IFS= read -r baris; do
        [[ -n "$baris" ]] && tag_urut+=("$baris")
    done < <(docker images --filter "reference=${pola}-app" --filter "reference=${pola}-harvester" \
                --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)

    if [[ ${#tag_urut[@]} -eq 0 ]]; then
        log_info "Tidak ada image aplikasi ini di lokal."
        docker image prune -f
        return 0
    fi

    # Kumpulkan daftar VERSI unik, urut sesuai kemunculan (terbaru dulu).
    local -a versi=()
    local t v ada u
    for t in "${tag_urut[@]}"; do
        v="${t##*:}"
        ada=0
        for u in "${versi[@]}"; do [[ "$u" == "$v" ]] && ada=1 && break; done
        [[ $ada -eq 0 ]] && versi+=("$v")
    done

    local simpan=3
    echo ""
    echo "Ditemukan ${#versi[@]} versi image aplikasi ini."
    read -rp "Berapa versi TERBARU yang disimpan? [default $simpan]: " n
    [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && simpan="$n"

    local -a buang=()
    local i=0
    for v in "${versi[@]}"; do
        i=$((i + 1))
        # Versi yang sedang dipakai .env JANGAN PERNAH dibuang, walau posisinya
        # sudah di luar N terbaru — membuangnya membuat `up -d` mencoba menarik
        # ulang dari ghcr.io, dan di server tanpa internet itu mematikan stack.
        if [[ "$v" == "${RELEASE_VERSION:-}" ]]; then
            continue
        fi
        [[ $i -le $simpan ]] && continue
        buang+=("$v")
    done

    if [[ ${#buang[@]} -eq 0 ]]; then
        log_info "Tidak ada versi lama yang perlu dibuang."
    else
        echo ""
        echo "Versi yang akan DIBUANG (${#buang[@]}):"
        printf '  %s\n' "${buang[@]}"
        echo "Disimpan: ${simpan} versi terbaru${RELEASE_VERSION:+ + versi aktif ($RELEASE_VERSION)}"
        if confirm "Lanjut hapus versi di atas?"; then
            local ref galat
            for v in "${buang[@]}"; do
                # Referensi diambil dari daftar NYATA hasil `docker images`,
                # tidak dirangkai dari pola — lihat catatan di pengumpulan.
                for ref in "${tag_urut[@]}"; do
                    [[ "${ref##*:}" == "$v" ]] || continue
                    if galat=$(docker rmi "$ref" 2>&1); then
                        echo "  dibuang: $ref"
                    else
                        # Error ASLI ditampilkan, bukan tebakan. Sebelumnya
                        # semua kegagalan dilaporkan sebagai "sedang dipakai
                        # container", padahal sebab sesungguhnya bisa apa saja
                        # — dan itu menyembunyikan bug di perintahnya sendiri.
                        echo "  gagal  : $ref"
                        echo "           $(echo "$galat" | head -1)"
                    fi
                done
            done
        else
            log_info "Dibatalkan — tidak ada yang dihapus."
        fi
    fi

    echo ""
    log_info "Membuang image tanpa tag (dangling)..."
    docker image prune -f
    echo ""
    echo "Pemakaian disk Docker setelah pembersihan:"
    docker system df
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
    echo "1) Superadmin (akses penuh — MAKSIMAL 1 akun di seluruh sistem)"
    echo "2) Admin (dibatasi — tanpa Riwayat Login, Skema Infrastruktur, Log Perubahan, & link Ops)"
    # Default sengaja ADMIN, bukan superadmin. Sebelumnya menekan Enter
    # langsung membuat superadmin — pilihan paling berbahaya dijadikan
    # perilaku paling mudah. Yang berwenang mengangkat superadmin pasti
    # sadar sedang melakukannya; yang sekadar membuat akun operasional
    # tidak boleh mendapatkannya karena salah pencet.
    read -rp "Role akun [default 2 = Admin]: " role_sel
    case "$role_sel" in
        1) admin_role="superadmin" ;;
        *) admin_role="admin" ;;
    esac

    # Mengangkat/mengganti superadmin menuntut password superadmin yang AKTIF —
    # akses server saja tidak cukup. Kalau belum ada superadmin sama sekali
    # (deployment baru), script seed melewatkan verifikasi ini sendiri, jadi
    # isian di bawah boleh dikosongkan.
    local admin_verify=""
    if [[ "$admin_role" == "superadmin" ]]; then
        echo ""
        log_warn "Superadmin dibatasi 1 akun. Mengangkat/mengganti superadmin menuntut password superadmin yang aktif."
        read -rsp "Password superadmin yang aktif (kosongkan kalau belum ada superadmin sama sekali): " admin_verify
        echo ""
    fi

    # Menimpa akun yang username-nya sudah terdaftar WAJIB disengaja — tanpa
    # ini, script menolak dan tidak mengubah apa pun.
    local admin_reset="false"
    if confirm "Kalau email ini SUDAH terdaftar, timpa akun yang ada (password & role diganti)?"; then
        admin_reset="true"
    fi

    log_info "Membuat/reset akun admin \"$admin_username\" (role: $admin_role)..."
    $COMPOSE_CMD run --rm         -e INITIAL_ADMIN_USERNAME="$admin_username"         -e INITIAL_ADMIN_PASSWORD="$admin_password"         -e INITIAL_ADMIN_ROLE="$admin_role"         -e INITIAL_ADMIN_VERIFY_PASSWORD="$admin_verify"         -e INITIAL_ADMIN_RESET="$admin_reset"         harvester node dist/scripts/seed-admin-user.js
    local result=$?
    unset admin_password admin_username admin_role admin_verify admin_reset
    if [[ $result -eq 0 ]]; then
        log_ok "Akun admin siap dipakai login dashboard."
    else
        log_error "Seed admin gagal — baca pesan di atas. Sebab tersering: email sudah terdaftar, password superadmin salah, atau migrasi (menu 14) belum dijalankan."
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

# ── Jangkauan simpul: daftar extra-hosts ────────────────────────────────────
# Sebagian simpul hanya bisa dijangkau lewat SATU jalur, dan jalurnya berbeda
# per simpul: mayoritas lewat internet, segelintir hanya lewat jaringan
# internal. Tidak ada satu setelan DNS yang benar untuk keduanya, jadi
# DNS_PRIMARY diarahkan ke resolver yang menang secara jumlah, dan sisanya
# ditangani sbg pengecualian di sini.
#
# Alasan lengkap + angka pengukurannya ada di extra-hosts.conf.example.
EXTRA_HOSTS_CONF="$SCRIPT_DIR/extra-hosts.conf"
EXTRA_HOSTS_YML="$SCRIPT_DIR/docker-compose.extra-hosts.yml"

# Baca konf jadi "nama|ip" per baris. Komentar, baris kosong, dan kolom ke-3
# dst (alasan) diabaikan.
eh_baca() {
    [[ -f "$EXTRA_HOSTS_CONF" ]] || return 0
    awk '!/^[[:space:]]*#/ && NF >= 2 { print $1 "|" $2 }' "$EXTRA_HOSTS_CONF"
}

eh_jumlah() { eh_baca | grep -c . || true; }

# Hasilkan overlay compose dari konf. DIHASILKAN, bukan disunting tangan —
# supaya daftar di konf tetap satu-satunya sumber kebenaran dan tidak mungkin
# berbeda dari yang benar-benar dipasang ke container.
eh_tulis_yml() {
    local n; n="$(eh_jumlah)"
    if [[ "$n" == "0" ]]; then
        rm -f "$EXTRA_HOSTS_YML"
        return 0
    fi
    {
        echo "# DIHASILKAN deploy.sh dari extra-hosts.conf — JANGAN disunting tangan."
        echo "# Ubah daftarnya di extra-hosts.conf, lalu jalankan menu"
        echo "# \"Survei jangkauan simpul\" (atau deploy) supaya berkas ini ditulis ulang."
        echo "#"
        echo "# extra_hosts memaksa nama-nama di bawah ke alamat internal, MELEWATI DNS."
        echo "# Nama lain tidak tersentuh dan tetap memakai DNS_PRIMARY seperti biasa."
        echo "#"
        echo "# Dibaca oleh app & harvester: keduanya menghubungi simpul jaringan —"
        echo "# harvester saat harvest, app saat proxy peta & thumbnail."
        echo "#"
        echo "# CATATAN PENTING: extra_hosts hanya berlaku saat container DIBUAT."
        echo "# Mengubah daftar ini berarti recreate app + harvester, bukan sekadar"
        echo "# restart. deploy.sh mengurusnya."
        echo "services:"
        local svc
        for svc in app harvester; do
            echo "  $svc:"
            echo "    extra_hosts:"
            local baris nama ip
            while IFS='|' read -r nama ip; do
                [[ -z "$nama" ]] && continue
                echo "      - \"$nama:$ip\""
            done < <(eh_baca)
        done
    } > "$EXTRA_HOSTS_YML"
    log_ok "docker-compose.extra-hosts.yml ditulis ulang ($n entri)."
}

# Pastikan overlay-nya benar-benar ikut dipakai. Sama seperti rute nginx:
# berkasnya bisa ada tapi tidak pernah terbaca kalau tidak tercantum di
# COMPOSE_FILE — dan `docker compose` tidak akan mengeluh sedikit pun.
eh_pastikan_compose_file() {
    local n; n="$(eh_jumlah)"
    [[ "$n" == "0" ]] && return 0
    local nama_berkas="docker-compose.extra-hosts.yml"
    if [[ "${COMPOSE_FILE:-}" == *"$nama_berkas"* ]]; then
        return 0
    fi

    log_warn "$nama_berkas belum tercantum di COMPOSE_FILE — daftar extra-hosts TIDAK akan dipakai."
    local usul
    if [[ -z "${COMPOSE_FILE:-}" ]]; then
        # COMPOSE_FILE kosong = Compose memakai penemuan bawaan. Begitu kita
        # mengisinya, penemuan itu mati dan docker-compose.yml WAJIB disebut
        # eksplisit, kalau tidak seluruh stack hilang.
        usul="docker-compose.yml:$nama_berkas"
    else
        usul="${COMPOSE_FILE}:$nama_berkas"
    fi
    log_info "Usulan: COMPOSE_FILE=$usul"
    confirm "Tulis ke .env sekarang?" || { log_warn "Dilewati — daftar extra-hosts belum aktif."; return 1; }
    env_set_kv COMPOSE_FILE "$usul"
    export COMPOSE_FILE="$usul"
    log_ok "COMPOSE_FILE diperbarui."
}

eh_terapkan() {
    eh_tulis_yml
    eh_pastikan_compose_file || return 1
    local n; n="$(eh_jumlah)"
    [[ "$n" == "0" ]] && { log_info "Daftar kosong — tidak ada yang diterapkan."; return 0; }

    log_warn "extra_hosts hanya berlaku saat container DIBUAT — app & harvester akan di-recreate."
    log_warn "Harvest yang sedang berjalan akan terhenti (bisa dilanjutkan lagi, ada checkpoint)."
    confirm "Recreate sekarang?" || { log_info "Ditunda. Jalankan menu 2 kapan pun siap."; return 0; }
    $COMPOSE_CMD up -d --force-recreate app harvester
    log_ok "app & harvester dibuat ulang dengan $n entri extra-hosts."
}

# Ambil seluruh URL simpul dari basis data. Lewat container postgres, bukan
# psql di host — host belum tentu punya klien psql, dan kredensialnya sudah
# ada di environment container.
eh_ambil_urls() {
    $COMPOSE_CMD exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc \
        "SELECT situs FROM simpul_jaringan WHERE situs ~ '^https?://'" 2>/dev/null | tr -d '\r' | tr '\n' ' '
}

action_survei_jangkauan() {
    local skrip="$SCRIPT_DIR/scripts/survei-jangkauan.js"
    if [[ ! -f "$skrip" ]]; then
        log_error "scripts/survei-jangkauan.js tidak ada — jalankan 'git pull' dulu."
        return 1
    fi

    log_info "Mengambil daftar simpul dari basis data..."
    local urls; urls="$(eh_ambil_urls)"
    local jml; jml="$(echo $urls | wc -w)"
    if [[ "$jml" -lt 1 ]]; then
        log_error "Tidak ada simpul terbaca. Pastikan service postgres berjalan (menu 2)."
        return 1
    fi

    log_info "Mengukur $jml simpul lewat dua resolver — ini menghubungi server instansi, butuh 1-3 menit."
    log_warn "Jangan dijalankan berulang tanpa perlu: sebagian server membatasi IP yang terlalu sering menyapa."
    confirm "Lanjut?" || return 1

    local keluaran
    keluaran="$($COMPOSE_CMD exec -T -e URLS="$urls" \
        -e DNS_INTERNAL="${DNS_PRIMARY_INTERNAL:-192.168.201.10}" \
        -e DNS_PUBLIK="${DNS_PUBLIK_SURVEI:-1.1.1.1}" \
        harvester node < "$skrip")" || { log_error "Survei gagal dijalankan."; return 1; }

    echo "$keluaran" | grep -v '^#JSON#'
    local json; json="$(echo "$keluaran" | grep '^#JSON#' | tail -1 | sed 's|^#JSON#||')"
    if [[ -z "$json" ]]; then
        log_error "Survei tidak menghasilkan ringkasan yang bisa dibaca."
        return 1
    fi

    # Selisih dihitung di node (JSON sudah di tangan) supaya tidak ada parsing
    # rapuh di bash.
    local diff_out
    diff_out="$(SEKARANG="$(eh_baca | tr '\n' ' ')" JSON="$json" node -e '
        const json = JSON.parse(process.env.JSON);
        const skr = new Map((process.env.SEKARANG||"").trim().split(/\s+/).filter(Boolean)
            .map(s => s.split("|")).map(([h,i]) => [h,i]));
        const usul = new Map(json.pin.map(p => [p.host, p.ip]));
        const tambah = [...usul].filter(([h]) => !skr.has(h));
        const ubah   = [...usul].filter(([h,i]) => skr.has(h) && skr.get(h) !== i);
        const hapus  = [...skr].filter(([h]) => !usul.has(h));
        for (const [h,i] of tambah) console.log("  + tambah  " + h + "  -> " + i);
        for (const [h,i] of ubah)   console.log("  ~ ubah    " + h + "  " + skr.get(h) + " -> " + i);
        for (const [h,i] of hapus)  console.log("  - hapus   " + h + "  (" + i + ")  jalur publik sudah pulih / tidak perlu lagi");
        console.log("#N#" + (tambah.length + ubah.length + hapus.length));
        console.log("#LIST#" + JSON.stringify([...usul]));
    ')" || { log_error "Gagal menghitung selisih."; return 1; }

    echo ""
    log_info "=== Usulan perubahan daftar extra-hosts ==="
    echo "$diff_out" | grep -v '^#'
    local n; n="$(echo "$diff_out" | grep '^#N#' | sed 's|^#N#||')"
    if [[ "$n" == "0" ]]; then
        log_ok "Tidak ada perubahan — daftar saat ini sudah sesuai keadaan jaringan."
        return 0
    fi

    echo ""
    log_warn "Angka ini hasil SATU kali pengukuran. Simpul yang kebetulan sedang"
    log_warn "gangguan sesaat bisa muncul di sini. Kalau selisihnya cuma satu-dua"
    log_warn "entri dan Anda tidak menduga ada perubahan, lebih aman ukur ulang dulu."
    confirm "Tulis daftar baru ke extra-hosts.conf?" || { log_info "Dibatalkan — tidak ada yang diubah."; return 0; }

    local cadangan
    if [[ -f "$EXTRA_HOSTS_CONF" ]]; then
        cadangan="${EXTRA_HOSTS_CONF}.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$EXTRA_HOSTS_CONF" "$cadangan"
        log_info "Daftar lama dicadangkan: $(basename "$cadangan")"
    fi
    {
        echo "# DIHASILKAN menu \"Survei jangkauan simpul\" pada $(date '+%Y-%m-%d %H:%M:%S')."
        echo "# Boleh disunting tangan; survei berikutnya akan menampilkan selisihnya"
        echo "# lebih dulu dan tidak menimpa tanpa persetujuan."
        echo "#"
        echo "# Tiap baris: <nama-host>  <ip-internal>"
        echo "# Alasan: jalur publik simpul ini tidak menjawab, jalur internal menjawab."
        echo "# Lihat extra-hosts.conf.example untuk latar belakang lengkapnya."
        echo "$diff_out" | grep '^#LIST#' | sed 's|^#LIST#||' | node -e '
            let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
                for (const [h,i] of JSON.parse(s)) console.log(h.padEnd(40) + i);
            });'
    } > "$EXTRA_HOSTS_CONF"
    log_ok "extra-hosts.conf ditulis ($(eh_jumlah) entri)."

    eh_terapkan
}

action_extra_hosts() {
    while :; do
        echo ""
        log_info "=== Daftar extra-hosts (simpul yang dipaksa ke alamat internal) ==="
        local n; n="$(eh_jumlah)"
        if [[ "$n" == "0" ]]; then
            log_info "Kosong — tidak ada simpul yang disematkan."
        else
            eh_baca | awk -F'|' '{ printf "  %-42s -> %s\n", $1, $2 }'
            echo "  ($n entri)"
            if [[ "${COMPOSE_FILE:-}" != *"docker-compose.extra-hosts.yml"* ]]; then
                log_warn "BELUM AKTIF — docker-compose.extra-hosts.yml tidak tercantum di COMPOSE_FILE."
            fi
        fi
        echo ""
        echo "  s) Survei ulang & perbarui daftar (1-3 menit)"
        echo "  t) Terapkan daftar sekarang (recreate app + harvester)"
        echo "  p) Periksa cepat daftar yang ada (beberapa detik)"
        echo "  0) Kembali"
        local p
        read -rp "Pilih: " p
        case "$p" in
            s|S) action_survei_jangkauan || true ;;
            t|T) eh_terapkan || true ;;
            p|P) "$SCRIPT_DIR/scripts/periksa-extra-hosts.sh" --verbose || true ;;
            0|"") return 0 ;;
            *) log_warn "Pilihan tidak dikenal." ;;
        esac
    done
}

# ── Rute proxy tambahan ─────────────────────────────────────────────────────
# Menempatkan aplikasi LAIN di sub-path domain yang sama, mis.
# https://<DOMAIN>/persetujuan-hln -> container portal-dgig:3000.
#
# KENAPA BUKAN DISUNTING LANGSUNG DI default.conf. Berkas itu DIHASILKAN
# deploy.sh dan ditulis ulang setiap kali APP_BASE_PATH berubah — suntingan
# tangan di dalamnya hilang tanpa peringatan. Terjadi nyata: blok
# /persetujuan-hln yang ditulis manual lenyap setelah satu kali deploy, dan
# portalnya mati diam-diam. Berkas di RUTE_DIR tidak pernah tersentuh
# regenerasi, dan di-include lewat wildcard yang aman walau kosong.
RUTE_DIR="$SCRIPT_DIR/nginx/snippets/rute-tambahan"

# Nama variabel nginx & nama berkas diturunkan dari path, bukan diminta
# terpisah — supaya tidak mungkin ada dua rute dgn nama berkas sama tapi path
# berbeda (atau sebaliknya).
rute_slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's|^/||; s|[^a-z0-9]|_|g; s|^_*||; s|_*$||'
}

rute_daftar_path() {
    [[ -d "$RUTE_DIR" ]] || return 0
    grep -h '^# path *: ' "$RUTE_DIR"/*.conf 2>/dev/null | sed 's|^# path *: ||'
}

# Path yang TIDAK boleh dipakai rute tambahan. Ditampilkan ke operator sebelum
# ia mengetik, bukan cuma dipakai menolak sesudahnya.
rute_path_terlarang() {
    echo "/"
    echo "/error.html"
    if [[ -n "${APP_BASE_PATH:-}" ]]; then
        echo "${APP_BASE_PATH}   (aplikasi ini)"
    else
        echo "/apis            (aplikasi ini)"
        echo "/_next           (aplikasi ini)"
        echo "/sample-csw.json (aplikasi ini)"
    fi
    local sudah
    while read -r sudah; do
        [[ -n "$sudah" ]] && echo "${sudah}   (sudah dipakai rute lain)"
    done < <(rute_daftar_path)
}

# Mengembalikan 0 kalau path BOLEH dipakai; kalau tidak, menjelaskan alasannya.
rute_path_valid() {
    local p="$1"
    if [[ ! "$p" =~ ^/[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]]; then
        log_error "Format salah — harus diawali '/', TANPA '/' di akhir, hanya huruf/angka/._~- mis. /persetujuan-hln"
        return 1
    fi
    if [[ -n "${APP_BASE_PATH:-}" && ( "$p" == "$APP_BASE_PATH" || "$p" == "$APP_BASE_PATH"/* ) ]]; then
        log_error "'$p' berada di dalam APP_BASE_PATH ('$APP_BASE_PATH') — itu milik aplikasi ini."
        return 1
    fi
    if [[ -z "${APP_BASE_PATH:-}" ]]; then
        # Dipasang di root: seluruh domain milik aplikasi ini KECUALI sub-path
        # yang dipesan rute tambahan. Yang dilarang cuma jalur internalnya.
        case "$p" in
            /apis|/apis/*|/_next|/_next/*|/sample-csw.json)
                log_error "'$p' dipakai internal oleh aplikasi ini."
                return 1 ;;
        esac
    fi
    local sudah
    while read -r sudah; do
        if [[ "$p" == "$sudah" || "$p" == "$sudah"/* || "$sudah" == "$p"/* ]]; then
            log_error "'$p' bertabrakan dgn rute yang sudah ada: '$sudah'"
            return 1
        fi
    done < <(rute_daftar_path)
    return 0
}

# Pastikan default.conf benar-benar meng-include folder rute.
#
# KENAPA PERLU DIPERIKSA TERPISAH. Baris include-nya ada di TEMPLATE, tapi
# default.conf hanya dihasilkan ulang kalau cap APP_BASE_PATH-nya berubah.
# Instalasi yang sudah berjalan karena itu TIDAK PERNAH menerima baris itu —
# dan tanpanya berkas rute tidak pernah dibaca nginx.
#
# Yang membuatnya berbahaya: `nginx -t` tetap LOLOS. Config-nya memang valid,
# cuma tidak memuat rutenya. Jadi menu ini melaporkan sukses, reload berhasil,
# dan rutenya tetap 404. Terjadi nyata pada pemakaian pertama fitur ini.
rute_pastikan_include() {
    local INC='    include /etc/nginx/snippets/rute-tambahan/*.conf;'

    if [[ ! -f "$NGINX_CONF" ]]; then
        return 0   # belum ada; nanti dihasilkan dari template yang sudah memuatnya
    fi
    if grep -q 'snippets/rute-tambahan' "$NGINX_CONF"; then
        return 0
    fi

    log_warn "nginx/conf.d/default.conf belum meng-include folder rute tambahan."
    log_warn "Tanpa baris itu, rute yang dibuat di sini TIDAK akan aktif — dan"
    log_warn "'nginx -t' tetap lolos, jadi kegagalannya tidak terlihat."
    confirm "Sisipkan baris include itu sekarang?" || return 1

    local cadangan
    cadangan="${NGINX_CONF}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$NGINX_CONF" "$cadangan"

    # Disisipkan tepat setelah server_name — baris itu pasti ada di setiap
    # config hasil template, dan posisinya di dalam blok server{} (syarat sah
    # bagi directive `set`/`location` yang dibawa berkas rute).
    #
    # awk, bukan sed: nilai server_name berbeda tiap instalasi dan replacement
    # multi-baris di sed butuh escaping yang mudah salah.
    awk -v ins="$INC" '
        { print }
        !sudah && $0 ~ /^[[:space:]]*server_name[[:space:]]/ {
            print ""
            print "    # Rute proxy tambahan (deploy.sh menu 22) - disisipkan otomatis."
            print ins
            sudah = 1
        }
    ' "$cadangan" > "$NGINX_CONF"

    if ! grep -q 'snippets/rute-tambahan' "$NGINX_CONF"; then
        cp "$cadangan" "$NGINX_CONF"
        log_error "Gagal menyisipkan (baris server_name tidak ketemu). Tambahkan manual di dalam blok server{}:"
        log_error "$INC"
        return 1
    fi
    if ! $COMPOSE_CMD exec -T nginx nginx -t; then
        cp "$cadangan" "$NGINX_CONF"
        log_error "nginx -t gagal setelah penyisipan — config DIKEMBALIKAN, tidak ada yang berubah."
        return 1
    fi
    $COMPOSE_CMD exec -T nginx nginx -s reload
    log_ok "Baris include disisipkan. Cadangan: $(basename "$cadangan")"
}

rute_list() {
    if [[ ! -d "$RUTE_DIR" ]] || ! ls "$RUTE_DIR"/*.conf >/dev/null 2>&1; then
        log_info "Belum ada rute proxy tambahan."
        return 0
    fi
    local f
    for f in "$RUTE_DIR"/*.conf; do
        printf '  %-28s -> %-28s (%s)\n' \
            "$(grep -m1 '^# path *: ' "$f" | sed 's|^# path *: ||')" \
            "$(grep -m1 '^# tujuan *: ' "$f" | sed 's|^# tujuan *: ||')" \
            "$(basename "$f")"
    done
}

rute_tambah() {
    echo ""
    log_info "Path yang TIDAK boleh dipakai:"
    rute_path_terlarang | sed 's|^|    |'
    echo ""

    local path svc port nextjs slug file inc
    read -rp "Path sub-path baru (mis. /persetujuan-hln): " path
    [[ -z "$path" ]] && { log_warn "Dibatalkan."; return 1; }
    rute_path_valid "$path" || return 1

    read -rp "Nama service/container tujuan (mis. portal-dgig): " svc
    [[ -z "$svc" ]] && { log_warn "Dibatalkan."; return 1; }
    read -rp "Port di dalam container tujuan [3000]: " port
    port="${port:-3000}"
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        log_error "Port '$port' bukan angka."
        return 1
    fi

    # Tujuan diuji DARI DALAM container nginx, bukan dari host — rute dan DNS
    # keduanya berbeda, dan nginx-lah yang nanti harus bisa menjangkaunya.
    local alamat
    alamat="$($COMPOSE_CMD exec -T nginx getent hosts "$svc" 2>/dev/null | awk '{print $1}' | sort -u)"
    if [[ -z "$alamat" ]]; then
        log_warn "nginx TIDAK bisa menyelesaikan nama '$svc' — kemungkinan besar container itu tidak berada di network yang sama."
        log_warn "Docker bisa menyambungkannya sekarang, TAPI sambungan itu HILANG begitu container tujuan dibuat ulang."
        log_warn "Perbaikan yang bertahan: deklarasikan network ini di docker-compose milik aplikasi tujuan."
        if confirm "Sambungkan container '$svc' ke network web sekarang (sementara)?"; then
            local net
            net="$($COMPOSE_CMD ps -q nginx | head -1 | xargs -r docker inspect \
                   -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' | grep -m1 '_web$')"
            if [[ -z "$net" ]]; then
                log_error "Network 'web' milik stack ini tidak ketemu."
                return 1
            fi
            docker network connect "$net" "$svc" 2>&1 | sed 's|^|    |' || true
            alamat="$($COMPOSE_CMD exec -T nginx getent hosts "$svc" 2>/dev/null | awk '{print $1}' | sort -u)"
        fi
    fi
    if [[ -z "$alamat" ]]; then
        log_error "'$svc' tetap tidak bisa dijangkau nginx — rute dibatalkan (config yang menunjuk nama mati akan membuat nginx gagal saat request)."
        return 1
    fi

    # Peringatan tabrakan nama — pelajaran mahal dari lapangan: nama service
    # hanya unik DI DALAM satu proyek compose. Kalau network dipakai bersama,
    # satu nama bisa menunjuk beberapa container dan DNS menjawab bergantian,
    # sehingga rute ini akan "kadang benar kadang salah" tanpa jejak di log.
    local jumlah
    jumlah="$(printf '%s\n' "$alamat" | grep -c .)"
    if [[ "$jumlah" -gt 1 ]]; then
        log_warn "Nama '$svc' menunjuk $jumlah alamat: $(printf '%s ' $alamat)"
        log_warn "Kalau itu BUKAN replica dari satu service yang sama, rute ini akan sesekali mendarat di container yang salah."
        confirm "Tetap lanjutkan?" || return 1
    else
        log_ok "nginx bisa menjangkau '$svc' di $alamat."
    fi

    read -rp "Tujuan adalah aplikasi Next.js (punya /_next/static)? [y/N] " nextjs

    slug="$(rute_slug "$path")"
    file="$RUTE_DIR/$slug.conf"
    if [[ -e "$file" ]]; then
        log_error "Berkas $file sudah ada."
        return 1
    fi
    inc="/etc/nginx/snippets/proxy-common.conf"
    [[ "${BEHIND_WAF:-false}" == "true" ]] && inc="/etc/nginx/snippets/proxy-common-waf.conf"

    mkdir -p "$RUTE_DIR"
    {
        echo "# DIHASILKAN deploy.sh — menu \"Rute proxy tambahan\". Jangan disunting"
        echo "# tangan: tambah/hapus lewat menu itu supaya validasi path ikut jalan."
        echo "# path   : $path"
        echo "# tujuan : $svc:$port"
        echo "# dibuat : $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "set \$rute_$slug http://$svc:$port;"
        echo ""
        echo "# Blok exact WAJIB terpisah: 'location $path/' (dgn garis miring) TIDAK"
        echo "# cocok dgn request ke '$path' polos — dan pada aplikasi Next.js"
        echo "# ber-basePath, justru itulah URL kanoniknya."
        echo "location = $path {"
        echo "    proxy_pass \$rute_$slug\$request_uri;"
        echo "    include $inc;"
        echo "}"
        echo ""
        if [[ "$nextjs" =~ ^[Yy]$ ]]; then
            echo "# Aset build Next.js — ber-hash, aman di-cache lama. Kunci cache diberi"
            echo "# awalan literal karena zona 'static_cache' dipakai bersama semua rute."
            echo "location ^~ $path/_next/static/ {"
            echo "    proxy_pass \$rute_$slug\$request_uri;"
            echo "    include $inc;"
            echo "    proxy_cache static_cache;"
            echo "    proxy_cache_key \"${slug}\$request_uri\";"
            echo "    proxy_cache_valid 200 30d;"
            echo "    proxy_cache_lock on;"
            echo "    add_header X-Nginx-Cache \$upstream_cache_status always;"
            echo "}"
            echo ""
        fi
        echo "# Prefiks BERGARIS-MIRING, sengaja: '$path' polos tanpa garis miring juga"
        echo "# akan menangkap '${path}abc' dan path lain yang kebetulan berawalan sama."
        echo "location ^~ $path/ {"
        echo "    proxy_pass \$rute_$slug\$request_uri;"
        echo "    include $inc;"
        echo "}"
    } > "$file"

    log_info "Menguji konfigurasi nginx..."
    if ! $COMPOSE_CMD exec -T nginx nginx -t; then
        rm -f "$file"
        log_error "Config baru TIDAK valid — berkas rute dihapus lagi, nginx tidak disentuh."
        return 1
    fi
    $COMPOSE_CMD exec -T nginx nginx -s reload
    log_ok "Rute $path -> $svc:$port aktif. Berkas: nginx/snippets/rute-tambahan/$slug.conf"
}

rute_hapus() {
    if ! rute_list; then return 1; fi
    if [[ ! -d "$RUTE_DIR" ]] || ! ls "$RUTE_DIR"/*.conf >/dev/null 2>&1; then
        return 0
    fi
    local path file cadangan
    read -rp "Path yang mau dihapus (persis seperti daftar di atas): " path
    [[ -z "$path" ]] && { log_warn "Dibatalkan."; return 1; }
    file="$RUTE_DIR/$(rute_slug "$path").conf"
    if [[ ! -f "$file" ]]; then
        log_error "Rute '$path' tidak ditemukan."
        return 1
    fi
    confirm "Hapus rute '$path'?" || return 1

    # Dicadangkan, bukan dihapus langsung — kalau ternyata salah hapus, isinya
    # masih bisa dikembalikan tanpa mengetik ulang.
    cadangan="$file.dihapus-$(date +%Y%m%d-%H%M%S)"
    mv "$file" "$cadangan"
    if ! $COMPOSE_CMD exec -T nginx nginx -t; then
        mv "$cadangan" "$file"
        log_error "nginx -t gagal setelah penghapusan — rute DIKEMBALIKAN, tidak ada yang berubah."
        return 1
    fi
    $COMPOSE_CMD exec -T nginx nginx -s reload
    log_ok "Rute '$path' dihapus. Cadangan: $(basename "$cadangan")"
}

action_rute_tambahan() {
    # Diperiksa SEKALI di depan, sebelum operator sempat membuat rute yang
    # tidak akan pernah aktif.
    rute_pastikan_include || log_warn "Rute yang dibuat mungkin belum aktif sampai baris include itu ada."
    while :; do
        echo ""
        log_info "=== Rute proxy tambahan (aplikasi lain di sub-path domain ini) ==="
        rute_list
        echo ""
        echo "  a) Tambah rute"
        echo "  h) Hapus rute"
        echo "  0) Kembali"
        local p
        read -rp "Pilih: " p
        case "$p" in
            a|A) rute_tambah || true ;;
            h|H) rute_hapus  || true ;;
            0|"") return 0 ;;
            *) log_warn "Pilihan tidak dikenal." ;;
        esac
    done
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
        echo "9)  Bersihkan image lama (versi lama aplikasi + image tanpa tag)"
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
        echo "20) Deploy APP SAJA (tanpa harvester — pakai harvester pihak lain)"
        echo "21) Hentikan harvester + tumpukan datanya (app tetap jalan)"
        echo "22) Rute proxy tambahan (pasang aplikasi lain di sub-path domain ini)"
        echo "23) Jangkauan simpul (daftar extra-hosts: survei, terapkan, periksa)"
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
            9) check_env && action_prune ;;
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
            20) check_env && action_deploy_app_only ;;
            21) check_env && action_down_harvester ;;
            22) check_env && action_rute_tambahan ;;
            23) check_env && action_extra_hosts ;;
            0) exit 0 ;;
            *) log_warn "Pilihan tidak valid." ;;
        esac
    done
}

main_menu
