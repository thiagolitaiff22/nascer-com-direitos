-- O formulário público não aceita "gestor" (o gestor define o cargo ao aprovar). Pode rodar de novo.
create or replace function public.equipe_solicitar(p_nome text, p_telefone text, p_funcao text, p_outra text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n text := trim(coalesce(p_nome, '')); f text := lower(trim(coalesce(p_funcao, '')));
begin
  if length(n) < 3 or length(n) > 120 then return jsonb_build_object('erro', 'Informe o nome completo.'); end if;
  if f not in ('closer', 'prospectador', 'parceiro', 'operacional', 'judicial') then return jsonb_build_object('erro', 'Escolha a função.'); end if;
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

select 'ok' as form_sem_gestor;
