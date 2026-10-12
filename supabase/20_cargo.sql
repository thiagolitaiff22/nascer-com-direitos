-- Cargo do funcionário (closer, operacional, admin). A permissão continua em "funcao" (admin ou assistente).
alter table public.equipe add column if not exists cargo text;
alter table public.equipe drop constraint if exists equipe_cargo_check;
alter table public.equipe add constraint equipe_cargo_check check (cargo is null or cargo in ('closer', 'operacional', 'admin'));
select 'ok' as cargo;
