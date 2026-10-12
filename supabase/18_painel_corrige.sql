-- Painel do aplicativo do prospectador (versão final da função campo_painel).
-- Ele vê só até "Ganhou": não recebe pagamento (pago aparece como ganhou) e não recebe as clientes que estão
-- aguardando sentença (audiência já passou e ainda sem sentença, "aguardando" ou conclusos).
-- Só dados de andamento (sem CPF, RG, endereço, número do processo nem valores). Pode rodar de novo.
--
-- Campos de cada cliente (ESPECIFICACAO.md §7):
--   id, nome, contato, cadastro, tipoSegurada, crianca, criancaNasc,
--   requerido (tem DER ou protocolo do INSS), inssStatus, protocolado (tem processo),
--   audData, audHora, online, resultado (só sentença), comparecimento, origem, faltaDocs, temPasta

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
        'temPasta', coalesce(c.data ->> 'pastaId', '') <> ''
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

select 'ok' as painel_app;
