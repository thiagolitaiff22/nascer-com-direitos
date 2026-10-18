// O aplicativo Android abre a página publicada (https://thiagolitaiff22.github.io/nascer-com-direitos/campo.html):
// assim TODA atualização do campo.html chega sozinha aos celulares, sem mandar link nem reinstalar.
// Aqui só montamos a tela de "sem conexão" que aparece se o celular nunca conseguiu abrir a página.
const fs = require('fs'), path = require('path');
const R = path.join(__dirname, '..'), W = path.join(__dirname, 'www');
fs.rmSync(W, { recursive: true, force: true });
fs.mkdirSync(W, { recursive: true });
const LIVE = 'https://thiagolitaiff22.github.io/nascer-com-direitos/campo.html';
const pagina = `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>Nascer com Direitos</title>
<style>html,body{height:100%;margin:0;background:#faf6ef;font-family:system-ui,Segoe UI,Roboto,Arial,sans-serif;color:#2a2318}
body{display:grid;place-items:center;text-align:center;padding:28px}
img{width:96px;margin-bottom:18px}h1{font-size:21px;margin:0 0 8px}p{margin:0 0 22px;color:#6e5f45;line-height:1.5;font-size:15px;max-width:300px}
button{border:0;border-radius:14px;background:#8c6a38;color:#fff;font:inherit;font-weight:600;padding:14px 26px;font-size:15px}</style></head>
<body><div><img src="img/logo-nascer-t.png" alt=""><h1>Sem conexão</h1>
<p>Para abrir o aplicativo pela primeira vez, ou atualizar, conecte o celular à internet.</p>
<button onclick="location.href='${LIVE}'">Tentar de novo</button></div></body></html>`;
fs.writeFileSync(path.join(W, 'index.html'), pagina);
fs.writeFileSync(path.join(W, 'offline.html'), pagina);
fs.mkdirSync(path.join(W, 'img'), { recursive: true });
fs.copyFileSync(path.join(R, 'img', 'logo-nascer-t.png'), path.join(W, 'img', 'logo-nascer-t.png'));
console.log('www montado (aplicativo abre a página publicada)');
