#!/bin/bash
# Publica google/campo.gs no Apps Script "Nascer com Direitos · Cadastro pelo celular" sem abrir o navegador
# (clasp: npm i -g @google/clasp, autorizado uma vez com "clasp login").
# Atualiza a MESMA implantação: o endereço /exec usado pelo sistema e pelo aplicativo não muda.
# Antes do primeiro uso, troque as duas linhas abaixo pelas do projeto novo:
#   PASTA       = pasta local (fora do repositório) com o .clasp.json; nele vai o scriptId do projeto
#                 Apps Script do Nascer com Direitos (script.google.com › Configurações do projeto › ID do script).
#   IMPLANTACAO = id da implantação App da Web (Implantar › Gerenciar implantações), o mesmo que aparece no endereço /exec.
# Uso: ./google/publicar.sh "descrição da versão"
set -e
cd "$(dirname "$0")"
PASTA=/c/Users/Admin/apps-script-nascer                     # .clasp.json com o scriptId: {"scriptId":"COLE_AQUI_O_ID_DO_SCRIPT"}
IMPLANTACAO=COLE_AQUI_O_ID_DA_IMPLANTACAO
case "$IMPLANTACAO" in COLE_AQUI*) echo "Configure IMPLANTACAO em google/publicar.sh antes de publicar."; exit 1;; esac
node -e "new Function(require('fs').readFileSync('campo.gs','utf8'))"   # não publica código com erro de sintaxe
cp campo.gs "$PASTA/Código.js"
cd "$PASTA"
clasp push -f
clasp deploy -i "$IMPLANTACAO" -d "${1:-atualização}"
clasp deployments | grep "$IMPLANTACAO"
