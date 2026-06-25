#!/bin/bash
# Релизная сборка ZBSEye: Release-конфигурация, стабильная подпись «Slishu Dev» (если сертификат
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
APP="$DERIVED/Build/Products/Release/ZBS Eye.app"
# Старый продукт убрать ДО сборки: при провале xcodebuild нельзя молча упаковать прошлый .app.
rm -rf "$APP"

set +e
# CODE_SIGN_STYLE=Manual + пустой DEVELOPMENT_TEAM: иначе SPM-зависимости (GRDB/swift-crypto/
# transformers) при явной identity требуют Apple Team для automatic-signing → BUILD FAILED.
# С Manual они подписываются нашим self-signed «Slishu Dev» без команды.
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  build 2>&1 | grep -E "error:|warning:|BUILD"
XC_STATUS=${PIPESTATUS[0]}
set -e
[ "$XC_STATUS" -eq 0 ] || { echo "❌ xcodebuild провалился (exit $XC_STATUS)"; exit 1; }
[ -d "$APP" ] || { echo "❌ ZBS Eye.app не собрался"; exit 1; }

# Упаковка e5-модели в бандл (если уже скачана): first-run без сети и без 300MB-загрузки.
MODEL_CACHE="$HOME/Library/Application Support/ZBS Eye/models/models/intfloat/multilingual-e5-small"
if [ -d "$MODEL_CACHE" ]; then
  # Путь в бандле = Bundle.resourceURL + "models/intfloat/multilingual-e5-small" (EmbeddingService.repo).
  # БЕЗ двойного models/ (это структура кеша HubApi, не бандла) — иначе copyBundledModelIfNeeded не найдёт
  # и first-run молча уйдёт в сеть несмотря на «✅ упакована».
  mkdir -p "$APP/Contents/Resources/models/intfloat"
  ditto "$MODEL_CACHE" "$APP/Contents/Resources/models/intfloat/multilingual-e5-small"
  # ресурсы изменились → переподписать. БЕЗ молчаливого ad-hoc fallback: ad-hoc ломает стабильность
  # TCC, а «✅» печаталось бы всё равно. Провал переподписи — прерываем явно.
  if ! codesign --force --sign "$IDENTITY" "$APP"; then
    echo "❌ Переподпись '$IDENTITY' после упаковки модели провалилась (keychain заперт?)."
    echo "   НЕ подписываю ad-hoc молча — это сломало бы TCC. Разблокируй keychain и перезапусти."
    exit 1
  fi
  echo "✅ e5-модель упакована в бандл ($(du -sh "$MODEL_CACHE" | cut -f1)) — first-run оффлайн"
else
  echo "ℹ️  Кеш e5 не найден — приложение скачает модель при первом поиске (~300MB)"
fi

codesign --verify --strict "$APP" && echo "✅ Подпись валидна ($IDENTITY)"

mkdir -p dist
ZIP="dist/ZBSEye-$(date +%Y%m%d).zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✅ $ZIP ($(du -h "$ZIP" | cut -f1))"
echo ""
echo "Установка у получателя: распаковать в /Applications."
echo "  macOS 15+: запустить → откажет → System Settings → Privacy & Security → «Open Anyway»."
echo "  macOS ≤14: правый клик → Открыть. Технарям: xattr -dr com.apple.quarantine /Applications/ZBS Eye.app"
echo ""
echo "⚠️  Если предыдущий билд был подписан иначе (ad-hoc → «Slishu Dev»), macOS ОДИН РАЗ сбросит"
echo "   TCC-права: в System Settings → Privacy & Security ВЫКЛЮЧИ и снова включи ZBSEye в"
echo "   Screen Recording (тоггл выглядит включённым — перещёлкнуть обязательно), затем Microphone."