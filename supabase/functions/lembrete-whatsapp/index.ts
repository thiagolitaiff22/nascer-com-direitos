// Nascer com Direitos (salário-maternidade, ação contra o INSS): avisos de audiência pelo LiderHub.
// - Régua automática: o agendador do banco chama esta função a cada 10 minutos em horário comercial;
//   ela envia poucos avisos por vez (3 dias antes e véspera da audiência).
// - Consulta diária ao tribunal pelo DataJud (tribunal configurável: config 'regua' › tribunalAlias, padrão trf1).
// - Ações do site (só administradores): conexões, prévia da régua, teste, avulso, preparar o agendador.
// A chave do LiderHub fica guardada no banco (tabela segredos) e só é lida aqui.
import { createClient } from 'npm:@supabase/supabase-js@2';

const LH = 'https://api.liderhub.com.br';
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-regua-token',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const espera = (ms: number) => new Promise((r) => setTimeout(r, ms));
const URL_SB = Deno.env.get('SUPABASE_URL')!;
const adm = createClient(URL_SB, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

// LiderHub aceita 3 requisições por segundo por workspace
let ultima = 0;
async function lh(key: string, method: string, path: string, body?: unknown) {
  const falta = 380 - (Date.now() - ultima);
  if (falta > 0) await espera(falta);
  for (let tentativa = 0; tentativa < 4; tentativa++) {
    ultima = Date.now();
    const r = await fetch(LH + path, {
      method,
      headers: { 'x-company-key': key, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (r.status === 429) { await espera(1000 * (tentativa + 1)); continue; }
    const txt = await r.text();
    let dados: any = null; try { dados = JSON.parse(txt); } catch { dados = { message: txt }; }
    return { ok: r.ok, status: r.status, dados };
  }
  return { ok: false, status: 429, dados: { message: 'Limite de requisições do LiderHub' } };
}

// Números do cadastro vêm como "(97) 8105-3097"; o WhatsApp pode ter a conta com ou sem o 9
function variantes(numero: string): string[] {
  let d = String(numero || '').replace(/\D/g, '');
  if (d.startsWith('55') && d.length >= 12) d = d.slice(2);
  if (d.startsWith('0')) d = d.slice(1);
  if (d.length === 10) return ['55' + d, '55' + d.slice(0, 2) + '9' + d.slice(2)];
  if (d.length === 11 && d[2] === '9') return ['55' + d, '55' + d.slice(0, 2) + d.slice(3)];
  return [];
}
function numeroBase(numero: string): string {
  let d = String(numero || '').replace(/\D/g, '');
  if (d.startsWith('55') && d.length >= 12) d = d.slice(2);
  if (d.startsWith('0')) d = d.slice(1);
  if (d.length === 11 && d[2] === '9') d = d.slice(0, 2) + d.slice(3);
  return d.length === 10 ? d : '';
}

/* ---------------- tribunal (DataJud / CNJ) ---------------- */
// O tribunal ainda pode mudar (Justiça Federal/TRF1 ou Justiça Estadual/TJAM em competência delegada):
// o alias vem de config 'regua' › tribunalAlias (ex.: 'trf1', 'tjam'); padrão 'trf1'.
const TRIBUNAL_PADRAO = 'trf1';
function aliasTribunal(cfg: any): string {
  const a = String(cfg?.tribunalAlias || '').trim().toLowerCase().replace(/^api_publica_/, '');
  return /^[a-z0-9-]{2,20}$/.test(a) ? a : TRIBUNAL_PADRAO;
}
const urlDataJud = (alias: string) => `https://api-publica.datajud.cnj.jus.br/api_publica_${alias}/_search`;
const semAcento = (t: string) => String(t || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
// o que importa para o salário-maternidade, lido dos nomes dos movimentos (TPU/CNJ); vale o primeiro que casar
function tipoMovimento(m: any): string {
  const t = semAcento((m?.nome || '') + ' ' + (m?.complementosTabelados || []).map((c: any) => (c?.nome || '') + ' ' + (c?.descricao || '')).join(' '));
  if (t.includes('requisicao de pequeno valor') || /\brpv\b/.test(t) || t.includes('precatorio')) return 'rpv';
  if (t.includes('implantacao') || t.includes('implantad')) return 'implantacao';
  if (t.includes('alvara') || t.includes('levantamento')) return 'alvara';
  if (t.includes('transito em julgado')) return 'transito';
  if (t.includes('recurso') || t.includes('apelacao') || t.includes('embargos')) return 'recurso';
  if (t.includes('sentenca') || t.includes('julgad') || t.includes('procedente') || t.includes('extincao') || t.includes('extinto') || t.includes('homologad')) return 'sentenca';
  if (t.includes('audiencia') && (t.includes('designad') || t.includes('redesignad') || t.includes('marcad'))) return 'audiencia_designada';
  if (t.includes('audiencia') && (t.includes('realizad') || t.includes('nao realizad'))) return 'audiencia_realizada';
  if (t.includes('conclus')) return 'concluso';
  return '';
}
async function sincronizarTribunal(): Promise<any> {
  const { data: seg } = await adm.from('segredos').select('valor').eq('nome', 'datajud').maybeSingle();
  if (!seg?.valor) return { rodou: false, motivo: 'chave do DataJud não cadastrada' };
  const alias = aliasTribunal(await lerConfig()), DATAJUD = urlDataJud(alias);
  const clientes = await carregarClientes();
  const porNumero = new Map<string, any[]>();
  for (const c of clientes as any[]) {
    const n = String(c.processo || '').replace(/\D/g, '');
    if (n.length === 20) porNumero.set(n, [...(porNumero.get(n) || []), c]);
  }
  const numeros = [...porNumero.keys()];
  let achados = 0, novidades = 0;
  for (let i = 0; i < numeros.length; i += 100) {
    const lote = numeros.slice(i, i + 100);
    const r = await fetch(DATAJUD, {
      method: 'POST',
      headers: { 'Authorization': 'APIKey ' + seg.valor, 'Content-Type': 'application/json' },
      body: JSON.stringify({ size: 100, query: { terms: { numeroProcesso: lote } } }),
    });
    if (!r.ok) return { rodou: false, motivo: 'DataJud recusou (' + r.status + ') no tribunal ' + alias.toUpperCase(), tribunal: alias, achados, novidades };
    const j = await r.json();
    for (const h of j?.hits?.hits || []) {
      const src = h._source || {}, n = String(src.numeroProcesso || '').replace(/\D/g, '');
      const movs = (src.movimentos || []).slice().sort((a: any, b: any) => String(b.dataHora).localeCompare(String(a.dataHora)));
      const ultimo = movs[0];
      const marcos: Record<string, string> = {};
      for (const m of movs) { const t = tipoMovimento(m); if (t && !marcos[t]) marcos[t] = String(m.dataHora || '').slice(0, 10); }
      const resumo = { atualizadoEm: new Date().toISOString(), ultimo: ultimo ? { nome: ultimo.nome, data: String(ultimo.dataHora || '').slice(0, 10) } : null, marcos, fonte: src.dataHoraUltimaAtualizacao || null };
      achados++;
      for (const c of porNumero.get(n) || []) {
        const antes = c.tribunal || {};
        const mudou = JSON.stringify(antes.ultimo || null) !== JSON.stringify(resumo.ultimo) || JSON.stringify(antes.marcos || {}) !== JSON.stringify(marcos);
        if (!mudou) continue;
        const novo: any = { tribunal: resumo };
        // novidade no tribunal desde a última consulta: marca para a equipe conferir
        if (antes.ultimo && mudou) { novo.tribunalNovidade = { em: new Date().toISOString(), movimento: resumo.ultimo?.nome || '', data: resumo.ultimo?.data || '' }; novidades++; }
        await adm.rpc('atualizar_doc', { p_tabela: 'clientes', p_id: c.id, p_campos: novo });
      }
    }
  }
  await adm.rpc('atualizar_doc', { p_tabela: 'config', p_id: 'regua', p_campos: { tribunalConsultaEm: new Date().toISOString(), tribunalAchados: achados, tribunalConsultado: alias } });
  return { rodou: true, tribunal: alias, processos: numeros.length, achados, novidades };
}

async function chaveLiderHub(): Promise<string> {
  const env = Deno.env.get('LIDERHUB_KEY'); if (env) return env;
  const { data } = await adm.from('segredos').select('valor').eq('nome', 'liderhub').maybeSingle();
  return data?.valor || '';
}

// cria (ou reaproveita) o contato no LiderHub e envia o texto
async function enviarTexto(key: string, conexao: string, numero: string, nome: string, texto: string) {
  let contato = '', usado = '', erro = 'Número não tem WhatsApp', semWhats = true;
  for (const n of variantes(numero)) {
    const c = await lh(key, 'POST', '/v1/contacts', { connection: conexao, number: n, ...(String(nome || '').trim() ? { name: String(nome).trim().slice(0, 80) } : {}) });
    if (!c.ok) { erro = 'Cadastro no LiderHub falhou (' + c.status + '): ' + (c.dados?.message || ''); semWhats = false; continue; }
    if (c.dados?.exist && c.dados?.id) { contato = c.dados.id; usado = n; break; }
  }
  if (!contato) return { ok: false, semWhats, erro };
  const m = await lh(key, 'POST', '/v1/send/message', { contact: contato, content: texto, messageType: 'conversation' });
  return m.ok ? { ok: true, numero: usado, contato, mensagem: m.dados?.id || m.dados?.messageId || null, resposta: m.dados } : { ok: false, semWhats: false, numero: usado, erro: 'Envio recusado (' + m.status + '): ' + (m.dados?.message || '') };
}

/* ---------------- datas (Manaus, UTC-4 o ano todo) ---------------- */
const MAO = -4 * 3600000;
const hojeMao = (t = Date.now()) => new Date(t + MAO).toISOString().slice(0, 10);
const horaMao = (t = Date.now()) => new Date(t + MAO).getUTCHours() + new Date(t + MAO).getUTCMinutes() / 60;
function somaDias(iso: string, n: number) { const d = new Date(iso + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); }
const diaSemana = (iso: string) => new Date(iso + 'T12:00:00Z').getUTCDay();
const diasEntre = (a: string, b: string) => Math.round((new Date(b + 'T12:00:00Z').getTime() - new Date(a + 'T12:00:00Z').getTime()) / 86400000);

/* ---------------- textos ---------------- */
const MESES = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
const DIAS = ['domingo', 'segunda-feira', 'terça-feira', 'quarta-feira', 'quinta-feira', 'sexta-feira', 'sábado'];
// Local padrão: o tribunal/vara ainda não está definido. Se config 'regua' tiver o campo "local", ele é usado.
const LOCAL = '📍 *Fórum / Vara onde corre o processo (confira no convite)*';
const ONLINE = '💻 *Audiência online, por videochamada.* A equipe Nascer com Direitos vai orientar você sobre como entrar.';
// {testemunhas} vira este aviso quando alguma das clientes do aviso é segurada especial (rural/pescadora); senão some
const TESTEMUNHAS = '\n\n👥 *Segurada especial:* leve também as suas testemunhas (pessoas que conhecem o seu trabalho na roça ou na pesca), cada uma com documento com foto.';
const ABRE = 'Olá, {nome}! Aqui é da equipe Nascer com Direitos.\n\n';
const DOCS = 'É obrigatório levar documento com foto (RG ou CNH) e a certidão de nascimento da criança.';
export const MODELOS: Record<string, string> = {
  h3: ABRE + 'Lembrete da sua audiência do salário-maternidade (ação contra o INSS):\n{audiencia}\n{local}\n\n' + DOCS + ' Se faltar, o processo pode ser encerrado.{testemunhas}\n\nPor favor, responda *OK* para confirmar que vai comparecer.',
  designacao: ABRE + 'Sua audiência do salário-maternidade (ação contra o INSS) foi marcada:\n{audiencia}\n{local}\n\n' + DOCS + '{testemunhas}\n\nVamos lembrar você de novo perto da data. Por favor, responda *OK* para confirmar que recebeu.',
  d10: ABRE + 'Passando para lembrar da sua audiência do salário-maternidade (ação contra o INSS):\n{audiencia}\n{local}\n\n' + DOCS + '{testemunhas}\n\nQualquer dúvida, é só responder esta mensagem.',
  h10: ABRE + 'Faltam {dias} dias para a sua audiência do salário-maternidade (ação contra o INSS):\n{audiencia}\n{local}\n\n' + DOCS + ' Se faltar, o processo pode ser encerrado.{testemunhas}\n\nPor favor, responda *OK* para confirmar que recebeu.',
  h5: ABRE + 'Faltam só {dias} dias para a sua audiência do salário-maternidade (ação contra o INSS):\n{audiencia}\n{local}\n\n' + DOCS + ' Se faltar, o processo pode ser encerrado.{testemunhas}\n\nPor favor, responda *OK* para confirmar.',
  h1: 'Olá, {nome}! Sua audiência do salário-maternidade (ação contra o INSS) é *{quando}*:\n{audiencia}\n{local}\n\nChegue no horário e não esqueça o documento com foto (RG ou CNH) e a certidão de nascimento da criança.{testemunhas}\n\nQualquer dúvida, é só responder esta mensagem.',
};
// cadência: 3 dias antes e véspera, em qualquer dia da semana
export const ETAPAS = ['h3', 'h1'];
const URGENCIA: Record<string, number> = { h1: 0, h3: 1 };
function dataLonga(iso: string) { const p = iso.split('-'); return p[2] + ' de ' + MESES[+p[1] - 1] + ' de ' + p[0] + ' (' + DIAS[diaSemana(iso)] + ')'; }
function horaConvite(h: string) { if (!h) return 'horário a confirmar'; const [a, b] = h.split(':').map(Number); let m = a * 60 + (b || 0) - 30; if (m < 0) m += 1440; const hh = Math.floor(m / 60), mm = m % 60; return hh + 'h' + (mm ? String(mm).padStart(2, '0') : ''); }
const primeiro = (n: string) => String(n || '').trim().split(/\s+/)[0] || '';
const nomes = (a: string[]) => a.length < 2 ? a.join('') : a.slice(0, -1).join(', ') + ' e ' + a[a.length - 1];
function texto(modelo: string, g: Grupo, envio: string, localCfg = '') {
  const local = String(localCfg || '').trim() ? '📍 *' + String(localCfg).trim() + '*' : LOCAL;
  // audiência online: no lugar do endereço do Fórum (também nos modelos salvos que trazem o local padrão escrito)
  const online = g.clientes.some((c) => c.online);
  modelo = modelo.split('{local}').join(online ? ONLINE : local);
  if (online) modelo = modelo.split(LOCAL).join(ONLINE);
  const especial = g.clientes.some((c) => c.tipoSegurada === 'especial');
  const dias = diasEntre(envio, g.aud);
  const quando = dias <= 1 ? 'amanhã' : 'na ' + DIAS[diaSemana(g.aud)] + ', ' + g.aud.slice(8, 10) + '/' + g.aud.slice(5, 7);
  const aud = '📅 *' + dataLonga(g.aud) + '*\n🕑 *' + horaConvite(g.hora) + '*';
  return modelo.split('{nome}').join(nomes(g.clientes.map((c) => primeiro(c.nome)))).split('{audiencia}').join(aud)
    .split('{dias}').join(String(dias)).split('{quando}').join(quando).split('{testemunhas}').join(especial ? TESTEMUNHAS : '');
}

/* ---------------- régua ---------------- */
type Cli = { id: string; nome: string; contato: string; audData: string; audHora: string; audMarcadaEm?: string; online?: boolean; tipoSegurada?: string; foraDaRegua?: boolean; contatoVia?: string };
type Grupo = { numero: string; aud: string; hora: string; marcada: string; clientes: Cli[] };
type Passo = { etapa: string; data: string; ate: string };

async function carregarClientes(): Promise<Cli[]> {
  const out: Cli[] = [];
  for (let de = 0; ; de += 1000) {
    const { data, error } = await adm.from('clientes').select('id,data').order('id').range(de, de + 999);
    if (error) throw error;
    for (const r of data || []) out.push({ id: r.id, ...(r.data || {}) });
    if (!data || data.length < 1000) break;
  }
  return out;
}
// nome do contato no LiderHub: nome completo de quem é dono do número (os parentes avisados por ele não entram)
function nomeDoNumero(clientes: Cli[], numero: string, reserva = ''): string {
  const n = numeroBase(numero);
  const donos = [...new Set(clientes.filter((c) => n && numeroBase(c.contato) === n).map((c) => String(c.nome || '').trim()).filter(Boolean))];
  return (donos.length ? donos.join(' / ') : reserva).slice(0, 80);
}

// um aviso por número e por data de audiência (parentes com o mesmo telefone recebem uma mensagem só)
function grupos(clientes: Cli[], hoje: string): Grupo[] {
  const m = new Map<string, Grupo>();
  const porId = new Map(clientes.map((c) => [c.id, c]));
  for (const c of clientes) {
    if (c.foraDaRegua) continue; // telefone preenchido agora: só entra quando liberado no cadastro
    // sem telefone próprio: usa o telefone do cliente pelo qual é avisado (irmão, mãe…)
    const via = !numeroBase(c.contato) && c.contatoVia ? porId.get(c.contatoVia) : undefined;
    const n = numeroBase(c.contato) || (via ? numeroBase(via.contato) : ''); if (!n || !c.audData || c.audData <= hoje) continue;
    const k = n + '|' + c.audData;
    const g = m.get(k) || { numero: n, aud: c.audData, hora: c.audHora || '', marcada: '', clientes: [] };
    g.clientes.push(c);
    if (c.audMarcadaEm) g.marcada = g.marcada ? (c.audMarcadaEm < g.marcada ? c.audMarcadaEm : g.marcada) : c.audMarcadaEm;
    m.set(k, g);
  }
  return [...m.values()];
}
// datas de cada etapa; cada uma vale do seu dia até o dia seguinte (folga para o limite diário), sem passar da próxima etapa
function passos(g: Grupo, inicio: string): Passo[] {
  const lista = [{ etapa: 'h3', data: somaDias(g.aud, -3) }, { etapa: 'h1', data: somaDias(g.aud, -1) }];
  const minimo = g.marcada ? g.marcada.slice(0, 10) : '';
  let ok = lista.filter((p) => p.data >= inicio && p.data < g.aud && (!minimo || p.data >= minimo));
  // mesma data para duas etapas: fica a mais próxima da audiência
  ok = ok.filter((p, i) => !ok.some((q, j) => j > i && q.data === p.data));
  return ok.map((p, i) => {
    const prox = ok[i + 1];
    let ate = somaDias(p.data, 1);
    if (prox && ate >= prox.data) ate = somaDias(prox.data, -1);
    if (ate >= g.aud) ate = somaDias(g.aud, -1);
    return { etapa: p.etapa, data: p.data, ate };
  });
}
async function jaFeitos(): Promise<Set<string>> {
  const s = new Set<string>();
  for (let de = 0; ; de += 1000) {
    const { data } = await adm.from('avisos_log').select('numero,etapa,aud_data,status').in('status', ['enviado', 'sem_whatsapp']).range(de, de + 999);
    for (const r of data || []) s.add(r.numero + '|' + r.etapa + '|' + r.aud_data);
    if (!data || data.length < 1000) break;
  }
  return s;
}
async function lerConfig() {
  const { data } = await adm.from('config').select('data').eq('id', 'regua').maybeSingle();
  return { ativo: false, porDia: 70, ...(data?.data || {}) } as any;
}
function pendentesNoDia(gs: Grupo[], feitos: Set<string>, dia: string, inicio: string) {
  const out: { g: Grupo; p: Passo }[] = [];
  for (const g of gs) {
    const devidos = passos(g, inicio).filter((p) => p.data <= dia && dia <= p.ate && !feitos.has(g.numero + '|' + p.etapa + '|' + g.aud));
    if (devidos.length) out.push({ g, p: devidos[devidos.length - 1] }); // só a etapa mais recente; as anteriores já passaram
  }
  return out.sort((a, b) => URGENCIA[a.p.etapa] - URGENCIA[b.p.etapa] || a.p.data.localeCompare(b.p.data) || a.g.aud.localeCompare(b.g.aud));
}

async function rodarRegua(): Promise<any> {
  const cfg = await lerConfig();
  if (!cfg.ativo) return { rodou: false, motivo: 'régua desligada' };
  const agora = Date.now(), hoje = hojeMao(agora), h = horaMao(agora);
  if (h < 8 || h >= 18) return { rodou: false, motivo: 'fora do horário (8h às 18h)' };
  const key = await chaveLiderHub(); if (!key || !cfg.conexao) return { rodou: false, motivo: 'falta chave ou número do LiderHub' };
  const inicioDia = new Date(hoje + 'T00:00:00-04:00').toISOString();
  const { count } = await adm.from('avisos_log').select('id', { count: 'exact', head: true }).eq('status', 'enviado').neq('etapa', 'teste').gte('criado_em', inicioDia);
  const restantes = Math.max(0, (+cfg.porDia || 70) - (count || 0));
  // espalha o limite pelas rodadas que ainda restam no dia (uma a cada 10 minutos até 17h50)
  const rodadas = Math.max(1, Math.ceil((18 - h) * 6));
  const cota = Math.min(restantes, Math.max(1, Math.round(restantes / rodadas + Math.random() * 0.8)), 4);
  const feitos = await jaFeitos();
  const todos = await carregarClientes();
  const fila = pendentesNoDia(grupos(todos, hoje), feitos, hoje, cfg.inicio || hoje);
  const enviados = [];
  for (const { g, p } of fila.slice(0, cota)) {
    const modelo = (cfg.modelos && cfg.modelos[p.etapa]) || MODELOS[p.etapa];
    const r = await enviarTexto(key, cfg.conexao, g.numero, nomeDoNumero(todos, g.numero, g.clientes.map((c) => c.nome).join(' / ')), texto(modelo, g, hoje, cfg.local));
    const status = r.ok ? 'enviado' : r.semWhats ? 'sem_whatsapp' : 'erro';
    await adm.from('avisos_log').insert({ numero: g.numero, clientes: g.clientes.map((c) => c.id), etapa: p.etapa, aud_data: g.aud, status, erro: r.ok ? null : r.erro });
    const marca = { reguaUltimo: { etapa: p.etapa, em: new Date().toISOString(), status } } as any;
    if (r.semWhats) marca.semWhatsApp = true;
    for (const c of g.clientes) await adm.rpc('atualizar_doc', { p_tabela: 'clientes', p_id: c.id, p_campos: marca });
    enviados.push({ numero: g.numero, etapa: p.etapa, status });
    await espera(8000 + Math.random() * 14000);
  }
  await adm.rpc('atualizar_doc', { p_tabela: 'config', p_id: 'regua', p_campos: { ultimaRodada: new Date().toISOString(), ultimaFila: fila.length } });
  return { rodou: true, fila: fila.length, cota, enviados };
}

// prévia dos próximos dias, simulando o limite diário
async function previa() {
  const cfg = await lerConfig(), hoje = hojeMao(), inicio = cfg.inicio || hoje;
  const gs = grupos(await carregarClientes(), hoje), feitos = await jaFeitos(), dias = [];
  let dia = hoje;
  for (let i = 0; i < 14; i++, dia = somaDias(dia, 1)) {
    const fila = pendentesNoDia(gs, feitos, dia, inicio), vai = fila.slice(0, +cfg.porDia || 70);
    const porEtapa: Record<string, number> = {};
    vai.forEach((x) => { porEtapa[x.p.etapa] = (porEtapa[x.p.etapa] || 0) + 1; feitos.add(x.g.numero + '|' + x.p.etapa + '|' + x.g.aud); });
    if (fila.length) dias.push({ dia, total: vai.length, sobra: fila.length - vai.length, porEtapa });
  }
  return { ativo: !!cfg.ativo, inicio, porDia: +cfg.porDia || 70, dias, numeros: gs.length };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const body = await req.json().catch(() => ({}));

    // chamada do agendador do banco (sem usuário): confere a chave interna
    if (body.acao === 'regua' || body.acao === 'tribunal-cron') {
      const { data } = await adm.from('segredos').select('valor').eq('nome', 'regua_token').maybeSingle();
      if (!data?.valor || req.headers.get('x-regua-token') !== data.valor) return json({ erro: 'não autorizado' }, 401);
      return json(body.acao === 'regua' ? await rodarRegua() : await sincronizarTribunal());
    }

    // demais ações: só administradores logados no site
    const publica = Deno.env.get('SUPABASE_ANON_KEY') || Deno.env.get('SUPABASE_PUBLISHABLE_KEY') || '';  // chave pública do próprio projeto (o Supabase injeta)
    const sb = createClient(URL_SB, publica, { global: { headers: { Authorization: req.headers.get('Authorization') || '' } } });
    const { data: funcao } = await sb.rpc('minha_funcao');
    if (funcao !== 'admin') return json({ erro: 'Só administradores podem usar os avisos por WhatsApp.' }, 403);

    if (body.acao === 'regua-previa') return json(await previa());
    if (body.acao === 'tribunal') return json(await sincronizarTribunal());
    if (body.acao === 'regua-modelos') return json({ modelos: MODELOS, etapas: ETAPAS, local: LOCAL, tribunalPadrao: TRIBUNAL_PADRAO });

    // guarda no cofre a chave pública que o agendador usa para chamar esta função
    if (body.acao === 'regua-preparar') {
      const anon = Deno.env.get('SUPABASE_ANON_KEY') || '';
      if (!anon.startsWith('eyJ')) return json({ erro: 'Não encontrei a chave pública antiga do projeto nesta função.' }, 500);
      const { error } = await adm.from('segredos').upsert({ nome: 'regua_anon', valor: anon, atualizado_por: 'sistema', atualizado_em: new Date().toISOString() });
      if (error) return json({ erro: error.message }, 500);
      return json({ ok: true });
    }

    const key = await chaveLiderHub();
    if (!key) return json({ erro: 'A chave do LiderHub ainda não foi cadastrada. Cadastre em Configurações, na parte Integrações.' }, 400);

    if (body.acao === 'conexoes') {
      const r = await lh(key, 'GET', '/v1/connections');
      if (!r.ok) return json({ erro: 'LiderHub recusou (' + r.status + '): ' + (r.dados?.message || '') }, 502);
      const conexoes = (r.dados?.connections || []).map((c: any) => ({ id: c.id, numero: c.number, status: c.connectionStatus, tipo: c.integration }));
      return json({ conexoes });
    }

    // lista de contatos do workspace (nome e número), para completar telefones que faltam no cadastro
    if (body.acao === 'contatos') {
      const out: { nome: string; numero: string }[] = [];
      for (let page = 1; page <= 200; page++) {
        const r = await lh(key, 'GET', '/v1/contacts?limit=100&page=' + page);
        if (!r.ok) return json({ erro: 'LiderHub recusou (' + r.status + '): ' + (r.dados?.message || ''), parcial: out }, 502);
        for (const c of r.dados?.contacts || []) if (c.contactNumber) out.push({ nome: c.contactName || '', numero: c.contactNumber });
        if (!r.dados?.pagination?.hasNextPage) break;
      }
      return json({ contatos: out });
    }

    // diagnóstico: últimas mensagens da conversa com o número, com o status de entrega no LiderHub
    if (body.acao === 'mensagens') {
      const conexao = String(body.conexao || (await lerConfig()).conexao || '');
      const out: any[] = [], nome = nomeDoNumero(await carregarClientes(), String(body.numero || ''));
      for (const n of variantes(String(body.numero || ''))) {
        const c = await lh(key, 'POST', '/v1/contacts', { connection: conexao, number: n, ...(nome ? { name: nome } : {}) });
        const item: any = { numero: n, existe: !!c.dados?.exist, contato: c.dados?.id || null };
        if (c.dados?.id) {
          const m = await lh(key, 'GET', '/v1/message?limit=5&contact=' + c.dados.id);
          item.mensagens = (m.dados?.messages || []).map((x: any) => ({ id: x.id, texto: String(x.content || '').slice(0, 40), saida: x.outbound, status: x.deliveryStatus, em: x.sentAt || x.createdAt, erro: x.errorDetails || null }));
          if (!m.ok) item.erro = m.status + ' ' + (m.dados?.message || '');
        }
        out.push(item);
      }
      return json({ conexao, nome, resultado: out });
    }

    // lembrete avulso: um número por chamada (o site espaça as chamadas); não repete para o mesmo número e audiência
    if (body.acao === 'avulso') {
      const cfg = await lerConfig(), hoje = hojeMao();
      if (!cfg.conexao) return json({ erro: 'Escolha o número que envia na régua.' }, 400);
      const modelo = String(body.texto || '');
      if (modelo.trim().length < 10) return json({ erro: 'Mensagem vazia.' }, 400);
      const todos = await carregarClientes(), porId = new Map(todos.map((c) => [c.id, c]));
      const cs = (Array.isArray(body.ids) ? body.ids : []).map((i: unknown) => porId.get(String(i))).filter(Boolean) as Cli[];
      if (!cs.length) return json({ erro: 'Cliente não encontrado.' }, 400);
      const c0 = cs[0], via = !numeroBase(c0.contato) && c0.contatoVia ? porId.get(c0.contatoVia) : undefined;
      const numero = numeroBase(c0.contato) || (via ? numeroBase(via.contato) : '');
      if (!numero) return json({ erro: 'Cliente sem telefone.' }, 400);
      if (!c0.audData || c0.audData <= hoje) return json({ erro: 'Audiência já passou.' }, 400);
      const { data: ja } = await adm.from('avisos_log').select('id').eq('numero', numero).eq('etapa', 'avulso').eq('aud_data', c0.audData).eq('status', 'enviado').limit(1);
      if (ja && ja.length) return json({ ok: true, pulado: true, numero });
      const g: Grupo = { numero, aud: c0.audData, hora: c0.audHora || '', marcada: '', clientes: cs };
      const r = await enviarTexto(key, cfg.conexao, numero, nomeDoNumero(todos, numero, cs.map((c) => c.nome).join(' / ')), texto(modelo, g, hoje, cfg.local));
      await adm.from('avisos_log').insert({ numero, clientes: cs.map((c) => c.id), etapa: 'avulso', aud_data: g.aud, status: r.ok ? 'enviado' : r.semWhats ? 'sem_whatsapp' : 'erro', erro: r.ok ? null : r.erro });
      return json({ ok: r.ok, semWhats: r.semWhats, erro: r.ok ? null : r.erro, numero });
    }

    // teste: manda a etapa escolhida, com os dados do primeiro cliente da régua, para o número informado
    if (body.acao === 'regua-teste') {
      const cfg = await lerConfig(), hoje = hojeMao();
      const etapa = ETAPAS.includes(body.etapa) ? body.etapa : 'h3';
      const todos = await carregarClientes();
      const gs = grupos(todos, hoje).sort((a, b) => a.aud.localeCompare(b.aud));
      if (!gs.length) return json({ erro: 'Nenhum cliente com audiência futura e telefone.' }, 400);
      const conexao = String(body.conexao || cfg.conexao || '');
      if (!conexao) return json({ erro: 'Escolha o número que envia.' }, 400);
      const modelo = String(body.modelo || (cfg.modelos && cfg.modelos[etapa]) || MODELOS[etapa]);
      const r = await enviarTexto(key, conexao, String(body.numero || ''), nomeDoNumero(todos, String(body.numero || '')), '[TESTE] ' + texto(modelo, gs[0], hoje, cfg.local));
      await adm.from('avisos_log').insert({ numero: numeroBase(body.numero) || String(body.numero || ''), etapa: 'teste', aud_data: null, status: r.ok ? 'enviado' : 'erro', erro: r.ok ? null : r.erro });
      return json(r);
    }

    return json({ erro: 'Ação desconhecida.' }, 400);
  } catch (e) {
    return json({ erro: 'Erro no servidor: ' + ((e as Error)?.message || e) }, 500);
  }
});
