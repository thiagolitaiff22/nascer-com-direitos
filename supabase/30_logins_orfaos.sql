-- Logins de aplicativo cujo dono foi apagado ficam desativados, e ao excluir um parceiro o acesso dele sai junto. Pode rodar de novo.
update public.campo_logins  set ativo = false where prosp_id not in (select id from public.prospectadores);
update public.campo_acessos set ativo = false where prosp_id not in (select id from public.prospectadores);

create or replace function public.prosp_apagado()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from public.campo_acessos where prosp_id = old.id;
  delete from public.campo_logins  where prosp_id = old.id;
  return old;
end $$;
drop trigger if exists prosp_apagado on public.prospectadores;
create trigger prosp_apagado after delete on public.prospectadores for each row execute function public.prosp_apagado();

select 'ok' as logins_orfaos;
