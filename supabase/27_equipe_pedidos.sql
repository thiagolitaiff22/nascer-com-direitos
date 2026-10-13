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
