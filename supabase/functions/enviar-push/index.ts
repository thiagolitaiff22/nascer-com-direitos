// Nascer com Direitos: envia os avisos (notificações) para o celular de parceiros e prospectadores.
// O banco chama esta função quando um aviso novo é criado (função "notificar"). Ela pega os avisos pendentes e manda:
//  - iPhone / navegador: Web Push (chave VAPID guardada na tabela segredos › vapid_privada)
//  - Android: Firebase Cloud Messaging (conta de serviço guardada na tabela segredos › fcm_conta)
// Sem as chaves, os avisos ficam marcados como enviados mas nada sai (por isso as chaves vão primeiro).
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';
import { SignJWT, importPKCS8 } from 'npm:jose@5';

const adm = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
const VAPID_PUBLICA = 'BESx_bCvncjwXN3sNTHSS4cuAzzSG-zRhBFHDL35ipgNP4lAvl6AQ0xkyuhNXckkraHGi9b0MD-P56F6vlMTyaA';
const SITE = 'https://thiagolitaiff22.github.io/nascer-com-direitos/campo.html';
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });

async function segredo(nome: string): Promise<string> {
  const { data } = await adm.from('segredos').select('valor').eq('nome', nome).maybeSingle();
  return (data?.valor as string) || '';
}

let fcmToken: { t: string; exp: number } | null = null;
async function tokenFcm(conta: any): Promise<string> {
  if (fcmToken && fcmToken.exp > Date.now() + 60_000) return fcmToken.t;
  const chave = await importPKCS8(conta.private_key, 'RS256');
  const agora = Math.floor(Date.now() / 1000);
  const jwt = await new SignJWT({ scope: 'https://www.googleapis.com/auth/firebase.messaging' })
    .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
    .setIssuer(conta.client_email).setSubject(conta.client_email).setAudience('https://oauth2.googleapis.com/token')
    .setIssuedAt(agora).setExpirationTime(agora + 3600).sign(chave);
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: jwt }),
  });
  const d = await r.json();
  if (!d.access_token) throw new Error('FCM: ' + JSON.stringify(d));
  fcmToken = { t: d.access_token, exp: Date.now() + (d.expires_in || 3000) * 1000 };
  return fcmToken.t;
}

Deno.serve(async () => {
  const { data: pend, error } = await adm.rpc('push_pegar_pendentes');
  if (error) return json({ erro: error.message }, 500);
  const avisos: any[] = pend || [];
  if (!avisos.length) return json({ enviados: 0 });

  const vapidPriv = await segredo('vapid_privada');
  if (vapidPriv) webpush.setVapidDetails('mailto:equipe@rodrigueslitaiffadv.com.br', VAPID_PUBLICA, vapidPriv);
  let conta: any = null;
  try { const s = await segredo('fcm_conta'); conta = s ? JSON.parse(s) : null; } catch { conta = null; }

  let ok = 0, falhas = 0, semChave = 0;
  for (const a of avisos) {
    for (const d of a.dispositivos || []) {
      try {
        if (d.tipo === 'webpush') {
          if (!vapidPriv) { semChave++; continue; }
          const sub = d.dados?.subscription || { endpoint: d.endpoint, keys: d.dados?.keys };
          await webpush.sendNotification(sub, JSON.stringify({ titulo: a.titulo, corpo: a.corpo, aba: a.aba, url: SITE }), { TTL: 86400 });
          ok++;
        } else if (d.tipo === 'fcm') {
          if (!conta) { semChave++; continue; }
          const t = await tokenFcm(conta);
          const r = await fetch(`https://fcm.googleapis.com/v1/projects/${conta.project_id}/messages:send`, {
            method: 'POST', headers: { Authorization: 'Bearer ' + t, 'Content-Type': 'application/json' },
            body: JSON.stringify({ message: { token: d.endpoint, notification: { title: a.titulo, body: a.corpo }, data: { aba: String(a.aba || 'painel') }, android: { priority: 'HIGH', notification: { channel_id: 'avisos' } } } }),
          });
          if (r.ok) ok++;
          else {
            falhas++;
            const txt = await r.text();
            if (r.status === 404 || /UNREGISTERED|NOT_FOUND|INVALID_ARGUMENT/.test(txt)) await adm.rpc('push_desativar', { p_endpoint: d.endpoint });
          }
        }
      } catch (e: any) {
        falhas++;
        if (e?.statusCode === 404 || e?.statusCode === 410) await adm.rpc('push_desativar', { p_endpoint: d.endpoint });
      }
    }
  }
  return json({ avisos: avisos.length, enviados: ok, falhas, semChave });
});
