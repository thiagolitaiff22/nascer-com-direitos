-- Lembrete avulso (enviado pelo site, espaçado).
alter table public.avisos_log drop constraint if exists avisos_log_etapa_check;
alter table public.avisos_log add constraint avisos_log_etapa_check check (etapa in ('h3', 'h1', 'avulso', 'designacao', 'd10', 'h10', 'h5', 'teste'));
select pg_get_constraintdef(oid) from pg_constraint where conname = 'avisos_log_etapa_check';
