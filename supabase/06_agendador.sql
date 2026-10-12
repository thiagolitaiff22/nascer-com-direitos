-- Agendadores (pg_cron) que chamam a função lembrete-whatsapp:
--   regua-avisos      a cada 10 minutos, todos os dias, das 8h às 17h50 de Manaus (12h–21h50 UTC)
--   tribunal-datajud  todo dia às 7h de Manaus (11h UTC), de segunda a sábado
-- Eles chamam a função só com a chave interna (x-regua-token); a própria função confere.
-- Requer "Verify JWT with legacy secret" DESLIGADO na função lembrete-whatsapp (Edge Functions › Settings).
--
-- ANTES DE RODAR: troque SEU-PROJETO abaixo pelo "Project ref" do projeto novo
-- (Project Settings › General; é o começo da Project URL: https://<ref>.supabase.co).
-- Enquanto estiver SEU-PROJETO, este arquivo não agenda nada (só avisa). Pode rodar de novo.

do $$
declare
  v_url text := 'https://SEU-PROJETO.supabase.co/functions/v1/lembrete-whatsapp';
begin
  if v_url like '%SEU-PROJETO%' then
    raise notice 'Agendadores NÃO criados: troque SEU-PROJETO no 06_agendador.sql pelo ref do projeto e rode de novo.';
    return;
  end if;
  perform cron.unschedule(jobid) from cron.job where jobname in ('regua-avisos', 'tribunal-datajud');
  perform cron.schedule('regua-avisos', '*/10 12-21 * * *', format($job$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-regua-token', (select valor from public.segredos where nome = 'regua_token')),
      body := '{"acao":"regua"}'::jsonb,
      timeout_milliseconds := 120000
    );
  $job$, v_url));
  perform cron.schedule('tribunal-datajud', '0 11 * * 1-6', format($job$
    select net.http_post(
      url := %L,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-regua-token', (select valor from public.segredos where nome = 'regua_token')),
      body := '{"acao":"tribunal-cron"}'::jsonb,
      timeout_milliseconds := 120000
    );
  $job$, v_url));
end $$;

select jobname, schedule, active from cron.job where jobname in ('regua-avisos', 'tribunal-datajud') order by 1;
