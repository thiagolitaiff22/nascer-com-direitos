-- Quem estiver com a senha padrão (123456) é sempre obrigado a criar a própria no próximo acesso,
-- não importa como ela chegou a ser 123456. Pode rodar de novo.

create or replace function public.equipe_precisa_trocar()
returns boolean language sql stable security definer set search_path = public, auth, extensions as $$
  select coalesce((select u.encrypted_password = extensions.crypt('123456', u.encrypted_password) from auth.users u where u.id = auth.uid()), false)
      or coalesce((select e.trocar_senha from public.equipe e where e.email = lower(coalesce(auth.jwt() ->> 'email', ''))), false)
$$;
revoke all on function public.equipe_precisa_trocar() from public, anon;
grant execute on function public.equipe_precisa_trocar() to authenticated;

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
  return jsonb_build_object('token', t, 'trocar', (l.trocar_senha or l.senha_hash = extensions.crypt('123456', l.senha_hash)));
end $$;
revoke all on function public.campo_entrar(text, text) from public;
grant execute on function public.campo_entrar(text, text) to anon, authenticated;

select 'ok' as senha_padrao_dinamica;
