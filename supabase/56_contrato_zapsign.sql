-- 56 · Contrato e procuração pelo ZapSign
-- 1) O token da API, o ID do modelo e a conta de teste são colados no BI (Configurações › Integrações › Contrato ZapSign)
--    e ficam no cofre (segredos: zapsign, zapsign_modelo, zapsign_teste). Só o script do Google, com o código dele, consegue ler.
-- 2) A mãe cadastrada pelo aplicativo guarda o contrato: { doc, url, status pendente|assinado }. Normalmente ela assina no app,
--    na hora; sem internet (exceção), o script gera o contrato no envio e o link vai para ela junto com as boas-vindas (WhatsApp).
-- 3) Quando ela assina depois, o script marca como assinado e o contrato conta como entregue (Contrato e procuração).
-- Pode rodar de novo.

create or replace function public.campo_zapsign_config(p_segredo text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from public.segredos s where s.nome = 'campo_script' and s.valor = p_segredo and length(p_segredo) >= 32)
    then jsonb_build_object(
      'token', coalesce((select valor from public.segredos where nome = 'zapsign'), ''),
      'modelo', coalesce((select valor from public.segredos where nome = 'zapsign_modelo'), ''),
      'teste', coalesce((select valor from public.segredos where nome = 'zapsign_teste'), '') = '1') end
$$;
revoke all on function public.campo_zapsign_config(text) from public;
grant execute on function public.campo_zapsign_config(text) to anon, authenticated;

-- mesmo cadastro do SQL 47, agora guardando o contrato
create or replace function public.campo_cadastrar(p_token text, p_envio text, p_dados jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare pid text; cid text; falta jsonb; agora text; ct jsonb;
begin
  select prosp_id into pid from public.campo_acessos where token = p_token and ativo and length(p_token) >= 20;
  if pid is null then raise exception 'Link inválido ou cancelado.'; end if;
  if coalesce(p_envio, '') !~ '^[A-Za-z0-9_-]{8,64}$' then raise exception 'Envio inválido.'; end if;
  cid := 'campo-' || p_envio;
  p_dados := coalesce(p_dados, '{}'::jsonb);
  -- dados principais obrigatórios: aplicativo antigo (que não enviava CPF e cidade) é recusado e o cadastro fica na fila do celular até atualizar
  if length(trim(coalesce(p_dados ->> 'nome', ''))) < 3
     or length(regexp_replace(coalesce(p_dados ->> 'cpf', ''), '\D', '', 'g')) <> 11
     or length(trim(coalesce(p_dados ->> 'cidade', ''))) < 2
     or length(regexp_replace(coalesce(p_dados ->> 'contato', ''), '\D', '', 'g')) not in (10, 11) then
    raise exception 'Atualize o aplicativo para enviar: faltam dados principais (nome, telefone, cidade ou CPF).';
  end if;
  agora := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into falta
  from jsonb_array_elements_text(case when jsonb_typeof(p_dados -> 'faltam') = 'array' then p_dados -> 'faltam' else '[]'::jsonb end) x
  where x in ('procuracao', 'rg_frente', 'cpf', 'titulo', 'titulo_verso', 'video', 'certidao', 'residencia', 'autodeclaracao', 'rural', 'ctps', 'cliente');
  -- contrato do ZapSign: assinado no aplicativo ou, sem internet na hora, gerado no envio (o link vai para a mãe nas boas-vindas)
  if jsonb_typeof(p_dados -> 'contrato') = 'object' and coalesce(p_dados -> 'contrato' ->> 'doc', '') ~ '^[A-Za-z0-9-]{10,80}$' then
    ct := jsonb_strip_nulls(jsonb_build_object(
      'doc', p_dados -> 'contrato' ->> 'doc',
      'url', case when p_dados -> 'contrato' ->> 'url' ~ '^https://[a-z0-9.-]*zapsign[.](co|com[.]br)/' then left(p_dados -> 'contrato' ->> 'url', 300) end,
      'status', case when p_dados -> 'contrato' ->> 'status' = 'assinado' then 'assinado' else 'pendente' end,
      'assinadoEm', case when p_dados -> 'contrato' ->> 'status' = 'assinado' then agora end,
      'geradoEm', agora));
  end if;
  -- só campos de cadastro; nada de INSS, financeiro ou audiência
  insert into public.clientes (id, data) values (cid,
    jsonb_strip_nulls(jsonb_build_object(
      'nome', left(coalesce(nullif(trim(p_dados ->> 'nome'), ''), 'Cliente sem nome (conferir)'), 200),
      'cpf', left(nullif(trim(p_dados ->> 'cpf'), ''), 20), 'rg', left(nullif(trim(p_dados ->> 'rg'), ''), 40),
      'nit', left(nullif(trim(p_dados ->> 'nit'), ''), 20),
      'endereco', left(nullif(trim(p_dados ->> 'endereco'), ''), 300), 'cidade', left(nullif(trim(p_dados ->> 'cidade'), ''), 100), 'cidadeUf', left(nullif(trim(p_dados ->> 'cidadeUf'), ''), 2), 'contato', left(nullif(trim(p_dados ->> 'contato'), ''), 40),
      'nascimento', left(nullif(trim(p_dados ->> 'nascimento'), ''), 20),
      'atividade', left(nullif(trim(p_dados ->> 'atividade'), ''), 100),
      'testemunhas', left(nullif(trim(p_dados ->> 'testemunhas'), ''), 1000),
      'tipoSegurada', case when p_dados ->> 'tipoSegurada' in ('especial', 'urbana', 'individual', 'desempregada') then p_dados ->> 'tipoSegurada' end,
      'fatoGerador', case when p_dados ->> 'fatoGerador' in ('parto', 'adocao', 'guarda', 'natimorto', 'aborto', 'gestante') then p_dados ->> 'fatoGerador' end,
      'crianca', left(nullif(trim(p_dados ->> 'crianca'), ''), 200),
      'criancaNasc', case when p_dados ->> 'criancaNasc' ~ '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$' then p_dados ->> 'criancaNasc' end,
      'dpp', case when p_dados ->> 'dpp' ~ '^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$' then p_dados ->> 'dpp' end,
      'pastaUrl', left(p_dados ->> 'pastaUrl', 300), 'pastaId', left(p_dados ->> 'pastaId', 100),
      'contrato', ct,
      'campoDocs', p_dados -> 'docs', 'campoLocal', p_dados -> 'local', 'obs', left(nullif(p_dados ->> 'leitura', ''), 2000),
      'faltaDocs', case when jsonb_array_length(falta) > 0 then falta end,
      'fotoCliente', case when left(p_dados ->> 'foto', 23) = 'data:image/jpeg;base64,' and length(p_dados ->> 'foto') < 120000 then p_dados ->> 'foto' end,
      'responsavelId', pid, 'origem', 'campo', 'conferirDados', true,
      'criadoEm', agora,
      'atualizadoEm', agora)))
  on conflict (id) do nothing;
  return cid;
end $$;
revoke all on function public.campo_cadastrar(text, text, jsonb) from public;
grant execute on function public.campo_cadastrar(text, text, jsonb) to anon, authenticated;

-- a mãe assinou depois (pelo link do WhatsApp): o script confere no ZapSign e marca aqui
create or replace function public.campo_contrato_assinado(p_segredo text, p_doc text)
returns text language plpgsql security definer set search_path = public as $$
declare cid text; atual jsonb; docs jsonb; falta jsonb; agora text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
begin
  if not exists (select 1 from public.segredos s where s.nome = 'campo_script' and s.valor = p_segredo and length(p_segredo) >= 32) then
    raise exception 'Script não autorizado.';
  end if;
  select id, data into cid, atual from public.clientes where data -> 'contrato' ->> 'doc' = p_doc limit 1;
  if cid is null then return null; end if;
  if atual -> 'contrato' ->> 'status' = 'assinado' then return cid; end if;
  docs := case when jsonb_typeof(atual -> 'campoDocs') = 'array' then atual -> 'campoDocs' else '[]'::jsonb end;
  if not docs ? 'procuracao' then docs := docs || '["procuracao"]'::jsonb; end if;
  falta := case when jsonb_typeof(atual -> 'faltaDocs') = 'array' then (atual -> 'faltaDocs') - 'procuracao' end;
  update public.clientes set data = data
      || jsonb_build_object('contrato', (atual -> 'contrato') || jsonb_build_object('status', 'assinado', 'assinadoEm', agora), 'campoDocs', docs, 'atualizadoEm', agora)
      || case when falta is null then '{}'::jsonb else jsonb_build_object('faltaDocs', falta) end
    where id = cid;
  return cid;
end $$;
revoke all on function public.campo_contrato_assinado(text, text) from public;
grant execute on function public.campo_contrato_assinado(text, text) to anon, authenticated;

select 'ok' as zapsign,
  to_regprocedure('public.campo_zapsign_config(text)') is not null as config,
  to_regprocedure('public.campo_contrato_assinado(text,text)') is not null as assinado;
