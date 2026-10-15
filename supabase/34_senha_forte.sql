-- Senha própria do parceiro/prospectador: mínimo de 6, com maiúscula, minúscula, número e símbolo. Pode rodar de novo.
create or replace function public.campo_trocar_senha(p_token text, p_senha text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pid text;
begin
  select prosp_id into pid from public.campo_acessos where token = p_token and ativo and length(p_token) >= 20;
  if pid is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  if length(coalesce(p_senha, '')) < 6 then return jsonb_build_object('erro', 'A senha precisa ter no mínimo 6 caracteres.'); end if;
  if p_senha = '123456' then return jsonb_build_object('erro', 'Escolha uma senha diferente da padrão.'); end if;
  if p_senha !~ '[A-Z]' then return jsonb_build_object('erro', 'Falta pelo menos uma letra maiúscula.'); end if;
  if p_senha !~ '[a-z]' then return jsonb_build_object('erro', 'Falta pelo menos uma letra minúscula.'); end if;
  if p_senha !~ '[0-9]' then return jsonb_build_object('erro', 'Falta pelo menos um número.'); end if;
  if p_senha !~ '[^A-Za-z0-9]' then return jsonb_build_object('erro', 'Falta pelo menos um símbolo (por exemplo ! @ # $ %).'); end if;
  update public.campo_logins set senha_hash = extensions.crypt(p_senha, extensions.gen_salt('bf')), senha_ver = p_senha,
    trocar_senha = false, erros = 0, bloqueado_ate = null, atualizado_em = now(), atualizado_por = 'proprio'
  where prosp_id = pid;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.campo_trocar_senha(text, text) from public;
grant execute on function public.campo_trocar_senha(text, text) to anon, authenticated;

select 'ok' as senha_forte;
