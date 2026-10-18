-- Apaga os logins de teste (11111111111 e 22222222222) e os dois cadastros de teste. Rodar no SQL Editor quando acabar de testar.
delete from public.campo_acessos where prosp_id in ('teste-parc','teste-prosp');
delete from public.campo_logins  where usuario in ('11111111111','22222222222');
delete from public.prospectadores where id in ('teste-parc','teste-prosp');
select 'testes apagados' as resultado;
