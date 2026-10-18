#!/bin/bash
# Gera o aplicativo do prospectador (.apk assinado) e publica em app/download/ para os celulares baixarem.
# Antes de gerar uma versão nova: aumente APP_VERSAO no campo.html (e versionCode em android/app/build.gradle).
# Ferramentas (Java e Android SDK) e a chave de assinatura ficam em C:\Users\Admin\android-tools (fora do repositório).
set -e
cd "$(dirname "$0")"
T=/c/Users/Admin/android-tools
export JAVA_HOME="$(cygpath -w "$(ls -d $T/jdk/*/ | head -1)")" ANDROID_HOME="$(cygpath -w $T/sdk)"
node montar.js
npx cap sync android > /dev/null
rm -f android/app/build/outputs/apk/release/app-release.apk
(cd android && ./gradlew.bat assembleRelease --no-daemon -q 2>&1 | grep -iv "warning\|deprecat\|unchecked\|Xlint" || true)
VC=$(grep -o "versionCode [0-9]*" android/app/build.gradle | grep -o "[0-9]*$")
mkdir -p download
cp android/app/build/outputs/apk/release/app-release.apk download/nascer-com-direitos.apk
node -e "const fs=require('fs');let o={};try{o=JSON.parse(fs.readFileSync('versao.json','utf8'))}catch(e){};o.apk=+process.argv[1];o.apkBuild=+process.argv[1];o.url='https://github.com/thiagolitaiff22/nascer-com-direitos/raw/main/app/download/nascer-com-direitos.apk';fs.writeFileSync('versao.json',JSON.stringify(o)+'\n')" "$VC"
"$T/sdk/build-tools/35.0.0/apksigner.bat" verify --print-certs download/nascer-com-direitos.apk | grep -i "signer #1 certificate DN"
echo "APK pronto: app/download/nascer-com-direitos.apk (versionCode $VC)"
