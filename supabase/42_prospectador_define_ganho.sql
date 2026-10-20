-- O prospectador define o ganho do parceiro que ele cadastra: quanto o parceiro recebe ao confirmar a mãe (contrato fechado)
-- e quando o benefício é liberado. Pode ser qualquer valor ou nenhum (0). Também pode mudar depois. Pode rodar de novo.

-- 1) prosp_painel: cada parceiro passa a trazer se tem ganho e os dois valores
create or replace function public.prosp_painel(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me text := public.prosp_dono(p_token); r jsonb;
begin
  if me is null then return null; end if;
  select jsonb_build_object(
    'atualizado', now(),
    'parceiros', coalesce(jsonb_agg(x order by (x ->> 'contratos')::int desc, x ->> 'nome'), '[]'::jsonb)
  ) into r
  from (
    select jsonb_build_object(
      'id', p.id,
      'nome', coalesce(p.data ->> 'nome', ''),
      'tipo', coalesce(p.data ->> 'tipo', 'pessoa'),
      'clinica', coalesce(p.data ->> 'clinica', ''),
      'cidade', coalesce(p.data ->> 'regiao', ''),
      'telefone', coalesce(p.data ->> 'telefone', ''),
      'usuario', (select l.usuario from public.campo_logins l where l.prosp_id = p.id),
      'ativo', coalesce((select l.ativo from public.campo_logins l where l.prosp_id = p.id), false),
      'criadoEm', coalesce(p.data ->> 'criadoEm', ''),
      'ganho', coalesce(p.data ->> 'semGanho', '') <> 'true',
      'comConf', coalesce(nullif(p.data ->> 'comConf', '')::numeric, 0),
      'comLib', coalesce(nullif(p.data ->> 'comLib', '')::numeric, 0),
      'indicacoes', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id),
      'contratos', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id and coalesce(c.data ->> 'contratoEm', '') <> ''),
      'guiasPagas', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id and c.data ->> 'guiaStatus' = 'paga'),
      'concedidos', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id
                      and (c.data ->> 'inssStatus' = 'concedido' or c.data ->> 'resultado' in ('procedente', 'parcial', 'acordo'))),
      'pagos', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id and c.data ->> 'pagamento' = 'pago')
    ) as x
    from public.prospectadores p
    where p.data ->> 'prospectadorId' = me
  ) t;
  return r;
end $$;
revoke all on function public.prosp_painel(text) from public;
grant execute on function public.prosp_painel(text) to anon, authenticated;

-- 2) prosp_criar_parceiro: aceita os dois valores do ganho (a versão de 9 parâmetros é substituída)
drop function if exists public.prosp_criar_parceiro(text, text, text, text, text, text, text, text, boolean);
create or replace function public.prosp_criar_parceiro(
  p_token text, p_nome text, p_tipo text, p_clinica text, p_cidade text, p_telefone text, p_usuario text, p_senha text,
  p_ganho boolean default true, p_com_conf numeric default 0, p_com_lib numeric default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := public.prosp_dono(p_token); u text := lower(trim(coalesce(p_usuario, ''))); novo text; reg text; tp text;
begin
  if me is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  if length(trim(coalesce(p_nome, ''))) < 3 then return jsonb_build_object('erro', 'Informe o nome do parceiro.'); end if;
  tp := case when p_tipo = 'clinica' then 'clinica' else 'pessoa' end;
  if tp = 'clinica' and length(trim(coalesce(p_clinica, ''))) < 2 then return jsonb_build_object('erro', 'Informe o nome da clínica.'); end if;
  if u !~ '^[a-z0-9._-]{3,30}$' then return jsonb_build_object('erro', 'Usuário: de 3 a 30 letras ou números, sem espaço nem acento.'); end if;
  if length(coalesce(p_senha, '')) < 6 then return jsonb_build_object('erro', 'A senha precisa ter pelo menos 6 caracteres.'); end if;
  if exists (select 1 from public.campo_logins where usuario = u) then return jsonb_build_object('erro', 'Este usuário já existe. Escolha outro.'); end if;
  select data ->> 'regiaoId' into reg from public.prospectadores where id = me;
  novo := replace(gen_random_uuid()::text, '-', '');
  insert into public.prospectadores (id, data) values (novo, jsonb_build_object(
    'nome', trim(p_nome), 'tipo', tp, 'clinica', case when tp = 'clinica' then trim(p_clinica) else '' end,
    'regiao', trim(coalesce(p_cidade, '')), 'regiaoId', coalesce(reg, ''), 'prospectadorId', me,
    'telefone', trim(coalesce(p_telefone, '')), 'ativo', true, 'semGanho', not coalesce(p_ganho, true),
    'comConf', case when coalesce(p_ganho, true) then greatest(coalesce(p_com_conf, 0), 0) else 0 end,
    'comLib', case when coalesce(p_ganho, true) then greatest(coalesce(p_com_lib, 0), 0) else 0 end,
    'criadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'atualizadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'criadoPor', 'prospectador:' || me));
  insert into public.campo_logins (usuario, prosp_id, senha_hash, senha_ver, trocar_senha, atualizado_por)
  values (u, novo, extensions.crypt(p_senha, extensions.gen_salt('bf')), p_senha, true, 'prospectador:' || me);
  return jsonb_build_object('ok', true, 'id', novo, 'usuario', u);
end $$;
revoke all on function public.prosp_criar_parceiro(text, text, text, text, text, text, text, text, boolean, numeric, numeric) from public;
grant execute on function public.prosp_criar_parceiro(text, text, text, text, text, text, text, text, boolean, numeric, numeric) to anon, authenticated;

-- 3) prosp_definir_ganho: o prospectador muda se o parceiro dele tem ganho e quanto (só dos parceiros dele)
create or replace function public.prosp_definir_ganho(p_token text, p_parceiro text, p_ganho boolean, p_conf numeric, p_lib numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := public.prosp_dono(p_token);
begin
  if me is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  if not exists (select 1 from public.prospectadores where id = p_parceiro and data ->> 'prospectadorId' = me) then
    return jsonb_build_object('erro', 'Este parceiro não é seu.'); end if;
  update public.prospectadores set data = data || jsonb_build_object(
      'semGanho', not coalesce(p_ganho, true),
      'comConf', case when coalesce(p_ganho, true) then greatest(coalesce(p_conf, 0), 0) else 0 end,
      'comLib', case when coalesce(p_ganho, true) then greatest(coalesce(p_lib, 0), 0) else 0 end,
      'atualizadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
  where id = p_parceiro;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.prosp_definir_ganho(text, text, boolean, numeric, numeric) from public;
grant execute on function public.prosp_definir_ganho(text, text, boolean, numeric, numeric) to anon, authenticated;

select 'ok' as prospectador_define_ganho;
