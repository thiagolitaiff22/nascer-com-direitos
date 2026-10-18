// Lança uma versão nova do aplicativo: sobe o número de versão, renova o cache e escreve app/versao.json.
// Todos os celulares (Android, iPhone e navegador) mostram o aviso "Nova versão disponível" quando abrem ou voltam ao app.
// Uso:  node app/lancar.js "o que mudou, em uma frase curta"
const fs = require('fs'), path = require('path');
const R = path.join(__dirname, '..');
const novidades = process.argv.slice(2).join(' ').trim() || 'Melhorias e correções.';
let h = fs.readFileSync(path.join(R, 'campo.html'), 'utf8');
const atual = +(h.match(/var APP_VERSAO = (\d+);/) || [])[1];
const v = atual + 1;
h = h.replace(/var APP_VERSAO = \d+;/, 'var APP_VERSAO = ' + v + ';');
fs.writeFileSync(path.join(R, 'campo.html'), h);
let sw = fs.readFileSync(path.join(R, 'campo-sw.js'), 'utf8');
sw = sw.replace(/nascer-campo-v\d+/, 'nascer-campo-v' + (v + 20));
fs.writeFileSync(path.join(R, 'campo-sw.js'), sw);
let old = {}; try { old = JSON.parse(fs.readFileSync(path.join(__dirname, 'versao.json'), 'utf8')); } catch (e) {}
const out = { versao: v, apk: old.apk || 25, apkBuild: old.apkBuild || 0, url: 'https://thiagolitaiff22.github.io/nascer-com-direitos/app/download/nascer-com-direitos.apk', novidades };
fs.writeFileSync(path.join(__dirname, 'versao.json'), JSON.stringify(out) + '\n');
console.log('Versão', v, 'pronta. Falta só publicar (git add, commit e push).');
