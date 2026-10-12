# Nascer com Direitos · especificação

Sistema irmão do **Queda de Energia**, para o produto **Salário-Maternidade**. Marca: **Nascer com Direitos** (logo dourada em img/logo-nascer.png, tema branco e dourado). Mesma arquitetura: `index.html` (sistema do escritório), `campo.html`
(aplicativo do prospectador), `google/campo.gs` (Drive + IA), Supabase (`supabase/*.sql` e a função `lembrete-whatsapp`).

Este arquivo é a referência única dos nomes de campos, documentos e etapas. Todas as peças usam os mesmos nomes.

---

## 1. Fluxo

```
Cadastro ──► INSS (requerimento) ──► Concedido ─────────────────────────────► Financeiro ──► Arquivados (pago)
                    │
                    ├─► Exigência (o INSS pediu documento; tem prazo) ─► volta para análise
                    │
                    └─► Indeferido ──► Ação na Justiça ──► Audiência ──► Sentença ──► RPV/implantação ──► Financeiro ──► Arquivados
```

- **Cadastro**: cliente sem requerimento no INSS (`der` e `protocoloInss` vazios) e sem `processo`.
- **INSS** (aba nova): tem `der` ou `protocoloInss`, ainda sem `processo`.
- **Controle**: tem `processo` (ação judicial) e a audiência ainda não aconteceu.
- **Contestações**: teses da contestação do INSS e resultado da audiência.
- **Financeiro**: concedidos no INSS e procedentes/acordos na Justiça.
- **Arquivados**: pagos e encerrados.

O tribunal ainda vai ser definido (Justiça Federal/PJe ou Justiça Estadual/PROJUDI em competência delegada).
Por isso o DataJud tem o tribunal configurável e o botão do PROJUDI continua, mas pode ser ignorado.

## 2. Tipos de segurada (`tipoSegurada`)

| Valor | Rótulo | Observação |
|---|---|---|
| `especial` | Segurada especial (rural/pescadora) | Precisa de autodeclaração rural e provas de atividade rural; audiência com testemunhas |
| `urbana` | Empregada / urbana | CTPS ou CNIS |
| `individual` | Contribuinte individual / MEI / facultativa | Guias de contribuição (GPS/DAS) |
| `desempregada` | Desempregada (período de graça) | CTPS com a última saída, CNIS |

## 3. Fato gerador (`fatoGerador`)

`parto` (Parto) · `adocao` (Adoção) · `guarda` (Guarda para adoção) · `natimorto` (Natimorto) · `aborto` (Aborto não criminoso) · `gestante` (Ainda gestante: pode requerer a partir de 28 dias antes do parto).

Prazo: o direito de pedir prescreve em **5 anos** contados do fato gerador (`criancaNasc`). O sistema avisa quando faltam menos de 6 meses.

## 4. Campos do cliente (JSON em `clientes.data`)

**Dados da mãe**: `nome`, `cpf`, `rg`, `nascimento` (data de nascimento da mãe, `YYYY-MM-DD`), `nit` (NIT/PIS/NIS), `endereco`, `contato`, `tipoSegurada`, `atividade` (texto livre: agricultora, pescadora, doméstica…).

**Criança / fato gerador**: `fatoGerador`, `crianca` (nome da criança), `criancaNasc` (data do nascimento, adoção ou guarda, `YYYY-MM-DD`), `dpp` (data prevista do parto, só para gestante), `testemunhas` (texto: nomes e telefones das testemunhas da atividade rural).

**INSS (administrativo)**: `der` (data de entrada do requerimento), `protocoloInss` (número do protocolo no Meu INSS), `nb` (número do benefício), `inssStatus` (`analise` · `exigencia` · `concedido` · `indeferido`), `exigenciaPrazo` (data limite para cumprir a exigência), `exigenciaObs` (o que o INSS pediu), `inssDecisaoEm` (data da decisão), `motivoIndeferimento` (texto).

**Justiça**: `processo`, `protocolo` (data do ajuizamento), `audData`, `audHora`, `online`, campos de aviso (iguais ao Energia: `avisado`, `situacao`, `meioAviso`, `avisadoEm`, `avisadoA`, `avisoRespId`), `comparecimento`, `motivoFalta`, `resultado`, `concluso`, `motivoConcluso`, `embargos` (`opostos` = **recurso do INSS**), `pagamento`, `previsao`, `tese` (texto da contestação do INSS).

`resultado`: `procedente` · `parcial` · `acordo` · `improcedente` · `extinto` · `ausente` (autora ausente) · `aguardando` (conclusos para sentença).
Ganhos = `procedente`, `parcial`, `acordo`.

`pagamento`: `aguardando` (Aguardando pagamento) · `implantado` (Benefício implantado) · `rpv` (RPV expedida) · `pago` (Pago).

**Financeiro**: `valorBeneficio` (valor total do benefício; padrão = 4 × salário mínimo), `valorGuia` (valor da guia paga pelo escritório e reembolsada pela cliente), `recebimento` `{ data, valor, onde: 'cliente'|'escritorio', obs }`, `repasse` `{ data, valor, forma, chavePix, terceiroNome, terceiroCpf, terceiroParentesco, testemunha }`, `arquivado`, `arquivadoEm`, `contatadoRetorno` (contatada para um novo benefício, ex.: outro filho).

**Honorários** = 30% do benefício + valor da guia. Quando o dinheiro cai na conta da cliente, o escritório recebe dela os honorários; quando cai na conta do escritório, o escritório paga à cliente o benefício menos os honorários.

**Iguais ao Energia**: `responsavelId`, `origem`, `conferirDados`, `pastaId`, `pastaUrl`, `faltaDocs`, `docsCompletos`, `campoDocs`, `fotoCliente`, `dataCadastro`, `criadoEm`, `atualizadoEm`, `contatoVia`, `foraDaRegua`, `semWhatsApp`, `regua*`, `tribunal*`.

## 5. Documentos

| Chave | Nome | Obrigatório |
|---|---|---|
| `procuracao` | Procuração e contrato | todas |
| `rg_frente` / `rg_verso` | RG da mãe (frente e verso) | todas (a chave que conta é `rg_frente`) |
| `cpf` | CPF da mãe | todas |
| `certidao` | Certidão de nascimento da criança (ou termo de guarda/adoção) | todas (gestante: pode faltar até o parto) |
| `residencia` | Comprovante de residência | todas |
| `cliente` | Foto da cliente | todas |
| `autodeclaracao` | Autodeclaração do segurado especial (rural) | só `especial` |
| `rural` | Provas de atividade rural (ITR, declaração do sindicato, carteira de pescadora/RGP, bloco de produtora, CAF/DAP, certidões com profissão de lavradora) | só `especial` |
| `ctps` | Carteira de trabalho, CNIS ou guias de contribuição | `urbana`, `individual`, `desempregada` |
| `arogo` | Documentos de quem assina a rogo | não |
| `outro` | Outro documento | não |

Arquivos na pasta do Drive (PDFs): `PROCURAÇÃO` (procuracao) · `DOCUMENTOS PESSOAIS` (rg_frente, rg_verso, cpf, residencia) · `CERTIDÃO DE NASCIMENTO` (certidao) · `AUTODECLARAÇÃO RURAL` (autodeclaracao) · `PROVAS DE ATIVIDADE RURAL` (rural) · `CTPS E CONTRIBUIÇÕES` (ctps) · `DOCUMENTOS A ROGO` (arogo) · `OUTROS DOCUMENTOS` (outro) · `FOTO DA CLIENTE` (cliente).

"Conferir documentos" (IA) devolve `tem: { procuracao, rg, cpf, certidao, residencia, autodeclaracao, rural, ctps }` (booleanos).
"Ler pasta" (IA) devolve `dados: { cpf, rg, endereco, nit, crianca, criancaNasc, observacao, tem }`.

Pastas no Drive: `NASCER COM DIREITOS › CLIENTES › PENDENTES DE REQUERIMENTO / NO INSS / NA JUSTIÇA / ARQUIVADOS`.
Etapa da pasta: `pendente` (sem requerimento), `inss` (tem `der`/`protocoloInss`, sem processo), `justica` (tem `processo`), `arquivado`.

## 6. Etapas (sistema do escritório)

`cadastrado` → `requerido` (INSS em análise) → `exigencia` → `concedido` | `indeferido` → `ajuizado` (aguardando audiência) → `marcada` → `resultado` (aguardando sentença) → `sentenca` → `recurso` → `rpv` (RPV/implantado) → `pago`.

## 7. Aplicativo do prospectador (o que ele vê)

O prospectador vê só até "Ganharam": não vê pagamento nem quem está aguardando sentença.

| Etapa no app | Quando |
|---|---|
| `preparo` · Em preparação | sem requerimento |
| `inss` · No INSS | `der` ou `protocoloInss`, status `analise` |
| `exigencia` · INSS pediu documento | `inssStatus = exigencia` |
| `indeferido` · Indeferido · vai para a Justiça | `inssStatus = indeferido` e sem processo |
| `protocolado` · Na Justiça | tem processo, sem audiência |
| `marcada` · Audiência marcada | audiência futura |
| `ganhou` · Ganhou | `inssStatus = concedido` ou resultado `procedente`/`parcial`/`acordo` |
| `faltou` · Faltou à audiência | `ausente` ou `comparecimento = faltou` |
| `perdeu` · Não ganhou | `improcedente` ou `extinto` |

O painel (`campo_painel`) manda: `id, nome, contato, cadastro, tipoSegurada, crianca, criancaNasc, requerido, inssStatus, protocolado, audData, audHora, online, resultado (só sentença), comparecimento, origem, faltaDocs, temPasta`.

## 8. Textos padrão

- Marca: "Nascer com Direitos" (sem nome de escritório). PDFs assinados como "Nascer com Direitos · Responsável".
- Ré: INSS (Instituto Nacional do Seguro Social).
- Convite: "CONVITE PARA AUDIÊNCIA DO SALÁRIO-MATERNIDADE". Orientação: levar documento com foto, a certidão de nascimento da criança e, se for segurada especial, as testemunhas.
- Avisos de WhatsApp: citam "o salário-maternidade" e o INSS, não a Âmbar.

## 9. O que precisa ser configurado (não vai pronto)

1. Projeto novo no Supabase → `config.js`, `campo.html` (CFG) e `google/campo.gs` (SUPABASE_URL/KEY).
2. Pastas no Drive → `PASTA_CLIENTES` em `google/campo.gs`.
3. Apps Script novo → endereço `/exec` em Configurações › Cadastro pelo celular.
4. Tribunal → Configurações › Tribunal (DataJud): escolher o tribunal (TRF1 ou TJAM).
5. Endereço do site (GitHub Pages/Vercel) → `app/gerar-apk.sh` e `app/versao.json`.
6. Salário mínimo do ano → `SALARIO_MINIMO` no `index.html` (padrão do benefício = 4 × SM).
