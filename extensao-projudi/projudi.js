// Roda só quando o BI abre o PROJUDI pelo botão "Pauta do PROJUDI" (#qe-pauta).
// Entra com o login que o próprio Chrome preencheu (só clica em Entrar), abre Audiências › Listagem,
// lê a pauta "Aguarda Realização" e devolve ao BI. Não guarda nem lê senha.
(function(){
  'use strict';
  if (window.top !== window) return;
  var CHAVE = 'qe-pauta-pedido';
  if (/qe-pauta/.test(location.hash)){
    sessionStorage.setItem(CHAVE, JSON.stringify({ em: Date.now(), bi: (location.hash.split('bi=')[1] || '') }));
    history.replaceState(null, '', location.pathname + location.search);
  }
  var pedido = null; try { pedido = JSON.parse(sessionStorage.getItem(CHAVE) || 'null'); } catch(e){}
  if (!pedido || Date.now() - pedido.em > 10 * 60 * 1000) return;
  var BI = decodeURIComponent(pedido.bi || '') || 'https://thiagolitaiff22.github.io';

  var espera = function(ms){ return new Promise(function(r){ setTimeout(r, ms); }); };
  var aviso = (function(){
    var el = null;
    return function(txt, cor){
      if (!el){ el = document.createElement('div'); el.style.cssText = 'position:fixed;z-index:2147483647;right:16px;bottom:16px;max-width:360px;padding:14px 16px;border-radius:12px;font:600 14px/1.4 system-ui,sans-serif;color:#fff;box-shadow:0 8px 30px rgba(0,0,0,.35)'; document.body.appendChild(el); }
      el.style.background = cor || '#111827'; el.textContent = txt;
    };
  })();
  function docs(){
    var out = [document];
    for (var i = 0; i < window.frames.length; i++){ try { out.push(window.frames[i].document); for (var j = 0; j < window.frames[i].frames.length; j++) out.push(window.frames[i].frames[j].document); } catch(e){} }
    return out;
  }
  function telaDeLogin(){ return docs().some(function(d){ return d && d.querySelector('input[type=password]'); }); }

  (async function(){
    await espera(800);
    // 1) login: só clica em Entrar se o Chrome já preencheu os campos
    if (telaDeLogin()){
      aviso('Pauta do PROJUDI: entrando…');
      var d = docs().filter(function(x){ return x && x.querySelector('input[type=password]'); })[0];
      await espera(1500);
      var bt = [].slice.call(d.querySelectorAll('input[type=submit],input[type=button],button')).filter(function(b){ return /entrar/i.test(b.value || b.textContent || ''); })[0];
      if (bt) bt.click();
      await espera(6000);
      if (telaDeLogin()) aviso('Pauta do PROJUDI: clique em Entrar para continuar. A busca segue sozinha depois.', '#b45309');
      return; // a página recarrega depois do login e este script roda de novo
    }
    var main = null;
    for (var m = 0; m < 30; m++){ main = window.frames['mainFrame']; try { if (main && main.document.readyState === 'complete' && main.document.querySelector('a')) break; } catch(e){} await espera(500); }
    if (!main) return;
    aviso('Pauta do PROJUDI: abrindo a listagem de audiências…');
    // 2) Audiências › Listagem
    var w = main.frames['userMainFrame'];
    if (!w || !w.document.forms['audienciaForm']){
      var l = [].slice.call(main.document.querySelectorAll('a')).filter(function(a){ return a.textContent.trim() === 'Listagem' && /audiencia/.test(a.getAttribute('href') || ''); })[0];
      if (!l){ aviso('Pauta do PROJUDI: não achei o menu Audiências › Listagem.', '#b91c1c'); return; }
      l.click();
      for (var t = 0; t < 30; t++){ await espera(500); w = main.frames['userMainFrame']; try { if (w && w.document.forms['audienciaForm']) break; } catch(e){} }
    }
    var f = w && w.document.forms['audienciaForm'];
    if (!f){ aviso('Pauta do PROJUDI: a listagem não abriu. Tente de novo pelo BI.', '#b91c1c'); return; }
    // 3) Aguarda Realização + Audiência Una, tudo numa página
    var antes = w.document;
    var sit = f.querySelector('[name=idSituacaoAudiencia][value="5"]'); if (sit) sit.checked = true;
    var sel = f.elements['idTipoAudiencia']; var op = [].slice.call(sel.options).filter(function(o){ return o.text.trim() === 'Audiência Una'; })[0]; if (op) sel.value = op.value;
    f.elements['audienciaPageSize'].value = '1000';
    aviso('Pauta do PROJUDI: lendo as audiências…');
    f.elements['pesquisar'].click();
    var dd = null;
    for (var i = 0; i < 80; i++){ await espera(500); try { var x = main.frames['userMainFrame'].document; if (x !== antes && x.readyState === 'complete' && /registro\(s\)/.test(x.body.innerText)){ dd = x; break; } } catch(e){} }
    if (!dd){ aviso('Pauta do PROJUDI: o PROJUDI demorou para responder. Tente de novo pelo BI.', '#b91c1c'); return; }
    var linhas = [];
    [].slice.call(dd.querySelectorAll('tr')).forEach(function(tr){
      var tds = [].slice.call(tr.children).filter(function(c){ return c.tagName === 'TD'; }); if (tds.length < 5) return;
      var p = (tds[0].innerText.match(/\d{7}-\d{2}\.\d{4}\.\d\.\d{2}\.\d{4}/) || [])[0];
      var dt = tds.map(function(c){ return c.innerText; }).join(' ').match(/(\d{2})\/(\d{2})\/(\d{4}) (\d{2}:\d{2})/);
      if (!p || !dt) return;
      var partes = tds[1].innerText.replace(/\s+/g, ' ');
      var autor = (partes.match(/(?:Requerente|Polo Ativo):\s*•?\s*(.+?)\s*(?:Requerido|Polo Passivo|Terceiro|$)/) || [])[1] || '';
      linhas.push({ p: p, d: dt[3] + '-' + dt[2] + '-' + dt[1], h: dt[4], autor: autor.trim() });
    });
    sessionStorage.removeItem(CHAVE);
    // 4) devolve ao BI que abriu esta aba
    var bi = window.opener;
    if (!bi){ aviso('Pauta do PROJUDI: li ' + linhas.length + ' audiências, mas a aba do BI foi fechada. Abra o BI e clique de novo.', '#b91c1c'); return; }
    var ok = false, em = new Date().toISOString();
    window.addEventListener('message', function(e){ if (e.data && e.data.tipo === 'qe-pauta-ok') ok = true; });
    for (var k = 0; k < 30 && !ok; k++){ try { bi.postMessage({ tipo: 'qe-pauta', linhas: linhas, em: em }, BI); } catch(e){} await espera(700); }
    if (ok){ aviso('Pauta enviada ao BI: ' + linhas.length + ' audiências. Esta aba fecha sozinha.', '#15803d'); await espera(2500); window.close(); }
    else aviso('Pauta do PROJUDI: não consegui entregar ao BI. Volte ao BI e clique de novo.', '#b91c1c');
  })();
})();
