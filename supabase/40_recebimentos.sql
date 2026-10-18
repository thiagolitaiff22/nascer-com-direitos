-- Recebimentos do parceiro/prospectador: o aplicativo passa a mostrar (1) em cada mãe se já foi confirmada e se o benefício foi liberado,
-- e (2) só o que JÁ FOI PAGO (data, mãe, momento, valor). Nunca mostra regra de remuneração nem valores a pagar. Pode rodar de novo.

-- 1) campo_painel: acrescenta confirmada (contrato fechado) e liberada (benefício concedido) em cada mãe
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

-- 2) campo_recebimentos: pagamentos já feitos para a pessoa dona do acesso (gravados pelo BI em clientes.data.rede)
create or replace function public.campo_recebimentos(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  with eu as (select a.prosp_id as id from public.campo_acessos a where a.token = p_token and a.ativo and length(p_token) >= 20),
  linhas as (
    select c.data ->> 'nome' as nome, m.key as marco, pa.key as papel, pa.value as p
    from public.clientes c, jsonb_each(coalesce(c.data -> 'rede', '{}'::jsonb)) m, jsonb_each(m.value) pa
    where jsonb_typeof(pa.value) = 'object' and coalesce(pa.value ->> 'pagoEm', '') <> ''
  )
  select jsonb_build_object('pagamentos', coalesce((
    select jsonb_agg(jsonb_build_object('mae', l.nome, 'marco', l.marco, 'papel', l.papel, 'valor', (l.p ->> 'valor')::numeric,
             'pagoEm', l.p ->> 'pagoEm', 'forma', l.p ->> 'forma') order by l.p ->> 'pagoEm' desc, l.nome)
    from linhas l join eu on l.p ->> 'pessoaId' = eu.id), '[]'::jsonb))
  from eu
$$;
revoke all on function public.campo_recebimentos(text) from public;
grant execute on function public.campo_recebimentos(text) to anon, authenticated;

select 'ok' as recebimentos;
