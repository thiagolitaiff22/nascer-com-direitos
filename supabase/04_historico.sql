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
