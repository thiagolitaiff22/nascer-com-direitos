-- Cadastro rápido pelo aplicativo (26/11/2026). Pedido: "um cadastro rápido... o cadastro do nome e número dessa mãe para que o Closer faça o fechamento".
-- O parceiro (ou o prospectador, ou o gestor) manda só o nome e o WhatsApp. A mãe entra no BI na tela Cadastro rápido (cadastroRapido = true,
-- origem 'rapido', sem contrato); o closer liga, completa CPF, parto e atividade e fecha o contrato. Com o contrato fechado ela vai para o Pós-venda.
-- O aplicativo só mostra a opção "Cadastro rápido" depois que este arquivo rodar (ele confere sozinho). Pode rodar de novo.

-- 1) campo_cadastro_rapido: grava a mãe só com nome e WhatsApp
create or replace function public.campo_cadastro_rapido(p_token text, p_envio text, p_nome text, p_contato text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pid text; cid text; nm text; d text; fone text; agora text; gem text; gnome text; ja text;
begin
  select prosp_id into pid from public.campo_acessos where token = p_token and ativo and length(coalesce(p_token, '')) >= 20;
  if pid is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  if pid like 'gestor:%' then   -- gestor cadastrando pelo aplicativo
    gem := substr(pid, 8);
    select q.nome into gnome from public.equipe q where lower(q.email) = gem and coalesce(q.ativo, true) limit 1;
    if gnome is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  end if;
  nm := regexp_replace(trim(coalesce(p_nome, '')), '\s+', ' ', 'g');
  if length(nm) < 3 then return jsonb_build_object('erro', 'Informe o nome da mãe.'); end if;
  d := regexp_replace(coalesce(p_contato, ''), '\D', '', 'g');
  if length(d) not in (10, 11) then return jsonb_build_object('erro', 'Informe o WhatsApp com DDD.'); end if;
  if coalesce(p_envio, '') !~ '^[A-Za-z0-9_-]{8,64}$' then return jsonb_build_object('erro', 'Envio inválido.'); end if;
  fone := '(' || left(d, 2) || ') ' || case when length(d) = 11 then substr(d, 3, 5) || '-' || substr(d, 8) else substr(d, 3, 4) || '-' || substr(d, 7) end;
  cid := 'rapido-' || p_envio;
  -- o mesmo WhatsApp já está esperando o closer (cadastro repetido): devolve o que já existe, sem criar outro
  select c.id into ja from public.clientes c
   where coalesce(c.data ->> 'cadastroRapido', '') = 'true' and coalesce(trim(c.data ->> 'contratoEm'), '') = ''
     and coalesce(c.data ->> 'leadStatus', '') <> 'desqualificado' and coalesce(c.data ->> 'arquivado', '') <> 'true'
     and regexp_replace(coalesce(c.data ->> 'contato', ''), '\D', '', 'g') = d and c.id <> cid
   limit 1;
  if ja is not null then return jsonb_build_object('ok', true, 'id', ja, 'repetido', true); end if;
  agora := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  insert into public.clientes (id, data) values (cid, jsonb_strip_nulls(jsonb_build_object(
    'nome', left(nm, 200), 'contato', fone, 'cadastroRapido', true, 'fatoGerador', 'gestante',
    'responsavelId', pid, 'origem', 'rapido',   -- 'rapido' e não 'campo': a Ana não manda as boas-vindas antes do closer ligar
    'criadoPorEmail', gem, 'criadoPorNome', gnome,   -- só no cadastro do gestor (nos outros fica nulo e some)
    'criadoEm', agora, 'atualizadoEm', agora)))
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true, 'id', cid);
end $$;
revoke all on function public.campo_cadastro_rapido(text, text, text, text) from public;
grant execute on function public.campo_cadastro_rapido(text, text, text, text) to anon, authenticated;

-- 2) campo_painel (o do 40): passa a dizer ao parceiro quando o closer não fechou o contrato
create or replace function public.campo_painel(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'atualizado', now(),
    'clientes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'nome', c.data ->> 'nome',
        'contato', c.data ->> 'contato',
        'cadastro', coalesce(nullif(c.data ->> 'dataCadastro', ''), left(c.data ->> 'criadoEm', 10)),
        'tipoSegurada', c.data ->> 'tipoSegurada',
        'crianca', c.data ->> 'crianca',
        'criancaNasc', c.data ->> 'criancaNasc',
        'requerido', coalesce(trim(c.data ->> 'der'), '') <> '' or coalesce(trim(c.data ->> 'protocoloInss'), '') <> '',
        'inssStatus', c.data ->> 'inssStatus',
        'protocolado', coalesce(trim(c.data ->> 'processo'), '') <> '',
        'audData', c.data ->> 'audData',
        'audHora', c.data ->> 'audHora',
        'online', coalesce(c.data ->> 'online', '') = 'true',
        -- resultado só quando já há sentença (o "aguardando" não vai)
        'resultado', case when c.data ->> 'resultado' in ('procedente', 'parcial', 'acordo', 'improcedente', 'extinto', 'ausente') then c.data ->> 'resultado' end,
        'comparecimento', c.data ->> 'comparecimento',
        'origem', c.data ->> 'origem',
        'faltaDocs', c.data -> 'faltaDocs',
        'temPasta', coalesce(c.data ->> 'pastaId', '') <> '',
        'confirmada', coalesce(trim(c.data ->> 'contratoEm'), '') <> '',
        -- cadastro rápido que o closer não fechou (62)
        'desqualificada', coalesce(c.data ->> 'leadStatus', '') = 'desqualificado',
        'liberada', (c.data ->> 'inssStatus' = 'concedido' or c.data ->> 'resultado' in ('procedente', 'parcial', 'acordo'))
      ) order by c.data ->> 'nome')
      from public.clientes c
      where c.data ->> 'responsavelId' = a.prosp_id
        -- fora: aguardando sentença (audiência passou sem sentença, "aguardando" ou conclusos para decisão)
        and not (
          coalesce(c.data ->> 'resultado', '') not in ('procedente', 'parcial', 'acordo', 'improcedente', 'extinto', 'ausente')
          and coalesce(c.data ->> 'comparecimento', '') <> 'faltou'
          and (
            coalesce(c.data ->> 'resultado', '') = 'aguardando'
            or coalesce(c.data ->> 'concluso', '') = 'true'
            or (coalesce(c.data ->> 'audData', '') ~ '^\d{4}-\d{2}-\d{2}' and left(c.data ->> 'audData', 10)::date < (now() at time zone 'America/Manaus')::date)
            -- (coalesce: sem audiência ou sem "concluso" o teste dava NULL e escondia a cliente nova)
          )
        )), '[]'::jsonb)
  )
  from public.campo_acessos a
  where a.token = p_token and a.ativo and length(p_token) >= 20
$$;
revoke all on function public.campo_painel(text) from public;
grant execute on function public.campo_painel(text) to anon, authenticated;

-- conferência: as duas devem dar true
select exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'campo_cadastro_rapido') as rapido_ok,
       position('desqualificada' in pg_get_functiondef('public.campo_painel(text)'::regprocedure)) > 0 as painel_ok;
