-- Senha do gov.br da cliente em cofre separado, no mesmo esquema do BI de Vendas: fica fora do jsonb de clientes (e fora do histórico e do tempo real),
-- a equipe lê e grava só por estas funções, o banco registra quem leu e o que foi trocado, e só o administrador vê esses registros. Pode rodar de novo.

create table if not exists public.clientes_senhas (
  cliente_id     text primary key references public.clientes(id) on delete cascade,
  senha_gov      text not null,
  atualizado_em  timestamptz not null default now(),
  atualizado_por text
);
create table if not exists public.clientes_senhas_historico (
  id         bigserial primary key,
  cliente_id text not null references public.clientes(id) on delete cascade,
  senha_gov  text not null,
  acao       text not null default 'trocou',
  por        text,
  em         timestamptz not null default now()
);
create table if not exists public.clientes_senhas_leituras (
  id         bigserial primary key,
  cliente_id text not null references public.clientes(id) on delete cascade,
  lida_por   text,
  lida_em    timestamptz not null default now()
);
create index if not exists clientes_senhas_historico_cliente on public.clientes_senhas_historico (cliente_id, em desc);
create index if not exists clientes_senhas_leituras_cliente on public.clientes_senhas_leituras (cliente_id, lida_em desc);

-- RLS ligada e nenhuma política: ninguém acessa estas tabelas direto, só as funções abaixo
alter table public.clientes_senhas enable row level security;
alter table public.clientes_senhas_historico enable row level security;
alter table public.clientes_senhas_leituras enable row level security;
revoke all on public.clientes_senhas, public.clientes_senhas_historico, public.clientes_senhas_leituras from public, anon, authenticated;

-- A mesma pessoa relendo a mesma cliente em 10 minutos não repete o registro
create or replace function public.senha_gov_ler(p_cliente text) returns text
language plpgsql security definer set search_path = public as $$
declare _eu text := lower(coalesce(auth.jwt() ->> 'email', '')); _senha text;
begin
  if public.minha_funcao() is null then raise exception 'Sem permissão para ver a senha.' using errcode = '42501'; end if;
  select s.senha_gov into _senha from public.clientes_senhas s where s.cliente_id = p_cliente;
  if _senha is null then return null; end if;
  insert into public.clientes_senhas_leituras (cliente_id, lida_por)
  select p_cliente, _eu
   where not exists (select 1 from public.clientes_senhas_leituras l
                      where l.cliente_id = p_cliente and l.lida_por = _eu and l.lida_em > now() - interval '10 minutes');
  return _senha;
end $$;

create or replace function public.senha_gov_gravar(p_cliente text, p_senha text) returns void
language plpgsql security definer set search_path = public as $$
declare _eu text := lower(coalesce(auth.jwt() ->> 'email', '')); _nova text := btrim(coalesce(p_senha, '')); _antiga text;
begin
  if public.minha_funcao() is null then raise exception 'Sem permissão para alterar a senha.' using errcode = '42501'; end if;
  if _nova = '' then raise exception 'Digite a senha.'; end if;
  if length(_nova) > 200 then raise exception 'Senha longa demais.'; end if;
  if not exists (select 1 from public.clientes c where c.id = p_cliente) then raise exception 'Cliente não encontrada.'; end if;
  select s.senha_gov into _antiga from public.clientes_senhas s where s.cliente_id = p_cliente;
  if _antiga is not null and _antiga <> _nova then
    insert into public.clientes_senhas_historico (cliente_id, senha_gov, por) values (p_cliente, _antiga, _eu);
  end if;
  insert into public.clientes_senhas (cliente_id, senha_gov, atualizado_em, atualizado_por)
  values (p_cliente, _nova, now(), _eu)
  on conflict (cliente_id) do update set senha_gov = excluded.senha_gov, atualizado_em = now(), atualizado_por = excluded.atualizado_por;
end $$;

-- Só o administrador vê quem leu e as senhas anteriores
create or replace function public.senha_gov_historico(p_cliente text)
returns table (em timestamptz, quem text, acao text, senha text)
language plpgsql stable security definer set search_path = public as $$
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só o administrador vê o histórico da senha.' using errcode = '42501'; end if;
  return query
  select x.em, coalesce(q.nome, x.autor, 'Sistema'), x.acao, x.senha from (
    select h.em, h.por as autor, h.acao, h.senha_gov as senha from public.clientes_senhas_historico h where h.cliente_id = p_cliente
    union all
    select l.lida_em, l.lida_por, 'leu', null from public.clientes_senhas_leituras l where l.cliente_id = p_cliente
  ) x
  left join public.equipe q on q.email = x.autor
  order by x.em desc
  limit 100;
end $$;

revoke all on function public.senha_gov_ler(text), public.senha_gov_gravar(text, text), public.senha_gov_historico(text) from public, anon;
grant execute on function public.senha_gov_ler(text), public.senha_gov_gravar(text, text), public.senha_gov_historico(text) to authenticated;

select 'ok' as cofre_senha_gov;
