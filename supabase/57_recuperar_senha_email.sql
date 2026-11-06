-- "Esqueci a senha" do BI por e-mail.
-- Quem usa o BI (gestores e pós-venda) continua entrando com o CPF; o e-mail serve só para receber o link de troca.
-- A pessoa digita o e-mail na tela de entrada, o banco gera um link que vale 1 hora e serve uma vez só,
-- e o script do Google (conta do escritório) manda o e-mail. Ninguém precisa pedir ao gestor.
-- Precisa do google/campo.gs com a ação "emailSenha" implantado. Pode rodar de novo.

-- 1) e-mail de recuperação de cada pessoa da equipe (o login continua sendo o CPF)
alter table public.equipe add column if not exists email_recuperacao text;

-- 2) links de troca já pedidos (o link em si não fica guardado: só a impressão digital dele)
create table if not exists public.equipe_trocas_senha (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,                 -- acesso da pessoa (o mesmo de equipe.email)
  para       text not null,                 -- e-mail que recebeu o link
  token_hash text not null unique,
  criado_em  timestamptz not null default now(),
  expira_em  timestamptz not null default now() + interval '1 hour',
  usado_em   timestamptz
);
create index if not exists equipe_trocas_senha_para on public.equipe_trocas_senha (para, criado_em);
alter table public.equipe_trocas_senha enable row level security;   -- sem políticas: só as funções abaixo leem e gravam

-- 3) tela de entrada: "Esqueci a senha". Responde sempre a mesma coisa, exista ou não o e-mail.
--    p_volta é o endereço do BI que pediu (o link do e-mail volta para ele); só vale o endereço do próprio sistema.
create or replace function public.equipe_esqueci_senha(p_email text, p_volta text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  e text := lower(trim(coalesce(p_email, '')));
  volta text := coalesce(nullif(trim(p_volta), ''), 'https://www.nascercomdireitos.com.br/');
  v_url text; v_seg text; tk text; u record;
begin
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(e) > 200 then
    return jsonb_build_object('erro', 'Informe o seu e-mail.');
  end if;
  if volta !~ '^https://(www\.nascercomdireitos\.com\.br|nascercomdireitos\.com\.br|thiagolitaiff22\.github\.io/nascer-com-direitos)/'
     and volta !~ '^http://(localhost|127\.0\.0\.1)(:\d+)?/' then
    volta := 'https://www.nascercomdireitos.com.br/';
  end if;
  volta := split_part(split_part(volta, '#', 1), '?', 1);

  select envio_url into v_url from public.campo_config where id = 1;
  select valor into v_seg from public.segredos where nome = 'campo_script';
  if coalesce(v_url, '') = '' or coalesce(v_seg, '') = '' then
    return jsonb_build_object('erro', 'O envio de e-mail ainda não está ligado. Avise o escritório.');
  end if;

  -- freio: no máximo 40 pedidos por hora no total e 3 por e-mail
  if (select count(*) from public.equipe_trocas_senha where criado_em > now() - interval '1 hour') >= 40 then
    return jsonb_build_object('erro', 'Muitos pedidos agora. Tente de novo em alguns minutos.');
  end if;
  delete from public.equipe_trocas_senha where criado_em < now() - interval '30 days';
  if (select count(*) from public.equipe_trocas_senha where para = e and criado_em > now() - interval '1 hour') >= 3 then
    return jsonb_build_object('ok', true);
  end if;

  for u in
    select q.email, q.nome from public.equipe q
    where q.ativo
      and (lower(trim(q.email_recuperacao)) = e
           or (lower(q.email) = e and q.email not like '%@acesso.rodrigueslitaiffadv.com.br'))
    order by q.nome limit 3
  loop
    tk := encode(extensions.gen_random_bytes(32), 'hex');
    insert into public.equipe_trocas_senha (email, para, token_hash)
    values (u.email, e, encode(extensions.digest(tk, 'sha256'), 'hex'));
    perform net.http_post(
      url := v_url,
      body := jsonb_build_object('acao', 'emailSenha', 'segredo', v_seg, 'para', e,
                                 'nome', split_part(trim(coalesce(u.nome, '')), ' ', 1),
                                 'link', volta || '#troca=' || tk),
      headers := jsonb_build_object('Content-Type', 'application/json'),
      timeout_milliseconds := 30000);
  end loop;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.equipe_esqueci_senha(text, text) from public;
grant execute on function public.equipe_esqueci_senha(text, text) to anon, authenticated;

-- 4) a pessoa abriu o link do e-mail e criou a senha nova. Devolve o acesso para o BI já entrar.
create or replace function public.equipe_trocar_senha(p_token text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare t record; uid uuid; s text := coalesce(p_senha, '');
begin
  if coalesce(p_token, '') !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('erro', 'Link inválido. Peça outro em Esqueci a senha.');
  end if;
  select * into t from public.equipe_trocas_senha
   where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
   for update;
  if not found or t.usado_em is not null or t.expira_em < now() then
    return jsonb_build_object('erro', 'Este link já foi usado ou venceu (vale 1 hora). Peça outro em Esqueci a senha.');
  end if;
  if not exists (select 1 from public.equipe where email = t.email and ativo) then
    return jsonb_build_object('erro', 'Este acesso está bloqueado. Fale com o gestor.');
  end if;
  if length(s) < 6 then return jsonb_build_object('erro', 'A senha precisa ter pelo menos 6 caracteres.'); end if;
  if s = '123456' then return jsonb_build_object('erro', 'Escolha uma senha diferente da padrão (123456).'); end if;

  perform set_config('app.criando_acesso', 'sim', true);
  select id into uid from auth.users where lower(email) = t.email;
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', t.email,
            extensions.crypt(s, extensions.gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text,
            jsonb_build_object('sub', uid::text, 'email', t.email, 'email_verified', true), 'email', now(), now(), now());
  else
    update auth.users
       set encrypted_password = extensions.crypt(s, extensions.gen_salt('bf')),
           email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now()
     where id = uid;
  end if;
  -- este link e os outros pendentes da mesma pessoa deixam de valer
  update public.equipe_trocas_senha set usado_em = now() where email = t.email and usado_em is null;
  update public.equipe set senha_em = now(), trocar_senha = false where email = t.email;
  return jsonb_build_object('ok', true, 'email', t.email);
end $$;
revoke all on function public.equipe_trocar_senha(text, text) from public;
grant execute on function public.equipe_trocar_senha(text, text) to anon, authenticated;

-- 5) a própria pessoa, já dentro do BI, cadastra ou troca o e-mail de recuperação
create or replace function public.equipe_meu_email_recuperacao(p_email text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(coalesce(p_email, ''))); eu text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if eu = '' or not exists (select 1 from public.equipe where email = eu) then
    return jsonb_build_object('erro', 'Entre no sistema primeiro.');
  end if;
  if e <> '' and (e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or e like '%@acesso.rodrigueslitaiffadv.com.br') then
    return jsonb_build_object('erro', 'Informe um e-mail que você abre.');
  end if;
  update public.equipe set email_recuperacao = nullif(e, '') where email = eu;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.equipe_meu_email_recuperacao(text) from public, anon;
grant execute on function public.equipe_meu_email_recuperacao(text) to authenticated;

-- 6) o e-mail de recuperação de cada pessoa se cadastra no BI (Configurações › Equipe › Editar, ou no menu da própria pessoa)
select email, nome, email_recuperacao from public.equipe where email_recuperacao is not null;
