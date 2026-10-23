-- O prospectador passa a ver o nome e a etapa das mães que os parceiros dele indicam (antes só via os números). Pode rodar de novo.
create or replace function public.prosp_painel(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me text := public.prosp_dono(p_token); r jsonb;
begin
  if me is null then return null; end if;
  select jsonb_build_object(
    'atualizado', now(),
    'parceiros', coalesce(jsonb_agg(x order by (x ->> 'contratos')::int desc, x ->> 'nome'), '[]'::jsonb)
  ) into r
  from (
    select jsonb_build_object(
      'id', p.id,
      'nome', coalesce(p.data ->> 'nome', ''),
      'tipo', coalesce(p.data ->> 'tipo', 'pessoa'),
      'clinica', coalesce(p.data ->> 'clinica', ''),
      'cidade', coalesce(p.data ->> 'regiao', ''),
      'telefone', coalesce(p.data ->> 'telefone', ''),
      'usuario', (select l.usuario from public.campo_logins l where l.prosp_id = p.id),
      'ativo', coalesce((select l.ativo from public.campo_logins l where l.prosp_id = p.id), false),
      'criadoEm', coalesce(p.data ->> 'criadoEm', ''),
      'ganho', coalesce(p.data ->> 'semGanho', '') <> 'true',
      'comConf', coalesce(nullif(p.data ->> 'comConf', '')::numeric, 0),
      'comLib', coalesce(nullif(p.data ->> 'comLib', '')::numeric, 0),
      'indicacoes', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id),
      'contratos', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id and coalesce(c.data ->> 'contratoEm', '') <> ''),
      'guiasPagas', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id and c.data ->> 'guiaStatus' = 'paga'),
      'concedidos', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id
                      and (c.data ->> 'inssStatus' = 'concedido' or c.data ->> 'resultado' in ('procedente', 'parcial', 'acordo'))),
      'pagos', (select count(*) from public.clientes c where c.data ->> 'responsavelId' = p.id and c.data ->> 'pagamento' = 'pago'),
      -- as mães indicadas por este parceiro (só o nome e em que etapa estão), para o prospectador acompanhar
      'maes', coalesce((select jsonb_agg(jsonb_build_object(
          'id', m.id, 'nome', m.data ->> 'nome',
          'cadastro', coalesce(nullif(m.data ->> 'dataCadastro', ''), left(m.data ->> 'criadoEm', 10)),
          'confirmada', coalesce(trim(m.data ->> 'contratoEm'), '') <> '',
          'liberada', (m.data ->> 'inssStatus' = 'concedido' or m.data ->> 'resultado' in ('procedente', 'parcial', 'acordo')),
          'desqualificada', m.data ->> 'leadStatus' = 'desqualificado',
          'faltaDocs', m.data -> 'faltaDocs') order by m.data ->> 'criadoEm' desc)
        from (select * from public.clientes c2 where c2.data ->> 'responsavelId' = p.id order by c2.data ->> 'criadoEm' desc limit 200) m), '[]'::jsonb)
    ) as x
    from public.prospectadores p
    where p.data ->> 'prospectadorId' = me
  ) t;
  return r;
end $$;
revoke all on function public.prosp_painel(text) from public;
grant execute on function public.prosp_painel(text) to anon, authenticated;

select 'ok' as prospectador_ve_maes;
