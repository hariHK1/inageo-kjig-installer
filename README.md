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
2) Deploy (pull + up -d)      # pertama kali — migrasi DB otomatis jalan setelahnya
15) Seed awal simpul_jaringan  # sekali, isi awal daftar simpul
```

Menu 14 ("Migrasi database harvester") tetap ada sebagai fallback manual — dipakai kalau migrasi otomatis gagal (mis. postgres belum siap benar saat instalasi pertama, lihat log warning-nya).

## Upgrade / rollback

`./deploy.sh` → **3) Ganti versi** — isi versi baru (upgrade) atau versi lama (rollback). Cuma container `app` dan `harvester` yang di-recreate; `postgres`/`redis`/`redis-queue`/`nginx`/`certbot` tidak disentuh (data & TLS aman). Migrasi database harvester ikut jalan otomatis setelahnya (idempotent — aman dijalankan walau tidak ada migration baru).

## Port kustom

Semua lewat `.env`, tidak perlu edit `docker-compose.yml`:

- `HTTP_PORT`/`HTTPS_PORT` — port publik nginx (default 80/443).
- `POSTGRES_HOST_PORT`, `REDIS_HOST_PORT`, `REDIS_QUEUE_HOST_PORT`, `MAPPROXY_HOST_PORT` — **opsional**, kosong (default) = service itu TIDAK bisa diakses dari luar Docker sama sekali (postur aman default, cocok produksi). Isi + set `COMPOSE_FILE=docker-compose.yml:docker-compose.ports.yml` (dilakukan otomatis oleh `install.sh` kalau kamu jawab "ya" saat ditanya) untuk expose ke host — berguna buat debug langsung (`psql`, `redis-cli`) tanpa lewat proxy app. **Tidak disarankan untuk server produksi yang publik.**
- `APP_DIRECT_PORT` & `HARVESTER_HOST_PORT` — sama kegunaannya (akses langsung/debug, mis. curl API harvester) tapi **overlay-nya masing-masing terpisah sendiri** (`docker-compose.app-port.yml` & `docker-compose.harvester-port.yml`, bukan `docker-compose.ports.yml`) — keduanya cuma bisa dipakai kalau service-nya berjalan **1 replica** (`APP_REPLICAS=1` / `HARVESTER_REPLICAS=1`, banyak replica tidak bisa berbagi satu port host yang sama). Kalau diisi, `COMPOSE_FILE` butuh overlay tambahan yang sesuai (`install.sh` menambahkannya otomatis, atau tambahkan manual kalau diisi belakangan). File-file ini sengaja dipisah dari `docker-compose.ports.yml` supaya nilai kosong benar-benar berarti "tidak ter-expose" — pernah ada bug nyata (dua kali, app lalu harvester) di mana port digabung satu file dengan fallback default, sehingga var kosong tetap ter-publish ke port default dan bikin replica ke-2 dst rebutan port host yang sama, gagal start.

## DNS (opsional, workaround jalur relay Docker)

Kalau container `app`/`harvester` mengalami gagal resolusi DNS intermiten (log `EAI_AGAIN`) padahal server sendiri terhubung internet normal, biasanya itu bug jalur relay DNS bawaan Docker (`127.0.0.11` di container → stub `systemd-resolved` `127.0.0.53` di host), **bukan** DNS server jaringan kamu yang rusak — ciri khasnya: query langsung ke DNS server itu (tanpa lewat Docker) selalu sukses, tapi lewat container selalu/sering gagal.

Isi `DNS_PRIMARY` (dan opsional `DNS_FALLBACK`, default `1.1.1.1`) di `.env` untuk membuat container query LANGSUNG ke DNS server, bypass jalur relay itu (`docker-compose.dns.yml`, sama pola dengan overlay port di atas — `install.sh` menambahkannya otomatis ke `COMPOSE_FILE` kalau `DNS_PRIMARY` diisi lewat wizard). `DNS_PRIMARY` sengaja tetap DNS server jaringan kamu sendiri (bukan diganti DNS publik) — sejumlah domain instansi (`big.go.id`, `ina-sdi.or.id`) resolve ke IP privat lewat resolver internal, DNS publik belum tentu punya jawaban yang sama.

## Menjalankan APP tanpa harvester (harvester dikelola pihak lain)

Dipakai kalau harvester di server ini diturunkan dan perannya diambil alih pihak lain — stack compose terpisah di server yang sama, atau host lain.

**`./deploy.sh` → 20) Deploy APP SAJA** menyalakan `nginx`, `app`, `redis`, `mapproxy`, `minio`, `minio-init` (+`certbot` kalau bukan mode WAF). Harvester dan tumpukan datanya (postgres, redis-queue, elasticsearch, postgres-backup, docker-socket-proxy) tidak disentuh sama sekali.

> **Ketiga service pendukung itu WAJIB ikut.** `app` bukan frontend statis: ia merender thumbnail peta (`sharp`) lalu menyimpannya ke MinIO, mem-proxy WMS/ArcGIS dengan cache Redis, dan menyajikan tile lewat MapProxy. Melepasnya bukan "meringankan" — itu mematikan fitur.

Sebelum menyalakan apa pun, menu ini **memverifikasi `.env` lebih dulu**: menampilkan `API_BACKEND` dan `API_ACCESS_TOKEN`, lalu menanyakan apakah sudah sesuai. Jawab **Tidak** dan Anda bisa langsung mengubahnya di situ (kosongkan input = pertahankan nilai lama), lalu nilainya ditampilkan ulang untuk dicek.

`API_ACCESS_TOKEN` **tidak pernah dicetak utuh** — ditampilkan tersamar plus **sidik jari** (8 hex pertama SHA-256). Sidik jari itulah alat pencocokannya dengan pengelola harvester tujuan: kedua pihak cukup membandingkan hash, tidak ada yang perlu menyebutkan tokennya.

Yang perlu disiapkan:

- **`API_BACKEND`** diisi alamat harvester tujuan. Kalau harvester itu container di server yang sama, ia **wajib ikut bergabung ke salah satu network stack ini** agar bisa dipanggil lewat nama service (mis. `http://harvester-mitra:4000`). Kalau di host lain, isi URL penuhnya.
- **`API_ACCESS_TOKEN`** harus **sama persis** dengan milik harvester tujuan — harvester menolak semua permintaan yang tokennya tidak cocok.

**`./deploy.sh` → 21) Hentikan harvester + tumpukan datanya** mematikan harvester dkk tanpa mengganggu `app` yang sedang melayani. Memakai `stop`, **bukan** `down` — volume data (`postgres_data`, `es_data`) tidak disentuh, jadi bisa dinyalakan lagi kapan pun lewat menu 2.

### Akibat yang perlu diketahui

Halaman admin **Kesehatan Sistem** dan **Skema Infrastruktur** mengambil datanya dari harvester. Begitu harvester berpindah, isinya mencerminkan apa yang dilaporkan harvester tersebut — status container & disk boleh jadi masih tepat (kalau satu server), tapi Skema Infrastruktur dibaca dari berkas compose **milik mereka**, jadi yang tampil layanan mereka.

Karena itu `deploy.sh` menyetel `HARVESTER_EXTERNAL=true` otomatis di menu 20 (dan mengembalikannya ke `false` di menu 2), yang membuat kedua halaman itu menampilkan keterangan asal data. Datanya sengaja **tidak disembunyikan** — sebagian masih berguna; yang berbahaya adalah menyajikannya tanpa keterangan seolah kondisi server ini sendiri.

## Object storage (MinIO) & cache thumbnail katalog

Service `minio` menyimpan **gambar pratinjau (thumbnail) katalog** yang sudah jadi, plus dokumen hasil harvest. Tanpa ini, peta berat (mis. batas desa se-Indonesia) harus digambar ulang oleh server instansi setiap kali ada pengunjung membuka katalog — lambat, dan berisiko membuat kita diblokir server sumber. Dengan cache ini, tiap layer digambar **sekali**.

- **Tidak diekspos sama sekali** — tanpa `ports:`, hanya di network `cache` (`internal: true`). Konsol admin MinIO (`:9001`) juga tidak dibuka; kelola lewat `docker compose exec` kalau perlu.
- **Kredensial otomatis.** Instalasi baru: digenerate `install.sh`. Instalasi lama: dilengkapi otomatis oleh `deploy.sh` (`ensure_minio_credentials`) saat deploy berikutnya — **tidak perlu** menjalankan ulang `install.sh` (yang akan menimpa seluruh `.env`). Nilai yang sudah diisi operator tidak pernah ditimpa, jadi aman kalau kamu menunjuk ke S3/MinIO eksternal lewat `MINIO_ENDPOINT`.
- **Bucket & masa berlaku** disiapkan service one-shot `minio-init` tiap `up -d` (idempoten): bucket `THUMBNAIL_BUCKET` (default `catalog-thumbnails`) + aturan kedaluwarsa `THUMBNAIL_TTL_DAYS` (default 30 hari).
- **Kenapa ada masa berlaku?** Nama file thumbnail diturunkan dari isi metadata (bbox + layer + URL layanan), jadi perubahan metadata otomatis memicu gambar ulang. Yang **tidak** terdeteksi begitu: instansi mengubah *isi* petanya tanpa menyentuh metadata. Batas umur ini jaring pengamannya. Kalau perlu segera, ada tombol **"Bersihkan cache thumbnail"** di `/admin/kesehatan-sistem` (khusus Superadmin).
- **Kalau MinIO mati/tidak dikonfigurasi**, thumbnail **tetap tampil** — cuma digambar langsung tiap kali dan tidak disimpan. Cache tidak pernah menjadi jalur gagal.
- Verifikasi: `docker compose exec minio mc ilm rule ls local/catalog-thumbnails` harus menampilkan aturan kedaluwarsa.

> `ALLOWED_BUCKETS` (allowlist untuk `/apis/file`, preview dokumen) **jangan** diisi bucket thumbnail — endpoint itu menerima nama berkas dari browser, sedangkan bucket thumbnail dilayani endpoint tersendiri yang tidak pernah begitu.

## Observability & backup (Fase 0)

- **Backup Postgres otomatis** — service `postgres-backup` menjalankan `pg_dump -F c` (format custom, mendukung restore parsial) tiap `POSTGRES_BACKUP_INTERVAL_SECONDS` (default 86400 = 24 jam) ke volume `postgres_backups`, retensi `POSTGRES_BACKUP_RETENTION_DAYS` (default 14 hari) dihapus otomatis. Restore manual: `docker compose exec postgres-backup sh -c 'pg_restore -h postgres -U $POSTGRES_USER -d $POSTGRES_DB -c /backups/harvester-<timestamp>.dump'`.
- **GlitchTip** (error-tracking, kompatibel SDK Sentry) & **Uptime Kuma** (uptime monitoring) — self-hosted, dashboard NATIVE keduanya **tidak diekspos publik sama sekali** (tidak ada port terpisah lagi, lihat § Lockdown port di bawah). Ringkasannya tampil di dashboard admin app: `https://<DOMAIN>/admin/kesehatan-sistem` (khusus akun role **Superadmin**, lihat repo source untuk sistem role) — halaman ini bicara ke GlitchTip/Uptime Kuma lewat API internal (harvester), bukan proxy nginx.
- **Setup awal wajib manual** (token API belum bisa diisi wizard `install.sh` — baru ada setelah kedua tool ini pernah dibuka pertama kali): buka dashboard native masing-masing sementara lewat SSH port-forward (mis. `ssh -L 8000:localhost:8000 user@server` untuk GlitchTip, ganti port sesuai `docker compose port glitchtip 8000` / `docker compose port uptime-kuma 3001`) atau `docker compose exec`, bikin akun+organisasi (GlitchTip) atau akun admin (Uptime Kuma), lalu:
  - GlitchTip → Profile → Auth Tokens → generate token (scope read-only cukup) → isi `GLITCHTIP_API_TOKEN` & `GLITCHTIP_ORG_SLUG` di `.env`.
  - Uptime Kuma → Settings → API Keys → generate → isi `UPTIME_KUMA_METRICS_PASSWORD` (username boleh apa saja) di `.env`.
  - `docker compose up -d harvester` (env baru saja, tidak perlu rebuild) — widget di `/admin/kesehatan-sistem` otomatis terisi begitu sampler pertama jalan (~1 menit).
  - Sekalian bikin project GlitchTip untuk `SENTRY_DSN`/`HARVESTER_SENTRY_DSN` kalau mau error-tracking SDK aktif juga.
- `install.sh` men-generate semua password/secret terkait (`GLITCHTIP_DB_PASSWORD`, `GLITCHTIP_VALKEY_PASSWORD`, `GLITCHTIP_SECRET_KEY`) otomatis saat instalasi pertama kali maupun saat upgrade dari `.env` versi lama (menu `patch_missing_env`).
- **Skema Teknologi & Kesehatan Sistem dinamis** — resource limit/port di halaman `/admin/infrastruktur` dan status hidup-mati/CPU/RAM container di `/admin/kesehatan-sistem` ditarik LIVE dari `docker-compose.yml` sungguhan + service `docker-socket-proxy` (read-only, scope dibatasi ketat — cuma baca daftar+statistik container, TIDAK BISA start/stop/exec apa pun). `harvester` yang query keduanya, bukan mengakses `docker.sock` langsung.

## Lockdown port (hanya :80 yang terbuka ke luar)

Server ini didesain untuk berjalan **di belakang WAF/load-balancer** yang menangani HTTPS (`BEHIND_WAF=true`) — nginx di sini cukup dengar `:80` polos, WAF di depan yang teruskan trafik. Kalau `BEHIND_WAF=false` (mode Let's Encrypt langsung, nginx sendiri urus TLS), `install.sh` otomatis menambahkan overlay `docker-compose.https-port.yml` supaya `:443` ikut terbuka — TIDAK terjadi kalau `BEHIND_WAF=true`.

Port lain (Postgres/Redis/MapProxy/harvester/Elasticsearch, lihat § Port kustom di atas) **default tertutup** dan cuma dibuka kalau operator eksplisit mengaktifkannya — cocok untuk debug lokal saja, jangan diaktifkan di produksi publik.

`./deploy.sh` → **19) Cek port yang listening di host** memberi cek cepat LOKAL (`ss`/`netstat`) begitu deploy selesai. Ini bukan pengganti verifikasi sesungguhnya — tetap wajib cek dari **LUAR** server (`nmap`/`curl` dari device lain) supaya firewall/security-group cloud di depan server ikut teruji, bukan cuma binding Docker di host ini.

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
