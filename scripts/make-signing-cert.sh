#!/bin/bash
# Создаёт self-signed code-signing сертификат «Slishu Dev» в login-keychain (БЕЗ платного
# Apple Developer аккаунта). Стабильная идентичность подписи = TCC-права (Screen Recording,
# Accessibility, Microphone) и Keychain ACL переживают ребилды — главная dev-боль уходит.
# Запускать ОДИН РАЗ: bash scripts/make-signing-cert.sh (спросит пароль администратора на trust
# и пароль login-keychain на partition-list).
# NB: первый билд с новой подписью ОДИН РАЗ сбросит уже выданные TCC-права (перевыдать в System
# Settings: выключить и снова включить Slishu в Screen Recording, затем Microphone).
set -euo pipefail

NAME="Slishu Dev"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

# Гейт по сертификату (не по identity): ловит и «недоверенный остаток» от прошлого частичного
# запуска — повторный import создал бы ВТОРОЙ серт → codesign: ambiguous identity.
if security find-certificate -c "$NAME" "$LOGIN_KC" >/dev/null 2>&1; then
  if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "✅ Сертификат «$NAME» уже существует и доверен:"
    security find-identity -v -p codesigning | grep "$NAME"
    exit 0
  fi
  echo "❌ Найден сертификат «$NAME», но он НЕ доверен для подписи (остаток прошлого запуска)."
  echo "   Удали его и перезапусти скрипт:  security delete-identity -c \"$NAME\" \"$LOGIN_KC\""
  exit 1
fi

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

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cert.cnf" 2>/dev/null

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:slishu -name "$NAME"

# Сначала trust (sudo), потом import: при провале любого шага не остаётся недоверенного огрызка.
echo "→ Доверие сертификату для подписи кода (спросит пароль администратора)…"
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$TMP/cert.pem"

security import "$TMP/cert.p12" -k "$LOGIN_KC" -P slishu \
  -T /usr/bin/codesign -T /usr/bin/security

# Разрешить codesign использовать ключ без диалога на каждый билд. БЕЗ -k "" (пустой пароль молча
# проваливается у всех с нормальным паролем) — команда сама спросит пароль login-keychain.
# -D "$NAME" — трогаем только НАШ ключ, не переписываем partition-list чужих signing-ключей.
echo "→ Partition-list для ключа (спросит пароль login-keychain = пароль твоего аккаунта)…"
security set-key-partition-list -S apple-tool:,apple: -s -D "$NAME" "$LOGIN_KC"

echo "✅ Готово:"
security find-identity -v -p codesigning | grep "$NAME"
echo "Дальше: bash scripts/build-release.sh"
echo "⚠️  Первый билд с этой подписью один раз сбросит TCC-права — перевыдай Screen Recording"
echo "   (выключить/включить в System Settings) и Microphone."