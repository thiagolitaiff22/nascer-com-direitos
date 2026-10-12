-- Prospectador: funcionário que procura os parceiros. Entra no mesmo aplicativo (usuário e senha),
-- cria o login e a senha dos parceiros e vê quantos contratos cada parceiro trouxe.
-- Reaproveita a tabela "prospectadores" (que no sistema aparece como Parceiros):
--   prospectador  -> data.perfil = 'prospectador' (com data.regiaoId = estado em que atua)
--   parceiro      -> sem perfil, com data.prospectadorId = id do prospectador que o trouxe
-- Pode rodar de novo sem perder dados.

-- quem entrou: acrescenta o perfil (parceiro ou prospectador) e o estado
create or replace function public.campo_quem(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'prospId', a.prosp_id,
    'nome', coalesce(p.data ->> 'nome', ''),
    'perfil', coalesce(p.data ->> 'perfil', 'parceiro'),
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

-- id do prospectador dono do código de acesso (ou nulo se o código não é de um prospectador)
create or replace function public.prosp_dono(p_token text)
returns text language sql stable security definer set search_path = public as $$
  select a.prosp_id
  from public.campo_acessos a join public.prospectadores p on p.id = a.prosp_id
  where a.token = p_token and a.ativo and length(p_token) >= 20 and p.data ->> 'perfil' = 'prospectador'
$$;
revoke all on function public.prosp_dono(text) from public, anon, authenticated;

-- painel do prospectador: os parceiros dele e os números de cada um (só números, sem dados das clientes)
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

-- cria o parceiro (cadastro + usuário + senha). Devolve {ok, id, usuario} ou {erro}
create or replace function public.prosp_criar_parceiro(
  p_token text, p_nome text, p_tipo text, p_clinica text, p_cidade text, p_telefone text, p_usuario text, p_senha text)
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
    'telefone', trim(coalesce(p_telefone, '')), 'ativo', true,
    'criadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'atualizadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'criadoPor', 'prospectador:' || me));
  insert into public.campo_logins (usuario, prosp_id, senha_hash, senha_ver, atualizado_por)
  values (u, novo, extensions.crypt(p_senha, extensions.gen_salt('bf')), p_senha, 'prospectador:' || me);
  return jsonb_build_object('ok', true, 'id', novo, 'usuario', u);
end $$;
revoke all on function public.prosp_criar_parceiro(text, text, text, text, text, text, text, text) from public;
grant execute on function public.prosp_criar_parceiro(text, text, text, text, text, text, text, text) to anon, authenticated;

-- troca a senha de um parceiro dele
create or replace function public.prosp_trocar_senha(p_token text, p_parceiro text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := public.prosp_dono(p_token);
begin
  if me is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  if not exists (select 1 from public.prospectadores where id = p_parceiro and data ->> 'prospectadorId' = me) then
    return jsonb_build_object('erro', 'Este parceiro não é seu.'); end if;
  if length(coalesce(p_senha, '')) < 6 then return jsonb_build_object('erro', 'A senha precisa ter pelo menos 6 caracteres.'); end if;
  update public.campo_logins set senha_hash = extensions.crypt(p_senha, extensions.gen_salt('bf')), senha_ver = p_senha,
    erros = 0, bloqueado_ate = null, atualizado_em = now(), atualizado_por = 'prospectador:' || me
  where prosp_id = p_parceiro;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.prosp_trocar_senha(text, text, text) from public;
grant execute on function public.prosp_trocar_senha(text, text, text) to anon, authenticated;

-- bloqueia ou libera o acesso de um parceiro dele
create or replace function public.prosp_ativar(p_token text, p_parceiro text, p_ativo boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := public.prosp_dono(p_token);
begin
  if me is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  if not exists (select 1 from public.prospectadores where id = p_parceiro and data ->> 'prospectadorId' = me) then
    return jsonb_build_object('erro', 'Este parceiro não é seu.'); end if;
  update public.campo_logins set ativo = coalesce(p_ativo, true), erros = 0, bloqueado_ate = null where prosp_id = p_parceiro;
  update public.prospectadores set data = data || jsonb_build_object('ativo', coalesce(p_ativo, true)) where id = p_parceiro;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.prosp_ativar(text, text, boolean) from public;
grant execute on function public.prosp_ativar(text, text, boolean) to anon, authenticated;

select 'ok' as prospectador;
