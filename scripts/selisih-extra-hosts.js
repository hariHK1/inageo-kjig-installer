// Hitung selisih antara daftar extra-hosts yang berlaku sekarang dan usulan
// hasil survei. Dijalankan DI DALAM container harvester oleh deploy.sh:
//
//     docker compose exec -T -e SEKARANG="..." -e JSON="..." harvester node \
//         < scripts/selisih-extra-hosts.js
//
// KENAPA DI DALAM CONTAINER, bukan di host. Host tidak dijamin punya Node —
// dan memang tidak punya pada server produksi (ketahuan saat pemakaian pertama
// menu ini: "node: command not found" setelah survei 3 menit selesai, sehingga
// hasilnya terbuang). Container harvester selalu punya, karena aplikasinya
// memang berjalan di atasnya.
//
// Masukan:
//   SEKARANG  "nama|ip nama|ip ..."  (isi extra-hosts.conf saat ini, boleh kosong)
//   JSON      keluaran #JSON# dari scripts/survei-jangkauan.js
//
// Keluaran: baris selisih yang bisa dibaca manusia, lalu dua baris bertanda —
//   #N#<jumlah perubahan>
//   #CONF#<baris untuk ditulis ke extra-hosts.conf>   (satu per entri)
const skr = new Map(
    (process.env.SEKARANG || '').trim().split(/\s+/).filter(Boolean)
        .map((s) => s.split('|'))
        .filter((p) => p.length === 2)
);

let json;
try {
    json = JSON.parse(process.env.JSON || '{}');
} catch {
    console.log('#N#-1');
    process.exit(1);
}
const usul = new Map((json.pin || []).map((p) => [p.host, p.ip]));

const tambah = [...usul].filter(([h]) => !skr.has(h));
const ubah = [...usul].filter(([h, i]) => skr.has(h) && skr.get(h) !== i);
// Yang hilang dari usulan = jalur publiknya sudah pulih, ATAU simpulnya mati
// dua-duanya. Dibedakan supaya operator tidak salah membaca "hapus" sebagai
// kabar baik padahal simpulnya justru mati total.
const pulih = new Set(json.publikJalan || []);
const hapus = [...skr].filter(([h]) => !usul.has(h));

for (const [h, i] of tambah) console.log('  + tambah  ' + h.padEnd(40) + '-> ' + i);
for (const [h, i] of ubah) console.log('  ~ ubah    ' + h.padEnd(40) + skr.get(h) + ' -> ' + i);
for (const [h, i] of hapus) {
    console.log('  - hapus   ' + h.padEnd(40) + '(' + i + ')  ' +
        (pulih.has(h) ? 'jalur publik sudah pulih' : 'TIDAK terjangkau lewat jalur mana pun — periksa manual'));
}

console.log('#N#' + (tambah.length + ubah.length + hapus.length));
for (const [h, i] of [...usul].sort((a, b) => a[0].localeCompare(b[0]))) {
    console.log('#CONF#' + h.padEnd(40) + i);
}
