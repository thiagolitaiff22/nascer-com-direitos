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
