-- Novo cargo da equipe: Pós-venda (acompanha a cliente depois do contrato e do benefício). Pode rodar de novo.
alter table public.equipe drop constraint if exists equipe_cargo_check;
alter table public.equipe add constraint equipe_cargo_check check (cargo is null or cargo in ('closer', 'operacional', 'judicial', 'posvenda', 'admin'));

-- o formulário público de pedido de acesso também aceita "posvenda"
create or replace function public.equipe_solicitar(p_nome text, p_telefone text, p_funcao text, p_outra text, p_cpf text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n text := trim(coalesce(p_nome, '')); f text := lower(trim(coalesce(p_funcao, ''))); c text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
begin
  if length(n) < 3 or length(n) > 120 then return jsonb_build_object('erro', 'Informe o nome completo.'); end if;
  if length(c) <> 11 then return jsonb_build_object('erro', 'Informe o CPF com 11 números.'); end if;
  if f not in ('closer', 'prospectador', 'parceiro', 'operacional', 'judicial', 'posvenda') then return jsonb_build_object('erro', 'Escolha a função.'); end if;
  if (select count(*) from public.equipe_pedidos where criado_em > now() - interval '1 hour') >= 60 then
    return jsonb_build_object('erro', 'Muitos pedidos agora. Tente de novo em alguns minutos.');
  end if;
  if exists (select 1 from public.equipe_pedidos where status = 'pendente' and (cpf = c or lower(nome) = lower(n)) and criado_em > now() - interval '1 day') then
    return jsonb_build_object('ok', true);
  end if;
  insert into public.equipe_pedidos (nome, telefone, funcao, outra, cpf)
  values (left(n, 120), left(trim(coalesce(p_telefone, '')), 30), f, left(trim(coalesce(p_outra, '')), 80), c);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.equipe_solicitar(text, text, text, text, text) from public;
grant execute on function public.equipe_solicitar(text, text, text, text, text) to anon, authenticated;

select 'ok' as cargo_posvenda;
