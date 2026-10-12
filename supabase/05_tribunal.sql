-- Consulta diária ao tribunal (DataJud / CNJ). O tribunal é configurável (config "regua", campo tribunalAlias: trf1, tjam...).
alter table public.segredos drop constraint if exists segredos_nome_check;
alter table public.segredos add constraint segredos_nome_check check (nome in ('liderhub', 'regua_token', 'regua_anon', 'datajud'));

-- o resumo do tribunal é atualizado pela consulta; não precisa entrar no histórico de alterações
create or replace function public.registrar_historico()
returns trigger language plpgsql security definer set search_path = public as $$
declare quem text := coalesce(lower(auth.jwt() ->> 'email'), 'sistema'); dif jsonb := '{}'::jsonb; k text;
begin
  if tg_op = 'INSERT' then
    insert into public.clientes_historico (cliente_id, acao, por, mudancas) values (new.id, 'criado', quem, jsonb_build_object('nome', new.data -> 'nome'));
    return new;
  elsif tg_op = 'DELETE' then
    insert into public.clientes_historico (cliente_id, acao, por, mudancas) values (old.id, 'excluido', quem, jsonb_build_object('nome', old.data -> 'nome'));
    return old;
  end if;
  for k in select key from jsonb_each(coalesce(new.data, '{}'::jsonb)) union select key from jsonb_each(coalesce(old.data, '{}'::jsonb)) loop
    if k not in ('atualizadoEm', 'reguaUltimo', 'tribunal') and (old.data -> k) is distinct from (new.data -> k) then
      dif := dif || jsonb_build_object(k, jsonb_build_array(old.data -> k, new.data -> k));
    end if;
  end loop;
  if dif <> '{}'::jsonb then
    insert into public.clientes_historico (cliente_id, acao, por, mudancas) values (new.id, 'alterado', quem, dif);
  end if;
  return new;
end $$;

-- O agendamento diário (7h de Manaus, segunda a sábado) fica no 06_agendador.sql.

select 'ok' as tribunal;
