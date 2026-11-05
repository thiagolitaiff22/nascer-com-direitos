/**
 * Nascer com Direitos · NIT automático (fluxo novo), SEM IA e sem custo.
 * Arquivo separado do campo.gs, no mesmo projeto do Apps Script (usa rpc() e SEGREDO_SISTEMA de lá).
 *
 * A cada 10 minutos: pergunta ao sistema quais mães do fluxo novo estão sem NIT (supabase/52_nit_automatico.sql),
 * olha só os arquivos NOVOS da pasta de cada uma (CNIS, CTPS, cartão cidadão...), pede ao Google Drive o texto do
 * arquivo (a mesma leitura do "Abrir com Documentos Google", de graça) e manda ao sistema os números que parecem NIT.
 * O sistema confere o dígito verificador e grava; com o NIT, a mãe urbana vai sozinha para a GPS.
 *
 * Instalação (uma vez, no projeto do script, conta thiago@rodrigueslitaiffadv.com.br):
 *  1. Arquivo + › Script › nome "nit" › cole este arquivo inteiro › Salvar.
 *  2. Serviços + › Drive API › Adicionar (liga a leitura de texto do Drive).
 *  3. Escolha a função instalarNit no topo › Executar (cria o agendamento de 10 em 10 minutos).
 *
 * Escala: só entram pastas de mães sem NIT; cada pasta só é lida quando recebe arquivo novo; cada rodada para
 * antes de 4,5 minutos e a próxima continua de onde parou (rodízio), então funciona com milhares de mães.
 */
var NIT_TEMPO = 270000;   // 4,5 min por rodada (o Google corta em 6)
var NIT_PULAR = /PROCURA|CERTID|COMPROVANTE DE RESID|FOTO D[AO] CLIENTE|AUTODECLARA|V[ÍI]DEO/i;   // arquivos que nunca têm o NIT da mãe

function instalarNit(){
  ScriptApp.getProjectTriggers().forEach(function(t){ if (t.getHandlerFunction() === 'lerNitAutomatico') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('lerNitAutomatico').timeBased().everyMinutes(10).create();
  return lerNitAutomatico();
}

function lerNitAutomatico(){
  var props = PropertiesService.getScriptProperties(), seg = props.getProperty('SEGREDO_SISTEMA');
  if (!seg) throw new Error('O script ainda não tem o código do sistema: abra o endereço /exec uma vez.');
  var t0 = Date.now(), gravados = 0;
  var pastas = (rpc('campo_pastas_sem_nit', { p_segredo: seg }) || []).map(function(p){ return p && typeof p === 'object' ? p.campo_pastas_sem_nit : p; }).filter(Boolean);
  // limpa o controle das pastas que já não precisam (a mãe ganhou NIT ou seguiu no fluxo)
  var ativas = {}; pastas.forEach(function(p){ ativas['nitlido_' + p] = 1; });
  Object.keys(props.getProperties()).forEach(function(k){ if (/^nitlido_/.test(k) && !ativas[k]) props.deleteProperty(k); });
  if (!pastas.length) return 0;
  var ini = Number(props.getProperty('nit_rodizio') || 0) % pastas.length;
  for (var n = 0; n < pastas.length; n++){
    if (Date.now() - t0 > NIT_TEMPO){ props.setProperty('nit_rodizio', String((ini + n) % pastas.length)); return gravados; }
    var id = pastas[(ini + n) % pastas.length], chave = 'nitlido_' + id, agora = Date.now(), pasta;
    try { pasta = DriveApp.getFolderById(id); } catch (x){ continue; }
    var novos = arquivosNovosNit_(pasta, Number(props.getProperty(chave) || 0)), terminou = true;
    for (var i = 0; i < novos.length; i++){
      if (Date.now() - t0 > NIT_TEMPO){ terminou = false; break; }
      try {
        var cand = nitsDoTexto_(textoDoArquivo_(novos[i]));
        if (cand.length && rpc('campo_gravar_nit', { p_segredo: seg, p_pasta: id, p_candidatos: cand, p_arquivo: novos[i].getName() })){ gravados++; break; }
      } catch (x){ console.log(pasta.getName() + ' / ' + novos[i].getName() + ': ' + x); }
    }
    if (terminou) props.setProperty(chave, String(agora));   // esses arquivos já foram lidos; só arquivo novo faz ler de novo
  }
  props.setProperty('nit_rodizio', '0');
  return gravados;
}

// fotos e PDFs da pasta (e subpastas) que chegaram ou mudaram depois da última leitura; primeiro os que costumam ter o NIT
function arquivosNovosNit_(pasta, desde){
  var l = [];
  function junta(f){
    var it = f.getFiles();
    while (it.hasNext()){
      var a = it.next(), t = a.getMimeType();
      if ((/^image\/(jpeg|png|gif|webp)$/.test(t) || t === 'application/pdf') && a.getLastUpdated().getTime() > desde && a.getSize() < 20e6 && !NIT_PULAR.test(a.getName())) l.push(a);
    }
  }
  junta(pasta); var sub = pasta.getFolders(); while (sub.hasNext()) junta(sub.next());
  var peso = function(a){ return /CNIS|NIT|PIS|NIS|CTPS|CARTEIRA|CONTRIBUI|CART[AÃ]O/i.test(a.getName()) ? 0 : 1; };
  return l.sort(function(a, b){ return peso(a) - peso(b); });
}

// texto do arquivo pela conversão do Google Drive (PDF com texto, PDF escaneado ou foto); a cópia temporária vai para a lixeira
function textoDoArquivo_(arq){
  var cab = { Authorization: 'Bearer ' + ScriptApp.getOAuthToken() };
  var r = UrlFetchApp.fetch('https://www.googleapis.com/drive/v3/files/' + arq.getId() + '/copy?supportsAllDrives=true&ocrLanguage=pt&fields=id', {
    method: 'post', contentType: 'application/json', headers: cab, muteHttpExceptions: true,
    payload: JSON.stringify({ name: 'leitura do NIT (temporario)', mimeType: 'application/vnd.google-apps.document', parents: ['root'] })
  });
  if (r.getResponseCode() >= 300) throw new Error('leitura do texto: ' + r.getContentText().slice(0, 200));
  var id = JSON.parse(r.getContentText()).id;
  try {
    var t = UrlFetchApp.fetch('https://www.googleapis.com/drive/v3/files/' + id + '/export?mimeType=text%2Fplain', { headers: cab, muteHttpExceptions: true });
    return t.getResponseCode() < 300 ? t.getContentText() : '';
  } finally { try { DriveApp.getFileById(id).setTrashed(true); } catch (x){} }
}

// números que parecem NIT: no formato do INSS (000.00000.00-0) ou logo depois de NIT, PIS, PASEP ou NIS; só os de dígito certo
function nitsDoTexto_(texto){
  var t = String(texto || ''), achados = [], m;
  var formato = /\d{3}\.\d{5}\.\d{2}-\d/g;
  while ((m = formato.exec(t))) achados.push(m[0]);
  var rotulo = /(?:NIT|PIS|PASEP|NIS)\b[^0-9]{0,30}(\d(?:[.\-\s]?\d){10})(?!\d)/gi;
  while ((m = rotulo.exec(t))) achados.push(m[1]);
  var visto = {};
  return achados.map(function(x){ return x.replace(/\D/g, ''); }).filter(function(d){
    if (visto[d] || !nitValido_(d)) return false; visto[d] = 1; return true;
  }).slice(0, 5);
}

function nitValido_(d){
  d = String(d || '').replace(/\D/g, '');
  if (d.length !== 11 || /^(\d)\1+$/.test(d)) return false;
  var p = [3, 2, 9, 8, 7, 6, 5, 4, 3, 2], s = 0;
  for (var i = 0; i < 10; i++) s += +d[i] * p[i];
  var dv = 11 - (s % 11); if (dv >= 10) dv = 0;
  return dv === +d[10];
}
