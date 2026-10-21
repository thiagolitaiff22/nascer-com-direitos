-- Cadastra Alanna Thanny Rodrigues Moia como prospectadora (Marabá-PA). Não cria login: o acesso é definido no BI (Parceiros > Login). Pode rodar de novo.
insert into public.prospectadores (id, data)
select replace(gen_random_uuid()::text, '-', ''), jsonb_build_object(
  'nome', 'Alanna Thanny Rodrigues Moia', 'tipo', 'pessoa', 'clinica', '', 'perfil', 'prospectador',
  'telefone', '', 'regiao', 'Marabá', 'regiaoId', 'PA', 'cpf', '01708701206', 'palavrasEndereco', '[]'::jsonb,
  'comConf', 0, 'comLib', 0, 'tambemParceiro', false, 'ativo', true,
  'criadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'atualizadoEm', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'criadoPor', 'assistente')
where not exists (select 1 from public.prospectadores where data ->> 'cpf' = '01708701206' or lower(data ->> 'nome') = 'alanna thanny rodrigues moia');
select id, data ->> 'nome' as nome, data ->> 'perfil' as perfil, data ->> 'regiao' as cidade, data ->> 'regiaoId' as estado from public.prospectadores where data ->> 'cpf' = '01708701206';
