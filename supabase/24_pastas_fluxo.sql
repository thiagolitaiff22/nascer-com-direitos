-- Pastas do Drive no fluxo: DOCUMENTOS PENDENTES › DOCUMENTOS OK › PROTOCOLADOS.
-- O script do Google pergunta aqui em que pasta deve estar a cliente de cada pasta e move a pasta. Pode rodar de novo.
--   protocolado = arquivada, com processo, ou com requerimento no INSS (DER/protocolo)
--   ok          = documentação completa (conferida no sistema ou enviada completa pelo aplicativo)
--   pendente    = o resto

create or replace function public.etapa_da_cliente(d jsonb)
returns text language sql immutable as $$
  select case
    when coalesce(d ->> 'arquivado', 'false') = 'true' then 'protocolado'
    when coalesce(trim(d ->> 'processo'), '') <> '' then 'protocolado'
    when coalesce(trim(d ->> 'der'), '') <> '' or coalesce(trim(d ->> 'protocoloInss'), '') <> '' then 'protocolado'
    when (d ->> 'docsCompletos' = 'true' or (d ->> 'origem' = 'campo' and jsonb_typeof(d -> 'faltaDocs') = 'array'))
         and (case when jsonb_typeof(d -> 'faltaDocs') = 'array' then jsonb_array_length(d -> 'faltaDocs') else 0 end) = 0 then 'ok'
    else 'pendente' end
$$;

create or replace function public.campo_pastas_etapas(p_ids text[])
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(x.pasta, x.etapa), '{}'::jsonb)
  from (
    select distinct on (c.data ->> 'pastaId') c.data ->> 'pastaId' as pasta, public.etapa_da_cliente(c.data) as etapa
    from public.clientes c
    where c.data ->> 'pastaId' = any(p_ids[1:1000])
    order by c.data ->> 'pastaId', c.atualizado_em desc
  ) x
$$;
revoke all on function public.campo_pastas_etapas(text[]) from public;
grant execute on function public.campo_pastas_etapas(text[]) to anon, authenticated;

create or replace function public.campo_pastas_status(p_ids text[])
returns jsonb language sql stable security definer set search_path = public as $$
  select public.campo_pastas_etapas(p_ids)
$$;
revoke all on function public.campo_pastas_status(text[]) from public;
grant execute on function public.campo_pastas_status(text[]) to anon, authenticated;

select 'ok' as pastas_fluxo;
