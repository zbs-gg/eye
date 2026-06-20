#!/bin/bash
# Создаёт self-signed code-signing сертификат «ZBS Eye Dev» в login-keychain (БЕЗ платного
# Apple Developer аккаунта). Стабильная идентичность подписи = TCC-права (Screen Recording,
# Accessibility, Microphone) и Keychain ACL переживают ребилды — главная dev-боль уходит.
#
# Запускать ОДИН РАЗ. Доверие кладётся в ПОЛЬЗОВАТЕЛЬСКИЙ trust-домен (без sudo) — macOS
# покажет GUI-диалог «вносятся изменения в настройки доверия», подтверди Touch ID/паролем.
#
# NB: первый билд с новой подписью ОДИН РАЗ сбросит уже выданные TCC-права (перевыдать в System
# Settings: выключить и снова включить ZBSEye в Screen Recording, затем Microphone).
set -euo pipefail

NAME="ZBS Eye Dev"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

# Уже есть рабочая идентичность для подписи кода? — повторно не пересоздаём (новый keypair = снова
# слетит TCC). Реюзаем стабильную идентичность.
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "✅ Сертификат «${NAME}» уже существует и доверен — реюзаем:"
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

# Остаток от прошлого частичного запуска (cert без trust / без приватного ключа) — убрать из
# login-keychain, иначе повторный import даст второй серт → codesign: ambiguous identity.
echo "→ Уборка прошлых копий сертификата из login-keychain (если были)…"
while security delete-certificate -c "$NAME" "$LOGIN_KC" >/dev/null 2>&1; do :; done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Конфиг расширений: codeSigning EKU обязателен, иначе codesign не примет идентичность.
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

# ЯВНО системный /usr/bin/openssl (LibreSSL): Homebrew OpenSSL 3.x шифрует p12 алгоритмами,
# которые macOS `security import` не понимает → «MAC verification failed (wrong password?)».
OPENSSL=/usr/bin/openssl

"$OPENSSL" req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cert.cnf" 2>/dev/null

"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:zbseye -name "$NAME"

# Импорт ключа+серта в login-keychain. -T codesign/security — добавить их в ACL ключа.
security import "$TMP/cert.p12" -k "$LOGIN_KC" -P zbseye \
  -T /usr/bin/codesign -T /usr/bin/security

# Доверие в ПОЛЬЗОВАТЕЛЬСКОМ trust-домене (без -d/sudo): появится GUI-диалог, подтверди Touch ID.
echo "→ Доверие сертификату (появится системный диалог — подтверди Touch ID)…"
security add-trusted-cert -r trustRoot -k "$LOGIN_KC" "$TMP/cert.pem"

# Partition-list, чтобы codesign не спрашивал на каждый билд. Без терминала пароль keychain
# спросить нельзя → best-effort; при провале первая подпись покажет GUI «Always Allow» (нажать раз).
echo "→ Partition-list для ключа (может не пройти без пароля — тогда «Always Allow» при первой сборке)…"
security set-key-partition-list -S apple-tool:,apple: -s -D "$NAME" "$LOGIN_KC" >/dev/null 2>&1 \
  && echo "   partition-list установлен" \
  || echo "   пропущено — подтверди «Always Allow» в диалоге при первой сборке"

echo ""
echo "✅ Готово:"
security find-identity -v -p codesigning | grep "$NAME"
echo ""
echo "Дальше: bash scripts/build-release.sh → установка в /Applications/ZBS Eye.app"
echo "⚠️  Первый билд с этой подписью один раз сбросит TCC-права — перевыдай Screen Recording"
echo "   (выключить/включить в System Settings) и Microphone."
