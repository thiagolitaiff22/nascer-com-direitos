-- Prazo (15 minutos, definido pelo BI em contatoPrazoEm) para o closer: cliente "Em contato" que não muda de situação volta ao Novo lead (fila),
-- e o closer recebe uma penalidade de 50% registrada na própria cliente (campo "penalidades"). Roda a cada minuto. Pode rodar de novo.
create extension if not exists pg_cron with schema pg_catalog;

create or replace function public.contato_expirar() returns integer language plpgsql security definer set search_path = public as $$
declare n integer; agora text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
begin
  update public.clientes c set data = (c.data - 'contatoPrazoEm') || jsonb_build_object(
      'leadStatus', 'novo', 'tentativas', 0, 'leadMudouEm', agora, 'atualizadoEm', agora,
      'penalidades', coalesce(c.data -> 'penalidades', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
        'tipo', 'contato_expirado', 'percentual', 50, 'closer', coalesce(c.data ->> 'contatoCloser', ''),
        'email', coalesce(c.data ->> 'contatoCloserEmail', ''), 'em', agora)))
  where c.data ->> 'leadStatus' = 'contato' and coalesce(c.data ->> 'contatoPrazoEm', '') <> ''
    and (c.data ->> 'contatoPrazoEm')::timestamptz < now() and coalesce(c.data ->> 'contratoEm', '') = '';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.contato_expirar() from public, anon, authenticated;

select cron.schedule('contato-expirar', '* * * * *', 'select public.contato_expirar()');
select jobname, schedule, active from cron.job where jobname = 'contato-expirar';
