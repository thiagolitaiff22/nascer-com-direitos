-- Mostra no sistema quem já tem senha cadastrada (e desde quando). Pode rodar de novo.
alter table public.equipe add column if not exists senha_em timestamptz;

-- quem já tem acesso por usuário e senha: usa a data da última alteração da senha
update public.equipe e
   set senha_em = u.updated_at
  from auth.users u
 where lower(u.email) = e.email and e.senha_em is null;

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
  update public.equipe set senha_em = now() where email = e;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.equipe_definir_senha(text, text) from public, anon;
grant execute on function public.equipe_definir_senha(text, text) to authenticated;

select email, nome, senha_em from public.equipe order by nome;
