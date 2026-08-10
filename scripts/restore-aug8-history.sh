#!/usr/bin/env bash
# Pasangan backup-aug8-history.sh — jalankan SETELAH stack baru di-deploy,
# migrasi (menu 14 deploy.sh), DAN seed simpul_jaringan (menu 15 deploy.sh)
# SUDAH selesai. Urutan ini wajib: csw_records/harvest_runs punya foreign key
# ke simpul_jaringan.uuid — kalau diimpor sebelum seed, gagal FK violation.
#
# Aman dijalankan ulang (idempoten) SELAMA tabel tujuan masih kosong (baru
# fresh migrate) — kalau sudah pernah diisi run harvest sungguhan, \copy bisa
# bentrok primary key/unique constraint. Untuk kasus normal (restore sekali
# tepat setelah reset), ini bukan masalah.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

HISTORY_DATE="${1:-2026-08-08}"
IN_DIR="$SCRIPT_DIR/staging-reset-backup-${HISTORY_DATE}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ ! -d "$IN_DIR" ]]; then
    log_error "Folder backup '$IN_DIR' tidak ada — jalankan backup-aug8-history.sh dulu SEBELUM reset (kalau belum sempat, data ini sudah tidak bisa dipulihkan)."
    exit 1
fi
if ! docker compose ps postgres 2>/dev/null | grep -q postgres; then
    log_error "Service 'postgres' tidak jalan. Deploy stack baru dulu (menu 2), migrasi (menu 14), seed simpul (menu 15) — BARU jalankan script ini."
    exit 1
fi

# "$@" diteruskan lewat placeholder $0 ("sh") supaya bisa dibaca ulang
# sebagai "$@" DI DALAM sh -c — tanpa trik ini, argumen setelah 'sh -c SCRIPT'
# jadi $0/$1 punya sh, tidak pernah benar-benar sampai ke psql (bug nyata,
# ketemu saat ditulis: psql_exec -tAc '...' diam-diam menjalankan psql TANPA
# -c sama sekali, keluar tanpa output alih-alih menjalankan query).
psql_exec() {
    docker compose exec -T postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' sh "$@"
}

SIMPUL_COUNT="$(psql_exec -tAc 'SELECT count(*) FROM simpul_jaringan' 2>/dev/null || echo 0)"
SIMPUL_COUNT="$(echo "$SIMPUL_COUNT" | tr -d '[:space:]')"
[[ -z "$SIMPUL_COUNT" ]] && SIMPUL_COUNT=0
if [[ "${SIMPUL_COUNT:-0}" -eq 0 ]]; then
    log_error "simpul_jaringan masih kosong — jalankan deploy.sh menu 15 (Seed awal simpul_jaringan) dulu, BARU jalankan script ini. FK csw_records/harvest_runs -> simpul_jaringan akan gagal kalau belum ada."
    exit 1
fi
log_info "simpul_jaringan: $SIMPUL_COUNT baris — lanjut restore riwayat $HISTORY_DATE."

# 1) csw_records — \copy FROM STDIN, urutan kolom mengikuti \copy TO STDOUT
#    saat ekspor (SELECT * di kedua sisi, schema sama krn baru di-migrate ulang).
log_info "1/3 — Impor csw_records..."
docker compose exec -T postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\copy csw_records FROM STDIN WITH CSV HEADER"' < "$IN_DIR/csw_records.csv"

# 2) harvest_runs
log_info "2/3 — Impor harvest_runs..."
docker compose exec -T postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\copy harvest_runs FROM STDIN WITH CSV HEADER"' < "$IN_DIR/harvest_runs.csv"

# 3) Reset sequence SERIAL supaya insert berikutnya (harvest run pertama di
#    stack baru) tidak bentrok id dgn yang baru diimpor — \copy menulis id
#    literal dari file, sequence-nya sendiri TIDAK otomatis maju.
log_info "3/3 — Reset sequence id csw_records/harvest_runs..."
psql_exec <<'SQL'
SELECT setval(pg_get_serial_sequence('csw_records', 'id'), COALESCE((SELECT MAX(id) FROM csw_records), 1));
SELECT setval(pg_get_serial_sequence('harvest_runs', 'id'), COALESCE((SELECT MAX(id) FROM harvest_runs), 1));
SQL

# Verifikasi jumlah baris sama persis dengan yang diekspor.
EXPECTED_CSW="$(cat "$IN_DIR/csw_records.count" 2>/dev/null || echo '?')"
EXPECTED_RUNS="$(cat "$IN_DIR/harvest_runs.count" 2>/dev/null || echo '?')"
ACTUAL_CSW="$(psql_exec -tAc 'SELECT count(*) FROM csw_records' | tr -d '[:space:]')"
ACTUAL_RUNS="$(psql_exec -tAc 'SELECT count(*) FROM harvest_runs' | tr -d '[:space:]')"

echo ""
log_info "Verifikasi jumlah baris — csw_records: $ACTUAL_CSW (ekspor: $EXPECTED_CSW), harvest_runs: $ACTUAL_RUNS (ekspor: $EXPECTED_RUNS)"
if [[ "$ACTUAL_CSW" != "$EXPECTED_CSW" || "$ACTUAL_RUNS" != "$EXPECTED_RUNS" ]]; then
    log_warn "Jumlah TIDAK cocok — cek manual sebelum lanjut (kemungkinan ada baris yang FK-nya ke simpul yang sudah tidak ada di sample-csw.json terbaru)."
else
    log_ok "Jumlah baris cocok persis dengan hasil ekspor."
fi

echo ""
log_info "Langkah terakhir (manual) — sinkron ulang index Elasticsearch dari csw_records yang baru diimpor:"
cat <<'CMD'

  docker compose run --rm harvester node -e "
    const { pool } = require('./dist/db/pool');
    const { syncCatalogIndex } = require('./dist/search/sync-catalog');
    (async () => {
      const { rows } = await pool.query('SELECT DISTINCT simpul_id FROM csw_records');
      for (const r of rows) { console.log('sync', r.simpul_id); await syncCatalogIndex(r.simpul_id); }
      await pool.end();
    })().catch((e) => { console.error(e); process.exit(1); });
  "

CMD
log_ok "Restore riwayat $HISTORY_DATE selesai (Postgres). Jalankan perintah resync ES di atas untuk menyelesaikan."
