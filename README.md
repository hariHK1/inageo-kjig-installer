# inageo-kjig-installer

Repo operasional untuk deploy [inageo-mapviewer](https://github.com/hariHK1/inageo-mapviewer) via Docker Compose. **Repo ini tidak berisi source code aplikasi sama sekali** — image `app` dan `harvester` dibangun & di-tag versi oleh GitHub Actions di repo source, lalu di-publish ke GHCR (`ghcr.io`). Server produksi cukup clone repo kecil ini dan `docker compose pull`.

## Alur rilis (dari repo source)

1. Bump versi di `package.json` (repo source), commit.
2. `git tag vX.Y.Z && git push --tags` — harus **persis** sama dengan versi `package.json` (workflow menolak kalau beda).
3. GitHub Actions (`.github/workflows/release.yml`) build image `app` & `harvester`, push ke `ghcr.io/<owner>/inageo-mapviewer-app:vX.Y.Z` dan `...-harvester:vX.Y.Z`, buat GitHub Release.
4. Di server: `deploy.sh` → menu **3) Ganti versi** (atau isi `RELEASE_VERSION` di `.env` lalu **1) Pull**).

### Sekali sebelum rilis pertama: set GitHub Actions repo Variables

`NEXT_PUBLIC_*` (origin publik, sumber data harvest, basemap) di-bake ke bundle JS **saat build**, bukan bisa diubah lagi oleh installer ini setelahnya. Di repo source: **Settings → Secrets and variables → Actions → Variables**, isi:

- `NEXT_PUBLIC_APP_ORIGIN` (mis. `https://mapviewer.instansi.go.id`)
- `NEXT_PUBLIC_DATA_SOURCE` (`backend` untuk pakai harvester, `sample` untuk baca `sample-csw.json` statis)
- `NEXT_PUBLIC_RBI_URL`, `NEXT_PUBLIC_GRAY_URL(_ATTR)`, `NEXT_PUBLIC_SATELLITE_URL(_ATTR)`, `NEXT_PUBLIC_TOPO_URL(_ATTR)` (opsional, basemap kustom)

Kosong = build tetap jalan, tapi pakai default kosong (basemap publik bawaan RBI/ArcGIS Online). **Kalau butuh beberapa domain dengan origin/basemap berbeda, itu di luar cakupan model "satu image, banyak deployment" ini** — perlu rilis terpisah per environment (repo Variables beda, atau branch/workflow terpisah).

## Pemasangan pertama kali di server

```bash
git clone https://github.com/hariHK1/inageo-kjig-installer.git
cd inageo-kjig-installer
./install.sh
```

Wizard akan menanyakan: kredensial GHCR (buat Personal Access Token **baru**, scope `read:packages` saja — jangan reuse token lama), versi rilis, domain/TLS, jumlah replica, port, dan men-generate semua password (Postgres/Redis/Redis-queue/API_ACCESS_TOKEN) otomatis.

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
- `POSTGRES_HOST_PORT`, `REDIS_HOST_PORT`, `REDIS_QUEUE_HOST_PORT`, `HARVESTER_HOST_PORT`, `MAPPROXY_HOST_PORT`, `APP_DIRECT_PORT` — **opsional**, kosong (default) = service itu TIDAK bisa diakses dari luar Docker sama sekali (postur aman default, cocok produksi). Isi + set `COMPOSE_FILE=docker-compose.yml:docker-compose.ports.yml` (dilakukan otomatis oleh `install.sh` kalau kamu jawab "ya" saat ditanya) untuk expose ke host — berguna buat debug langsung (`psql`, `redis-cli`, curl API harvester) tanpa lewat proxy app. **Tidak disarankan untuk server produksi yang publik.**
- `APP_DIRECT_PORT` cuma bisa dipakai kalau `APP_REPLICAS=1` (banyak replica tidak bisa berbagi satu port host).

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
