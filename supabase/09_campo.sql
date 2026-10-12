-- Cadastro pelo celular do prospectador (página campo.html).
-- O prospectador não tem login: entra por um link individual (campo.html#t=CÓDIGO) que o administrador gera.
-- Quem grava no banco é o script do Google (Drive + leitura dos documentos), usando o código do link.
-- Pode rodar de novo sem perder dados.

create table if not exists public.campo_acessos (
  token      text primary key,
  prosp_id   text not null,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now(),
  criado_por text
);
alter table public.campo_acessos enable row level security;
revoke all on public.campo_acessos from anon, authenticated;
grant all on public.campo_acessos to service_role;

-- endereço do script do Google que recebe as fotos (gravado pelo administrador)
create table if not exists public.campo_config (
  id         int primary key default 1 check (id = 1),
  envio_url  text
);
alter table public.campo_config enable row level security;
revoke all on public.campo_config from anon, authenticated;
insert into public.campo_config (id) values (1) on conflict do nothing;

-- administrador: gera (ou devolve) o link de um prospectador
create or replace function public.campo_link(p_prosp text, p_novo boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare t text;
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  if p_novo then update public.campo_acessos set ativo = false where prosp_id = p_prosp; end if;
  select token into t from public.campo_acessos where prosp_id = p_prosp and ativo order by criado_em desc limit 1;
  if t is null then
    t := replace(replace(encode(extensions.gen_random_bytes(18), 'base64'), '+', '-'), '/', '_');
    insert into public.campo_acessos (token, prosp_id, criado_por) values (t, p_prosp, lower(auth.jwt() ->> 'email'));
  end if;
  return t;
end $$;
revoke all on function public.campo_link(text, boolean) from public, anon;
grant execute on function public.campo_link(text, boolean) to authenticated;

-- administrador: grava o endereço do script do Google
create or replace function public.campo_salvar_url(p_url text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.minha_funcao() is distinct from 'admin' then raise exception 'Só administradores.'; end if;
  update public.campo_config set envio_url = nullif(trim(p_url), '') where id = 1;
end $$;
revoke all on function public.campo_salvar_url(text) from public, anon;
grant execute on function public.campo_salvar_url(text) to authenticated;

create or replace function public.campo_url_status()
returns text language sql stable security definer set search_path = public as $$
  select envio_url from public.campo_config where id = 1 and public.minha_funcao() = 'admin'
$$;
revoke all on function public.campo_url_status() from public, anon;
grant execute on function public.campo_url_status() to authenticated;

-- celular / script: quem é o dono do link, para onde enviar e os cadastros dele
-- etapa: sem_requerimento (sem DER/protocolo do INSS e sem processo) · inss (requerida no INSS, sem processo)
--        justica (tem processo, sem audiência) · audiencia (audiência marcada)
create or replace function public.campo_quem(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'prospId', a.prosp_id,
    'nome', coalesce(p.data ->> 'nome', ''),
    'envioUrl', (select envio_url from public.campo_config where id = 1),
    'cadastros', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nome', c.data ->> 'nome', 'em', c.data ->> 'criadoEm',
        'etapa', case when coalesce(trim(c.data ->> 'processo'), '') <> '' then
                        case when coalesce(c.data ->> 'audData', '') = '' then 'justica' else 'audiencia' end
                      when coalesce(trim(c.data ->> 'der'), '') <> '' or coalesce(trim(c.data ->> 'protocoloInss'), '') <> '' then 'inss'
                      else 'sem_requerimento' end)
        order by c.data ->> 'criadoEm' desc)
      from (select * from public.clientes c2 where c2.data ->> 'responsavelId' = a.prosp_id and c2.data ->> 'origem' = 'campo'
            order by c2.data ->> 'criadoEm' desc limit 60) c), '[]'::jsonb)
  )
  from public.campo_acessos a left join public.prospectadores p on p.id = a.prosp_id
  where a.token = p_token and a.ativo and length(p_token) >= 20
$$;
revoke all on function public.campo_quem(text) from public;
grant execute on function public.campo_quem(text) to anon, authenticated;

-- script do Google: cria a cliente (uma vez por envio) já ligada ao prospectador do link.
-- A função campo_cadastrar fica num lugar só, na versão completa: 19_foto_cliente.sql
-- (dados da mãe, tipo de segurada, criança, fato gerador, documentos que faltaram e foto).

select 'ok' as campo;

-- script do Google: das pastas que ele informa, em que etapa está a cliente de cada uma
-- (só as que já saíram de "pendente"): 'arquivado' · 'justica' (tem processo) · 'inss' (tem DER ou protocolo do INSS)
drop function if exists public.campo_pastas_protocoladas(text[]);  -- substituída por campo_pastas_etapas
create or replace function public.campo_pastas_etapas(p_ids text[])
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(x.pasta, x.etapa), '{}'::jsonb)
  from (
    select distinct on (c.data ->> 'pastaId') c.data ->> 'pastaId' as pasta,
      case when coalesce(c.data ->> 'arquivado', 'false') = 'true' then 'arquivado'
           when coalesce(trim(c.data ->> 'processo'), '') <> '' then 'justica'
           else 'inss' end as etapa
    from public.clientes c
    where c.data ->> 'pastaId' = any(p_ids[1:500])
      and (coalesce(c.data ->> 'arquivado', 'false') = 'true'
           or coalesce(trim(c.data ->> 'processo'), '') <> ''
           or coalesce(trim(c.data ->> 'der'), '') <> ''
           or coalesce(trim(c.data ->> 'protocoloInss'), '') <> '')
    order by c.data ->> 'pastaId', c.atualizado_em desc
  ) x
$$;
revoke all on function public.campo_pastas_etapas(text[]) from public;
grant execute on function public.campo_pastas_etapas(text[]) to anon, authenticated;

select 'ok' as campo_pastas;
