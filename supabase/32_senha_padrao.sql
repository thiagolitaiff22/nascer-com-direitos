-- Senha padrão com troca obrigatória no primeiro acesso.
-- Toda senha definida por um administrador é "provisória": a pessoa entra e é obrigada a criar a sua.
-- Vale para a equipe (BI e painel do gestor) e para parceiros e prospectadores (aplicativo). Pode rodar de novo.

alter table public.campo_logins add column if not exists trocar_senha boolean not null default false;
alter table public.equipe       add column if not exists trocar_senha boolean not null default false;

-- ---------- equipe (acesso por usuário e senha) ----------
drop function if exists public.equipe_definir_senha(text, text);
create or replace function public.equipe_definir_senha(p_email text, p_senha text, p_provisoria boolean default false)
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare e text := lower(trim(coalesce(p_email, ''))); uid uuid;
begin
  if public.minha_funcao() is distinct from 'admin' then
    return jsonb_build_object('erro', 'Só administrador pode definir senha.');
  end if;
  if e not like '%@acesso.rodrigueslitaiffadv.com.br' then
    return jsonb_build_object('erro', 'Este funcionário entra com e-mail: ele mesmo cria a senha pelo Primeiro acesso.');
  end if;
  if not exists (select 1 from public.equipe where email = e) then
    return jsonb_build_object('erro', 'Cadastre o funcionário na equipe antes de definir a senha.');
  end if;
  if length(coalesce(p_senha, '')) < 6 then
    return jsonb_build_object('erro', 'A senha precisa ter pelo menos 6 caracteres.');
  end if;

  perform set_config('app.criando_acesso', 'sim', true);
  select id into uid from auth.users where lower(email) = e;
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', e,
            extensions.crypt(p_senha, extensions.gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text,
            jsonb_build_object('sub', uid::text, 'email', e, 'email_verified', true), 'email', now(), now(), now());
  else
    update auth.users
       set encrypted_password = extensions.crypt(p_senha, extensions.gen_salt('bf')),
           email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now()
     where id = uid;
  end if;
  update public.equipe set senha_em = now(), trocar_senha = coalesce(p_provisoria, false) where email = e;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.equipe_definir_senha(text, text, boolean) from public, anon;
grant execute on function public.equipe_definir_senha(text, text, boolean) to authenticated;

-- a própria pessoa criou a senha nova: tira a obrigação de trocar
create or replace function public.equipe_senha_trocada()
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.equipe set trocar_senha = false, senha_em = now() where email = lower(coalesce(auth.jwt() ->> 'email', ''));
end $$;
revoke all on function public.equipe_senha_trocada() from public, anon;
grant execute on function public.equipe_senha_trocada() to authenticated;

-- ---------- parceiros e prospectadores (aplicativo) ----------
drop function if exists public.campo_definir_login(text, text, text);
create or replace function public.campo_definir_login(p_prosp text, p_usuario text, p_senha text, p_provisoria boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare u text := lower(trim(coalesce(p_usuario, '')));
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
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

-- lista dos acessos de parceiros e prospectadores (para redefinir senhas de uma vez)
create or replace function public.campo_logins_lista()
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.minha_funcao() = 'admin' then
    coalesce((select jsonb_agg(jsonb_build_object('prosp_id', l.prosp_id, 'usuario', l.usuario, 'ativo', l.ativo, 'trocar', l.trocar_senha,
              'nome', coalesce(p.data ->> 'nome', ''), 'perfil', coalesce(p.data ->> 'perfil', 'parceiro')) order by p.data ->> 'nome')
              from public.campo_logins l join public.prospectadores p on p.id = l.prosp_id where l.ativo), '[]'::jsonb)
  end
$$;
revoke all on function public.campo_logins_lista() from public, anon;
grant execute on function public.campo_logins_lista() to authenticated;

-- entrar no aplicativo: devolve também se precisa trocar a senha
create or replace function public.campo_entrar(p_usuario text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.campo_logins; t text;
begin
  select * into l from public.campo_logins where usuario = lower(trim(coalesce(p_usuario, ''))) and ativo;
  if l.usuario is null then return jsonb_build_object('erro', 'Usuário ou senha errados.'); end if;
  if l.bloqueado_ate is not null and l.bloqueado_ate > now() then
    return jsonb_build_object('erro', 'Muitas tentativas erradas. Espere 15 minutos ou fale com a equipe Nascer com Direitos.');
  end if;
  if l.senha_hash <> extensions.crypt(coalesce(p_senha, ''), l.senha_hash) then
    update public.campo_logins set erros = erros + 1,
      bloqueado_ate = case when erros + 1 >= 5 then now() + interval '15 minutes' else null end
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

-- o parceiro ou prospectador cria a senha nova (com o código de acesso dele)
create or replace function public.campo_trocar_senha(p_token text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pid text;
begin
  select prosp_id into pid from public.campo_acessos where token = p_token and ativo and length(p_token) >= 20;
  if pid is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  if length(coalesce(p_senha, '')) < 6 then return jsonb_build_object('erro', 'A senha precisa ter pelo menos 6 caracteres.'); end if;
  if p_senha = '123456' then return jsonb_build_object('erro', 'Escolha uma senha diferente da padrão.'); end if;
  update public.campo_logins set senha_hash = extensions.crypt(p_senha, extensions.gen_salt('bf')), senha_ver = p_senha,
    trocar_senha = false, erros = 0, bloqueado_ate = null, atualizado_em = now(), atualizado_por = 'proprio'
  where prosp_id = pid;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.campo_trocar_senha(text, text) from public;
grant execute on function public.campo_trocar_senha(text, text) to anon, authenticated;

-- prospectador cria parceiro: a senha que ele coloca é provisória (o parceiro cria a dele ao entrar)
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
  insert into public.campo_logins (usuario, prosp_id, senha_hash, senha_ver, trocar_senha, atualizado_por)
  values (u, novo, extensions.crypt(p_senha, extensions.gen_salt('bf')), p_senha, true, 'prospectador:' || me);
  return jsonb_build_object('ok', true, 'id', novo, 'usuario', u);
end $$;
revoke all on function public.prosp_criar_parceiro(text, text, text, text, text, text, text, text) from public;
grant execute on function public.prosp_criar_parceiro(text, text, text, text, text, text, text, text) to anon, authenticated;

select 'ok' as senha_padrao;
