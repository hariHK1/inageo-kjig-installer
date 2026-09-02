#!/usr/bin/env bash
# Periksa apakah daftar extra-hosts masih sesuai keadaan jaringan.
#
# Dirancang untuk CRON. Berjalan sunyi kalau semuanya baik; hanya berbicara
# kalau ada yang perlu ditindak. Kode keluar 1 = ada simpul yang benar-benar
# mati, jadi cron/monitoring bisa memicu alarm dari situ tanpa perlu membaca
# teksnya.
#
# Pemakaian (lewat `bash`, karena repo ini tidak melacak bit executable —
# checkout di server menghasilkan berkas non-executable):
#     bash scripts/periksa-extra-hosts.sh              # ringkas, untuk cron
#     bash scripts/periksa-extra-hosts.sh --verbose    # selalu cetak hasil
#
# Contoh entri cron (tiap 6 jam, hasilnya masuk syslog):
#     0 */6 * * *  cd /home/adminhi/inageo-kjig-installer && \
#                  ./scripts/periksa-extra-hosts.sh 2>&1 | logger -t extra-hosts
#
# Opsional, kalau memakai Uptime Kuma (lihat README § Memantau daftar
# extra-hosts): isi KUMA_PUSH_URL di .env. Skrip memanggilnya HANYA saat semua
# entri sehat; begitu ada yang rusak ia berhenti memanggil, dan Kuma yang
# berteriak. Tanpa variabel itu, skrip ini tetap berguna lewat kode keluarnya.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# KUMA_PUSH_URL dibaca dari .env kalau ada. Cuma variabel ITU yang diambil —
# .env memuat kredensial database dsb, dan skrip ini tidak berkepentingan
# dengannya. `source .env` polos akan menariknya semua ke environment cron.
if [[ -f .env ]]; then
    KUMA_PUSH_URL="$(awk -F= '/^KUMA_PUSH_URL=/ { sub(/^KUMA_PUSH_URL=/, ""); print; exit }' .env)"
fi

KONF="extra-hosts.conf"
VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

if [[ ! -f "$KONF" ]]; then
    [[ "$VERBOSE" == "1" ]] && echo "Tidak ada $KONF — tidak ada yang disematkan, tidak ada yang diperiksa."
    exit 0
fi

# "nama|ip" dipisah spasi. Komentar & baris kosong dibuang; kolom ke-3 dst
# (alasan) diabaikan.
ENTRI="$(awk '!/^[[:space:]]*#/ && NF >= 2 { printf "%s|%s ", $1, $2 }' "$KONF")"
if [[ -z "${ENTRI// /}" ]]; then
    [[ "$VERBOSE" == "1" ]] && echo "$KONF kosong — tidak ada yang diperiksa."
    exit 0
fi

COMPOSE_CMD="docker compose"
docker compose version >/dev/null 2>&1 || COMPOSE_CMD="docker-compose"

# Dijalankan DI DALAM container harvester: rute & resolver container berbeda
# dari host, dan yang perlu diukur adalah apa yang dilihat harvester.
HASIL="$($COMPOSE_CMD exec -T -e ENTRI="$ENTRI" harvester node < scripts/periksa-extra-hosts.js 2>&1)"
KODE=$?

if [[ "$KODE" != "0" || "$VERBOSE" == "1" ]] || grep -q '^TAK PERLU' <<< "$HASIL"; then
    echo "$HASIL"
fi

if [[ "$KODE" == "0" && -n "${KUMA_PUSH_URL:-}" ]]; then
    curl -fsS --max-time 10 "$KUMA_PUSH_URL" >/dev/null 2>&1 || true
fi

exit "$KODE"
