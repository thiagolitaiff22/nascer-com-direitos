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
