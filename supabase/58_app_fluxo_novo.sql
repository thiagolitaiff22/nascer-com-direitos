-- 58 · Cadastros do aplicativo novo entram no Fluxo novo do BI (06/11/2026)
-- O aplicativo novo já qualifica a mãe e colhe o contrato e a procuração pelo ZapSign. Com o contrato (assinado ou gerado no envio),
-- o cadastro é gravado com fluxo = novo: não passa pelo closer e entra sozinho no Pós-venda. Sem contrato (aplicativo antigo ou falha
-- no ZapSign), segue no Fluxo antigo, como antes. Cadastros que já existem não mudam. Mesma função do SQL 56, só com o campo fluxo.
-- Pode rodar de novo.

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
      -- procuração: documento separado no ZapSign (pode faltar, se o escritório só tiver o modelo do contrato)
      'docProc', case when coalesce(p_dados -> 'contrato' ->> 'docProc', '') ~ '^[A-Za-z0-9-]{10,80}$' then p_dados -> 'contrato' ->> 'docProc' end,
      'urlProc', case when p_dados -> 'contrato' ->> 'urlProc' ~ '^https://[a-z0-9.-]*zapsign[.](co|com[.]br)/' then left(p_dados -> 'contrato' ->> 'urlProc', 300) end,
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
      -- fluxo novo (06/11/2026): o cadastro feito no aplicativo novo (com o contrato do ZapSign) entra direto no Fluxo novo do BI,
      -- sem closer; versão antiga do aplicativo (sem contrato) continua no Fluxo antigo, onde o closer colhe a assinatura
      'fluxo', case when ct is not null then 'novo' end,
      'criadoEm', agora,
      'atualizadoEm', agora)))
  on conflict (id) do nothing;
  return cid;
end $$;
revoke all on function public.campo_cadastrar(text, text, jsonb) from public;
grant execute on function public.campo_cadastrar(text, text, jsonb) to anon, authenticated;

-- conferência: deve mostrar tem_fluxo = true
select position('fluxo' in pg_get_functiondef('public.campo_cadastrar(text,text,jsonb)'::regprocedure)) > 0 as tem_fluxo;
