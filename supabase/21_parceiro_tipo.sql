-- O app mostra no topo "Parceira" ou, quando o parceiro é uma clínica, o nome da clínica.
-- campo_quem passa a devolver também o tipo ('pessoa' ou 'clinica') e o nome da clínica.
create or replace function public.campo_quem(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'prospId', a.prosp_id,
    'nome', coalesce(p.data ->> 'nome', ''),
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
select 'ok' as parceiro_tipo;
