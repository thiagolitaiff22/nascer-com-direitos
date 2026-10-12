-- Acesso ao BI por usuário e senha (sem e-mail).
-- O usuário "thiago" vira internamente thiago@acesso.rodrigueslitaiffadv.com.br (endereço que não recebe e-mail).
-- Só um administrador logado, pelo BI (Configurações › Equipe), consegue criar o acesso ou trocar a senha.
-- Pode rodar de novo sem perder dados.

-- 1) Ninguém cria conta com esse final de endereço pelo cadastro público: só a função abaixo.
create or replace function public.bloquear_acesso_interno()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if lower(coalesce(new.email, '')) like '%@acesso.rodrigueslitaiffadv.com.br'
     and coalesce(current_setting('app.criando_acesso', true), '') <> 'sim' then
    raise exception 'Este tipo de acesso só é criado por um administrador.';
  end if;
  return new;
end $$;

drop trigger if exists bloquear_acesso_interno on auth.users;
create trigger bloquear_acesso_interno before insert or update of email on auth.users
  for each row execute function public.bloquear_acesso_interno();

-- 2) Administrador cria o acesso (ou troca a senha) de um usuário da equipe.
--    Devolve {ok:true} ou {erro:'...'}.
create or replace function public.equipe_definir_senha(p_email text, p_senha text)
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
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.equipe_definir_senha(text, text) from public, anon;
grant execute on function public.equipe_definir_senha(text, text) to authenticated;

select 'ok' as acesso_usuario;
