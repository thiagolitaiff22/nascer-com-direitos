-- 55 · Qualificação da mãe no aplicativo (3 perguntas de toque: trabalho, quando saiu do emprego, benefício)
-- Amplia a função do SQL 54: além do endereço e da senha gov.br, grava a qualificação e o caminho
-- (guia de facultativa 1473, guia de contribuinte individual 1163, MEI, pedido direto ao INSS, rural ou "escritório analisa").
-- Rural (pescadora, agricultora, indígena) já entra como segurada especial com a atividade; as outras como urbana.
-- Só preenche o tipo de segurada se ainda estiver vazio (não passa por cima do que o escritório decidiu). Pode rodar de novo.

drop function if exists public.campo_completar_dados(text, text, jsonb, text);
create or replace function public.campo_completar_dados(p_token text, p_cliente text, p_endereco jsonb default null, p_senha_gov text default null, p_qualif jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare pid text; quem text; atual jsonb; e jsonb := coalesce(p_endereco, '{}'::jsonb); q jsonb := coalesce(p_qualif, '{}'::jsonb);
        muda jsonb := '{}'::jsonb; txt text; s text := btrim(coalesce(p_senha_gov, '')); trab text; ativ text;
begin
  select a.prosp_id, coalesce(p.data ->> 'nome', '') into pid, quem
    from public.campo_acessos a left join public.prospectadores p on p.id = a.prosp_id
   where a.token = p_token and a.ativo and length(p_token) >= 20;
  if pid is null then return jsonb_build_object('erro', 'Acesso inválido. Entre de novo.'); end if;
  select data into atual from public.clientes where id = p_cliente;
  if atual is null then return jsonb_build_object('erro', 'Cliente não encontrada.'); end if;
  if coalesce(atual ->> 'responsavelId', '') <> pid then return jsonb_build_object('erro', 'Esta mãe não foi cadastrada por você.'); end if;

  -- endereço: "Rua X, 246, Complemento, Bairro, Cidade/UF, CEP 00000-000"
  if coalesce(trim(e ->> 'rua'), '') <> '' or coalesce(trim(e ->> 'cep'), '') <> '' then
    txt := concat_ws(', ',
      nullif(trim(e ->> 'rua'), ''), nullif(trim(e ->> 'numero'), ''), nullif(trim(e ->> 'complemento'), ''), nullif(trim(e ->> 'bairro'), ''),
      nullif(concat_ws('/', nullif(trim(e ->> 'cidade'), ''), nullif(upper(trim(e ->> 'uf')), '')), ''),
      case when length(regexp_replace(coalesce(e ->> 'cep', ''), '\D', '', 'g')) = 8
           then 'CEP ' || substr(regexp_replace(e ->> 'cep', '\D', '', 'g'), 1, 5) || '-' || substr(regexp_replace(e ->> 'cep', '\D', '', 'g'), 6, 3) end);
    muda := muda || jsonb_build_object('endereco', left(txt, 300), 'cep', left(regexp_replace(coalesce(e ->> 'cep', ''), '\D', '', 'g'), 8),
      'enderecoNumero', left(coalesce(trim(e ->> 'numero'), ''), 20), 'enderecoComplemento', left(coalesce(trim(e ->> 'complemento'), ''), 80));
  end if;

  -- senha gov.br: cofre separado (o histórico guarda a anterior, se for troca)
  if s <> '' then
    if length(s) > 200 then return jsonb_build_object('erro', 'Senha longa demais.'); end if;
    insert into public.clientes_senhas_historico (cliente_id, senha_gov, por)
      select p_cliente, c.senha_gov, 'app: ' || quem from public.clientes_senhas c where c.cliente_id = p_cliente and c.senha_gov <> s;
    insert into public.clientes_senhas (cliente_id, senha_gov, atualizado_em, atualizado_por)
      values (p_cliente, s, now(), 'app: ' || quem)
      on conflict (cliente_id) do update set senha_gov = excluded.senha_gov, atualizado_em = now(), atualizado_por = excluded.atualizado_por;
    muda := muda || jsonb_build_object('senhaGovOk', true);
  end if;

  -- qualificação: só as chaves conhecidas, textos curtos
  if q <> '{}'::jsonb then
    muda := muda || jsonb_build_object('qualificacao', jsonb_build_object(
      'trabalho', left(coalesce(q ->> 'trabalho', ''), 30), 'saida', left(coalesce(q ->> 'saida', ''), 30), 'beneficio', left(coalesce(q ->> 'beneficio', ''), 30),
      'caminho', left(coalesce(q ->> 'caminho', ''), 30), 'analisar', coalesce((q ->> 'analisar')::boolean, false),
      'em', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'por', 'app: ' || quem));
    trab := coalesce(q ->> 'trabalho', '');
    if coalesce(atual ->> 'tipoSegurada', '') = '' then
      ativ := case trab when 'pescadora' then 'Pescadora' when 'agricultora' then 'Agricultora' when 'indigena' then 'Indígena' else '' end;
      if ativ <> '' then muda := muda || jsonb_build_object('tipoSegurada', 'especial', 'atividade', ativ);
      elsif trab <> '' then muda := muda || jsonb_build_object('tipoSegurada', 'urbana');
      end if;
    end if;
  end if;

  if muda <> '{}'::jsonb then
    update public.clientes set data = data || muda || jsonb_build_object('atualizadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')) where id = p_cliente;
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.campo_completar_dados(text, text, jsonb, text, jsonb) from public;
grant execute on function public.campo_completar_dados(text, text, jsonb, text, jsonb) to anon, authenticated;

select 'ok' as qualificacao_app, to_regprocedure('public.campo_completar_dados(text,text,jsonb,text,jsonb)') is not null as funcao_criada;
