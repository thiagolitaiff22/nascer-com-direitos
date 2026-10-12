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
