// Copia a página do celular (campo.html) para dentro do aplicativo: tudo fica no aparelho e abre sem internet
const fs = require('fs'), path = require('path');
const R = path.join(__dirname, '..'), W = path.join(__dirname, 'www');
fs.rmSync(W, { recursive: true, force: true });
fs.mkdirSync(path.join(W, 'vendor'), { recursive: true });
let html = fs.readFileSync(path.join(R, 'campo.html'), 'utf8')
  .replace(/<link rel="manifest"[^>]*>\s*/, '')             // no aplicativo não precisa do manifesto da página
  .replace(', viewport-fit=cover', '');                      // o Android encaixa a tela entre as barras do sistema
fs.writeFileSync(path.join(W, 'index.html'), html);
fs.cpSync(path.join(R, 'img'), path.join(W, 'img'), { recursive: true });   // logo do escritório
fs.copyFileSync(path.join(R, 'vendor', 'jspdf.umd.min.js'), path.join(W, 'vendor', 'jspdf.umd.min.js'));
const v = (html.match(/var APP_VERSAO = (\d+);/) || [])[1];
console.log('www montado · versão do app', v);
