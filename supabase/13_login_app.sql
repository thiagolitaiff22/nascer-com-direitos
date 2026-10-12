-- Aplicativo do prospectador: entrada com usuário e senha (em vez de colar o link).
-- O administrador define o usuário e a senha no BI (Prospectadores › Acesso do aplicativo).
-- A senha fica guardada só como hash (bcrypt). Depois de 5 senhas erradas, o usuário fica bloqueado por 15 minutos.
-- Pode rodar de novo sem perder dados.

create table if not exists public.campo_logins (
  usuario       text primary key,
  prosp_id      text not null unique,
  senha_hash    text not null,
  ativo         boolean not null default true,
  erros         int not null default 0,
  bloqueado_ate timestamptz,
  atualizado_em timestamptz not null default now(),
  atualizado_por text
);
alter table public.campo_logins enable row level security;
revoke all on public.campo_logins from anon, authenticated;
grant all on public.campo_logins to service_role;

-- administrador: cria ou troca o usuário e a senha de um prospectador
create or replace function public.campo_definir_login(p_prosp text, p_usuario text, p_senha text)
returns text language plpgsql security definer set search_path = public as $$
declare u text := lower(trim(coalesce(p_usuario, '')));
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  if u !~ '^[a-z0-9._-]{3,30}$' then raise exception 'Usuário: de 3 a 30 letras ou números, sem espaço nem acento.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  if exists (select 1 from public.campo_logins where usuario = u and prosp_id <> p_prosp) then raise exception 'Este usuário já é de outro prospectador.'; end if;
  delete from public.campo_logins where prosp_id = p_prosp and usuario <> u;
  insert into public.campo_logins (usuario, prosp_id, senha_hash, atualizado_por)
  values (u, p_prosp, extensions.crypt(p_senha, extensions.gen_salt('bf')), lower(auth.jwt() ->> 'email'))
  on conflict (usuario) do update set senha_hash = excluded.senha_hash, ativo = true, erros = 0, bloqueado_ate = null,
    atualizado_em = now(), atualizado_por = excluded.atualizado_por;
  return u;
end $$;
revoke all on function public.campo_definir_login(text, text, text) from public, anon;
grant execute on function public.campo_definir_login(text, text, text) to authenticated;

-- administrador: qual é o usuário de um prospectador (a senha nunca volta)
create or replace function public.campo_login_status(p_prosp text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.minha_funcao() = 'admin' then
    (select jsonb_build_object('usuario', usuario, 'ativo', ativo, 'atualizado_em', atualizado_em) from public.campo_logins where prosp_id = p_prosp)
  end
$$;
revoke all on function public.campo_login_status(text) from public, anon;
grant execute on function public.campo_login_status(text) to authenticated;

-- administrador: tira o acesso por usuário e senha
create or replace function public.campo_remover_login(p_prosp text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  delete from public.campo_logins where prosp_id = p_prosp;
end $$;
revoke all on function public.campo_remover_login(text) from public, anon;
grant execute on function public.campo_remover_login(text) to authenticated;

-- aplicativo: entra com usuário e senha e recebe o código de acesso do prospectador
-- (devolve {token} ou {erro}; não usa raise para não desfazer a contagem de senhas erradas)
drop function if exists public.campo_entrar(text, text);
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
  return jsonb_build_object('token', t);
end $$;
revoke all on function public.campo_entrar(text, text) from public;
grant execute on function public.campo_entrar(text, text) to anon, authenticated;

select 'ok' as login_app;
