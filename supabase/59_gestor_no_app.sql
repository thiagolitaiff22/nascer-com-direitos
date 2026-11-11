-- 59 · Gestor no aplicativo (11/11/2026)
-- O gestor (equipe do BI com função de administrador) entra no aplicativo com o mesmo CPF e a mesma senha do BI
-- e vê a rede dele no mesmo formato do prospectador:
--   prospectadores (e parceiros) da equipe dele      → gestorEmail ("Gestor responsável" no BI); sem escolha, criadoPor = 'gestor:<e-mail dele>'
--   parceiros desses prospectadores                 → prospectadorId = id do prospectador
--   mães que vieram por todos eles                  → responsavelId = um deles (e as que ele mesmo cadastrou no BI)
-- Só acrescenta duas funções: não altera nem apaga nada que já existe. Pode rodar de novo.

-- 1) acesso do gestor no aplicativo: troca a sessão do BI (logado) por um acesso do aplicativo (como o do prospectador)
create or replace function public.gestor_app_entrar()
returns jsonb language plpgsql security definer set search_path = public as $$
declare em text := lower(coalesce(auth.jwt() ->> 'email', '')); nm text; pid text; t text;
begin
  if em = '' then return jsonb_build_object('erro', 'Entre de novo.'); end if;
  select q.nome into nm from public.equipe q where lower(q.email) = em and coalesce(q.ativo, true) limit 1;
  if nm is null or coalesce(public.minha_funcao(), '') <> 'admin' then return jsonb_build_object('erro', 'Este acesso é só para gestores.'); end if;
  pid := 'gestor:' || em;
  select token into t from public.campo_acessos where prosp_id = pid and ativo order by criado_em desc limit 1;
  if t is null then
    t := replace(replace(encode(extensions.gen_random_bytes(18), 'base64'), '+', '-'), '/', '_');
    insert into public.campo_acessos (token, prosp_id, criado_por) values (t, pid, pid);
  end if;
  return jsonb_build_object('ok', true, 'token', t, 'nome', nm);
end $$;
revoke all on function public.gestor_app_entrar() from public, anon;
grant execute on function public.gestor_app_entrar() to authenticated;

-- 2) painel do gestor no aplicativo: a equipe dele (com os números de cada um) e todas as mães que vieram por ela
create or replace function public.gestor_painel(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare pid text; em text; nm text; r jsonb;
begin
  select a.prosp_id into pid from public.campo_acessos a where a.token = p_token and a.ativo and length(p_token) >= 20 and a.prosp_id like 'gestor:%';
  if pid is null then return null; end if;
  em := substr(pid, 8);
  select q.nome into nm from public.equipe q where lower(q.email) = em and coalesce(q.ativo, true) limit 1;
  if nm is null then return null; end if;   -- saiu da equipe: o acesso deixa de mostrar a rede
  with l1 as (   -- a equipe do gestor: o "Gestor responsável" escolhido no BI; sem escolha, quem o gestor cadastrou pelo painel dele
    select p.id, p.data from public.prospectadores p
    where lower(coalesce(p.data ->> 'gestorEmail', case when p.data ->> 'criadoPor' like 'gestor:%' then substr(p.data ->> 'criadoPor', 8) end, '')) = em
  ), l2 as (     -- parceiros dos prospectadores dele
    select x.id, x.data, l1.id as via from public.prospectadores x join l1 on x.data ->> 'prospectadorId' = l1.id
    where not exists (select 1 from l1 z where z.id = x.id)
  ), todos as (
    select id, id as dono from l1 union all select id, via as dono from l2
  ), cl as (     -- mães da rede (e as que o gestor mesmo cadastrou no BI)
    select c.id, c.data, t.dono from public.clientes c join todos t on t.id = c.data ->> 'responsavelId'
    union all
    select c.id, c.data, null from public.clientes c
    where lower(coalesce(c.data ->> 'criadoPorEmail', '')) = em and not exists (select 1 from todos t where t.id = c.data ->> 'responsavelId')
  )
  select jsonb_build_object(
    'atualizado', now(), 'nome', nm,
    'parceiros', coalesce((select jsonb_agg(jsonb_build_object(
        'id', l1.id, 'nome', coalesce(l1.data ->> 'nome', ''), 'perfil', coalesce(l1.data ->> 'perfil', 'parceiro'),
        'tipo', coalesce(l1.data ->> 'tipo', 'pessoa'), 'clinica', coalesce(l1.data ->> 'clinica', ''),
        'cidade', coalesce(nullif(l1.data ->> 'cidadeParc', ''), l1.data ->> 'regiao', ''), 'telefone', coalesce(l1.data ->> 'telefone', ''),
        'usuario', (select l.usuario from public.campo_logins l where l.prosp_id = l1.id limit 1),
        'ativo', coalesce((select l.ativo from public.campo_logins l where l.prosp_id = l1.id limit 1), false),
        'criadoEm', coalesce(l1.data ->> 'criadoEm', ''),
        'indicacoes', (select count(*) from cl where cl.dono = l1.id),
        'contratos', (select count(*) from cl where cl.dono = l1.id and coalesce(trim(cl.data ->> 'contratoEm'), '') <> ''),
        'concedidos', (select count(*) from cl where cl.dono = l1.id and (cl.data ->> 'inssStatus' = 'concedido' or cl.data ->> 'resultado' in ('procedente', 'parcial', 'acordo'))),
        'parceirosQtd', (select count(*) from l2 where l2.via = l1.id),
        'rede', coalesce((select jsonb_agg(jsonb_build_object(
            'id', l2.id, 'nome', coalesce(l2.data ->> 'nome', ''), 'perfil', coalesce(l2.data ->> 'perfil', 'parceiro'),
            'tipo', coalesce(l2.data ->> 'tipo', 'pessoa'), 'clinica', coalesce(l2.data ->> 'clinica', ''),
            'cidade', coalesce(nullif(l2.data ->> 'cidadeParc', ''), l2.data ->> 'regiao', ''), 'telefone', coalesce(l2.data ->> 'telefone', ''),
            'usuario', (select l.usuario from public.campo_logins l where l.prosp_id = l2.id limit 1),
            'ativo', coalesce((select l.ativo from public.campo_logins l where l.prosp_id = l2.id limit 1), false),
            'criadoEm', coalesce(l2.data ->> 'criadoEm', ''),
            'indicacoes', (select count(*) from cl where cl.data ->> 'responsavelId' = l2.id),
            'contratos', (select count(*) from cl where cl.data ->> 'responsavelId' = l2.id and coalesce(trim(cl.data ->> 'contratoEm'), '') <> ''),
            'concedidos', (select count(*) from cl where cl.data ->> 'responsavelId' = l2.id and (cl.data ->> 'inssStatus' = 'concedido' or cl.data ->> 'resultado' in ('procedente', 'parcial', 'acordo'))))
          order by l2.data ->> 'nome') from l2 where l2.via = l1.id), '[]'::jsonb))
      order by (select count(*) from cl where cl.dono = l1.id) desc, l1.data ->> 'nome') from l1), '[]'::jsonb),
    'clientes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', cl.id, 'nome', cl.data ->> 'nome', 'contato', cl.data ->> 'contato',
        'cadastro', coalesce(nullif(cl.data ->> 'dataCadastro', ''), left(cl.data ->> 'criadoEm', 10)),
        'tipoSegurada', cl.data ->> 'tipoSegurada', 'crianca', cl.data ->> 'crianca', 'criancaNasc', cl.data ->> 'criancaNasc',
        'requerido', coalesce(trim(cl.data ->> 'der'), '') <> '' or coalesce(trim(cl.data ->> 'protocoloInss'), '') <> '',
        'inssStatus', cl.data ->> 'inssStatus', 'protocolado', coalesce(trim(cl.data ->> 'processo'), '') <> '',
        'audData', cl.data ->> 'audData', 'audHora', cl.data ->> 'audHora', 'online', coalesce(cl.data ->> 'online', '') = 'true',
        'resultado', case when cl.data ->> 'resultado' in ('procedente', 'parcial', 'acordo', 'improcedente', 'extinto', 'ausente') then cl.data ->> 'resultado' end,
        'comparecimento', cl.data ->> 'comparecimento', 'origem', cl.data ->> 'origem',
        'faltaDocs', cl.data -> 'faltaDocs', 'temPasta', coalesce(cl.data ->> 'pastaId', '') <> '',
        'confirmada', coalesce(trim(cl.data ->> 'contratoEm'), '') <> '',
        'liberada', (cl.data ->> 'inssStatus' = 'concedido' or cl.data ->> 'resultado' in ('procedente', 'parcial', 'acordo')),
        'desqualificada', cl.data ->> 'leadStatus' = 'desqualificado', 'arquivada', coalesce(cl.data ->> 'arquivado', '') = 'true',
        'resp', cl.data ->> 'responsavelId', 'dono', cl.dono,
        'parceiro', (select coalesce(nullif(p.data ->> 'clinica', ''), p.data ->> 'nome') from public.prospectadores p where p.id = cl.data ->> 'responsavelId'),
        'prospectador', (select p.data ->> 'nome' from public.prospectadores p where p.id = cl.dono))
      order by cl.data ->> 'criadoEm' desc) from cl), '[]'::jsonb)
  ) into r;
  return r;
end $$;
revoke all on function public.gestor_painel(text) from public;
grant execute on function public.gestor_painel(text) to anon, authenticated;

-- conferência: as duas funções existem
select to_regprocedure('public.gestor_app_entrar()') is not null as entrar, to_regprocedure('public.gestor_painel(text)') is not null as painel;
