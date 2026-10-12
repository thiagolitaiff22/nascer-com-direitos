-- Aplicativo do prospectador: a senha salva fica visível para o administrador no BI (para reenviar quando precisar).
-- A entrada no aplicativo continua conferindo pelo hash. Só administradores leem a senha. Pode rodar de novo.

alter table public.campo_logins add column if not exists senha_ver text;

create or replace function public.campo_definir_login(p_prosp text, p_usuario text, p_senha text)
returns text language plpgsql security definer set search_path = public as $$
declare u text := lower(trim(coalesce(p_usuario, '')));
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  if u !~ '^[a-z0-9._-]{3,30}$' then raise exception 'Usuário: de 3 a 30 letras ou números, sem espaço nem acento.'; end if;
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha precisa ter pelo menos 6 caracteres.'; end if;
  if exists (select 1 from public.campo_logins where usuario = u and prosp_id <> p_prosp) then raise exception 'Este usuário já é de outro prospectador.'; end if;
  delete from public.campo_logins where prosp_id = p_prosp and usuario <> u;
  insert into public.campo_logins (usuario, prosp_id, senha_hash, senha_ver, atualizado_por)
  values (u, p_prosp, extensions.crypt(p_senha, extensions.gen_salt('bf')), p_senha, lower(auth.jwt() ->> 'email'))
  on conflict (usuario) do update set senha_hash = excluded.senha_hash, senha_ver = excluded.senha_ver, ativo = true, erros = 0, bloqueado_ate = null,
    atualizado_em = now(), atualizado_por = excluded.atualizado_por;
  return u;
end $$;
revoke all on function public.campo_definir_login(text, text, text) from public, anon;
grant execute on function public.campo_definir_login(text, text, text) to authenticated;

create or replace function public.campo_login_status(p_prosp text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.minha_funcao() = 'admin' then
    (select jsonb_build_object('usuario', usuario, 'senha', senha_ver, 'ativo', ativo, 'atualizado_em', atualizado_em) from public.campo_logins where prosp_id = p_prosp)
  end
$$;
revoke all on function public.campo_login_status(text) from public, anon;
grant execute on function public.campo_login_status(text) to authenticated;

select 'ok' as senha_visivel;
