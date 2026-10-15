-- Gestor regional: cada pessoa da equipe pode ter os estados que gere. Sem estados = vê todos. Pode rodar de novo.
alter table public.equipe add column if not exists estados text[];

select nome, estados from public.equipe order by nome;
