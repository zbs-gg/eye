#!/bin/bash
# Релизная сборка Slishu: Release-конфигурация, стабильная подпись «Slishu Dev» (если сертификат
# создан scripts/make-signing-cert.sh, иначе ad-hoc с предупреждением), zip в dist/.
# Без нотаризации (нет $99-аккаунта). Установка у получателя на macOS 15+: запустить → отказ →
# System Settings → Privacy & Security → «Open Anyway» (right-click → Open больше не работает).
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Slishu Dev"
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "⚠️  Сертификата «$IDENTITY» нет — подпишу ad-hoc (TCC-права слетят при следующем билде)."
  echo "   Для стабильной подписи: bash scripts/make-signing-cert.sh"
  IDENTITY="-"
fi

xcodegen generate
DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/Slishu.app"
# Старый продукт убрать ДО сборки: при провале xcodebuild нельзя молча упаковать прошлый .app.
rm -rf "$APP"

set +e
xcodebuild -project Slishu.xcodeproj -scheme Slishu -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  build 2>&1 | grep -E "error:|warning:.*Sendable|BUILD"
XC_STATUS=${PIPESTATUS[0]}
set -e
[ "$XC_STATUS" -eq 0 ] || { echo "❌ xcodebuild провалился (exit $XC_STATUS)"; exit 1; }
[ -d "$APP" ] || { echo "❌ Slishu.app не собрался"; exit 1; }

codesign --verify --strict "$APP" && echo "✅ Подпись валидна ($IDENTITY)"

mkdir -p dist
ZIP="dist/Slishu-$(date +%Y%m%d).zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✅ $ZIP ($(du -h "$ZIP" | cut -f1))"
echo ""
echo "Установка у получателя: распаковать в /Applications."
echo "  macOS 15+: запустить → откажет → System Settings → Privacy & Security → «Open Anyway»."
echo "  macOS ≤14: правый клик → Открыть. Технарям: xattr -dr com.apple.quarantine /Applications/Slishu.app"
echo ""
echo "⚠️  Если предыдущий билд был подписан иначе (ad-hoc → «Slishu Dev»), macOS ОДИН РАЗ сбросит"
echo "   TCC-права: в System Settings → Privacy & Security ВЫКЛЮЧИ и снова включи Slishu в"
echo "   Screen Recording (тоггл выглядит включённым — перещёлкнуть обязательно), затем Microphone."