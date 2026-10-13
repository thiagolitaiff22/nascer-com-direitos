
-- ================= 01_estrutura.sql =================
-- Nascer com Direitos (salário-maternidade): estrutura do banco no Supabase.
-- Cole este arquivo inteiro no SQL Editor do Supabase e clique em "Run".
-- Pode rodar de novo sem perder dados (usa "if not exists" / "or replace").

-- ---------------------------------------------------------------
-- Equipe: quem pode entrar no sistema (pelo e-mail do login)
-- ---------------------------------------------------------------
create table if not exists public.equipe (
  email      text primary key check (email = lower(email)),
  nome       text not null,
  funcao     text not null default 'assistente' check (funcao in ('admin', 'assistente')),
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

-- Função do usuário logado ('admin', 'assistente' ou null se não estiver na equipe/ativo)
create or replace function public.minha_funcao()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select funcao from public.equipe
  where email = lower(coalesce(auth.jwt() ->> 'email', '')) and ativo
$$;
revoke all on function public.minha_funcao() from public;
grant execute on function public.minha_funcao() to authenticated;

-- ---------------------------------------------------------------
-- Documentos do app (mesmo formato usado hoje: id + dados em JSON)
-- ---------------------------------------------------------------
create table if not exists public.clientes (
  id            text primary key,
  data          jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
create table if not exists public.prospectadores (
  id            text primary key,
  data          jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);
create table if not exists public.config (
  id            text primary key,
  data          jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now(),
  atualizado_por uuid default auth.uid()
);

-- Carimbo de alteração automático
create or replace function public.carimbar()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  new.atualizado_por := auth.uid();
  return new;
end $$;
drop trigger if exists carimbar on public.clientes;
create trigger carimbar before update on public.clientes for each row execute function public.carimbar();
drop trigger if exists carimbar on public.prospectadores;
create trigger carimbar before update on public.prospectadores for each row execute function public.carimbar();
drop trigger if exists carimbar on public.config;
create trigger carimbar before update on public.config for each row execute function public.carimbar();

-- Atualização parcial (junta os campos novos aos existentes), respeitando as regras de acesso
create or replace function public.atualizar_doc(p_tabela text, p_id text, p_campos jsonb)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare n integer;
begin
  if p_tabela not in ('clientes', 'prospectadores', 'config') then
    raise exception 'tabela inválida';
  end if;
  execute format(
    'update public.%I set data = data || $2 where id = $1',
    p_tabela) using p_id, p_campos;
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'registro não encontrado ou sem permissão';
  end if;
end $$;
grant execute on function public.atualizar_doc(text, text, jsonb) to authenticated;

-- ---------------------------------------------------------------
-- Regras de acesso (RLS)
--   membro ativo: lê e grava clientes, prospectadores e config
--   só administrador: exclui registros e gerencia a equipe
-- ---------------------------------------------------------------
alter table public.equipe enable row level security;
alter table public.clientes enable row level security;
alter table public.prospectadores enable row level security;
alter table public.config enable row level security;

do $$
declare t text;
begin
  foreach t in array array['clientes', 'prospectadores', 'config'] loop
    execute format('drop policy if exists membro_le on public.%I', t);
    execute format('drop policy if exists membro_cria on public.%I', t);
    execute format('drop policy if exists membro_altera on public.%I', t);
    execute format('drop policy if exists admin_exclui on public.%I', t);
    execute format('create policy membro_le on public.%I for select to authenticated using (public.minha_funcao() is not null)', t);
    execute format('create policy membro_cria on public.%I for insert to authenticated with check (public.minha_funcao() is not null)', t);
    execute format('create policy membro_altera on public.%I for update to authenticated using (public.minha_funcao() is not null) with check (public.minha_funcao() is not null)', t);
    execute format('create policy admin_exclui on public.%I for delete to authenticated using (public.minha_funcao() = ''admin'')', t);
  end loop;
end $$;

drop policy if exists equipe_le on public.equipe;
drop policy if exists equipe_admin_cria on public.equipe;
drop policy if exists equipe_admin_altera on public.equipe;
drop policy if exists equipe_admin_exclui on public.equipe;
create policy equipe_le on public.equipe for select to authenticated
  using (public.minha_funcao() is not null or email = lower(coalesce(auth.jwt() ->> 'email', '')));
create policy equipe_admin_cria on public.equipe for insert to authenticated
  with check (public.minha_funcao() = 'admin');
create policy equipe_admin_altera on public.equipe for update to authenticated
  using (public.minha_funcao() = 'admin') with check (public.minha_funcao() = 'admin');
create policy equipe_admin_exclui on public.equipe for delete to authenticated
  using (public.minha_funcao() = 'admin' and email <> lower(coalesce(auth.jwt() ->> 'email', '')));

-- Nunca deixar o sistema sem administrador ativo
create or replace function public.proteger_ultimo_admin()
returns trigger language plpgsql as $$
begin
  if (tg_op = 'DELETE' or new.funcao <> 'admin' or not new.ativo) and old.funcao = 'admin' and old.ativo then
    if (select count(*) from public.equipe where funcao = 'admin' and ativo and email <> old.email) = 0 then
      raise exception 'É preciso manter pelo menos um administrador ativo.';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  new.atualizado_em := now();
  return new;
end $$;
drop trigger if exists proteger_ultimo_admin on public.equipe;
create trigger proteger_ultimo_admin before update or delete on public.equipe
  for each row execute function public.proteger_ultimo_admin();

-- ---------------------------------------------------------------
-- Tempo real (as telas abertas se atualizam sozinhas)
-- ---------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['clientes', 'prospectadores', 'config', 'equipe'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
alter table public.clientes replica identity full;
alter table public.prospectadores replica identity full;
alter table public.config replica identity full;
alter table public.equipe replica identity full;

-- Permissões de acesso pela API (as regras acima decidem o que cada um vê)
grant usage on schema public to authenticated;
grant select, insert, update, delete on public.equipe, public.clientes, public.prospectadores, public.config to authenticated;
revoke all on public.equipe, public.clientes, public.prospectadores, public.config from anon;

-- ---------------------------------------------------------------
-- Primeiro administrador
-- ---------------------------------------------------------------
-- Projeto novo: a tabela equipe começa vazia e ninguém entra no sistema até existir um administrador.
--  1) Crie o usuário em Authentication › Users (o mesmo e-mail que vai usar para entrar no sistema).
--  2) Tire os "--" das três linhas abaixo, troque o e-mail (em minúsculas) e o nome, e rode só esse trecho.
--
-- insert into public.equipe (email, nome, funcao)
-- values ('seu.email@exemplo.com.br', 'Seu Nome', 'admin')
-- on conflict (email) do update set funcao = 'admin', ativo = true;
--
-- Os demais membros o administrador cadastra pelo próprio sistema (Configurações › Equipe).


-- ================= 02_segredos.sql =================
-- Chaves de integração (ex.: LiderHub) guardadas no banco, sem leitura pelo site.
-- Administradores gravam pela aba Equipe; só a função de envio (chave de serviço) lê.
create table if not exists public.segredos (
  nome          text primary key check (nome in ('liderhub')),
  valor         text not null,
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
alter table public.segredos enable row level security;
-- nenhuma regra de leitura: o site (anon/authenticated) não enxerga a tabela
revoke all on public.segredos from anon, authenticated;
grant all on public.segredos to service_role;

create or replace function public.salvar_segredo(p_nome text, p_valor text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.minha_funcao() is distinct from 'admin' then
    raise exception 'Só administradores podem alterar chaves de integração.';
  end if;
  if coalesce(trim(p_valor), '') = '' then
    delete from public.segredos where nome = p_nome;
    return;
  end if;
  insert into public.segredos (nome, valor, atualizado_em, atualizado_por)
  values (p_nome, trim(p_valor), now(), lower(auth.jwt() ->> 'email'))
  on conflict (nome) do update set valor = excluded.valor, atualizado_em = now(), atualizado_por = excluded.atualizado_por;
end $$;
revoke all on function public.salvar_segredo(text, text) from public, anon;
grant execute on function public.salvar_segredo(text, text) to authenticated;

-- Só informa se existe e quando foi trocada (nunca devolve a chave)
create or replace function public.status_segredo(p_nome text)
returns table (configurada boolean, atualizado_em timestamptz, atualizado_por text, final text)
language sql stable security definer set search_path = public as $$
  select true, s.atualizado_em, s.atualizado_por, right(s.valor, 4)
  from public.segredos s
  where s.nome = p_nome and public.minha_funcao() = 'admin'
$$;
revoke all on function public.status_segredo(text) from public, anon;
grant execute on function public.status_segredo(text) to authenticated;

select 'ok' as segredos;


-- ================= 03_regua.sql =================
-- Régua automática de avisos por WhatsApp (LiderHub).
-- Registro de cada aviso enviado (ou pulado/com erro) por número, etapa e data da audiência.
-- Pode rodar de novo sem perder dados.
create table if not exists public.avisos_log (
  id          bigserial primary key,
  numero      text not null,
  clientes    text[] not null default '{}',
  etapa       text not null check (etapa in ('designacao', 'd10', 'h10', 'h5', 'h1', 'teste')),
  aud_data    date,
  status      text not null check (status in ('enviado', 'erro', 'sem_whatsapp')),
  erro        text,
  criado_em   timestamptz not null default now()
);
create unique index if not exists avisos_log_unico on public.avisos_log (numero, etapa, aud_data) where status in ('enviado', 'sem_whatsapp');
create index if not exists avisos_log_data on public.avisos_log (criado_em);
alter table public.avisos_log enable row level security;
drop policy if exists membro_le on public.avisos_log;
create policy membro_le on public.avisos_log for select to authenticated using (public.minha_funcao() is not null);
grant select on public.avisos_log to authenticated;
grant all on public.avisos_log to service_role;
grant usage, select on sequence public.avisos_log_id_seq to service_role;

-- Chave interna para o agendador chamar a função (gerada aqui, nunca exibida)
alter table public.segredos drop constraint if exists segredos_nome_check;
alter table public.segredos add constraint segredos_nome_check check (nome in ('liderhub', 'regua_token', 'regua_anon'));
insert into public.segredos (nome, valor, atualizado_por)
values ('regua_token', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'sistema')
on conflict (nome) do nothing;

-- Configuração padrão (régua desligada até o administrador ativar).
-- tribunalAlias: tribunal consultado no DataJud (api_publica_<alias>): 'trf1' (Justiça Federal) ou 'tjam'.
insert into public.config (id, data) values ('regua', jsonb_build_object('ativo', false, 'porDia', 70, 'tribunalAlias', 'trf1'))
on conflict (id) do nothing;

-- Extensões usadas pelos agendadores (o agendamento em si fica no 06_agendador.sql)
create extension if not exists pg_cron;
create extension if not exists pg_net;

select 'ok' as regua;


-- ================= 04_historico.sql =================
-- Histórico de alterações dos clientes: quem mudou o quê e quando (gravado pelo próprio banco).
create table if not exists public.clientes_historico (
  id          bigserial primary key,
  cliente_id  text not null,
  acao        text not null check (acao in ('criado', 'alterado', 'excluido')),
  por         text,
  em          timestamptz not null default now(),
  mudancas    jsonb not null default '{}'::jsonb
);
create index if not exists clientes_historico_cliente on public.clientes_historico (cliente_id, em desc);
alter table public.clientes_historico enable row level security;
drop policy if exists membro_le on public.clientes_historico;
create policy membro_le on public.clientes_historico for select to authenticated using (public.minha_funcao() is not null);
grant select on public.clientes_historico to authenticated;
grant all on public.clientes_historico to service_role;

create or replace function public.registrar_historico()
returns trigger language plpgsql security definer set search_path = public as $$
declare quem text := coalesce(lower(auth.jwt() ->> 'email'), 'sistema'); dif jsonb := '{}'::jsonb; k text;
begin
  if tg_op = 'INSERT' then
    insert into public.clientes_historico (cliente_id, acao, por, mudancas) values (new.id, 'criado', quem, jsonb_build_object('nome', new.data -> 'nome'));
    return new;
  elsif tg_op = 'DELETE' then
    insert into public.clientes_historico (cliente_id, acao, por, mudancas) values (old.id, 'excluido', quem, jsonb_build_object('nome', old.data -> 'nome'));
    return old;
  end if;
  for k in select key from jsonb_each(coalesce(new.data, '{}'::jsonb)) union select key from jsonb_each(coalesce(old.data, '{}'::jsonb)) loop
    if k not in ('atualizadoEm', 'reguaUltimo') and (old.data -> k) is distinct from (new.data -> k) then
      dif := dif || jsonb_build_object(k, jsonb_build_array(old.data -> k, new.data -> k));
    end if;
  end loop;
  if dif <> '{}'::jsonb then
    insert into public.clientes_historico (cliente_id, acao, por, mudancas) values (new.id, 'alterado', quem, dif);
  end if;
  return new;
end $$;
drop trigger if exists registrar_historico on public.clientes;
create trigger registrar_historico after insert or update or delete on public.clientes
  for each row execute function public.registrar_historico();

select 'ok' as historico;


-- ================= 05_tribunal.sql =================
-- Consulta diária ao tribunal (DataJud / CNJ). O tribunal é configurável (config "regua", campo tribunalAlias: trf1, tjam...).
alter table public.segredos drop constraint if exists segredos_nome_check;
alter table public.segredos add constraint segredos_nome_check check (nome in ('liderhub', 'regua_token', 'regua_anon', 'datajud'));

-- o resumo do tribunal é atualizado pela consulta; não precisa entrar no histórico de alterações
create or replace function public.registrar_historico()
returns trigger language plpgsql security definer set search_path = public as $$
declare quem text := coalesce(lower(auth.jwt() ->> 'email'), 'sistema'); dif jsonb := '{}'::jsonb; k text;
begin
  if tg_op = 'INSERT' then
    insert into public.clientes_historico (cliente_id, acao, por, mudancas) values (new.id, 'criado', quem, jsonb_build_object('nome', new.data -> 'nome'));
    return new;
  elsif tg_op = 'DELETE' then
    insert into public.clientes_historico (cliente_id, acao, por, mudancas) values (old.id, 'excluido', quem, jsonb_build_object('nome', old.data -> 'nome'));
    return old;
  end if;
  for k in select key from jsonb_each(coalesce(new.data, '{}'::jsonb)) union select key from jsonb_each(coalesce(old.data, '{}'::jsonb)) loop
    if k not in ('atualizadoEm', 'reguaUltimo', 'tribunal') and (old.data -> k) is distinct from (new.data -> k) then
      dif := dif || jsonb_build_object(k, jsonb_build_array(old.data -> k, new.data -> k));
    end if;
  end loop;
  if dif <> '{}'::jsonb then
    insert into public.clientes_historico (cliente_id, acao, por, mudancas) values (new.id, 'alterado', quem, dif);
  end if;
  return new;
end $$;

-- O agendamento diário (7h de Manaus, segunda a sábado) fica no 06_agendador.sql.

select 'ok' as tribunal;


-- ================= 06_agendador.sql =================
-- Agendadores (pg_cron) que chamam a função lembrete-whatsapp:
--   regua-avisos      a cada 10 minutos, todos os dias, das 8h às 17h50 de Manaus (12h–21h50 UTC)
--   tribunal-datajud  todo dia às 7h de Manaus (11h UTC), de segunda a sábado
-- Eles chamam a função só com a chave interna (x-regua-token); a própria função confere.
-- Requer "Verify JWT with legacy secret" DESLIGADO na função lembrete-whatsapp (Edge Functions › Settings).
--
-- ANTES DE RODAR: troque SEU-PROJETO abaixo pelo "Project ref" do projeto novo
-- (Project Settings › General; é o começo da Project URL: https://<ref>.supabase.co).
-- Enquanto estiver SEU-PROJETO, este arquivo não agenda nada (só avisa). Pode rodar de novo.

do $$
declare
  v_url text := 'https://SEU-PROJETO.supabase.co/functions/v1/lembrete-whatsapp';
begin
  if v_url like '%SEU-PROJETO%' then
    raise notice 'Agendadores NÃO criados: troque SEU-PROJETO no 06_agendador.sql pelo ref do projeto e rode de novo.';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname in ('regua-avisos', 'tribunal-datajud');
  perform cron.schedule('regua-avisos', '*/10 12-21 * * *', format($job$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-regua-token', (select valor from public.segredos where nome = 'regua_token')),
      body := '{"acao":"regua"}'::jsonb,
      timeout_milliseconds := 120000
    );
  $job$, v_url));
  perform cron.schedule('tribunal-datajud', '0 11 * * 1-6', format($job$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-regua-token', (select valor from public.segredos where nome = 'regua_token')),
      body := '{"acao":"tribunal-cron"}'::jsonb,
      timeout_milliseconds := 120000
    );
  $job$, v_url));
end $$;

select jobname, schedule, active from cron.job where jobname in ('regua-avisos', 'tribunal-datajud') order by 1;


-- ================= 07_cadencia.sql =================
-- Cadência da régua: 3 dias antes (h3) e véspera (h1), todos os dias da semana.
-- O horário do agendador (8h às 18h de Manaus, todos os dias) já está no 06_agendador.sql. Pode rodar de novo.
alter table public.avisos_log drop constraint if exists avisos_log_etapa_check;
alter table public.avisos_log add constraint avisos_log_etapa_check check (etapa in ('h3', 'h1', 'designacao', 'd10', 'h10', 'h5', 'teste'));
select 'ok' as cadencia;


-- ================= 08_avulso.sql =================
-- Lembrete avulso (enviado pelo site, espaçado).
alter table public.avisos_log drop constraint if exists avisos_log_etapa_check;
alter table public.avisos_log add constraint avisos_log_etapa_check check (etapa in ('h3', 'h1', 'avulso', 'designacao', 'd10', 'h10', 'h5', 'teste'));
select pg_get_constraintdef(oid) from pg_constraint where conname = 'avisos_log_etapa_check';


-- ================= 09_campo.sql =================
-- Cadastro pelo celular do prospectador (página campo.html).
-- O prospectador não tem login: entra por um link individual (campo.html#t=CÓDIGO) que o administrador gera.
-- Quem grava no banco é o script do Google (Drive + leitura dos documentos), usando o código do link.
-- Pode rodar de novo sem perder dados.

create table if not exists public.campo_acessos (
  token      text primary key,
  prosp_id   text not null,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now(),
  criado_por text
);
alter table public.campo_acessos enable row level security;
revoke all on public.campo_acessos from anon, authenticated;
grant all on public.campo_acessos to service_role;

-- endereço do script do Google que recebe as fotos (gravado pelo administrador)
create table if not exists public.campo_config (
  id         int primary key default 1 check (id = 1),
  envio_url  text
);
alter table public.campo_config enable row level security;
revoke all on public.campo_config from anon, authenticated;
insert into public.campo_config (id) values (1) on conflict do nothing;

-- administrador: gera (ou devolve) o link de um prospectador
create or replace function public.campo_link(p_prosp text, p_novo boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare t text;
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  if p_novo then update public.campo_acessos set ativo = false where prosp_id = p_prosp; end if;
  select token into t from public.campo_acessos where prosp_id = p_prosp and ativo order by criado_em desc limit 1;
  if t is null then
    t := replace(replace(encode(extensions.gen_random_bytes(18), 'base64'), '+', '-'), '/', '_');
    insert into public.campo_acessos (token, prosp_id, criado_por) values (t, p_prosp, lower(auth.jwt() ->> 'email'));
  end if;
  return t;
end $$;
revoke all on function public.campo_link(text, boolean) from public, anon;
grant execute on function public.campo_link(text, boolean) to authenticated;

-- administrador: grava o endereço do script do Google
create or replace function public.campo_salvar_url(p_url text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  update public.campo_config set envio_url = nullif(trim(p_url), '') where id = 1;
end $$;
revoke all on function public.campo_salvar_url(text) from public, anon;
grant execute on function public.campo_salvar_url(text) to authenticated;

create or replace function public.campo_url_status()
returns text language sql stable security definer set search_path = public as $$
  select envio_url from public.campo_config where id = 1 and public.minha_funcao() = 'admin'
$$;
revoke all on function public.campo_url_status() from public, anon;
grant execute on function public.campo_url_status() to authenticated;

-- celular / script: quem é o dono do link, para onde enviar e os cadastros dele
-- etapa: sem_requerimento (sem DER/protocolo do INSS e sem processo) · inss (requerida no INSS, sem processo)
--        justica (tem processo, sem audiência) · audiencia (audiência marcada)
create or replace function public.campo_quem(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'prospId', a.prosp_id,
    'nome', coalesce(p.data ->> 'nome', ''),
    'envioUrl', (select envio_url from public.campo_config where id = 1),
    'cadastros', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nome', c.data ->> 'nome', 'em', c.data ->> 'criadoEm',
        'etapa', case when coalesce(trim(c.data ->> 'processo'), '') <> '' then
                        case when coalesce(c.data ->> 'audData', '') = '' then 'justica' else 'audiencia' end
                      when coalesce(trim(c.data ->> 'der'), '') <> '' or coalesce(trim(c.data ->> 'protocoloInss'), '') <> '' then 'inss'
                      else 'sem_requerimento' end)
        order by c.data ->> 'criadoEm' desc)
      from (select * from public.clientes c2 where c2.data ->> 'responsavelId' = a.prosp_id and c2.data ->> 'origem' = 'campo'
            order by c2.data ->> 'criadoEm' desc limit 60) c), '[]'::jsonb)
  )
  from public.campo_acessos a left join public.prospectadores p on p.id = a.prosp_id
  where a.token = p_token and a.ativo and length(p_token) >= 20
$$;
revoke all on function public.campo_quem(text) from public;
grant execute on function public.campo_quem(text) to anon, authenticated;

-- script do Google: cria a cliente (uma vez por envio) já ligada ao prospectador do link.
-- A função campo_cadastrar fica num lugar só, na versão completa: 19_foto_cliente.sql
-- (dados da mãe, tipo de segurada, criança, fato gerador, documentos que faltaram e foto).

select 'ok' as campo;

-- script do Google: das pastas que ele informa, em que etapa está a cliente de cada uma
-- (só as que já saíram de "pendente"): 'arquivado' · 'justica' (tem processo) · 'inss' (tem DER ou protocolo do INSS)
drop function if exists public.campo_pastas_protocoladas(text[]);  -- substituída por campo_pastas_etapas
create or replace function public.campo_pastas_etapas(p_ids text[])
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(x.pasta, x.etapa), '{}'::jsonb)
  from (
    select distinct on (c.data ->> 'pastaId') c.data ->> 'pastaId' as pasta,
      case when coalesce(c.data ->> 'arquivado', 'false') = 'true' then 'arquivado'
           when coalesce(trim(c.data ->> 'processo'), '') <> '' then 'justica'
           else 'inss' end as etapa
    from public.clientes c
    where c.data ->> 'pastaId' = any(p_ids[1:500])
      and (coalesce(c.data ->> 'arquivado', 'false') = 'true'
           or coalesce(trim(c.data ->> 'processo'), '') <> ''
           or coalesce(trim(c.data ->> 'der'), '') <> ''
           or coalesce(trim(c.data ->> 'protocoloInss'), '') <> '')
    order by c.data ->> 'pastaId', c.atualizado_em desc
  ) x
$$;
revoke all on function public.campo_pastas_etapas(text[]) from public;
grant execute on function public.campo_pastas_etapas(text[]) to anon, authenticated;

select 'ok' as campo_pastas;


-- ================= 10_claude.sql =================
-- Chave do Claude guardada no banco (Configurações › Integrações › Claude), lida só pelo script do Google.
-- O script se registra uma vez com um código secreto gerado por ele mesmo; só quem tem esse código lê a chave.
-- Pode rodar de novo sem perder dados.

alter table public.segredos drop constraint if exists segredos_nome_check;
alter table public.segredos add constraint segredos_nome_check
  check (nome in ('liderhub', 'regua_token', 'regua_anon', 'datajud', 'claude', 'campo_script'));

-- script do Google: registra o código dele (só funciona se ainda não houver um registrado)
create or replace function public.campo_registrar_script(p_segredo text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if length(coalesce(p_segredo, '')) < 32 then return false; end if;
  insert into public.segredos (nome, valor, atualizado_por) values ('campo_script', p_segredo, 'script do Google')
  on conflict (nome) do nothing;
  return exists (select 1 from public.segredos where nome = 'campo_script' and valor = p_segredo);
end $$;
revoke all on function public.campo_registrar_script(text) from public;
grant execute on function public.campo_registrar_script(text) to anon, authenticated;

-- script do Google: lê a chave do Claude com o código dele
create or replace function public.campo_chave_claude(p_segredo text)
returns text language sql stable security definer set search_path = public as $$
  select c.valor from public.segredos c
  where c.nome = 'claude'
    and exists (select 1 from public.segredos s where s.nome = 'campo_script' and s.valor = p_segredo and length(p_segredo) >= 32)
$$;
revoke all on function public.campo_chave_claude(text) from public;
grant execute on function public.campo_chave_claude(text) to anon, authenticated;

-- administrador: desfaz o registro do script (se trocar de script, ele se registra de novo)
create or replace function public.campo_esquecer_script()
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  delete from public.segredos where nome = 'campo_script';
end $$;
revoke all on function public.campo_esquecer_script() from public, anon;
grant execute on function public.campo_esquecer_script() to authenticated;

select 'ok' as claude;


-- ================= 11_pastas.sql =================
-- Pasta automática da cliente no Google Drive
-- (NASCER COM DIREITOS › CLIENTES › PENDENTES DE REQUERIMENTO / NO INSS / NA JUSTIÇA / ARQUIVADOS).
-- Pode rodar de novo sem perder dados.

-- equipe: endereço do script do Google (o mesmo do cadastro pelo celular), para criar a pasta ao cadastrar
create or replace function public.campo_url_equipe()
returns text language sql stable security definer set search_path = public as $$
  select envio_url from public.campo_config where id = 1 and public.minha_funcao() is not null
$$;
revoke all on function public.campo_url_equipe() from public, anon;
grant execute on function public.campo_url_equipe() to authenticated;

-- script do Google: em que etapa está a cliente de cada pasta (só das pastas que ele mesmo informa)
-- 'arquivado' · 'justica' (tem processo) · 'inss' (tem DER ou protocolo do INSS) · 'pendente' (sem requerimento)
create or replace function public.campo_pastas_status(p_ids text[])
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(x.pasta, x.etapa), '{}'::jsonb)
  from (
    select distinct on (c.data ->> 'pastaId') c.data ->> 'pastaId' as pasta,
      case when coalesce(c.data ->> 'arquivado', 'false') = 'true' then 'arquivado'
           when coalesce(trim(c.data ->> 'processo'), '') <> '' then 'justica'
           when coalesce(trim(c.data ->> 'der'), '') <> '' or coalesce(trim(c.data ->> 'protocoloInss'), '') <> '' then 'inss'
           else 'pendente' end as etapa
    from public.clientes c
    where c.data ->> 'pastaId' = any(p_ids[1:1000])
    order by c.data ->> 'pastaId', c.atualizado_em desc
  ) x
$$;
revoke all on function public.campo_pastas_status(text[]) from public;
grant execute on function public.campo_pastas_status(text[]) to anon, authenticated;

select 'ok' as pastas;


-- ================= 12_ler_pasta.sql =================
-- Leitura automática dos documentos da pasta da cliente (script do Google + IA):
-- dados da mãe (nome, CPF, RG, nascimento, endereço, NIT) e da criança (nome, data de nascimento).
-- Preenche só os campos que estão vazios no cadastro e marca "conferir dados". Pode rodar de novo.

create or replace function public.campo_preencher_pasta(p_segredo text, p_pasta text, p_dados jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare cid text; atual jsonb; novos jsonb;
begin
  if not exists (select 1 from public.segredos s where s.nome = 'campo_script' and s.valor = p_segredo and length(p_segredo) >= 32) then
    raise exception 'Script não autorizado.';
  end if;
  select id, data into cid, atual from public.clientes where data ->> 'pastaId' = p_pasta limit 1;
  if cid is null then return 0; end if;
  select coalesce(jsonb_object_agg(e.key, left(e.value, 300)), '{}'::jsonb) into novos
  from jsonb_each_text(coalesce(p_dados, '{}'::jsonb)) e
  where e.key in ('nome', 'cpf', 'rg', 'nascimento', 'endereco', 'nit', 'crianca', 'criancaNasc')
    and coalesce(trim(e.value), '') <> ''
    and (e.key <> 'criancaNasc' or e.value ~ '^\d{4}-\d{2}-\d{2}$')
    and coalesce(trim(atual ->> e.key), '') = '';
  update public.clientes set data = data || novos
    || jsonb_build_object('leituraIA', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
    || case when novos <> '{}'::jsonb then jsonb_build_object('conferirDados', true) else '{}'::jsonb end
  where id = cid;
  return (select count(*) from jsonb_object_keys(novos));
end $$;
revoke all on function public.campo_preencher_pasta(text, text, jsonb) from public;
grant execute on function public.campo_preencher_pasta(text, text, jsonb) to anon, authenticated;

select 'ok' as ler_pasta;


-- ================= 13_login_app.sql =================
-- Aplicativo do prospectador: entrada com usuário e senha (em vez de colar o link).
-- O administrador define o usuário e a senha no BI (Prospectadores › Acesso do aplicativo).
-- A senha fica guardada só como hash (bcrypt). Depois de 5 senhas erradas, o usuário fica bloqueado por 15 minutos.
-- Pode rodar de novo sem perder dados.

create table if not exists public.campo_logins (
  usuario       text primary key,
  prosp_id      text not null unique,
  senha_hash    text not null,
  ativo         boolean not null default true,
  erros         int not null default 0,
  bloqueado_ate timestamptz,
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
alter table public.campo_logins enable row level security;
revoke all on public.campo_logins from anon, authenticated;
grant all on public.campo_logins to service_role;

-- administrador: cria ou troca o usuário e a senha de um prospectador
create or replace function public.campo_definir_login(p_prosp text, p_usuario text, p_senha text)
returns text language plpgsql security definer set search_path = public as $$
declare u text := lower(trim(coalesce(p_usuario, '')));
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  if u !~ '^[a-z0-9._-]{3,30}$' then raise exception 'Usuário: de 3 a 30 letras ou números, sem espaço nem acento.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  if exists (select 1 from public.campo_logins where usuario = u and prosp_id <> p_prosp) then raise exception 'Este usuário já é de outro prospectador.'; end if;
  delete from public.campo_logins where prosp_id = p_prosp and usuario <> u;
  insert into public.campo_logins (usuario, prosp_id, senha_hash, atualizado_por)
  values (u, p_prosp, extensions.crypt(p_senha, extensions.gen_salt('bf')), lower(auth.jwt() ->> 'email'))
  on conflict (usuario) do update set senha_hash = excluded.senha_hash, ativo = true, erros = 0, bloqueado_ate = null,
    atualizado_em = now(), atualizado_por = excluded.atualizado_por;
  return u;
end $$;
revoke all on function public.campo_definir_login(text, text, text) from public, anon;
grant execute on function public.campo_definir_login(text, text, text) to authenticated;

-- administrador: qual é o usuário de um prospectador (a senha nunca volta)
create or replace function public.campo_login_status(p_prosp text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.minha_funcao() = 'admin' then
    (select jsonb_build_object('usuario', usuario, 'ativo', ativo, 'atualizado_em', atualizado_em) from public.campo_logins where prosp_id = p_prosp)
  end
$$;
revoke all on function public.campo_login_status(text) from public, anon;
grant execute on function public.campo_login_status(text) to authenticated;

-- administrador: tira o acesso por usuário e senha
create or replace function public.campo_remover_login(p_prosp text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  delete from public.campo_logins where prosp_id = p_prosp;
end $$;
revoke all on function public.campo_remover_login(text) from public, anon;
grant execute on function public.campo_remover_login(text) to authenticated;

-- aplicativo: entra com usuário e senha e recebe o código de acesso do prospectador
-- (devolve {token} ou {erro}; não usa raise para não desfazer a contagem de senhas erradas)
drop function if exists public.campo_entrar(text, text);
create or replace function public.campo_entrar(p_usuario text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.campo_logins; t text;
begin
  select * into l from public.campo_logins where usuario = lower(trim(coalesce(p_usuario, ''))) and ativo;
  if l.usuario is null then return jsonb_build_object('erro', 'Usuário ou senha errados.'); end if;
  if l.bloqueado_ate is not null and l.bloqueado_ate > now() then
    return jsonb_build_object('erro', 'Muitas tentativas erradas. Espere 15 minutos ou fale com a equipe Nascer com Direitos.');
  end if;
  if l.senha_hash <> extensions.crypt(coalesce(p_senha, ''), l.senha_hash) then
    update public.campo_logins set erros = erros + 1,
      bloqueado_ate = case when erros + 1 >= 5 then now() + interval '15 minutes' else null end
    where usuario = l.usuario;
    return jsonb_build_object('erro', 'Usuário ou senha errados.');
  end if;
  update public.campo_logins set erros = 0, bloqueado_ate = null where usuario = l.usuario;
  select token into t from public.campo_acessos where prosp_id = l.prosp_id and ativo order by criado_em desc limit 1;
  if t is null then
    t := replace(replace(encode(extensions.gen_random_bytes(18), 'base64'), '+', '-'), '/', '_');
    insert into public.campo_acessos (token, prosp_id, criado_por) values (t, l.prosp_id, 'login:' || l.usuario);
  end if;
  return jsonb_build_object('token', t);
end $$;
revoke all on function public.campo_entrar(text, text) from public;
grant execute on function public.campo_entrar(text, text) to anon, authenticated;

select 'ok' as login_app;


-- ================= 14_senha_visivel.sql =================
-- Aplicativo do prospectador: a senha salva fica visível para o administrador no BI (para reenviar quando precisar).
-- A entrada no aplicativo continua conferindo pelo hash. Só administradores leem a senha. Pode rodar de novo.

alter table public.campo_logins add column if not exists senha_ver text;

create or replace function public.campo_definir_login(p_prosp text, p_usuario text, p_senha text)
returns text language plpgsql security definer set search_path = public as $$
declare u text := lower(trim(coalesce(p_usuario, '')));
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  if u !~ '^[a-z0-9._-]{3,30}$' then raise exception 'Usuário: de 3 a 30 letras ou números, sem espaço nem acento.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  if exists (select 1 from public.campo_logins where usuario = u and prosp_id <> p_prosp) then raise exception 'Este usuário já é de outro prospectador.'; end if;
  delete from public.campo_logins where prosp_id = p_prosp and usuario <> u;
  insert into public.campo_logins (usuario, prosp_id, senha_hash, senha_ver, atualizado_por)
  values (u, p_prosp, extensions.crypt(p_senha, extensions.gen_salt('bf')), p_senha, lower(auth.jwt() ->> 'email'))
  on conflict (usuario) do update set senha_hash = excluded.senha_hash, senha_ver = excluded.senha_ver, ativo = true, erros = 0, bloqueado_ate = null,
    atualizado_em = now(), atualizado_por = excluded.atualizado_por;
  return u;
end $$;
revoke all on function public.campo_definir_login(text, text, text) from public, anon;
grant execute on function public.campo_definir_login(text, text, text) to authenticated;

create or replace function public.campo_login_status(p_prosp text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.minha_funcao() = 'admin' then
    (select jsonb_build_object('usuario', usuario, 'senha', senha_ver, 'ativo', ativo, 'atualizado_em', atualizado_em) from public.campo_logins where prosp_id = p_prosp)
  end
$$;
revoke all on function public.campo_login_status(text) from public, anon;
grant execute on function public.campo_login_status(text) to authenticated;

select 'ok' as senha_visivel;


-- ================= 15_painel_app.sql =================
-- Aplicativo do prospectador: painel com todas as clientes que ele indicou e a situação de cada uma.
-- Só dados de andamento (sem CPF, RG, endereço, número do processo nem valores).
-- A função campo_painel fica num lugar só, na versão final: 18_painel_corrige.sql
-- (este arquivo é mantido para a numeração continuar igual à do guia). Pode rodar de novo.

select 'ok (campo_painel: veja 18_painel_corrige.sql)' as painel_app;


-- ================= 16_faltam_docs.sql =================
-- Documentos que faltam: o cadastro do celular guarda o que não foi fotografado (faltaDocs),
-- o prospectador completa depois pelo aplicativo e o escritório acompanha no BI. Pode rodar de novo.
-- Chaves que contam como obrigatórias (ESPECIFICACAO.md §5):
--   procuracao (procuração e contrato) · rg_frente (RG da mãe) · cpf (CPF da mãe)
--   certidao (certidão de nascimento da criança, ou termo de guarda/adoção) · residencia (comprovante de residência)
--   autodeclaracao (autodeclaração rural, só segurada especial) · rural (provas de atividade rural, só segurada especial)
--   ctps (carteira de trabalho, CNIS ou guias, urbana/individual/desempregada) · cliente (foto da cliente)

-- 1) cadastro pelo celular (grava também a lista do que faltou): a função campo_cadastrar fica num lugar só,
--    na versão completa, em 19_foto_cliente.sql.

-- 2) script do Google: pasta de uma cliente deste prospectador (para completar os documentos)
create or replace function public.campo_pasta_cliente(p_token text, p_cliente text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('pastaId', c.data ->> 'pastaId', 'nome', c.data ->> 'nome')
  from public.campo_acessos a join public.clientes c on c.data ->> 'responsavelId' = a.prosp_id
  where a.token = p_token and a.ativo and length(p_token) >= 20 and c.id = p_cliente
$$;
revoke all on function public.campo_pasta_cliente(text, text) from public;
grant execute on function public.campo_pasta_cliente(text, text) to anon, authenticated;

-- 3) script do Google: o prospectador mandou os documentos que faltavam; tira da lista e avisa o escritório
create or replace function public.campo_completar(p_token text, p_cliente text, p_docs jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pid text; atual jsonb; resta jsonb; enviados jsonb;
begin
  select prosp_id into pid from public.campo_acessos where token = p_token and ativo and length(p_token) >= 20;
  if pid is null then raise exception 'Acesso inválido.'; end if;
  select data into atual from public.clientes where id = p_cliente and data ->> 'responsavelId' = pid;
  if atual is null then raise exception 'Cliente não encontrado.'; end if;
  enviados := case when jsonb_typeof(p_docs) = 'array' then p_docs else '[]'::jsonb end;
  select coalesce(jsonb_agg(x), '[]'::jsonb) into resta
  from jsonb_array_elements_text(coalesce(atual -> 'faltaDocs', '[]'::jsonb)) x
  where not enviados ? x;
  update public.clientes set data = (data - 'faltaDocs')
    || case when jsonb_array_length(resta) > 0 then jsonb_build_object('faltaDocs', resta) else '{}'::jsonb end
    || jsonb_build_object('conferirDados', true, 'docsCompletadosEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'campoDocs', coalesce(data -> 'campoDocs', '[]'::jsonb) || enviados,
         'atualizadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
  where id = p_cliente;
  return resta;
end $$;
revoke all on function public.campo_completar(text, text, jsonb) from public;
grant execute on function public.campo_completar(text, text, jsonb) to anon, authenticated;

-- 4) painel do aplicativo (inclui o que falta de cada cliente): a função campo_painel fica num lugar só,
--    na versão final, em 18_painel_corrige.sql.

select 'ok' as faltam_docs;


-- ================= 17_painel_restrito.sql =================
-- Painel do aplicativo do prospectador: ele vê só até "Ganhou".
-- Não recebe pagamento e não recebe as clientes que estão aguardando sentença.
-- A função campo_painel fica num lugar só, na versão final: 18_painel_corrige.sql
-- (este arquivo é mantido para a numeração continuar igual à do guia). Pode rodar de novo.

select 'ok (campo_painel: veja 18_painel_corrige.sql)' as painel_restrito;


-- ================= 18_painel_corrige.sql =================
-- Painel do aplicativo do prospectador (versão final da função campo_painel).
-- Ele vê só até "Ganhou": não recebe pagamento (pago aparece como ganhou) e não recebe as clientes que estão
-- aguardando sentença (audiência já passou e ainda sem sentença, "aguardando" ou conclusos).
-- Só dados de andamento (sem CPF, RG, endereço, número do processo nem valores). Pode rodar de novo.
--
-- Campos de cada cliente (ESPECIFICACAO.md §7):
--   id, nome, contato, cadastro, tipoSegurada, crianca, criancaNasc,
--   requerido (tem DER ou protocolo do INSS), inssStatus, protocolado (tem processo),
--   audData, audHora, online, resultado (só sentença), comparecimento, origem, faltaDocs, temPasta

create or replace function public.campo_painel(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'atualizado', now(),
    'clientes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'nome', c.data ->> 'nome',
        'contato', c.data ->> 'contato',
        'cadastro', coalesce(nullif(c.data ->> 'dataCadastro', ''), left(c.data ->> 'criadoEm', 10)),
        'tipoSegurada', c.data ->> 'tipoSegurada',
        'crianca', c.data ->> 'crianca',
        'criancaNasc', c.data ->> 'criancaNasc',
        'requerido', coalesce(trim(c.data ->> 'der'), '') <> '' or coalesce(trim(c.data ->> 'protocoloInss'), '') <> '',
        'inssStatus', c.data ->> 'inssStatus',
        'protocolado', coalesce(trim(c.data ->> 'processo'), '') <> '',
        'audData', c.data ->> 'audData',
        'audHora', c.data ->> 'audHora',
        'online', coalesce(c.data ->> 'online', '') = 'true',
        -- resultado só quando já há sentença (o "aguardando" não vai)
        'resultado', case when c.data ->> 'resultado' in ('procedente', 'parcial', 'acordo', 'improcedente', 'extinto', 'ausente') then c.data ->> 'resultado' end,
        'comparecimento', c.data ->> 'comparecimento',
        'origem', c.data ->> 'origem',
        'faltaDocs', c.data -> 'faltaDocs',
        'temPasta', coalesce(c.data ->> 'pastaId', '') <> ''
      ) order by c.data ->> 'nome')
      from public.clientes c
      where c.data ->> 'responsavelId' = a.prosp_id
        -- fora: aguardando sentença (audiência passou sem sentença, "aguardando" ou conclusos para decisão)
        and not (
          coalesce(c.data ->> 'resultado', '') not in ('procedente', 'parcial', 'acordo', 'improcedente', 'extinto', 'ausente')
          and coalesce(c.data ->> 'comparecimento', '') <> 'faltou'
          and (
            coalesce(c.data ->> 'resultado', '') = 'aguardando'
            or coalesce(c.data ->> 'concluso', '') = 'true'
            or (coalesce(c.data ->> 'audData', '') ~ '^\d{4}-\d{2}-\d{2}' and left(c.data ->> 'audData', 10)::date < (now() at time zone 'America/Manaus')::date)
            -- (coalesce: sem audiência ou sem "concluso" o teste dava NULL e escondia a cliente nova)
          )
        )), '[]'::jsonb)
  )
  from public.campo_acessos a
  where a.token = p_token and a.ativo and length(p_token) >= 20
$$;
revoke all on function public.campo_painel(text) from public;
grant execute on function public.campo_painel(text) to anon, authenticated;

select 'ok' as painel_app;


-- ================= 19_foto_cliente.sql =================
-- Cadastro pelo celular (versão completa e única da função campo_cadastrar) e foto da cliente
-- (miniatura tirada pelo prospectador, guardada no cadastro para aparecer no BI). Pode rodar de novo.
--
-- p_dados (enviado pelo script do Google):
--   nome, cpf, rg, nascimento, nit, endereco, contato, atividade, testemunhas    dados da mãe
--   tipoSegurada   especial | urbana | individual | desempregada (outro valor é ignorado)
--   fatoGerador    parto | adocao | guarda | natimorto | aborto | gestante (outro valor é ignorado)
--   crianca        nome da criança
--   criancaNasc    data do nascimento/adoção/guarda, AAAA-MM-DD (outro formato é ignorado)
--   dpp            data prevista do parto (gestante), AAAA-MM-DD
--   pastaUrl, pastaId, docs, local, leitura, foto
--   faltam         documentos que não foram fotografados; só valem as chaves:
--                  procuracao, rg_frente, cpf, certidao, residencia, autodeclaracao, rural, ctps, cliente

create or replace function public.campo_cadastrar(p_token text, p_envio text, p_dados jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare pid text; cid text; falta jsonb; agora text;
begin
  select prosp_id into pid from public.campo_acessos where token = p_token and ativo and length(p_token) >= 20;
  if pid is null then raise exception 'Link inválido ou cancelado.'; end if;
  if coalesce(p_envio, '') !~ '^[A-Za-z0-9_-]{8,64}$' then raise exception 'Envio inválido.'; end if;
  cid := 'campo-' || p_envio;
  p_dados := coalesce(p_dados, '{}'::jsonb);
  agora := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into falta
  from jsonb_array_elements_text(case when jsonb_typeof(p_dados -> 'faltam') = 'array' then p_dados -> 'faltam' else '[]'::jsonb end) x
  where x in ('procuracao', 'rg_frente', 'cpf', 'certidao', 'residencia', 'autodeclaracao', 'rural', 'ctps', 'cliente');
  -- só campos de cadastro; nada de INSS, financeiro ou audiência
  insert into public.clientes (id, data) values (cid,
    jsonb_strip_nulls(jsonb_build_object(
      'nome', left(coalesce(nullif(trim(p_dados ->> 'nome'), ''), 'Cliente sem nome (conferir)'), 200),
      'cpf', left(nullif(trim(p_dados ->> 'cpf'), ''), 20), 'rg', left(nullif(trim(p_dados ->> 'rg'), ''), 40),
      'nit', left(nullif(trim(p_dados ->> 'nit'), ''), 20),
      'endereco', left(nullif(trim(p_dados ->> 'endereco'), ''), 300), 'contato', left(nullif(trim(p_dados ->> 'contato'), ''), 40),
      'nascimento', left(nullif(trim(p_dados ->> 'nascimento'), ''), 20),
      'atividade', left(nullif(trim(p_dados ->> 'atividade'), ''), 100),
      'testemunhas', left(nullif(trim(p_dados ->> 'testemunhas'), ''), 1000),
      'tipoSegurada', case when p_dados ->> 'tipoSegurada' in ('especial', 'urbana', 'individual', 'desempregada') then p_dados ->> 'tipoSegurada' end,
      'fatoGerador', case when p_dados ->> 'fatoGerador' in ('parto', 'adocao', 'guarda', 'natimorto', 'aborto', 'gestante') then p_dados ->> 'fatoGerador' end,
      'crianca', left(nullif(trim(p_dados ->> 'crianca'), ''), 200),
      'criancaNasc', case when p_dados ->> 'criancaNasc' ~ '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$' then p_dados ->> 'criancaNasc' end,
      'dpp', case when p_dados ->> 'dpp' ~ '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$' then p_dados ->> 'dpp' end,
      'pastaUrl', left(p_dados ->> 'pastaUrl', 300), 'pastaId', left(p_dados ->> 'pastaId', 100),
      'campoDocs', p_dados -> 'docs', 'campoLocal', p_dados -> 'local', 'obs', left(nullif(p_dados ->> 'leitura', ''), 2000),
      'faltaDocs', case when jsonb_array_length(falta) > 0 then falta end,
      'fotoCliente', case when left(p_dados ->> 'foto', 23) = 'data:image/jpeg;base64,' and length(p_dados ->> 'foto') < 120000 then p_dados ->> 'foto' end,
      'responsavelId', pid, 'origem', 'campo', 'conferirDados', true,
      'criadoEm', agora,
      'atualizadoEm', agora)))
  on conflict (id) do nothing;
  return cid;
end $$;
revoke all on function public.campo_cadastrar(text, text, jsonb) from public;
grant execute on function public.campo_cadastrar(text, text, jsonb) to anon, authenticated;

-- script do Google: grava a foto (miniatura) de um cliente pela pasta dele (usado na organização das pastas antigas)
create or replace function public.campo_foto_pasta(p_segredo text, p_pasta text, p_foto text)
returns integer language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.segredos s where s.nome = 'campo_script' and s.valor = p_segredo and length(p_segredo) >= 32) then
    raise exception 'Script não autorizado.';
  end if;
  if p_foto !~ '^data:image/(jpeg|png);base64,' or length(p_foto) > 200000 then return 0; end if;
  update public.clientes set data = data || jsonb_build_object('fotoCliente', p_foto) where data ->> 'pastaId' = p_pasta;
  return 1;
end $$;
revoke all on function public.campo_foto_pasta(text, text, text) from public;
grant execute on function public.campo_foto_pasta(text, text, text) to anon, authenticated;

select 'ok' as foto_cliente;


-- ================= 20_cargo.sql =================
-- Cargo do funcionário (closer, operacional, admin). A permissão continua em "funcao" (admin ou assistente).
alter table public.equipe add column if not exists cargo text;
alter table public.equipe drop constraint if exists equipe_cargo_check;
alter table public.equipe add constraint equipe_cargo_check check (cargo is null or cargo in ('closer', 'operacional', 'admin'));
select 'ok' as cargo;

-- ================= 21_parceiro_tipo.sql =================
-- O app mostra no topo "Parceira" ou, quando o parceiro é uma clínica, o nome da clínica.
-- campo_quem passa a devolver também o tipo ('pessoa' ou 'clinica') e o nome da clínica.
create or replace function public.campo_quem(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'prospId', a.prosp_id,
    'nome', coalesce(p.data ->> 'nome', ''),
    'tipo', coalesce(p.data ->> 'tipo', 'pessoa'),
    'clinica', coalesce(p.data ->> 'clinica', ''),
    'regiaoId', coalesce(p.data ->> 'regiaoId', ''),
    'envioUrl', (select envio_url from public.campo_config where id = 1),
    'cadastros', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nome', c.data ->> 'nome', 'em', c.data ->> 'criadoEm',
        'etapa', case when coalesce(trim(c.data ->> 'processo'), '') <> '' then
                        case when coalesce(c.data ->> 'audData', '') = '' then 'justica' else 'audiencia' end
                      when coalesce(trim(c.data ->> 'der'), '') <> '' or coalesce(trim(c.data ->> 'protocoloInss'), '') <> '' then 'inss'
                      else 'sem_requerimento' end)
        order by c.data ->> 'criadoEm' desc)
      from (select * from public.clientes c2 where c2.data ->> 'responsavelId' = a.prosp_id and c2.data ->> 'origem' = 'campo'
            order by c2.data ->> 'criadoEm' desc limit 60) c), '[]'::jsonb)
  )
  from public.campo_acessos a left join public.prospectadores p on p.id = a.prosp_id
  where a.token = p_token and a.ativo and length(p_token) >= 20
$$;
revoke all on function public.campo_quem(text) from public;
grant execute on function public.campo_quem(text) to anon, authenticated;
select 'ok' as parceiro_tipo;

-- ================= 22_prospectador.sql =================

-- Prospectador: funcionário que procura os parceiros. Entra no mesmo aplicativo (usuário e senha),
-- cria o login e a senha dos parceiros e vê quantos contratos cada parceiro trouxe.
-- Reaproveita a tabela "prospectadores" (que no sistema aparece como Parceiros):
--   prospectador  -> data.perfil = 'prospectador' (com data.regiaoId = estado em que atua)
--   parceiro      -> sem perfil, com data.prospectadorId = id do prospectador que o trouxe
-- Pode rodar de novo sem perder dados.

-- quem entrou: acrescenta o perfil (parceiro ou prospectador) e o estado
create or replace function public.campo_quem(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'prospId', a.prosp_id,
    'nome', coalesce(p.data ->> 'nome', ''),
    'perfil', coalesce(p.data ->> 'perfil', 'parceiro'),
    'tipo', coalesce(p.data ->> 'tipo', 'pessoa'),
    'clinica', coalesce(p.data ->> 'clinica', ''),
    'regiaoId', coalesce(p.data ->> 'regiaoId', ''),
    'envioUrl', (select envio_url from public.campo_config where id = 1),
    'cadastros', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nome', c.data ->> 'nome', 'em', c.data ->> 'criadoEm',
        'etapa', case when coalesce(trim(c.data ->> 'processo'), '') <> '' then
                        case when coalesce(c.data ->> 'audData', '') = '' then 'justica' else 'audiencia' end
                      when coalesce(trim(c.data ->> 'der'), '') <> '' or coalesce(trim(c.data ->> 'protocoloInss'), '') <> '' then 'inss'
                      else 'sem_requerimento' end)
        order by c.data ->> 'criadoEm' desc)
      from (select * from public.clientes c2 where c2.data ->> 'responsavelId' = a.prosp_id and c2.data ->> 'origem' = 'campo'
            order by c2.data ->> 'criadoEm' desc limit 60) c), '[]'::jsonb)
  )
  from public.campo_acessos a left join public.prospectadores p on p.id = a.prosp_id
  where a.token = p_token and a.ativo and length(p_token) >= 20
$$;
revoke all on function public.campo_quem(text) from public;
grant execute on function public.campo_quem(text) to anon, authenticated;

-- id do prospectador dono do código de acesso (ou nulo se o código não é de um prospectador)
create or replace function public.prosp_dono(p_token text)
returns text language sql stable security definer set search_path = public as $$
  select a.prosp_id
  from public.campo_acessos a join public.prospectadores p on p.id = a.prosp_id
  where a.token = p_token and a.ativo and length(p_token) >= 20 and p.data ->> 'perfil' = 'prospectador'
$$;
revoke all on function public.prosp_dono(text) from public, anon, authenticated;

-- painel do prospectador: os parceiros dele e os números de cada um (só números, sem dados das clientes)
create or replace function public.prosp_painel(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me text := public.prosp_dono(p_token); r jsonb;
begin
  if me is null then return null; end if;
  select jsonb_build_object(
    'atualizado', now(),
    'parceiros', coalesce(jsonb_agg(x order by (x ->> 'contratos')::int desc, x ->> 'nome'), '[]'::jsonb)
  ) into r
  from (
    select jsonb_build_object(
      'id', p.id,
      'nome', coalesce(p.data ->> 'nome', ''),
      'tipo', coalesce(p.data ->> 'tipo', 'pessoa'),
      'clinica', coalesce(p.data ->> 'clinica', ''),
      'cidade', coalesce(p.data ->> 'regiao', ''),
      'telefone', coalesce(p.data ->> 'telefone', ''),
      'usuario', (select l.usuario from public.campo_logins l where l.prosp_id = p.id),
      'ativo', coalesce((select l.ativo from public.campo_logins l where l.prosp_id = p.id), false),
      'criadoEm', coalesce(p.data ->> 'criadoEm', ''),
      'indicacoes', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id),
      'contratos', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id and coalesce(c.data ->> 'contratoEm', '') <> ''),
      'guiasPagas', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id and c.data ->> 'guiaStatus' = 'paga'),
      'concedidos', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id
                      and (c.data ->> 'inssStatus' = 'concedido' or c.data ->> 'resultado' in ('procedente', 'parcial', 'acordo'))),
      'pagos', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id and c.data ->> 'pagamento' = 'pago')
    ) as x
    from public.prospectadores p
    where p.data ->> 'prospectadorId' = me
  ) t;
  return r;
end $$;
revoke all on function public.prosp_painel(text) from public;
grant execute on function public.prosp_painel(text) to anon, authenticated;

-- cria o parceiro (cadastro + usuário + senha). Devolve {ok, id, usuario} ou {erro}
create or replace function public.prosp_criar_parceiro(
  p_token text, p_nome text, p_tipo text, p_clinica text, p_cidade text, p_telefone text, p_usuario text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := public.prosp_dono(p_token); u text := lower(trim(coalesce(p_usuario, ''))); novo text; reg text; tp text;
begin
  if me is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  if length(trim(coalesce(p_nome, ''))) < 3 then return jsonb_build_object('erro', 'Informe o nome do parceiro.'); end if;
  tp := case when p_tipo = 'clinica' then 'clinica' else 'pessoa' end;
  if tp = 'clinica' and length(trim(coalesce(p_clinica, ''))) < 2 then return jsonb_build_object('erro', 'Informe o nome da clínica.'); end if;
  if u !~ '^[a-z0-9._-]{3,30}$' then return jsonb_build_object('erro', 'Usuário: de 3 a 30 letras ou números, sem espaço nem acento.'); end if;
  if length(coalesce(p_senha, '')) < 6 then return jsonb_build_object('erro', 'A senha precisa ter pelo menos 6 caracteres.'); end if;
  if exists (select 1 from public.campo_logins where usuario = u) then return jsonb_build_object('erro', 'Este usuário já existe. Escolha outro.'); end if;
  select data ->> 'regiaoId' into reg from public.prospectadores where id = me;
  novo := replace(gen_random_uuid()::text, '-', '');
  insert into public.prospectadores (id, data) values (novo, jsonb_build_object(
    'nome', trim(p_nome), 'tipo', tp, 'clinica', case when tp = 'clinica' then trim(p_clinica) else '' end,
    'regiao', trim(coalesce(p_cidade, '')), 'regiaoId', coalesce(reg, ''), 'prospectadorId', me,
    'telefone', trim(coalesce(p_telefone, '')), 'ativo', true,
    'criadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'atualizadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'criadoPor', 'prospectador:' || me));
  insert into public.campo_logins (usuario, prosp_id, senha_hash, senha_ver, atualizado_por)
  values (u, novo, extensions.crypt(p_senha, extensions.gen_salt('bf')), p_senha, 'prospectador:' || me);
  return jsonb_build_object('ok', true, 'id', novo, 'usuario', u);
end $$;
revoke all on function public.prosp_criar_parceiro(text, text, text, text, text, text, text, text) from public;
grant execute on function public.prosp_criar_parceiro(text, text, text, text, text, text, text, text) to anon, authenticated;

-- troca a senha de um parceiro dele
create or replace function public.prosp_trocar_senha(p_token text, p_parceiro text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := public.prosp_dono(p_token);
begin
  if me is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  if not exists (select 1 from public.prospectadores where id = p_parceiro and data ->> 'prospectadorId' = me) then
    return jsonb_build_object('erro', 'Este parceiro não é seu.'); end if;
  if length(coalesce(p_senha, '')) < 6 then return jsonb_build_object('erro', 'A senha precisa ter pelo menos 6 caracteres.'); end if;
  update public.campo_logins set senha_hash = extensions.crypt(p_senha, extensions.gen_salt('bf')), senha_ver = p_senha,
    erros = 0, bloqueado_ate = null, atualizado_em = now(), atualizado_por = 'prospectador:' || me
  where prosp_id = p_parceiro;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.prosp_trocar_senha(text, text, text) from public;
grant execute on function public.prosp_trocar_senha(text, text, text) to anon, authenticated;

-- bloqueia ou libera o acesso de um parceiro dele
create or replace function public.prosp_ativar(p_token text, p_parceiro text, p_ativo boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := public.prosp_dono(p_token);
begin
  if me is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  if not exists (select 1 from public.prospectadores where id = p_parceiro and data ->> 'prospectadorId' = me) then
    return jsonb_build_object('erro', 'Este parceiro não é seu.'); end if;
  update public.campo_logins set ativo = coalesce(p_ativo, true), erros = 0, bloqueado_ate = null where prosp_id = p_parceiro;
  update public.prospectadores set data = data || jsonb_build_object('ativo', coalesce(p_ativo, true)) where id = p_parceiro;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.prosp_ativar(text, text, boolean) from public;
grant execute on function public.prosp_ativar(text, text, boolean) to anon, authenticated;

select 'ok' as prospectador;

-- Acesso ao BI por usuário e senha (sem e-mail).
-- O usuário "thiago" vira internamente thiago@acesso.rodrigueslitaiffadv.com.br (endereço que não recebe e-mail).
-- Só um administrador logado, pelo BI (Configurações › Equipe), consegue criar o acesso ou trocar a senha.
-- Pode rodar de novo sem perder dados.

-- 1) Ninguém cria conta com esse final de endereço pelo cadastro público: só a função abaixo.
create or replace function public.bloquear_acesso_interno()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if lower(coalesce(new.email, '')) like '%@acesso.rodrigueslitaiffadv.com.br'
     and coalesce(current_setting('app.criando_acesso', true), '') <> 'sim' then
    raise exception 'Este tipo de acesso só é criado por um administrador.';
  end if;
  return new;
end $$;

drop trigger if exists bloquear_acesso_interno on auth.users;
create trigger bloquear_acesso_interno before insert or update of email on auth.users
  for each row execute function public.bloquear_acesso_interno();

-- 2) Administrador cria o acesso (ou troca a senha) de um usuário da equipe.
--    Devolve {ok:true} ou {erro:'...'}.
create or replace function public.equipe_definir_senha(p_email text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare e text := lower(trim(coalesce(p_email, ''))); uid uuid;
begin
  if public.minha_funcao() is distinct from 'admin' then
    return jsonb_build_object('erro', 'Só administrador pode definir senha.');
  end if;
  if e not like '%@acesso.rodrigueslitaiffadv.com.br' then
    return jsonb_build_object('erro', 'Este funcionário entra com e-mail: ele mesmo cria a senha pelo Primeiro acesso.');
  end if;
  if not exists (select 1 from public.equipe where email = e) then
    return jsonb_build_object('erro', 'Cadastre o funcionário na equipe antes de definir a senha.');
  end if;
  if length(coalesce(p_senha, '')) < 6 then
    return jsonb_build_object('erro', 'A senha precisa ter pelo menos 6 caracteres.');
  end if;

  perform set_config('app.criando_acesso', 'sim', true);
  select id into uid from auth.users where lower(email) = e;
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', e,
            extensions.crypt(p_senha, extensions.gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text,
            jsonb_build_object('sub', uid::text, 'email', e, 'email_verified', true), 'email', now(), now(), now());
  else
    update auth.users
       set encrypted_password = extensions.crypt(p_senha, extensions.gen_salt('bf')),
           email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now()
     where id = uid;
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.equipe_definir_senha(text, text) from public, anon;
grant execute on function public.equipe_definir_senha(text, text) to authenticated;

select 'ok' as acesso_usuario;
-- Pastas do Drive no fluxo: DOCUMENTOS PENDENTES › DOCUMENTOS OK › PROTOCOLADOS.
-- O script do Google pergunta aqui em que pasta deve estar a cliente de cada pasta e move a pasta. Pode rodar de novo.
--   protocolado = arquivada, com processo, ou com requerimento no INSS (DER/protocolo)
--   ok          = documentação completa (conferida no sistema ou enviada completa pelo aplicativo)
--   pendente    = o resto

create or replace function public.etapa_da_cliente(d jsonb)
returns text language sql immutable as $$
  select case
    when coalesce(d ->> 'arquivado', 'false') = 'true' then 'protocolado'
    when coalesce(trim(d ->> 'processo'), '') <> '' then 'protocolado'
    when coalesce(trim(d ->> 'der'), '') <> '' or coalesce(trim(d ->> 'protocoloInss'), '') <> '' then 'protocolado'
    when (d ->> 'docsCompletos' = 'true' or (d ->> 'origem' = 'campo' and jsonb_typeof(d -> 'faltaDocs') = 'array'))
         and (case when jsonb_typeof(d -> 'faltaDocs') = 'array' then jsonb_array_length(d -> 'faltaDocs') else 0 end) = 0 then 'ok'
    else 'pendente' end
$$;

create or replace function public.campo_pastas_etapas(p_ids text[])
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(x.pasta, x.etapa), '{}'::jsonb)
  from (
    select distinct on (c.data ->> 'pastaId') c.data ->> 'pastaId' as pasta, public.etapa_da_cliente(c.data) as etapa
    from public.clientes c
    where c.data ->> 'pastaId' = any(p_ids[1:1000])
    order by c.data ->> 'pastaId', c.atualizado_em desc
  ) x
$$;
revoke all on function public.campo_pastas_etapas(text[]) from public;
grant execute on function public.campo_pastas_etapas(text[]) to anon, authenticated;

create or replace function public.campo_pastas_status(p_ids text[])
returns jsonb language sql stable security definer set search_path = public as $$
  select public.campo_pastas_etapas(p_ids)
$$;
revoke all on function public.campo_pastas_status(text[]) from public;
grant execute on function public.campo_pastas_status(text[]) to anon, authenticated;

select 'ok' as pastas_fluxo;
-- O cadastro do aplicativo passa a guardar também título de eleitor (frente e verso) e vídeo na lista do que faltou.
-- Pode rodar de novo.

create or replace function public.campo_cadastrar(p_token text, p_envio text, p_dados jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare pid text; cid text; falta jsonb; agora text;
begin
  select prosp_id into pid from public.campo_acessos where token = p_token and ativo and length(p_token) >= 20;
  if pid is null then raise exception 'Link inválido ou cancelado.'; end if;
  if coalesce(p_envio, '') !~ '^[A-Za-z0-9_-]{8,64}$' then raise exception 'Envio inválido.'; end if;
  cid := 'campo-' || p_envio;
  p_dados := coalesce(p_dados, '{}'::jsonb);
  agora := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into falta
  from jsonb_array_elements_text(case when jsonb_typeof(p_dados -> 'faltam') = 'array' then p_dados -> 'faltam' else '[]'::jsonb end) x
  where x in ('procuracao', 'rg_frente', 'cpf', 'titulo', 'titulo_verso', 'video', 'certidao', 'residencia', 'autodeclaracao', 'rural', 'ctps', 'cliente');
  -- só campos de cadastro; nada de INSS, financeiro ou audiência
  insert into public.clientes (id, data) values (cid,
    jsonb_strip_nulls(jsonb_build_object(
      'nome', left(coalesce(nullif(trim(p_dados ->> 'nome'), ''), 'Cliente sem nome (conferir)'), 200),
      'cpf', left(nullif(trim(p_dados ->> 'cpf'), ''), 20), 'rg', left(nullif(trim(p_dados ->> 'rg'), ''), 40),
      'nit', left(nullif(trim(p_dados ->> 'nit'), ''), 20),
      'endereco', left(nullif(trim(p_dados ->> 'endereco'), ''), 300), 'contato', left(nullif(trim(p_dados ->> 'contato'), ''), 40),
      'nascimento', left(nullif(trim(p_dados ->> 'nascimento'), ''), 20),
      'atividade', left(nullif(trim(p_dados ->> 'atividade'), ''), 100),
      'testemunhas', left(nullif(trim(p_dados ->> 'testemunhas'), ''), 1000),
      'tipoSegurada', case when p_dados ->> 'tipoSegurada' in ('especial', 'urbana', 'individual', 'desempregada') then p_dados ->> 'tipoSegurada' end,
      'fatoGerador', case when p_dados ->> 'fatoGerador' in ('parto', 'adocao', 'guarda', 'natimorto', 'aborto', 'gestante') then p_dados ->> 'fatoGerador' end,
      'crianca', left(nullif(trim(p_dados ->> 'crianca'), ''), 200),
      'criancaNasc', case when p_dados ->> 'criancaNasc' ~ '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$' then p_dados ->> 'criancaNasc' end,
      'dpp', case when p_dados ->> 'dpp' ~ '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$' then p_dados ->> 'dpp' end,
      'pastaUrl', left(p_dados ->> 'pastaUrl', 300), 'pastaId', left(p_dados ->> 'pastaId', 100),
      'campoDocs', p_dados -> 'docs', 'campoLocal', p_dados -> 'local', 'obs', left(nullif(p_dados ->> 'leitura', ''), 2000),
      'faltaDocs', case when jsonb_array_length(falta) > 0 then falta end,
      'fotoCliente', case when left(p_dados ->> 'foto', 23) = 'data:image/jpeg;base64,' and length(p_dados ->> 'foto') < 120000 then p_dados ->> 'foto' end,
      'responsavelId', pid, 'origem', 'campo', 'conferirDados', true,
      'criadoEm', agora,
      'atualizadoEm', agora)))
  on conflict (id) do nothing;
  return cid;
end $$;
revoke all on function public.campo_cadastrar(text, text, jsonb) from public;
grant execute on function public.campo_cadastrar(text, text, jsonb) to anon, authenticated;

select 'ok' as cadastro_docs;
-- O cadastro do aplicativo guarda também a cidade da cliente (e o estado dela). Pode rodar de novo.

create or replace function public.campo_cadastrar(p_token text, p_envio text, p_dados jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare pid text; cid text; falta jsonb; agora text;
begin
  select prosp_id into pid from public.campo_acessos where token = p_token and ativo and length(p_token) >= 20;
  if pid is null then raise exception 'Link inválido ou cancelado.'; end if;
  if coalesce(p_envio, '') !~ '^[A-Za-z0-9_-]{8,64}$' then raise exception 'Envio inválido.'; end if;
  cid := 'campo-' || p_envio;
  p_dados := coalesce(p_dados, '{}'::jsonb);
  agora := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into falta
  from jsonb_array_elements_text(case when jsonb_typeof(p_dados -> 'faltam') = 'array' then p_dados -> 'faltam' else '[]'::jsonb end) x
  where x in ('procuracao', 'rg_frente', 'cpf', 'titulo', 'titulo_verso', 'video', 'certidao', 'residencia', 'autodeclaracao', 'rural', 'ctps', 'cliente');
  -- só campos de cadastro; nada de INSS, financeiro ou audiência
  insert into public.clientes (id, data) values (cid,
    jsonb_strip_nulls(jsonb_build_object(
      'nome', left(coalesce(nullif(trim(p_dados ->> 'nome'), ''), 'Cliente sem nome (conferir)'), 200),
      'cpf', left(nullif(trim(p_dados ->> 'cpf'), ''), 20), 'rg', left(nullif(trim(p_dados ->> 'rg'), ''), 40),
      'nit', left(nullif(trim(p_dados ->> 'nit'), ''), 20),
      'endereco', left(nullif(trim(p_dados ->> 'endereco'), ''), 300), 'cidade', left(nullif(trim(p_dados ->> 'cidade'), ''), 100), 'cidadeUf', left(nullif(trim(p_dados ->> 'cidadeUf'), ''), 2), 'contato', left(nullif(trim(p_dados ->> 'contato'), ''), 40),
      'nascimento', left(nullif(trim(p_dados ->> 'nascimento'), ''), 20),
      'atividade', left(nullif(trim(p_dados ->> 'atividade'), ''), 100),
      'testemunhas', left(nullif(trim(p_dados ->> 'testemunhas'), ''), 1000),
      'tipoSegurada', case when p_dados ->> 'tipoSegurada' in ('especial', 'urbana', 'individual', 'desempregada') then p_dados ->> 'tipoSegurada' end,
      'fatoGerador', case when p_dados ->> 'fatoGerador' in ('parto', 'adocao', 'guarda', 'natimorto', 'aborto', 'gestante') then p_dados ->> 'fatoGerador' end,
      'crianca', left(nullif(trim(p_dados ->> 'crianca'), ''), 200),
      'criancaNasc', case when p_dados ->> 'criancaNasc' ~ '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$' then p_dados ->> 'criancaNasc' end,
      'dpp', case when p_dados ->> 'dpp' ~ '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$' then p_dados ->> 'dpp' end,
      'pastaUrl', left(p_dados ->> 'pastaUrl', 300), 'pastaId', left(p_dados ->> 'pastaId', 100),
      'campoDocs', p_dados -> 'docs', 'campoLocal', p_dados -> 'local', 'obs', left(nullif(p_dados ->> 'leitura', ''), 2000),
      'faltaDocs', case when jsonb_array_length(falta) > 0 then falta end,
      'fotoCliente', case when left(p_dados ->> 'foto', 23) = 'data:image/jpeg;base64,' and length(p_dados ->> 'foto') < 120000 then p_dados ->> 'foto' end,
      'responsavelId', pid, 'origem', 'campo', 'conferirDados', true,
      'criadoEm', agora,
      'atualizadoEm', agora)))
  on conflict (id) do nothing;
  return cid;
end $$;
revoke all on function public.campo_cadastrar(text, text, jsonb) from public;
grant execute on function public.campo_cadastrar(text, text, jsonb) to anon, authenticated;

select 'ok' as cadastro_cidade;
-- Pedidos de acesso da equipe: o pessoal preenche um formulário (link enviado no grupo) com nome, telefone e função;
-- o administrador vê os pedidos em Configurações › Equipe e aprova (cria o acesso) ou descarta.
-- O formulário só cria PEDIDOS: não dá acesso a nada. Pode rodar de novo.

create table if not exists public.equipe_pedidos (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null,
  telefone  text,
  funcao    text,
  outra     text,
  status    text not null default 'pendente',
  criado_em timestamptz not null default now()
);
alter table public.equipe_pedidos enable row level security;
revoke all on public.equipe_pedidos from anon, authenticated;
grant select, update, delete on public.equipe_pedidos to authenticated;

drop policy if exists ped_admin_le on public.equipe_pedidos;
drop policy if exists ped_admin_altera on public.equipe_pedidos;
drop policy if exists ped_admin_exclui on public.equipe_pedidos;
create policy ped_admin_le on public.equipe_pedidos for select to authenticated using (public.minha_funcao() = 'admin');
create policy ped_admin_altera on public.equipe_pedidos for update to authenticated using (public.minha_funcao() = 'admin') with check (public.minha_funcao() = 'admin');
create policy ped_admin_exclui on public.equipe_pedidos for delete to authenticated using (public.minha_funcao() = 'admin');

-- formulário público: grava um pedido (com limites para não virar lixo)
create or replace function public.equipe_solicitar(p_nome text, p_telefone text, p_funcao text, p_outra text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n text := trim(coalesce(p_nome, '')); f text := lower(trim(coalesce(p_funcao, '')));
begin
  if length(n) < 3 or length(n) > 120 then return jsonb_build_object('erro', 'Informe o nome completo.'); end if;
  if f not in ('closer', 'operacional', 'outra') then return jsonb_build_object('erro', 'Escolha a função.'); end if;
  if (select count(*) from public.equipe_pedidos where criado_em > now() - interval '1 hour') >= 60 then
    return jsonb_build_object('erro', 'Muitos pedidos agora. Tente de novo em alguns minutos.');
  end if;
  if exists (select 1 from public.equipe_pedidos where status = 'pendente' and lower(nome) = lower(n) and criado_em > now() - interval '1 day') then
    return jsonb_build_object('ok', true);
  end if;
  insert into public.equipe_pedidos (nome, telefone, funcao, outra)
  values (left(n, 120), left(trim(coalesce(p_telefone, '')), 30), f, left(trim(coalesce(p_outra, '')), 80));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.equipe_solicitar(text, text, text, text) from public;
grant execute on function public.equipe_solicitar(text, text, text, text) to anon, authenticated;

-- atualização ao vivo no sistema
do $$ begin
  begin alter publication supabase_realtime add table public.equipe_pedidos; exception when others then null; end;
end $$;

select 'ok' as equipe_pedidos;
