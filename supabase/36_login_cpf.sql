-- O login passa a ser o CPF. Cada pessoa da equipe tem o CPF registrado; a tela de entrada acha o acesso por ele.
-- Parceiros e prospectadores entram direto com o CPF como usuário. Pode rodar de novo.

alter table public.equipe         add column if not exists cpf text;
alter table public.equipe_pedidos add column if not exists cpf text;
create unique index if not exists equipe_cpf_unico on public.equipe (cpf) where cpf is not null and cpf <> '';

-- tela de entrada: devolve o endereço de acesso ligado a um CPF (ou nada)
create or replace function public.login_por_cpf(p_cpf text)
returns text language sql stable security definer set search_path = public as $$
  select email from public.equipe
  where cpf = regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g') and ativo
  limit 1
$$;
revoke all on function public.login_por_cpf(text) from public;
grant execute on function public.login_por_cpf(text) to anon, authenticated;

-- formulário público: agora também recebe o CPF
drop function if exists public.equipe_solicitar(text, text, text, text);
create or replace function public.equipe_solicitar(p_nome text, p_telefone text, p_funcao text, p_outra text, p_cpf text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n text := trim(coalesce(p_nome, '')); f text := lower(trim(coalesce(p_funcao, ''))); c text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
begin
  if length(n) < 3 or length(n) > 120 then return jsonb_build_object('erro', 'Informe o nome completo.'); end if;
  if length(c) <> 11 then return jsonb_build_object('erro', 'Informe o CPF com 11 números.'); end if;
  if f not in ('closer', 'prospectador', 'parceiro', 'operacional', 'judicial') then return jsonb_build_object('erro', 'Escolha a função.'); end if;
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

select 'ok' as login_cpf;
