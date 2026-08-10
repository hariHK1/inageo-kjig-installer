#!/usr/bin/env bash
# Ekspor riwayat harvest tanggal tertentu (default 2026-08-08) SEBELUM stack
# di-reset total (`docker compose down -v`). Script ini HANYA MEMBACA — tidak
# mengubah/menghapus apa pun, aman dijalankan berkali-kali.
#
# Dipakai bersama restore-aug8-history.sh sebagai sepasang: jalankan script
# ini DULU (stack lama masih hidup), baru lakukan reset total, baru jalankan
# restore-aug8-history.sh setelah stack baru migrate+seed selesai.
#
# Cakupan yang diekspor SENGAJA dibatasi ke 2 tabel inti (csw_records,
# harvest_runs) — ini yang menggerakkan katalog pencarian + chart "Records
# per hari" di dashboard admin. Tabel log operasional (harvest_run_steps,
# harvest_record_failures, harvest_sessions, record_change_log, dkk) TIDAK
# ikut diekspor — itu jejak proses (bukan "riwayat data"), dan mempertahankan
# cakupan sesempit mungkin membuat proses restore lebih gampang diverifikasi
# benar. Kalau ternyata tabel lain juga perlu disisakan, tambah manual ke
# TABLES_TO_EXPORT di bawah (kolom filter tanggalnya beda-beda per tabel,
# cek migrations/ di repo source dulu sebelum menambah).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

HISTORY_DATE="${1:-2026-08-08}"
OUT_DIR="$SCRIPT_DIR/staging-reset-backup-${HISTORY_DATE}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    log_error ".env tidak ditemukan di $SCRIPT_DIR — jalankan script ini dari server yang stack-nya masih hidup, SEBELUM reset."
    exit 1
fi

if ! docker compose ps postgres 2>/dev/null | grep -q postgres; then
    log_error "Service 'postgres' tidak terdeteksi jalan (docker compose ps). Jalankan script ini SEBELUM 'docker compose down -v'."
    exit 1
fi

mkdir -p "$OUT_DIR"
log_info "Tanggal yang disisakan: $HISTORY_DATE"
log_info "Output: $OUT_DIR"

psql_exec() {
    # Semua kredensial diambil dari env var YANG SUDAH ADA di dalam container
    # postgres (di-set docker-compose.yml dari .env) — script ini sengaja
    # TIDAK membaca .env sendiri, supaya tidak ada risiko salah parse format.
    #
    # "$@" diteruskan lewat placeholder $0 ("sh") supaya terbaca ulang sebagai
    # "$@" DI DALAM sh -c — tanpa trik ini argumen jadi $0/$1 milik sh sendiri,
    # tidak pernah sampai ke psql.
    docker compose exec -T postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' sh "$@"
}

# 1) Backup penuh (jaring pengaman tambahan, format custom pg_dump — restore
#    manual kalau ternyata ada tabel lain yang lupa disisakan). Restore:
#    `docker compose exec -T postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean' < full-backup.dump`
log_info "1/3 — Backup penuh database (jaring pengaman)..."
docker compose exec -T postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -F c -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > "$OUT_DIR/full-backup.dump"
log_ok "Backup penuh: $OUT_DIR/full-backup.dump ($(du -h "$OUT_DIR/full-backup.dump" | cut -f1))"

# 2) csw_records tanggal $HISTORY_DATE (fallback ke updated_at kalau
#    tanggal_harvest kosong — bisa terjadi utk record yang belum pernah
#    ke-refresh sejak field ini ditambahkan).
log_info "2/3 — Ekspor csw_records ($HISTORY_DATE)..."
psql_exec <<SQL > "$OUT_DIR/csw_records.csv"
\copy (SELECT * FROM csw_records WHERE tanggal_harvest::date = '$HISTORY_DATE' OR (tanggal_harvest IS NULL AND updated_at::date = '$HISTORY_DATE') ORDER BY id) TO STDOUT WITH CSV HEADER
SQL
CSW_COUNT=$(($(wc -l < "$OUT_DIR/csw_records.csv") - 1))
log_ok "csw_records: $CSW_COUNT baris -> $OUT_DIR/csw_records.csv"

# 3) harvest_runs tanggal $HISTORY_DATE.
log_info "3/3 — Ekspor harvest_runs ($HISTORY_DATE)..."
psql_exec <<SQL > "$OUT_DIR/harvest_runs.csv"
\copy (SELECT * FROM harvest_runs WHERE started_at::date = '$HISTORY_DATE' ORDER BY id) TO STDOUT WITH CSV HEADER
SQL
RUNS_COUNT=$(($(wc -l < "$OUT_DIR/harvest_runs.csv") - 1))
log_ok "harvest_runs: $RUNS_COUNT baris -> $OUT_DIR/harvest_runs.csv"

echo "$HISTORY_DATE" > "$OUT_DIR/HISTORY_DATE"
echo "$CSW_COUNT" > "$OUT_DIR/csw_records.count"
echo "$RUNS_COUNT" > "$OUT_DIR/harvest_runs.count"

echo ""
if [[ "$CSW_COUNT" -eq 0 && "$RUNS_COUNT" -eq 0 ]]; then
    log_warn "Kedua tabel 0 baris untuk tanggal $HISTORY_DATE — cek lagi tanggalnya benar (server pakai timezone apa?) sebelum lanjut reset total."
else
    log_ok "Selesai. Simpan folder '$OUT_DIR' di LUAR server ini juga (scp) sebagai jaring pengaman kedua sebelum lanjut 'docker compose down -v'."
fi
