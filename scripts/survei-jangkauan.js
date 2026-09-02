// Survei jangkauan simpul — dijalankan DI DALAM container harvester:
//     docker compose exec -T -e URLS="..." harvester node < scripts/survei-jangkauan.js
//
// Untuk tiap simpul, ia menanyakan alamatnya ke DUA resolver (internal &
// publik) lalu benar-benar MENCOBA URL-nya ke masing-masing alamat. Hasilnya:
// resolver mana yang memberi jalur yang bisa dipakai dari server ini.
//
// KENAPA HARUS MENCOBA URL-nya, bukan cuma ping/DNS. Terbukti di lapangan:
// jalur internal MENERIMA koneksi TCP lalu MEMBUANG handshake TLS. Uji DNS
// lolos, uji TCP lolos, tapi HTTPS-nya tidak pernah jalan. Hanya permintaan
// yang sungguhan — dengan skema & port URL aslinya — yang menangkap itu.
//
// KENAPA DARI DALAM CONTAINER. Rute dan resolver container berbeda dari host.
// Yang perlu diukur adalah apa yang dilihat harvester, bukan apa yang dilihat
// operator.
//
// Keluaran: JSON satu baris di akhir (dipakai deploy.sh), didahului tabel
// yang bisa dibaca manusia. deploy.sh membaca baris terakhir saja.
const dns = require('dns'), http = require('http'), https = require('https');

const URLS = (process.env.URLS || '').trim().split(/\s+/).filter(Boolean);
const INT = process.env.DNS_INTERNAL || '192.168.201.10';
const PUB = process.env.DNS_PUBLIK || '1.1.1.1';
const BATAS = Number(process.env.BATAS_MS || 6000);
const PARALEL = Number(process.env.PARALEL || 12);

const privat = (ip) => !!ip && /^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)/.test(ip);

const tanya = (srv, host) => new Promise((r) => {
    const x = new dns.Resolver();
    x.setServers([srv]);
    const t = setTimeout(() => r(null), BATAS);
    x.resolve4(host, (e, a) => { clearTimeout(t); r(e ? null : a[0]); });
});

// Sengaja memakai IP sbg tujuan koneksi TAPI Host/servername nama aslinya —
// satu IP melayani puluhan subdomain ina-sdi, jadi tanpa itu server tidak tahu
// situs mana yang diminta dan menjawab salah.
const coba = (ip, u) => new Promise((r) => {
    if (!ip) return r(false);
    const lib = u.protocol === 'https:' ? https : http;
    const port = u.port || (u.protocol === 'https:' ? 443 : 80);
    const q = lib.request({
        host: ip, port, path: u.pathname || '/',
        headers: { Host: u.hostname }, servername: u.hostname,
        rejectUnauthorized: false, timeout: BATAS,
    }, (res) => { r(res.statusCode < 500); res.destroy(); });
    q.on('timeout', () => { r(false); q.destroy(); });
    q.on('error', () => r(false));
    q.end();
});

(async () => {
    const hasil = [];
    let i = 0;
    await Promise.all(Array.from({ length: PARALEL }, async () => {
        while (i < URLS.length) {
            const s = URLS[i++];
            let u;
            try { u = new URL(s); } catch { continue; }
            const [ipI, ipP] = [await tanya(INT, u.hostname), await tanya(PUB, u.hostname)];
            if (ipI === ipP) continue;   // jawaban sama -> pilihan DNS tidak berpengaruh
            hasil.push({
                host: u.hostname, url: s, ipI, ipP,
                okI: await coba(ipI, u), okP: await coba(ipP, u),
            });
        }
    }));

    // Yang butuh disematkan: internal jalan, publik TIDAK, dan alamat
    // internalnya memang privat (kalau publik, tidak ada gunanya disematkan).
    const pin = hasil.filter((h) => h.okI && !h.okP && privat(h.ipI));
    const lepas = hasil.filter((h) => h.okP);   // publik jalan -> tidak perlu pin

    hasil.sort((a, b) => a.host.localeCompare(b.host));
    console.log('jalur  internal          publik            host');
    for (const h of hasil) {
        const tag = h.okI && h.okP ? 'dua  ' : h.okI ? 'INTRN' : h.okP ? 'publk' : 'mati ';
        console.log(tag + '  ' + (String(h.ipI) + ' '.repeat(18)).slice(0, 18) +
            (String(h.ipP) + ' '.repeat(18)).slice(0, 18) + h.host);
    }
    console.log('\ndari ' + URLS.length + ' simpul, ' + hasil.length + ' berbeda jawaban DNS-nya');
    console.log('  perlu disematkan (internal jalan, publik mati) : ' + pin.length);
    console.log('  publik jalan (tidak perlu pin)                 : ' + lepas.length);
    console.log('  dua-duanya mati                                : ' +
        hasil.filter((h) => !h.okI && !h.okP).length);

    // Baris TERAKHIR = JSON, dibaca deploy.sh. Ditandai supaya tidak tertukar
    // dgn keluaran lain kalau format tabel di atas berubah suatu saat.
    console.log('#JSON#' + JSON.stringify({
        pin: pin.map((h) => ({ host: h.host, ip: h.ipI })),
        publikJalan: lepas.map((h) => h.host),
        total: URLS.length,
    }));
})();
