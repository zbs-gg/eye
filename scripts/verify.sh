#!/bin/bash
# Verify-сборка ZBS Eye для оркестратора / агент-лупов (build-гейт «сделано/не сделано»).
# Паттерн повторяет scripts/build-release.sh: xcodegen generate → xcodebuild
# (PIPESTATUS-gated, нельзя доверять exit-коду grep) → проверка, что «ZBS Eye.app»
# реально лежит в DerivedData (а не остался от прошлой сборки — поэтому rm ДО).
# Отличия от релиза: Debug-конфигурация, ad-hoc подпись, без упаковки модели и zip.
# SwiftLint — ТОЛЬКО advisory: печатает счётчик, никогда не блокирует.
# Финал: строка в ~/.claude/verify-log.jsonl по схеме
#   {"ts","workspace","repo","loop","kind","outcome","ref"}.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_DIR="$(pwd)"
LEDGER="$HOME/.claude/verify-log.jsonl"
REF="$(git rev-parse --short HEAD 2>/dev/null || echo "no-git")"
START=$(date +%s)

ledger() { # $1 = outcome (pass|fail)
  printf '{"ts":"%s","workspace":"%s","repo":"zbseye","loop":"verify","kind":"repo-verify","outcome":"%s","ref":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REPO_DIR" "$1" "$REF" >> "$LEDGER"
}

fail() {
  echo "❌ $1"
  ledger fail
  exit 1
}

xcodegen generate || fail "xcodegen generate провалился"

DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Debug/ZBS Eye.app"
# Старый продукт убрать ДО сборки: при провале xcodebuild нельзя молча
# засчитать прошлый .app как «собрался».
rm -rf "$APP"

set +e
# CODE_SIGN_STYLE=Manual + пустой DEVELOPMENT_TEAM — как в build-release.sh:
# SPM-зависимости (GRDB/swift-crypto/transformers) при automatic-signing
# требуют Apple Team → BUILD FAILED. С Manual ad-hoc подписываются без команды.
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Debug \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  build 2>&1 | grep -E "error:|warning:|BUILD"
XC_STATUS=${PIPESTATUS[0]}
set -e
[ "$XC_STATUS" -eq 0 ] || fail "xcodebuild провалился (exit $XC_STATUS)"
[ -d "$APP" ] || fail "ZBS Eye.app не появился в $APP"

# SwiftLint — advisory only. Не блокирует НИКОГДА: swiftlint возвращает
# non-zero при error-severity находках, поэтому весь вызов под || true.
# Скоуп только на собственные исходники: без путей линтуется build/DerivedData
# со всеми SPM-чекаутами — десятки тысяч чужих замечаний, чистый шум.
if command -v swiftlint >/dev/null 2>&1; then
  LINT_COUNT=$(swiftlint lint --quiet ZBSEyeApp Packages 2>/dev/null | grep -c ': \(warning\|error\):' || true)
  echo "ℹ️  SwiftLint (advisory, не блокирует): ${LINT_COUNT} замечаний"
else
  echo "ℹ️  SwiftLint не установлен — пропускаю (advisory)"
fi

ledger pass
echo "✅ verify зелёный: $APP ($(( $(date +%s) - START ))s)"
