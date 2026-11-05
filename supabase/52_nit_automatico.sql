-- 52 · Fluxo novo: o NIT entra sozinho, sem IA
-- O script do Google Drive (google/nit.gs, função lerNitAutomatico) roda a cada 10 minutos e olha só as pastas das mães
-- do fluxo novo que ainda estão sem NIT válido. Quando chega arquivo novo na pasta (CNIS, CTPS, cartão cidadão),
-- o próprio Google Drive lê o texto do arquivo (de graça) e manda os números candidatos; o banco confere o dígito
-- verificador e grava o primeiro que valer. Com o NIT, a mãe urbana sai do Pós-venda e vai para a GPS.
-- Pode rodar de novo.

-- NIT / PIS / PASEP / NIS: 11 dígitos, dígito verificador com pesos 3 2 9 8 7 6 5 4 3 2 (o mesmo cálculo do BI)
create or replace function public.nit_valido(p text)
returns boolean language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p, ''), '\D', '', 'g'); w int[] := array[3, 2, 9, 8, 7, 6, 5, 4, 3, 2]; s int := 0; dv int;
begin
  if length(d) <> 11 or d ~ '^(\d)\1+$' then return false; end if;
  for i in 1..10 loop s := s + substr(d, i, 1)::int * w[i]; end loop;
  dv := 11 - (s % 11); if dv >= 10 then dv := 0; end if;
  return dv = substr(d, 11, 1)::int;
end $$;

-- pastas que o script precisa olhar: fluxo novo, ainda antes do INSS, não é pescadora/agricultora/indígena (essas não pagam GPS) e sem NIT válido
create or replace function public.campo_pastas_sem_nit(p_segredo text)
returns setof text language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.segredos s where s.nome = 'campo_script' and s.valor = p_segredo and length(p_segredo) >= 32) then
    raise exception 'Script não autorizado.';
  end if;
  return query
    select c.data ->> 'pastaId' from public.clientes c
    where c.data ->> 'fluxo' = 'novo'
      and coalesce(c.data ->> 'pastaId', '') <> ''
      and coalesce(c.data ->> 'tipoSegurada', '') <> 'especial'
      and not public.nit_valido(c.data ->> 'nit')
      and coalesce(c.data ->> 'arquivado', 'false') <> 'true'
      and coalesce(trim(c.data ->> 'der'), '') = ''
      and coalesce(trim(c.data ->> 'protocoloInss'), '') = ''
      and coalesce(trim(c.data ->> 'processo'), '') = ''
    order by c.data ->> 'contratoEm' desc nulls last;
end $$;
revoke all on function public.campo_pastas_sem_nit(text) from public;
grant execute on function public.campo_pastas_sem_nit(text) to anon, authenticated;

-- grava o primeiro candidato com dígito verificador certo (nunca o CPF da mãe e nunca por cima de um NIT válido)
create or replace function public.campo_gravar_nit(p_segredo text, p_pasta text, p_candidatos text[], p_arquivo text default '')
returns text language plpgsql security definer set search_path = public as $$
declare cid text; atual jsonb; cpf text; v text; d text; agora text := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
begin
  if not exists (select 1 from public.segredos s where s.nome = 'campo_script' and s.valor = p_segredo and length(p_segredo) >= 32) then
    raise exception 'Script não autorizado.';
  end if;
  select id, data into cid, atual from public.clientes where data ->> 'pastaId' = p_pasta and data ->> 'fluxo' = 'novo' limit 1;
  if cid is null or public.nit_valido(atual ->> 'nit') then return null; end if;
  cpf := regexp_replace(coalesce(atual ->> 'cpf', ''), '\D', '', 'g');
  foreach v in array coalesce(p_candidatos, '{}'::text[]) loop
    d := regexp_replace(coalesce(v, ''), '\D', '', 'g');
    if public.nit_valido(d) and d <> cpf then
      d := substr(d, 1, 3) || '.' || substr(d, 4, 5) || '.' || substr(d, 9, 2) || '-' || substr(d, 11, 1);
      update public.clientes set data = data || jsonb_build_object('nit', d, 'nitLidoEm', agora, 'nitArquivo', left(coalesce(p_arquivo, ''), 200), 'atualizadoEm', agora)
      where id = cid;
      return d;
    end if;
  end loop;
  return null;
end $$;
revoke all on function public.campo_gravar_nit(text, text, text[], text) from public;
grant execute on function public.campo_gravar_nit(text, text, text[], text) to anon, authenticated;

select 'ok' as nit_automatico;
