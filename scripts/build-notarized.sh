#!/bin/bash
# Сборка → Developer ID подпись → Hardened Runtime → НОТАРИЗАЦИЯ Apple → staple.
# Цель: раздача ВНЕ App Store (как Rewind / screenpipe — App Store несовместим с cross-app AX под sandbox).
# Нотаризованный билд проходит Gatekeeper ЧИСТО (запуск двойным кликом, без «Open Anyway») и подпись
# СТАБИЛЬНА — уходит вся cdhash/TCC-чехарда self-signed.
#
# ТРЕБУЕТ один раз (см. docs/NOTARIZE.md):
#   1. Платная Apple Developer Program ($99/год).
#   2. Серт «Developer ID Application» в keychain (НЕ «Apple Development»! это другой тип).
#   3. notarytool-профиль:
#        xcrun notarytool store-credentials zbseye-notary \
#          --apple-id <твой-apple-id> --team-id <TEAMID> --password <app-specific-password>
#
# Переопределяемо: ZBSEYE_NOTARY_PROFILE (имя профиля notarytool).
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${ZBSEYE_NOTARY_PROFILE:-zbseye-notary}"
ENTITLEMENTS="ZBSEyeApp/ZBSEye.entitlements"
DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/ZBS Eye.app"

# ── 0. найти Developer ID identity + team из keychain ──
DEVID_LINE=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
if [ -z "${DEVID_LINE}" ]; then
  echo "❌ В keychain нет серта «Developer ID Application»."
  echo "   У тебя сейчас «Apple Development» — это ДРУГОЙ тип, нотаризовать им нельзя."
  echo "   Оформи Apple Developer Program (\$99) и создай Developer ID cert. Шаги: docs/NOTARIZE.md"
  exit 1
fi
IDENTITY=$(echo "${DEVID_LINE}" | sed -E 's/.*"(Developer ID Application: [^"]+)".*/\1/')
TEAM=$(echo "${IDENTITY}" | sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/; s/.*\(([A-Z0-9]+)\)$/\1/')
echo "▸ Подпись: ${IDENTITY}  (team ${TEAM})"

# проверка notarytool-профиля ДО долгой сборки
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  echo "❌ notarytool-профиль «${NOTARY_PROFILE}» не настроен (или просрочены креды)."
  echo "   xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <id> --team-id ${TEAM} --password <app-spec-pwd>"
  echo "   Подробно: docs/NOTARIZE.md"
  exit 1
fi

# ── 1. сборка Release + Hardened Runtime (--options runtime) + secure timestamp ──
xcodegen generate
rm -rf "${APP}"
set +e
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Release \
  -derivedDataPath "${DERIVED}" \
  CODE_SIGN_IDENTITY="${IDENTITY}" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="${TEAM}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  build 2>&1 | grep -E "error:|warning:|BUILD"
XC=${PIPESTATUS[0]}; set -e
[ "${XC}" -eq 0 ] || { echo "❌ xcodebuild провалился (exit ${XC})"; exit 1; }
[ -d "${APP}" ] || { echo "❌ «ZBS Eye.app» не собрался"; exit 1; }

# ── 2. упаковка e5-модели в бандл (как в build-release.sh) — first-run оффлайн ──
MODEL_CACHE="${HOME}/Library/Application Support/ZBS Eye/models/models/intfloat/multilingual-e5-small"
if [ -d "${MODEL_CACHE}" ]; then
  mkdir -p "${APP}/Contents/Resources/models/intfloat"
  ditto "${MODEL_CACHE}" "${APP}/Contents/Resources/models/intfloat/multilingual-e5-small"
  echo "✅ e5-модель упакована ($(du -sh "${MODEL_CACHE}" | cut -f1))"
else
  echo "ℹ️  Кеш e5 не найден — first-run скачает (~300MB)"
fi

# ── 3. переподпись app после вставки модели: Hardened Runtime + timestamp + entitlements ──
# Вложенный код (frameworks/dylibs/bundles) уже подписан в сборке с runtime+timestamp и не менялся;
# модель добавлена в Contents/Resources самого app, поэтому перепечатываем ТОЛЬКО верхний бандл.
codesign --force --timestamp --options runtime --entitlements "${ENTITLEMENTS}" --sign "${IDENTITY}" "${APP}"
codesign --verify --strict --verbose=2 "${APP}" && echo "✅ Подпись валидна (Developer ID + Hardened Runtime)"

# ── 4. нотаризация (Apple проверяет 5–15 мин) ──
mkdir -p dist
ZIP="dist/ZBSEye-notarized-$(date +%Y%m%d).zip"
ditto -c -k --keepParent "${APP}" "${ZIP}"
echo "▸ Отправляю в Apple notarytool (--wait, обычно 2–10 мин)…"
xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait

# ── 5. staple тикета в app + проверка Gatekeeper ──
xcrun stapler staple "${APP}"
echo "▸ Gatekeeper:"
spctl -a -vvv -t exec "${APP}" 2>&1 | grep -iE "accepted|rejected|source=" || true
# финальный zip — с уже застейпленным .app (получатель оффлайн пройдёт Gatekeeper)
rm -f "${ZIP}"; ditto -c -k --keepParent "${APP}" "${ZIP}"
echo ""
echo "✅ ${ZIP} — нотаризован + stapled."
echo "   Установка у получателя: распаковать в /Applications, запуск ДВОЙНЫМ КЛИКОМ (без «Open Anyway»)."
echo "   Права (Screen Recording / Accessibility / Mic) выдаются один раз; подпись стабильна — ребилды их НЕ ломают."
