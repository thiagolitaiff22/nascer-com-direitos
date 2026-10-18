-- Parceiro sem ganhos: o prospectador (ou a equipe) pode marcar que o parceiro NÃO terá ganhos. Nesse caso o aplicativo dele
-- não mostra "Meus ganhos". Também deixa o aplicativo saber se o prospectador atua como parceiro (tambemParceiro). Pode rodar de novo.

-- 1) campo_quem: acrescenta temGanho e tambemParceiro
create or replace function public.campo_quem(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'prospId', a.prosp_id,
    'nome', coalesce(p.data ->> 'nome', ''),
    'perfil', coalesce(p.data ->> 'perfil', 'parceiro'),
    'tambemParceiro', coalesce(p.data ->> 'tambemParceiro', '') = 'true',
    'temGanho', coalesce(p.data ->> 'semGanho', '') <> 'true',
    'tipo', coalesce(p.data ->> 'tipo', 'pessoa'),
    'clinica', coalesce(p.data ->> 'clinica', ''),
    'regiaoId', coalesce(p.data ->> 'regiaoId', ''),
    'envioUrl', (select envio_url from public.campo_config where id = 1),
    'cadastros', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nome', c.data ->> 'nome', 'em', c.data ->> 'criadoEm',
        'etapa', case when coalesce(trim(c.data ->> 'processo'), '') <> '' then
                        case when coalesce(c.data ->> 'audData', '') = '' then 'justica' else 'audiencia' end
                      when coalesce(trim(c.data ->> 'der'), '') <> '' or coalesce(trim(c.data ->> 'protocoloInss'), '') <> '' then 'inss'
                      else 'sem_requerimento' end)
        order by c.data ->> 'criadoEm' desc)
      from (select * from public.clientes c2 where c2.data ->> 'responsavelId' = a.prosp_id and c2.data ->> 'origem' = 'campo'
            order by c2.data ->> 'criadoEm' desc limit 60) c), '[]'::jsonb)
  )
  from public.campo_acessos a left join public.prospectadores p on p.id = a.prosp_id
  where a.token = p_token and a.ativo and length(p_token) >= 20
$$;
revoke all on function public.campo_quem(text) from public;
grant execute on function public.campo_quem(text) to anon, authenticated;

-- 2) prosp_criar_parceiro: novo parâmetro p_ganho (padrão: terá ganhos). A versão antiga (8 parâmetros) é substituída por esta.
drop function if exists public.prosp_criar_parceiro(text, text, text, text, text, text, text, text);
create or replace function public.prosp_criar_parceiro(
  p_token text, p_nome text, p_tipo text, p_clinica text, p_cidade text, p_telefone text, p_usuario text, p_senha text, p_ganho boolean default true)
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
    'telefone', trim(coalesce(p_telefone, '')), 'ativo', true, 'semGanho', not coalesce(p_ganho, true),
    'criadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'atualizadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'criadoPor', 'prospectador:' || me));
  insert into public.campo_logins (usuario, prosp_id, senha_hash, senha_ver, trocar_senha, atualizado_por)
  values (u, novo, extensions.crypt(p_senha, extensions.gen_salt('bf')), p_senha, true, 'prospectador:' || me);
  return jsonb_build_object('ok', true, 'id', novo, 'usuario', u);
end $$;
revoke all on function public.prosp_criar_parceiro(text, text, text, text, text, text, text, text, boolean) from public;
grant execute on function public.prosp_criar_parceiro(text, text, text, text, text, text, text, text, boolean) to anon, authenticated;

select 'ok' as parceiro_sem_ganho;
