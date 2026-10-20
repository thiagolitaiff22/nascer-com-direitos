-- Corrige logins do aplicativo cadastrados com pontos e traço (ex.: 610.161.012-87). O aplicativo só aceita números (61016101287),
-- então esses parceiros nunca conseguiam entrar, mesmo com a senha certa. Passa a valer sempre só o número do CPF.
-- Também destrava quem ficou bloqueado por tentativas erradas. Não mexe em nenhuma senha. Pode rodar de novo.

-- 1) conserta os logins que já existem (só troca o usuário, a senha continua a mesma)
update public.campo_logins l
set usuario = regexp_replace(l.usuario, '\D', '', 'g')
where l.usuario ~ '^[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2}$'
  and not exists (select 1 from public.campo_logins x where x.usuario = regexp_replace(l.usuario, '\D', '', 'g'));

-- 2) destrava quem estava bloqueado por erros de senha
update public.campo_logins set erros = 0, bloqueado_ate = null where erros > 0 or bloqueado_ate is not null;

-- 3) entrar: aceita o CPF com ou sem pontuação
create or replace function public.campo_entrar(p_usuario text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.campo_logins; t text; u text := lower(trim(coalesce(p_usuario, '')));
begin
  if u ~ '^[0-9. -]+$' then u := regexp_replace(u, '\D', '', 'g'); end if;
  select * into l from public.campo_logins where ativo and (usuario = u or regexp_replace(usuario, '\D', '', 'g') = u) order by (usuario = u) desc limit 1;
  if l.usuario is null then return jsonb_build_object('erro', 'Usuário ou senha errados.'); end if;
  if l.bloqueado_ate is not null and l.bloqueado_ate > now() then
    return jsonb_build_object('erro', 'Muitas tentativas erradas. Espere 10 minutos ou fale com a equipe Nascer com Direitos.');
  end if;
  if l.senha_hash <> extensions.crypt(coalesce(p_senha, ''), l.senha_hash) then
    update public.campo_logins set erros = erros + 1,
      bloqueado_ate = case when erros + 1 >= 8 then now() + interval '10 minutes' else null end
    where usuario = l.usuario;
    return jsonb_build_object('erro', 'Usuário ou senha errados.');
  end if;
  update public.campo_logins set erros = 0, bloqueado_ate = null where usuario = l.usuario;
  select token into t from public.campo_acessos where prosp_id = l.prosp_id and ativo order by criado_em desc limit 1;
  if t is null then
    t := replace(replace(encode(extensions.gen_random_bytes(18), 'base64'), '+', '-'), '/', '_');
    insert into public.campo_acessos (token, prosp_id, criado_por) values (t, l.prosp_id, 'login:' || l.usuario);
  end if;
  return jsonb_build_object('token', t, 'trocar', l.trocar_senha);
end $$;
revoke all on function public.campo_entrar(text, text) from public;
grant execute on function public.campo_entrar(text, text) to anon, authenticated;

-- 4) definir login (BI): grava sempre só os números quando é CPF
create or replace function public.campo_definir_login(p_prosp text, p_usuario text, p_senha text, p_provisoria boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare u text := lower(trim(coalesce(p_usuario, '')));
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  if u ~ '^[0-9. -]+$' then u := regexp_replace(u, '\D', '', 'g'); end if;
  if u !~ '^[a-z0-9._-]{3,30}$' then raise exception 'Usuário: de 3 a 30 letras ou números, sem espaço nem acento.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  if exists (select 1 from public.campo_logins where usuario = u and prosp_id <> p_prosp) then raise exception 'Este usuário já é de outro prospectador.'; end if;
  delete from public.campo_logins where prosp_id = p_prosp and usuario <> u;
  insert into public.campo_logins (usuario, prosp_id, senha_hash, senha_ver, trocar_senha, atualizado_por)
  values (u, p_prosp, extensions.crypt(p_senha, extensions.gen_salt('bf')), p_senha, coalesce(p_provisoria, false), lower(auth.jwt() ->> 'email'))
  on conflict (usuario) do update set senha_hash = excluded.senha_hash, senha_ver = excluded.senha_ver, trocar_senha = excluded.trocar_senha,
    ativo = true, erros = 0, bloqueado_ate = null, atualizado_em = now(), atualizado_por = excluded.atualizado_por;
  return u;
end $$;
revoke all on function public.campo_definir_login(text, text, text, boolean) from public, anon;
grant execute on function public.campo_definir_login(text, text, text, boolean) to authenticated;

-- 5) prospectador cria parceiro: usuário sempre só números quando é CPF
create or replace function public.prosp_criar_parceiro(
  p_token text, p_nome text, p_tipo text, p_clinica text, p_cidade text, p_telefone text, p_usuario text, p_senha text,
  p_ganho boolean default true, p_com_conf numeric default 0, p_com_lib numeric default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me text := public.prosp_dono(p_token); u text := lower(trim(coalesce(p_usuario, ''))); novo text; reg text; tp text;
begin
  if u ~ '^[0-9. -]+$' then u := regexp_replace(u, '\D', '', 'g'); end if;
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

select usuario, ativo from public.campo_logins order by atualizado_em desc;
