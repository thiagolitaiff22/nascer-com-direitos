-- Cadência da régua: 3 dias antes (h3) e véspera (h1), todos os dias da semana.
-- O horário do agendador (8h às 18h de Manaus, todos os dias) já está no 06_agendador.sql. Pode rodar de novo.
alter table public.avisos_log drop constraint if exists avisos_log_etapa_check;
alter table public.avisos_log add constraint avisos_log_etapa_check check (etapa in ('h3', 'h1', 'designacao', 'd10', 'h10', 'h5', 'teste'));
select 'ok' as cadencia;
