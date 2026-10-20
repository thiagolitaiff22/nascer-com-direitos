-- Notificações no celular (push). Pode rodar de novo.
-- Fluxo: um fato acontece (mãe confirmada, benefício liberado, pagamento registrado, documento faltando, mãe nova enviada)
--  -> o banco grava um aviso em "notificacoes" -> chama a função "enviar-push" -> ela manda para os celulares da pessoa
--     (iPhone/navegador por Web Push; Android pelo Firebase). O aviso nunca fala "contrato" e só mostra valor de pagamento já feito.

create extension if not exists pg_net;

-- as chaves de envio ficam na tabela de segredos (só a função de envio lê)
alter table public.segredos drop constraint if exists segredos_nome_check;

-- 1) celulares que aceitaram receber avisos
create table if not exists public.push_dispositivos (
  id         bigserial primary key,
  prosp_id   text not null,
  tipo       text not null check (tipo in ('webpush', 'fcm')),
  endpoint   text not null unique,
  dados      jsonb not null default '{}'::jsonb,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);
create index if not exists push_dispositivos_prosp on public.push_dispositivos (prosp_id) where ativo;
alter table public.push_dispositivos enable row level security;
revoke all on public.push_dispositivos from anon, authenticated;

-- 2) avisos
create table if not exists public.notificacoes (
  id         bigserial primary key,
  prosp_id   text not null,
  titulo     text not null,
  corpo      text not null,
  aba        text not null default 'painel',
  criada_em  timestamptz not null default now(),
  enviada_em timestamptz
);
create index if not exists notificacoes_pendentes on public.notificacoes (id) where enviada_em is null;
alter table public.notificacoes enable row level security;
revoke all on public.notificacoes from anon, authenticated;

-- 3) o aplicativo registra / remove o celular (pelo código de acesso da pessoa)
create or replace function public.push_registrar(p_token text, p_tipo text, p_endpoint text, p_dados jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pid text;
begin
  select prosp_id into pid from public.campo_acessos where token = p_token and ativo and length(p_token) >= 20;
  if pid is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  if p_tipo not in ('webpush', 'fcm') or coalesce(p_endpoint, '') = '' then return jsonb_build_object('erro', 'Dados inválidos.'); end if;
  insert into public.push_dispositivos (prosp_id, tipo, endpoint, dados, ativo) values (pid, p_tipo, p_endpoint, coalesce(p_dados, '{}'::jsonb), true)
  on conflict (endpoint) do update set prosp_id = excluded.prosp_id, tipo = excluded.tipo, dados = excluded.dados, ativo = true;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.push_registrar(text, text, text, jsonb) from public;
grant execute on function public.push_registrar(text, text, text, jsonb) to anon, authenticated;

create or replace function public.push_remover(p_token text, p_endpoint text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pid text;
begin
  select prosp_id into pid from public.campo_acessos where token = p_token and ativo and length(p_token) >= 20;
  if pid is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  update public.push_dispositivos set ativo = false where endpoint = p_endpoint and prosp_id = pid;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.push_remover(text, text) from public;
grant execute on function public.push_remover(text, text) to anon, authenticated;

-- 4) a função de envio pega os avisos pendentes (e já marca como enviados) junto com os celulares de cada pessoa
create or replace function public.push_pegar_pendentes()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  with pegos as (
    update public.notificacoes n set enviada_em = now()
    where n.id in (select id from public.notificacoes where enviada_em is null order by id limit 50 for update skip locked)
    returning n.id, n.prosp_id, n.titulo, n.corpo, n.aba
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'titulo', g.titulo, 'corpo', g.corpo, 'aba', g.aba,
      'dispositivos', coalesce((select jsonb_agg(jsonb_build_object('tipo', d.tipo, 'endpoint', d.endpoint, 'dados', d.dados))
                                from public.push_dispositivos d where d.prosp_id = g.prosp_id and d.ativo), '[]'::jsonb))), '[]'::jsonb)
  into r from pegos g;
  return r;
end $$;
revoke all on function public.push_pegar_pendentes() from public, anon, authenticated;
grant execute on function public.push_pegar_pendentes() to service_role;

create or replace function public.push_desativar(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  update public.push_dispositivos set ativo = false where endpoint = p_endpoint;
$$;
revoke all on function public.push_desativar(text) from public, anon, authenticated;
grant execute on function public.push_desativar(text) to service_role;

-- 5) criar um aviso e acordar a função de envio
create or replace function public.notificar(p_dest text, p_titulo text, p_corpo text, p_aba text default 'painel')
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_dest, '') = '' then return; end if;
  insert into public.notificacoes (prosp_id, titulo, corpo, aba) values (p_dest, p_titulo, p_corpo, coalesce(p_aba, 'painel'));
  begin
    perform net.http_post(
      url := 'https://rqgaliouhuulycbxxmjd.supabase.co/functions/v1/enviar-push',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJxZ2FsaW91aHV1bHljYnh4bWpkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTE4MjU4OTIsImV4cCI6MjEwNzQwMTg5Mn0.Jgtz27iGOI9Vwt_4EXzbe6xuKEYKt5JjETO6Q9vgAuM'),
      body := '{}'::jsonb);
  exception when others then null;   -- sem a extensão ou sem a função publicada: o aviso fica guardado e sai depois
  end;
end $$;
revoke all on function public.notificar(text, text, text, text) from public, anon, authenticated;

-- 6) os fatos que geram aviso
create or replace function public.tg_notificar_clientes()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  n jsonb := new.data;
  o jsonb := case when tg_op = 'UPDATE' then old.data else '{}'::jsonb end;
  resp text := coalesce(n ->> 'responsavelId', '');
  nome text := coalesce(nullif(trim(n ->> 'nome'), ''), 'uma mãe');
  pros text; parc text; rec record; v numeric; qual text;
  lib_n boolean; lib_o boolean; fd_n int; fd_o int;
begin
  if resp = '' then return new; end if;
  select coalesce(data ->> 'prospectadorId', ''), coalesce(data ->> 'nome', '') into pros, parc from public.prospectadores where id = resp;
  pros := coalesce(pros, ''); parc := coalesce(parc, '');
  if pros = resp then pros := ''; end if;

  if tg_op = 'INSERT' then
    if n ->> 'origem' = 'campo' and pros <> '' then
      perform public.notificar(pros, 'Nova mãe enviada', coalesce(nullif(parc, ''), 'Um parceiro seu') || ' enviou ' || nome || '.', 'maes');
    end if;
    return new;
  end if;

  -- mãe confirmada (o contrato foi fechado)
  if coalesce(o ->> 'contratoEm', '') = '' and coalesce(n ->> 'contratoEm', '') <> '' then
    perform public.notificar(resp, 'Mãe confirmada', nome || ' foi confirmada.', 'maes');
    if pros <> '' then perform public.notificar(pros, 'Mãe confirmada', nome || ' (' || coalesce(nullif(parc, ''), 'parceiro') || ') foi confirmada.', 'maes'); end if;
  end if;

  -- benefício liberado
  lib_n := (n ->> 'inssStatus' = 'concedido' or n ->> 'resultado' in ('procedente', 'parcial', 'acordo'));
  lib_o := (o ->> 'inssStatus' = 'concedido' or o ->> 'resultado' in ('procedente', 'parcial', 'acordo'));
  if lib_n and not coalesce(lib_o, false) then
    perform public.notificar(resp, 'Benefício liberado', 'O benefício de ' || nome || ' foi liberado.', 'maes');
    if pros <> '' then perform public.notificar(pros, 'Benefício liberado', 'O benefício de ' || nome || ' (' || coalesce(nullif(parc, ''), 'parceiro') || ') foi liberado.', 'maes'); end if;
  end if;

  -- documento faltando
  fd_n := case when jsonb_typeof(n -> 'faltaDocs') = 'array' then jsonb_array_length(n -> 'faltaDocs') else 0 end;
  fd_o := case when jsonb_typeof(o -> 'faltaDocs') = 'array' then jsonb_array_length(o -> 'faltaDocs') else 0 end;
  if fd_n > 0 and fd_o = 0 then
    perform public.notificar(resp, 'Falta documento', 'Falta documento de ' || nome || '. Toque para completar.', 'maes');
  end if;

  -- pagamento registrado (só depois de pago)
  for rec in
    select m.key as marco, pa.key as papel, pa.value as p
    from jsonb_each(coalesce(n -> 'rede', '{}'::jsonb)) m, jsonb_each(m.value) pa
    where jsonb_typeof(pa.value) = 'object' and coalesce(pa.value ->> 'pagoEm', '') <> ''
  loop
    if coalesce(o #>> array['rede', rec.marco, rec.papel, 'pagoEm'], '') = '' then
      v := coalesce(nullif(rec.p ->> 'valor', '')::numeric, 0);
      qual := case when rec.marco = 'lib' then 'Benefício liberado' else 'Mãe confirmada' end;
      perform public.notificar(rec.p ->> 'pessoaId', 'Pagamento registrado',
        'Você recebeu R$ ' || replace(to_char(v, 'FM999999990.00'), '.', ',') || ' · ' || nome || ' (' || qual || ').', 'recebimentos');
    end if;
  end loop;
  return new;
exception when others then
  return new;   -- um erro nos avisos nunca pode atrapalhar a gravação da cliente
end $$;
drop trigger if exists notificar_clientes on public.clientes;
create trigger notificar_clientes after insert or update on public.clientes
  for each row execute function public.tg_notificar_clientes();

select 'ok' as notificacoes_push;
