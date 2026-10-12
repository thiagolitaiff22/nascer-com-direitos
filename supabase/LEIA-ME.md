# Banco do Nascer com Direitos (Supabase)

Projeto **novo** no Supabase (separado do projeto do sistema antigo). Nomes de campos, documentos e etapas: `ESPECIFICACAO.md`.

## 1. Rodar os arquivos SQL, em ordem

No SQL Editor, cole e rode um arquivo de cada vez, **nessa ordem**:

`01_estrutura` → `02_segredos` → `03_regua` → `04_historico` → `05_tribunal` → `06_agendador` → `07_cadencia` → `08_avulso` → `09_campo` → `10_claude` → `11_pastas` → `12_ler_pasta` → `13_login_app` → `14_senha_visivel` → `15_painel_app` → `16_faltam_docs` → `17_painel_restrito` → `18_painel_corrige` → `19_foto_cliente`

Todos podem rodar de novo sem perder dados.

Onde está cada função do aplicativo, na versão final:
- `campo_cadastrar` (cadastro pelo celular): `19_foto_cliente.sql`
- `campo_painel` (painel do prospectador): `18_painel_corrige.sql`
- `campo_quem` e `campo_pastas_etapas`: `09_campo.sql` · `campo_pastas_status`: `11_pastas.sql`

Os arquivos 15 e 17 ficaram só com um aviso, para a numeração continuar igual à do guia.

## 2. Primeiro administrador

1. Authentication › Users › **Add user** com o e-mail de quem vai administrar.
2. No SQL Editor, rode (troque e-mail, em minúsculas, e nome):

```sql
insert into public.equipe (email, nome, funcao)
values ('seu.email@exemplo.com.br', 'Seu Nome', 'admin')
on conflict (email) do update set funcao = 'admin', ativo = true;
```

O restante da equipe o administrador cadastra pelo sistema.

## 3. Função de avisos e tribunal (`lembrete-whatsapp`)

Com a [Supabase CLI](https://supabase.com/docs/guides/cli), na pasta do projeto:

```
supabase login
supabase link --project-ref SEU-PROJETO
supabase functions deploy lembrete-whatsapp --no-verify-jwt
```

- Em Edge Functions › lembrete-whatsapp › Settings, deixe **"Verify JWT with legacy secret" desligado** (o agendador chama só com a chave interna `x-regua-token`; a função confere sozinha quem é administrador).
- Chaves (LiderHub e DataJud): o administrador cola em Configurações › Integrações. Ficam na tabela `segredos`, que o site não lê.
- Tribunal do DataJud: `config` › `regua` › `tribunalAlias` (`trf1` = Justiça Federal da 1ª Região, `tjam` = TJAM). Padrão: `trf1`.
- Local da audiência nos avisos: por padrão "Fórum / Vara onde corre o processo (confira no convite)". Para fixar um local, grave `local` em `config` › `regua`.

## 4. Agendadores (`06_agendador.sql`)

Antes de rodar o `06_agendador.sql`, troque `SEU-PROJETO` pelo **Project ref** (Project Settings › General; é o começo da Project URL `https://<ref>.supabase.co`). Enquanto estiver `SEU-PROJETO`, o arquivo só avisa e não agenda nada. Depois de trocar, rode de novo.

Ele cria:
- `regua-avisos`: a cada 10 minutos, todos os dias, das 8h às 17h50 de Manaus (a régua só envia se estiver ativada no sistema);
- `tribunal-datajud`: todo dia às 7h de Manaus, de segunda a sábado.

Para conferir: `select jobname, schedule, active from cron.job;`

## 5. O que trocar fora desta pasta

Project URL e chave **publishable/anon** (nunca a `service_role`) em `config.js`, `campo.html` (CFG) e `google/campo.gs` (`SUPABASE_URL`/`SUPABASE_KEY`). Em Authentication › URL Configuration, coloque o endereço do site novo.
