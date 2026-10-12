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
