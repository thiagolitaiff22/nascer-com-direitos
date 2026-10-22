-- O cadastro vindo do aplicativo só é aceito com nome, telefone, cidade e CPF. Versão antiga do app (sem CPF/cidade) é recusada e fica na fila do celular até atualizar. Pode rodar de novo.
create or replace function public.campo_cadastrar(p_token text, p_envio text, p_dados jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare pid text; cid text; falta jsonb; agora text;
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

select 'ok' as cadastro_exige_dados;
