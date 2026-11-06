// Gera o ícone e a tela de abertura do aplicativo Android a partir das imagens do app (img/)
// Ícone: logo roxa sobre fundo lilás (igual ao ícone do iPhone, img/icone-512.png).
// Abertura: roxo com a logo e o nome (img/abertura-marca.png), igual à abertura do iPhone; no Android 12 ou mais, roxo com a logo branca.
const sharp = require('sharp'), fs = require('fs'), path = require('path');
const RES = path.join(__dirname, 'android/app/src/main/res');
const IMG = path.join(__dirname, '../img');
const LILAS = '#f8f4fb', LILAS2 = '#eadcf4', LILAS_FUNDO = '#f3ebf8';   // fundo do ícone (a logo é roxa)
const ROXO = '#6a2bae', ROXO_FIM = '#3a146a';                          // fundo da abertura
const icone = fs.readFileSync(path.join(IMG, 'logo-nascer-t.png'));     // logo roxa, fundo transparente
const marca = fs.readFileSync(path.join(IMG, 'abertura-marca.png'));   // logo branca + "Nascer com Direitos" + "Salário-maternidade"
const branca = fs.readFileSync(path.join(IMG, 'marca-branca.png'));    // só a logo, branca
const degrade = (w, h, a, b, raio, vertical) => Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><defs><linearGradient id="g" x1="0" y1="0" x2="${vertical ? 0 : 1}" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient></defs><rect width="${w}" height="${h}" rx="${raio || 0}" fill="url(#g)"/></svg>`);
async function logoNo(lado, fracao){ const h = Math.round(lado * fracao); return sharp(icone).resize({ height: h }).png().toBuffer(); }
const D = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
(async () => {
  for (const [k, f] of Object.entries(D)){
    const dir = path.join(RES, 'mipmap-' + k), L = Math.round(48 * f), A = Math.round(108 * f);
    // ícone antigo (quadrado arredondado) e redondo
    await sharp(degrade(L, L, LILAS, LILAS2, Math.round(L * 0.22))).composite([{ input: await logoNo(L, 0.74), gravity: 'center' }]).png().toFile(path.join(dir, 'ic_launcher.png'));
    const circ = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${L}" height="${L}"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${LILAS}"/><stop offset="1" stop-color="${LILAS2}"/></linearGradient></defs><circle cx="${L / 2}" cy="${L / 2}" r="${L / 2}" fill="url(#g)"/></svg>`);
    await sharp(circ).composite([{ input: await logoNo(L, 0.7), gravity: 'center' }]).png().toFile(path.join(dir, 'ic_launcher_round.png'));
    // ícone adaptável: a logo dentro da área segura (66 de 108)
    await sharp({ create: { width: A, height: A, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } }).composite([{ input: await logoNo(A, 0.60), gravity: 'center' }]).png().toFile(path.join(dir, 'ic_launcher_foreground.png'));
  }
  fs.writeFileSync(path.join(RES, 'values/ic_launcher_background.xml'), `<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <color name="ic_launcher_background">${LILAS_FUNDO}</color>\n</resources>\n`);
  // tela de abertura (até o Android 11): roxo com a logo e o nome no meio
  for (const p of fs.readdirSync(RES).filter(n => n.startsWith('drawable'))){
    const arq = path.join(RES, p, 'splash.png'); if (!fs.existsSync(arq)) continue;
    const { width, height } = await sharp(arq).metadata();
    const lg = await sharp(marca).resize({ width: Math.round(Math.min(width * 0.76, height * 0.76, Math.min(width, height) * 0.9)) }).png().toBuffer();
    const buf = await sharp(degrade(width, height, ROXO, ROXO_FIM, 0, true)).composite([{ input: lg, gravity: 'center' }]).png().toBuffer();
    fs.writeFileSync(arq, buf);
  }
  // Android 12 ou mais: a abertura do sistema mostra um ícone no meio do fundo roxo (240 dp, a logo cabe no círculo de 160 dp)
  const dirI = path.join(RES, 'drawable-xxxhdpi'); fs.mkdirSync(dirI, { recursive: true });
  const lgB = await sharp(branca).resize({ height: 500 }).png().toBuffer();
  await sharp({ create: { width: 960, height: 960, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } }).composite([{ input: lgB, gravity: 'center' }]).png().toFile(path.join(dirI, 'splash_icone.png'));
  console.log('ícones ok');
})();
