-- Logins de TESTE do aplicativo. Rodar no SQL Editor do Supabase (você aperta Run). Pode rodar de novo.
--   111.111.111-11  Teste Parceiro      (parceiro, Amazonas · Manaus)
--   222.222.222-22  Teste Prospectador  (prospectador que também atua como parceiro)
-- Senha padrão 123456 (a pessoa pode criar outra no primeiro acesso).
-- Para apagar depois: rode o arquivo 39b_apagar_logins_de_teste.sql.

insert into public.prospectadores (id, data) values
  ('teste-prosp', jsonb_build_object('id','teste-prosp','nome','Teste Prospectador','perfil','prospectador','tipo','pessoa',
     'regiaoId','AM','regiao','Manaus','telefone','(92) 90000-0002','tambemParceiro',true,'ativo',true,'criadoEm',now())),
  ('teste-parc',  jsonb_build_object('id','teste-parc','nome','Teste Parceiro','tipo','pessoa','regiaoId','AM','regiao','Manaus',
     'prospectadorId','teste-prosp','telefone','(92) 90000-0001','ativo',true,'criadoEm',now()))
on conflict (id) do update set data = excluded.data;

insert into public.campo_logins (usuario, prosp_id, senha_hash, senha_ver, trocar_senha, atualizado_por) values
  ('11111111111', 'teste-parc',  extensions.crypt('123456', extensions.gen_salt('bf')), '123456', true, 'teste'),
  ('22222222222', 'teste-prosp', extensions.crypt('123456', extensions.gen_salt('bf')), '123456', true, 'teste')
on conflict (usuario) do update set prosp_id = excluded.prosp_id, senha_hash = excluded.senha_hash, senha_ver = excluded.senha_ver,
  trocar_senha = true, ativo = true, erros = 0, bloqueado_ate = null, atualizado_em = now();

select usuario, prosp_id, ativo from public.campo_logins where usuario in ('11111111111','22222222222');
