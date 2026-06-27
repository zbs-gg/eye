#!/bin/bash
# Verify build of ZBS Eye for the orchestrator / agent loops (a "done/not done" build gate).
# The pattern mirrors scripts/build-release.sh: xcodegen generate → xcodebuild
# (PIPESTATUS-gated, can't trust grep's exit code) → check that "ZBS Eye.app"
# is actually in DerivedData (and isn't left over from a previous build — hence the rm BEFORE).
# Differences from release: Debug configuration, ad-hoc signing, no model bundling and no zip.
# SwiftLint — advisory ONLY: prints a count, never blocks.
# Final: a line in ~/.claude/verify-log.jsonl per the schema
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

xcodegen generate || fail "xcodegen generate failed"

DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Debug/ZBS Eye.app"
# Remove the old product BEFORE building: if xcodebuild fails we must not silently
# count the previous .app as "built".
rm -rf "$APP"

set +e
# CODE_SIGN_STYLE=Manual + empty DEVELOPMENT_TEAM — as in build-release.sh:
# SPM dependencies (GRDB/swift-crypto/transformers) with automatic-signing
# require an Apple Team → BUILD FAILED. With Manual they get ad-hoc signed without a team.
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Debug \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  build 2>&1 | grep -E "error:|warning:|BUILD"
XC_STATUS=${PIPESTATUS[0]}
set -e
[ "$XC_STATUS" -eq 0 ] || fail "xcodebuild failed (exit $XC_STATUS)"
[ -d "$APP" ] || fail "ZBS Eye.app did not appear in $APP"

# SwiftLint — advisory only. NEVER blocks: swiftlint returns
# non-zero on error-severity findings, so the whole call is under || true.
# Scoped only to our own sources: without paths it lints build/DerivedData
# with all the SPM checkouts — tens of thousands of foreign warnings, pure noise.
if command -v swiftlint >/dev/null 2>&1; then
  LINT_COUNT=$(swiftlint lint --quiet ZBSEyeApp Packages 2>/dev/null | grep -c ': \(warning\|error\):' || true)
  echo "ℹ️  SwiftLint (advisory, non-blocking): ${LINT_COUNT} findings"
else
  echo "ℹ️  SwiftLint not installed — skipping (advisory)"
fi

ledger pass
echo "✅ verify green: $APP ($(( $(date +%s) - START ))s)"
