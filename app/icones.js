// Gera o ícone e a tela de abertura do aplicativo Nascer com Direitos a partir da logo (img/logo-nascer.png)
const sharp = require('sharp'), fs = require('fs'), path = require('path');
const RES = path.join(__dirname, 'android/app/src/main/res');
const IMG = path.join(__dirname, '../img');
const ROXO = '#ffffff', ROXO2 = '#ffffff', FUNDO = '#ffffff', FUNDO2 = '#ffffff';   // fundo branco: a logo é dourada
const icone = fs.readFileSync(path.join(IMG, 'logo-nascer.png'));
const completa = fs.readFileSync(path.join(IMG, 'logo-nascer.png'));
const degrade = (w, h, a, b, raio) => Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient></defs><rect width="${w}" height="${h}" rx="${raio || 0}" fill="url(#g)"/></svg>`);
async function logoNo(lado, fracao){ const h = Math.round(lado * fracao); return sharp(icone).resize({ height: h }).png().toBuffer(); }
const D = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
(async () => {
  for (const [k, f] of Object.entries(D)){
    const dir = path.join(RES, 'mipmap-' + k), L = Math.round(48 * f), A = Math.round(108 * f);
    // ícone antigo (quadrado arredondado) e redondo
    await sharp(degrade(L, L, ROXO, ROXO2, Math.round(L * 0.22))).composite([{ input: await logoNo(L, 0.6), gravity: 'center' }]).png().toFile(path.join(dir, 'ic_launcher.png'));
    const circ = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${L}" height="${L}"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${ROXO}"/><stop offset="1" stop-color="${ROXO2}"/></linearGradient></defs><circle cx="${L / 2}" cy="${L / 2}" r="${L / 2}" fill="url(#g)"/></svg>`);
    await sharp(circ).composite([{ input: await logoNo(L, 0.55), gravity: 'center' }]).png().toFile(path.join(dir, 'ic_launcher_round.png'));
    // ícone adaptável: a logo dentro da área segura (66 de 108)
    await sharp({ create: { width: A, height: A, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } }).composite([{ input: await logoNo(A, 0.46), gravity: 'center' }]).png().toFile(path.join(dir, 'ic_launcher_foreground.png'));
  }
  fs.writeFileSync(path.join(RES, 'values/ic_launcher_background.xml'), `<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">${ROXO}</color>\n</resources>\n`);
  // tela de abertura: degradê do aplicativo com a logo no meio
  for (const p of fs.readdirSync(RES).filter(n => n.startsWith('drawable'))){
    const arq = path.join(RES, p, 'splash.png'); if (!fs.existsSync(arq)) continue;
    const { width, height } = await sharp(arq).metadata();
    const lg = await sharp(completa).resize({ width: Math.round(Math.min(width, height) * 0.62) }).png().toBuffer();
    const buf = await sharp(degrade(width, height, FUNDO, FUNDO2)).composite([{ input: lg, gravity: 'center' }]).png().toBuffer();
    fs.writeFileSync(arq, buf);
  }
  console.log('ícones ok');
})();
