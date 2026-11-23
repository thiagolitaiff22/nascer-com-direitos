-- 61 · Gestor cadastra mães e parceiros pelo aplicativo (23/11/2026)
-- Pedido: "atualize o login do Erley para que ele possa fazer cadastros de parceiros e mães".
-- O gestor (equipe do BI com função de administrador, SQL 59) entra no aplicativo com o acesso "gestor:<e-mail>".
-- 1) campo_quem: devolve o nome do gestor (vem da equipe; ele não está em prospectadores). O script do Google usa esse nome.
-- 2) campo_cadastrar: a mãe que o gestor cadastra leva criadoPorNome e criadoPorEmail dele (o BI mostra "Cadastro de <nome>").
--    Mesma função do SQL 58; nada muda para parceiros e prospectadores.
-- 3) gestor_criar_parceiro: igual ao prosp_criar_parceiro (SQL 44), mas o parceiro entra direto na equipe do gestor
--    ("Gestor responsável" = ele). Login pelo CPF, senha inicial que o gestor escolhe, ganhos como no prospectador.
-- Só troca e acrescenta funções: não altera nem apaga dados. Pode rodar de novo.

-- 1) campo_quem
create or replace function public.campo_quem(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'prospId', a.prosp_id,
    'nome', coalesce(p.data ->> 'nome', (select q.nome from public.equipe q where a.prosp_id = 'gestor:' || lower(q.email) limit 1), ''),
    'perfil', coalesce(p.data ->> 'perfil', 'parceiro'),
    'tambemParceiro', coalesce(p.data ->> 'tambemParceiro', '') = 'true',
    'temGanho', coalesce(p.data ->> 'semGanho', '') <> 'true',
    'tipo', coalesce(p.data ->> 'tipo', 'pessoa'),
    'clinica', coalesce(p.data ->> 'clinica', ''),
    'regiaoId', coalesce(p.data ->> 'regiaoId', ''),
    'envioUrl', (select envio_url from public.campo_config where id = 1),
    'cadastros', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nome', c.data ->> 'nome', 'em', c.data ->> 'criadoEm',
        'etapa', case when coalesce(trim(c.data ->> 'processo'), '') <> '' then
                        case when coalesce(c.data ->> 'audData', '') = '' then 'justica' else 'audiencia' end
                      when coalesce(trim(c.data ->> 'der'), '') <> '' or coalesce(trim(c.data ->> 'protocoloInss'), '') <> '' then 'inss'
                      else 'sem_requerimento' end)
        order by c.data ->> 'criadoEm' desc)
      from (select * from public.clientes c2 where c2.data ->> 'responsavelId' = a.prosp_id and c2.data ->> 'origem' = 'campo'
            order by c2.data ->> 'criadoEm' desc limit 60) c), '[]'::jsonb)
  )
  from public.campo_acessos a left join public.prospectadores p on p.id = a.prosp_id
  where a.token = p_token and a.ativo and length(p_token) >= 20
$$;
revoke all on function public.campo_quem(text) from public;
grant execute on function public.campo_quem(text) to anon, authenticated;

-- 2) campo_cadastrar
create or replace function public.campo_cadastrar(p_token text, p_envio text, p_dados jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare pid text; cid text; falta jsonb; agora text; ct jsonb; gem text; gnome text;
begin
  select prosp_id into pid from public.campo_acessos where token = p_token and ativo and length(p_token) >= 20;
  if pid is null then raise exception 'Link inválido ou cancelado.'; end if;
  if pid like 'gestor:%' then   -- gestor cadastrando pelo aplicativo (SQL 61)
    gem := substr(pid, 8);
    select q.nome into gnome from public.equipe q where lower(q.email) = gem and coalesce(q.ativo, true) limit 1;
    if gnome is null then raise exception 'Link inválido ou cancelado.'; end if;
  end if;
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
      'criadoPorEmail', gem, 'criadoPorNome', gnome,   -- só no cadastro do gestor (nos outros fica nulo e some)
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

-- 3) gestor_criar_parceiro
create or replace function public.gestor_criar_parceiro(
  p_token text, p_nome text, p_tipo text, p_clinica text, p_cidade text, p_telefone text, p_usuario text, p_senha text,
  p_ganho boolean default true, p_com_conf numeric default 0, p_com_lib numeric default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me text; em text; u text := lower(trim(coalesce(p_usuario, ''))); novo text; reg text; tp text;
begin
  if u ~ '^[0-9. -]+$' then u := regexp_replace(u, '\D', '', 'g'); end if;
  select a.prosp_id into me from public.campo_acessos a where a.token = p_token and a.ativo and length(p_token) >= 20 and a.prosp_id like 'gestor:%';
  if me is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  em := substr(me, 8);
  -- só quem continua na equipe do BI como administrador (o mesmo que o aplicativo exige para entrar como gestor)
  select case when coalesce(array_length(q.estados, 1), 0) = 1 then q.estados[1] else '' end into reg
    from public.equipe q where lower(q.email) = em and coalesce(q.ativo, true) and q.funcao = 'admin' limit 1;
  if not found then return jsonb_build_object('erro', 'Este acesso é só para gestores.'); end if;
  if length(trim(coalesce(p_nome, ''))) < 3 then return jsonb_build_object('erro', 'Informe o nome do parceiro.'); end if;
  tp := case when p_tipo = 'clinica' then 'clinica' else 'pessoa' end;
  if tp = 'clinica' and length(trim(coalesce(p_clinica, ''))) < 2 then return jsonb_build_object('erro', 'Informe o nome da clínica.'); end if;
  if u !~ '^[a-z0-9._-]{3,30}$' then return jsonb_build_object('erro', 'Usuário: de 3 a 30 letras ou números, sem espaço nem acento.'); end if;
  if length(coalesce(p_senha, '')) < 6 then return jsonb_build_object('erro', 'A senha precisa ter pelo menos 6 caracteres.'); end if;
  if exists (select 1 from public.campo_logins where usuario = u) then return jsonb_build_object('erro', 'Este usuário já existe. Escolha outro.'); end if;
  novo := replace(gen_random_uuid()::text, '-', '');
  insert into public.prospectadores (id, data) values (novo, jsonb_build_object(
    'nome', trim(p_nome), 'tipo', tp, 'clinica', case when tp = 'clinica' then trim(p_clinica) else '' end,
    'regiao', trim(coalesce(p_cidade, '')), 'regiaoId', coalesce(reg, ''), 'gestorEmail', em,
    'telefone', trim(coalesce(p_telefone, '')), 'ativo', true, 'semGanho', not coalesce(p_ganho, true),
    'comConf', case when coalesce(p_ganho, true) then greatest(coalesce(p_com_conf, 0), 0) else 0 end,
    'comLib', case when coalesce(p_ganho, true) then greatest(coalesce(p_com_lib, 0), 0) else 0 end,
    'criadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'atualizadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'criadoPor', me));
  insert into public.campo_logins (usuario, prosp_id, senha_hash, senha_ver, trocar_senha, atualizado_por)
  values (u, novo, extensions.crypt(p_senha, extensions.gen_salt('bf')), p_senha, true, me);
  return jsonb_build_object('ok', true, 'id', novo, 'usuario', u);
end $$;
revoke all on function public.gestor_criar_parceiro(text, text, text, text, text, text, text, text, boolean, numeric, numeric) from public;
grant execute on function public.gestor_criar_parceiro(text, text, text, text, text, text, text, text, boolean, numeric, numeric) to anon, authenticated;

-- conferência: as três funções no ar com a mudança
select position('gestor:' in pg_get_functiondef('public.campo_quem(text)'::regprocedure)) > 0 as quem_ok,
       position('criadoPorNome' in pg_get_functiondef('public.campo_cadastrar(text,text,jsonb)'::regprocedure)) > 0 as cadastro_ok,
       to_regprocedure('public.gestor_criar_parceiro(text,text,text,text,text,text,text,text,boolean,numeric,numeric)') is not null as parceiro_ok;
