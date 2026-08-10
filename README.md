# inageo-kjig-installer

Repo operasional untuk deploy [inageo-kjig](https://github.com/hariHK1/inageo-kjig) (nama kode `inageo-mapviewer`) via Docker Compose. **Repo ini tidak berisi source code aplikasi sama sekali** — image `app` dan `harvester` dibangun & di-tag versi oleh GitHub Actions di repo source, lalu di-publish ke GHCR (`ghcr.io`). Server produksi cukup clone repo kecil ini, lalu ambil image dengan salah satu dari **dua cara**:

- **Pull langsung dari GHCR** (`PULL_MODE=true` di `.env`) — server butuh akses internet ke `ghcr.io`. Kredensial (username + PAT scope `read:packages`) **tidak pernah disimpan di `.env`** — `deploy.sh` menanyakannya interaktif setiap kali `docker login` dibutuhkan (menu **1) Pull** / **3) Ganti versi**), input token disembunyikan di terminal dan tidak ditulis ke disk. Ini sengaja: server sering diakses banyak dev lewat SSH/shared account, dan `.env` gampang terbaca siapa pun yang punya akses baca file — token yang disimpan di sana bocor ke semua orang itu. Buat Personal Access Token **baru** khusus ini (GitHub → Settings → Developer settings → Personal access tokens → Fine-grained, scope minimal `read:packages`) — jangan reuse token yang pernah ter-expose di tempat lain (chat, commit, dsb), anggap token begitu selalu sudah bocor.
- **Load dari bundle tar.gz** (`PULL_MODE=false` di `.env`) — untuk server **tanpa akses internet ke ghcr.io** (mis. jaringan internal tertutup), tidak pernah butuh `docker login`. Setiap rilis, workflow yang sama juga `docker save` kedua image jadi satu `.tar.gz` dan melampirkannya sebagai asset di halaman GitHub Release repo source. Download manual di mesin yang punya internet, transfer ke server ini (scp/rsync/USB), lalu `./deploy.sh` → menu **16) Load image dari bundle**. **`GHCR_OWNER`/`GHCR_REPO` tetap wajib diisi di kedua mode** (dipakai membentuk nama image yang dicari `docker compose`, harus sama persis dengan owner/nama repo GitHub source — cek lewat `git remote -v` di repo source kalau ragu).

## Alur rilis (dari repo source)

1. Bump versi di `package.json` (repo source), commit.
2. `git tag vX.Y.Z && git push --tags` — harus **persis** sama dengan versi `package.json` (workflow menolak kalau beda).
3. GitHub Actions (`.github/workflows/release.yml`) build image `app` & `harvester`, push ke `ghcr.io/<owner>/<repo>-app:vX.Y.Z` dan `...-harvester:vX.Y.Z`, bundle keduanya jadi `<repo>-vX.Y.Z.tar.gz`, buat GitHub Release dengan tar.gz itu terlampir.
4. Di server (pilih salah satu):
   - Ada akses ghcr.io: `deploy.sh` → menu **3) Ganti versi** (atau isi `RELEASE_VERSION` di `.env` lalu **1) Pull**).
   - Tanpa akses ghcr.io: download `<repo>-vX.Y.Z.tar.gz` dari halaman Release, transfer ke server, `deploy.sh` → menu **16) Load image dari bundle**, baru samakan `RELEASE_VERSION` di `.env` dengan tag itu.

### Config publik app (origin, sumber data, basemap) — sepenuhnya di `.env`, bukan repo Variables

Beda dari asumsi awal: `APP_ORIGIN`, `DATA_SOURCE`, dan basemap (`RBI_URL` dkk) **tidak** di-bake ke image saat build — image `app` benar-benar environment-agnostic, satu image yang sama dipakai untuk domain/basemap/sumber-data apa pun. Semua nilainya dibaca **runtime** langsung dari `.env` installer ini (`src/lib/runtimeConfig.ts` di repo source, disuntik server-side tiap request). Artinya:

- **Tidak perlu** set apa pun di GitHub Actions repo Variables untuk ini.
- Ganti nilai kapan pun di `.env`, cukup `docker compose up -d app` (bukan pull/rilis baru) — perubahan langsung terlihat.
- Beberapa deployment (dev/staging/prod) dengan origin/basemap berbeda **bisa pakai image yang sama persis**, tinggal `.env` masing-masing beda.

## Pemasangan pertama kali di server

```bash
git clone https://github.com/hariHK1/inageo-kjig-installer.git
cd inageo-kjig-installer
./install.sh
```

Wizard akan tanya dulu mode ambil image (pull GHCR vs bundle — lihat di atas; kredensial GHCR-nya sendiri **tidak** ditanya di sini, baru diminta interaktif oleh `deploy.sh` saat benar-benar dibutuhkan), lalu versi rilis, domain/TLS, jumlah replica, port, sumber data harvest & basemap kustom (opsional, runtime), backup Postgres & dashboard ops (GlitchTip/Uptime Kuma, lihat [Observability & backup](#observability--backup-fase-0)), dan men-generate semua password (Postgres/Redis/Redis-queue/API_ACCESS_TOKEN/GlitchTip/basic-auth ops) otomatis.

Untuk server internal/dev tanpa domain publik (mis. IP `192.168.x.x`), jawab "ya" di pertanyaan "di belakang WAF, atau internal/dev tanpa TLS?" — nginx akan jalan HTTP polos tanpa certbot.

Setelah wizard selesai, lanjut ke `./deploy.sh`:

```
2) Deploy (pull + up -d)      # pertama kali
14) Migrasi database harvester # sekali, setelah postgres jalan
15) Seed awal simpul_jaringan  # sekali, isi awal daftar simpul
```

## Upgrade / rollback

`./deploy.sh` → **3) Ganti versi** — isi versi baru (upgrade) atau versi lama (rollback). Cuma container `app` dan `harvester` yang di-recreate; `postgres`/`redis`/`redis-queue`/`nginx`/`certbot` tidak disentuh (data & TLS aman).

## Port kustom

Semua lewat `.env`, tidak perlu edit `docker-compose.yml`:

- `HTTP_PORT`/`HTTPS_PORT` — port publik nginx (default 80/443).
- `POSTGRES_HOST_PORT`, `REDIS_HOST_PORT`, `REDIS_QUEUE_HOST_PORT`, `MAPPROXY_HOST_PORT` — **opsional**, kosong (default) = service itu TIDAK bisa diakses dari luar Docker sama sekali (postur aman default, cocok produksi). Isi + set `COMPOSE_FILE=docker-compose.yml:docker-compose.ports.yml` (dilakukan otomatis oleh `install.sh` kalau kamu jawab "ya" saat ditanya) untuk expose ke host — berguna buat debug langsung (`psql`, `redis-cli`) tanpa lewat proxy app. **Tidak disarankan untuk server produksi yang publik.**
- `APP_DIRECT_PORT` & `HARVESTER_HOST_PORT` — sama kegunaannya (akses langsung/debug, mis. curl API harvester) tapi **overlay-nya masing-masing terpisah sendiri** (`docker-compose.app-port.yml` & `docker-compose.harvester-port.yml`, bukan `docker-compose.ports.yml`) — keduanya cuma bisa dipakai kalau service-nya berjalan **1 replica** (`APP_REPLICAS=1` / `HARVESTER_REPLICAS=1`, banyak replica tidak bisa berbagi satu port host yang sama). Kalau diisi, `COMPOSE_FILE` butuh overlay tambahan yang sesuai (`install.sh` menambahkannya otomatis, atau tambahkan manual kalau diisi belakangan). File-file ini sengaja dipisah dari `docker-compose.ports.yml` supaya nilai kosong benar-benar berarti "tidak ter-expose" — pernah ada bug nyata (dua kali, app lalu harvester) di mana port digabung satu file dengan fallback default, sehingga var kosong tetap ter-publish ke port default dan bikin replica ke-2 dst rebutan port host yang sama, gagal start.

## Observability & backup (Fase 0)

- **Backup Postgres otomatis** — service `postgres-backup` menjalankan `pg_dump -F c` (format custom, mendukung restore parsial) tiap `POSTGRES_BACKUP_INTERVAL_SECONDS` (default 86400 = 24 jam) ke volume `postgres_backups`, retensi `POSTGRES_BACKUP_RETENTION_DAYS` (default 14 hari) dihapus otomatis. Restore manual: `docker compose exec postgres-backup sh -c 'pg_restore -h postgres -U $POSTGRES_USER -d $POSTGRES_DB -c /backups/harvester-<timestamp>.dump'`.
- **GlitchTip** (`https://<DOMAIN>:8443`) — error-tracking self-hosted, kompatibel SDK Sentry. `SENTRY_DSN`/`HARVESTER_SENTRY_DSN` di `.env` kosong secara default (SDK no-op, aplikasi tetap jalan normal) — isi setelah login pertama kali ke dashboard dan bikin akun+project lewat UI-nya sendiri.
- **Uptime Kuma** (`https://<DOMAIN>:8444`) — uptime monitoring self-hosted, konfigurasi monitor dilakukan lewat UI setelah login pertama kali.
- Kedua dashboard **hanya** bisa diakses lewat port terpisah (:8443/:8444), **tidak pernah** di path publik `:443`, dan dilindungi HTTP Basic Auth tambahan (`OPS_BASIC_AUTH_USER`/`OPS_BASIC_AUTH_PASSWORD` di `.env`, wajib diisi — `deploy.sh` men-generate `nginx/ops.htpasswd` dari dua nilai ini tiap deploy). Login basic-auth ini lapisan tambahan di depan, GlitchTip & Uptime Kuma tetap punya sistem login sendiri di baliknya.
- `install.sh` men-generate semua password/secret terkait (`GLITCHTIP_DB_PASSWORD`, `GLITCHTIP_VALKEY_PASSWORD`, `GLITCHTIP_SECRET_KEY`, `OPS_BASIC_AUTH_PASSWORD`) otomatis saat instalasi pertama kali maupun saat upgrade dari `.env` versi lama (menu `patch_missing_env`).

## Gap yang diketahui: sinkronisasi config MapProxy

`mapproxy/mapproxy.yaml` **tidak** di-generate di repo ini (butuh `scripts/generate-mapproxy-config.mjs` + app hidup, ada di repo source). Kalau MapProxy dipakai: jalankan sync-nya dari repo source (`./deploy.sh` → menu "Sync config MapProxy" di sana), lalu salin hasil `mapproxy/mapproxy.yaml` ke server ini secara manual (scp). Tanpa file ini, service `mapproxy` tidak akan bisa start — kalau tidak dipakai, hapus/comment service `mapproxy` di `docker-compose.yml`.

## Struktur

```
docker-compose.yml         # stack utama, semua image di-pull (tanpa build:)
docker-compose.ports.yml   # overlay opsional, expose port infra/app ke host
.env.example                # template konfigurasi (copy ke .env)
install.sh                  # wizard setup awal
deploy.sh                   # menu operasional (pull/deploy/upgrade/logs/dst)
nginx/                      # template config (disalin apa adanya dari repo source)
certbot/, mapproxy/         # direktori state runtime (kosong di git)
```
