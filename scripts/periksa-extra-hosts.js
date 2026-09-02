// Pemeriksa ringkas untuk daftar extra-hosts — dijalankan DI DALAM container
// harvester oleh scripts/periksa-extra-hosts.sh.
//
// Berbeda dari survei: ini HANYA memeriksa nama yang sudah disematkan (belasan,
// bukan 471), jadi selesai dalam hitungan detik dan tidak menembaki ratusan
// server instansi. Cocok dijalankan berkala lewat cron.
//
// Dua pertanyaan yang dijawab untuk tiap entri:
//   1. Apakah IP internal yang disematkan MASIH melayani? Kalau tidak, pin-nya
//      sudah basi dan simpul itu mati tanpa ada yang tahu.
//   2. Apakah jalur PUBLIK sudah pulih? Kalau ya, pin-nya tidak perlu lagi —
//      dan membiarkannya justru menyembunyikan pemulihan itu.
//
// ENTRI dikirim lewat env sbg "nama|ip" dipisah spasi.
const http = require('http'), https = require('https'), dns = require('dns');

const ENTRI = (process.env.ENTRI || '').trim().split(/\s+/).filter(Boolean);
const PUB = process.env.DNS_PUBLIK || '1.1.1.1';
const BATAS = Number(process.env.BATAS_MS || 6000);

const tanya = (srv, host) => new Promise((r) => {
    const x = new dns.Resolver();
    x.setServers([srv]);
    const t = setTimeout(() => r(null), BATAS);
    x.resolve4(host, (e, a) => { clearTimeout(t); r(e ? null : a[0]); });
});

const ketuk = (ip, host, port) => new Promise((r) => {
    if (!ip) return r(false);
    const lib = port === 443 ? https : http;
    const q = lib.request({
        host: ip, port, path: '/', headers: { Host: host }, servername: host,
        rejectUnauthorized: false, timeout: BATAS,
    }, (res) => { r(res.statusCode < 500); res.destroy(); });
    q.on('timeout', () => { r(false); q.destroy(); });
    q.on('error', () => r(false));
    q.end();
});

// Hidup = salah satu port menjawab. Registry memuat campuran http & https, dan
// berkas extra-hosts hanya menyimpan nama+IP tanpa skema, jadi keduanya dicoba.
const hidup = async (ip, host) => (await ketuk(ip, host, 80)) || (await ketuk(ip, host, 443));

(async () => {
    const rusak = [], takPerlu = [];
    for (const e of ENTRI) {
        const [host, ip] = e.split('|');
        if (!host || !ip) continue;
        const okInternal = await hidup(ip, host);
        const ipPublik = await tanya(PUB, host);
        const okPublik = await hidup(ipPublik, host);

        if (!okInternal) rusak.push({ host, ip, ipPublik, okPublik });
        else if (okPublik) takPerlu.push({ host, ip, ipPublik });
    }

    for (const r of rusak) {
        console.log('RUSAK      ' + r.host + '  -> ' + r.ip + ' tidak menjawab' +
            (r.okPublik ? '  (tapi jalur publik ' + r.ipPublik + ' HIDUP - pin bisa dilepas)' : '  (jalur publik juga mati)'));
    }
    for (const t of takPerlu) {
        console.log('TAK PERLU  ' + t.host + '  -> jalur publik ' + t.ipPublik + ' sudah pulih, pin bisa dilepas');
    }
    if (!rusak.length && !takPerlu.length) {
        console.log('OK         ' + ENTRI.length + ' entri masih sesuai');
    }

    // Kode keluar: 1 HANYA kalau ada yang RUSAK (simpul benar-benar mati).
    // "Tak perlu" bukan kegagalan — cuma informasi bahwa daftarnya bisa
    // dirapikan — jadi ia TIDAK memicu alarm. Membedakan keduanya penting:
    // alarm yang berbunyi untuk hal yang tidak mendesak akan diabaikan orang,
    // dan berhenti berguna justru saat dibutuhkan.
    process.exit(rusak.length ? 1 : 0);
})();
