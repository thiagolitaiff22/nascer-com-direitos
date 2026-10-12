> **Nota:** este guia veio do sistema Queda de Energia e serviu de base para o Nascer com Direitos. O que vale agora está em ESPECIFICACAO.md.

# Guia para criar um sistema irmão (ex.: Salário-Maternidade)

Este repositório é o sistema **Queda de Energia** (ação contra a Âmbar Energia, Alvarães/AM). Este guia explica como ele é montado e o que trocar para criar um sistema parecido para outro produto, como o **Salário-Maternidade**.

> Nada de dados de clientes está aqui. Os dados ficam no banco (Supabase) e os documentos no Google Drive.

---

## 1. As peças do sistema

| Peça | Onde está | O que faz |
|---|---|---|
| **Sistema do escritório (BI)** | `index.html` + `config.js` | Página única em HTML e JavaScript, sem etapa de build. Abas: Cadastro, Controle, Contestações, Financeiro, Arquivados, Prospectadores, Configurações. |
| **Banco e login** | Supabase, arquivos `supabase/01…19_*.sql` | Tabelas `clientes` e `prospectadores` (cada registro é um JSON em `data`), equipe, segredos, histórico e as funções (RPC) usadas pelo sistema e pelo aplicativo. |
| **Aviso por WhatsApp** | `supabase/functions/lembrete-whatsapp` | Função do Supabase que manda os avisos de audiência pelo LiderHub (régua automática e lembrete avulso). |
| **Aplicativo do prospectador** | `campo.html` (+ `campo.webmanifest`, `campo-sw.js`, `img/`) | O prospectador cadastra o cliente pelo celular: nome, telefone e fotos dos documentos (scanner com recorte automático). Funciona sem internet e envia sozinho depois. No iPhone é instalado pelo Safari (Adicionar à Tela de Início). |
| **App Android** | `app/` (Capacitor) | Empacota o mesmo `campo.html` como app Android. O APK fica em `app/download/rl-advogados.apk`, e `app/versao.json` avisa os celulares quando sai versão nova. |
| **Script do Google** | `google/campo.gs` | Apps Script na conta do escritório. Recebe as fotos do app, cria a pasta do cliente no Drive, monta os PDFs (PROCURAÇÃO, DOCUMENTOS PESSOAIS, FOTO DO CLIENTE), registra o cliente no banco e move as pastas de PENDENTES para PROTOCOLADOS e ARQUIVADOS. Também tem o botão "Conferir documentos" (a IA diz quais documentos estão na pasta). |
| **Extensão do PROJUDI** | `extensao-projudi/` (+ `.zip`) | Extensão do Chrome que lê a pauta de audiências do PROJUDI e devolve ao sistema. |

### Como as peças conversam
1. O prospectador entra no app com **usuário e senha** (definidos pelo administrador em Prospectadores › Aplicativo).
2. O app manda cada arquivo para o **script do Google** (`acao: 'arquivo'`) e depois fecha o cadastro (`acao: 'fechar'`).
3. O script cria a pasta no Drive e chama a RPC `campo_cadastrar` no Supabase. O cliente aparece no **Cadastro** com "Conferir dados".
4. O app consulta a RPC `campo_painel` para mostrar ao prospectador os clientes dele: Painel, Clientes e ficha com a linha do tempo.
5. O escritório confere os dados, protocola (põe o número do processo) e o cliente passa para o **Controle**.

---

## 2. Passo a passo para o sistema irmão

### 2.1 Repositório e site
1. Crie um repositório novo no GitHub, por exemplo `controle-salario-maternidade`, e copie todos estes arquivos para ele.
2. Ligue o **GitHub Pages** (Settings › Pages › branch `main`). O endereço vira `https://<usuario>.github.io/<repositorio>/`.

### 2.2 Banco (Supabase)
1. Crie um **projeto novo** no Supabase. Não use o mesmo do Queda de Energia.
2. No SQL Editor, rode os arquivos `supabase/01_estrutura.sql` até `19_foto_cliente.sql`, **nessa ordem**.
3. Em `config.js`, troque `url` e `key` pela Project URL e pela chave **publishable/anon** do projeto novo. **Nunca** use a `service_role`.
4. Em Authentication › URL Configuration, coloque o endereço do site novo em Site URL e em Redirect URLs.
5. Cadastre a equipe e o primeiro administrador (veja `01_estrutura.sql`).

### 2.3 Google Drive e script
1. Crie a estrutura de pastas do novo produto no Drive, por exemplo `SALÁRIO MATERNIDADE › CLIENTES › PENDENTES DE PROTOCOLO / PROTOCOLADOS / ARQUIVADOS`.
2. Crie um **projeto novo** de Apps Script e cole `google/campo.gs`. No topo, troque:
   - `SUPABASE_URL` e `SUPABASE_KEY` (do projeto novo);
   - `PASTA_CLIENTES` (id da pasta CLIENTES nova);
   - os nomes `PENDENTES`, `PROTOCOLADOS` e `ARQUIVADOS`, se forem diferentes;
   - `NOMES` (os tipos de documento; veja a seção 3).
3. Implantar › Nova implantação › App da Web · Executar como: Eu · Quem pode acessar: Qualquer pessoa. Copie o endereço `/exec`.
4. No sistema novo: Configurações › Cadastro pelo celular › cole o endereço `/exec`.
5. Para publicar mudanças sem abrir o navegador: `google/publicar.sh` usa o **clasp** (`npm i -g @google/clasp`, `clasp login` uma vez e a "Google Apps Script API" ligada em script.google.com/home/usersettings). Troque no arquivo a pasta local, o `scriptId` e o id da implantação pelos do projeto novo.

### 2.4 Aplicativo
1. Em `campo.html`, procure os endereços do Supabase e do script e troque pelos do projeto novo. Troque também textos e cores, se quiser.
2. Em `app/capacitor.config.json`, troque o **`appId`**, por exemplo `br.com.nascercomdireitos.app`, e o `appName`. Com o mesmo appId, um app instalaria por cima do outro.
3. Em `app/android/app/build.gradle`, troque o `applicationId` e o `namespace` para o mesmo appId, e recomece em `versionCode 1`.
4. Em `app/gerar-apk.sh` e em `app/versao.json`, troque o endereço do site e o nome do APK.
5. **Chave de assinatura do Android:** fica fora do repositório (`C:\Users\Admin\android-tools`). Pode criar uma nova para o app novo. Guarde bem: sem ela não dá para atualizar o app por cima.
6. Ferramentas para gerar o APK: Java 21 e Android SDK, também em `C:\Users\Admin\android-tools`. Rode `./app/gerar-apk.sh`.

### 2.5 Integrações (Configurações › Integrações)
- **LiderHub** (WhatsApp): chave do workspace, colada pelo usuário.
- **DataJud** (tribunal): chave pública do CNJ.
- **IA (ChatGPT)**: só para "Conferir documentos". Precisa de crédito na OpenAI.

---

## 3. O que muda no conteúdo (Queda de Energia → Salário-Maternidade)

Estes pontos são específicos do produto de energia e precisam ser revistos:

1. **Documentos obrigatórios**
   - Hoje: procuração, RG (frente e verso), CPF, talão de luz e foto do cliente.
   - Para a maternidade, por exemplo: procuração, RG/CPF da mãe, certidão de nascimento da criança, comprovante de residência, documentos de atividade rural ou CNIS, autodeclaração.
   - Onde mexer:
     - `campo.html`: lista `DOCS`, `MOLDURA`, `GRUPOS_ARQ` e `NOME_DOC`;
     - `index.html`: `DOC_FALTA`;
     - `google/campo.gs`: `NOMES` e o pedido da IA em `conferirDocsDaPasta`;
     - `supabase/16_faltam_docs.sql`: a lista de documentos obrigatórios.
2. **Campos do cliente**
   - Hoje: UC (unidade consumidora), período da ação e endereço do talão.
   - Na maternidade, por exemplo: data de nascimento da criança, nome da criança, NIT/PIS, segurada especial (rural) ou urbana, DER (data do requerimento) e número do benefício (NB).
3. **Etapas do processo**
   - Hoje: cadastrado → protocolado → audiência marcada → resultado → sentença → embargos → alvará → pago.
   - Na maternidade pode haver a fase administrativa (requerimento no INSS, exigência, indeferimento) antes da judicial.
   - A função é `etapa()` no `index.html`.
4. **Resultados possíveis**
   - Hoje: parcialmente procedente, improcedente, extinto, autor ausente, conclusos. Não tem "procedente" puro nem acordo.
   - Revisar para o novo produto.
5. **Financeiro**
   - Hoje: condenação padrão de R$ 2.000 dividida 50/50 e valor por indicação do prospectador.
   - Na maternidade o valor é o do benefício (4 meses de salário) e os honorários seguem o contrato.
6. **Convite de audiência e textos dos avisos de WhatsApp**
   - Hoje citam a Âmbar Energia e o local da audiência.
   - Onde mexer: `index.html` (convites) e `supabase/functions/lembrete-whatsapp`.
7. **Contestações**
   - A aba lê as teses da Âmbar.
   - No novo produto, a ré é o INSS. As teses mudam, ou a aba pode nem ser necessária.

---

## 4. Regras que valem para os dois sistemas (decisões do escritório)
- **Nome do cliente:** no aplicativo, sempre em MAIÚSCULAS. No sistema, no padrão "Eliel dos Santos" (o sistema corrige sozinho).
- **RG, CPF, endereço e UC:** são preenchidos pela equipe. A IA só confere quais documentos estão na pasta.
- **Prospectador e aviso:** prospectador (quem trouxe o cliente, define o app e o repasse) é diferente do responsável pelo aviso.
- **"Pronto para protocolar":** só com os dados preenchidos e a documentação completa.
- **Telefones:** preenchidos à mão. Número novo fica fora da régua de avisos até ser liberado.
- **O que o prospectador vê:** no app ele vê só até "Ganharam". Não vê "Pagos" nem "Aguardando resultado".
- **Exclusões:** o que for excluído no sistema some também dos aplicativos.

---

## 5. Começando o chat novo
No chat do projeto novo, anexe este arquivo e diga, por exemplo:

> "Quero um sistema irmão deste, para Salário-Maternidade. Use este código como base, siga o GUIA-NOVO-PROJETO.md e vamos começar pelo banco e pelos documentos obrigatórios."
