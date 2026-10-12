-- Chave do Claude guardada no banco (Configurações › Integrações › Claude), lida só pelo script do Google.
-- O script se registra uma vez com um código secreto gerado por ele mesmo; só quem tem esse código lê a chave.
-- Pode rodar de novo sem perder dados.

alter table public.segredos drop constraint if exists segredos_nome_check;
alter table public.segredos add constraint segredos_nome_check
  check (nome in ('liderhub', 'regua_token', 'regua_anon', 'datajud', 'claude', 'campo_script'));

-- script do Google: registra o código dele (só funciona se ainda não houver um registrado)
create or replace function public.campo_registrar_script(p_segredo text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if length(coalesce(p_segredo, '')) < 32 then return false; end if;
  insert into public.segredos (nome, valor, atualizado_por) values ('campo_script', p_segredo, 'script do Google')
  on conflict (nome) do nothing;
  return exists (select 1 from public.segredos where nome = 'campo_script' and valor = p_segredo);
end $$;
revoke all on function public.campo_registrar_script(text) from public;
grant execute on function public.campo_registrar_script(text) to anon, authenticated;

-- script do Google: lê a chave do Claude com o código dele
create or replace function public.campo_chave_claude(p_segredo text)
returns text language sql stable security definer set search_path = public as $$
  select c.valor from public.segredos c
  where c.nome = 'claude'
    and exists (select 1 from public.segredos s where s.nome = 'campo_script' and s.valor = p_segredo and length(p_segredo) >= 32)
$$;
revoke all on function public.campo_chave_claude(text) from public;
grant execute on function public.campo_chave_claude(text) to anon, authenticated;

-- administrador: desfaz o registro do script (se trocar de script, ele se registra de novo)
create or replace function public.campo_esquecer_script()
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  delete from public.segredos where nome = 'campo_script';
end $$;
revoke all on function public.campo_esquecer_script() from public, anon;
grant execute on function public.campo_esquecer_script() to authenticated;

select 'ok' as claude;
