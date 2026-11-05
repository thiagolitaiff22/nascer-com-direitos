-- 53 · Conta do aplicativo: o nome que a parceira (ou o prospectador) quer ver no app e a foto de perfil.
-- Ficam em prospectadores.data (apelido, fotoPerfil). O nome oficial (data.nome) não muda: é o que o escritório usa.
-- Antes deste SQL o aplicativo guarda o nome e a foto só no celular; depois dele, valem em qualquer celular.
-- Pode rodar de novo.

-- lê o perfil (o app chama ao abrir)
create or replace function public.campo_perfil(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('apelido', coalesce(p.data ->> 'apelido', ''), 'foto', coalesce(p.data ->> 'fotoPerfil', ''))
  from public.campo_acessos a join public.prospectadores p on p.id = a.prosp_id
  where a.token = p_token and a.ativo and length(p_token) >= 20
$$;
revoke all on function public.campo_perfil(text) from public;
grant execute on function public.campo_perfil(text) to anon, authenticated;

-- grava o nome de exibição e/ou a foto (null = não mexe; '' = apaga). Foto: JPEG/PNG/WebP pequena (o app manda 192x192)
create or replace function public.campo_perfil_salvar(p_token text, p_apelido text default null, p_foto text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pid text; muda jsonb := '{}'::jsonb;
begin
  select prosp_id into pid from public.campo_acessos where token = p_token and ativo and length(p_token) >= 20;
  if pid is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  if p_apelido is not null then
    muda := muda || jsonb_build_object('apelido', left(trim(regexp_replace(p_apelido, '\s+', ' ', 'g')), 40));
  end if;
  if p_foto is not null then
    if p_foto <> '' and (p_foto !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$' or length(p_foto) > 80000) then
      return jsonb_build_object('erro', 'Foto inválida ou grande demais.');
    end if;
    muda := muda || jsonb_build_object('fotoPerfil', p_foto);
  end if;
  update public.prospectadores set data = coalesce(data, '{}'::jsonb) || muda where id = pid;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.campo_perfil_salvar(text, text, text) from public;
grant execute on function public.campo_perfil_salvar(text, text, text) to anon, authenticated;

select 'ok' as perfil_app;
