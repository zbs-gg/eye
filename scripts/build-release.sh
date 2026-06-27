#!/bin/bash
# Release build of ZBSEye: Release configuration, stable "ZBS Eye Dev" signature (if the certificate
# was created by scripts/make-signing-cert.sh, otherwise ad-hoc with a warning), zip into dist/.
# No notarization (no $99 account). Install on the recipient's macOS 15+: launch → refused →
# System Settings → Privacy & Security → "Open Anyway" (right-click → Open no longer works).
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="ZBS Eye Dev"
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "⚠️  No \"$IDENTITY\" certificate — will sign ad-hoc (TCC permissions break on the next build)."
  echo "   For a stable signature: bash scripts/make-signing-cert.sh"
  IDENTITY="-"
fi

xcodegen generate
DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/ZBS Eye.app"
# Remove the old product BEFORE building: if xcodebuild fails, we must not silently package the previous .app.
rm -rf "$APP"

set +e
# CODE_SIGN_STYLE=Manual + empty DEVELOPMENT_TEAM: otherwise SPM dependencies (GRDB/swift-crypto/
# transformers) with an explicit identity require an Apple Team for automatic-signing → BUILD FAILED.
# With Manual they get signed by our self-signed "ZBS Eye Dev" without a team.
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  build 2>&1 | grep -E "error:|warning:|BUILD"
XC_STATUS=${PIPESTATUS[0]}
set -e
[ "$XC_STATUS" -eq 0 ] || { echo "❌ xcodebuild failed (exit $XC_STATUS)"; exit 1; }
[ -d "$APP" ] || { echo "❌ ZBS Eye.app did not build"; exit 1; }

# Bundle the e5 model into the app (if already downloaded): first-run without network and without a 300MB download.
MODEL_CACHE="$HOME/Library/Application Support/ZBS Eye/models/models/intfloat/multilingual-e5-small"
if [ -d "$MODEL_CACHE" ]; then
  # Path in the bundle = Bundle.resourceURL + "models/intfloat/multilingual-e5-small" (EmbeddingService.repo).
  # WITHOUT a double models/ (that's the HubApi cache layout, not the bundle's) — otherwise copyBundledModelIfNeeded won't find it
  # and first-run silently goes to the network despite "✅ bundled".
  mkdir -p "$APP/Contents/Resources/models/intfloat"
  ditto "$MODEL_CACHE" "$APP/Contents/Resources/models/intfloat/multilingual-e5-small"
  # resources changed → re-sign. WITHOUT a silent ad-hoc fallback: ad-hoc breaks TCC
  # stability, and "✅" would print anyway. On re-sign failure — abort explicitly.
  if ! codesign --force --sign "$IDENTITY" "$APP"; then
    echo "❌ Re-signing '$IDENTITY' after bundling the model failed (keychain locked?)."
    echo "   NOT signing ad-hoc silently — that would break TCC. Unlock the keychain and re-run."
    exit 1
  fi
  echo "✅ e5 model bundled into the app ($(du -sh "$MODEL_CACHE" | cut -f1)) — first-run offline"
else
  echo "ℹ️  e5 cache not found — the app will download the model on the first search (~300MB)"
fi

codesign --verify --strict "$APP" && echo "✅ Signature valid ($IDENTITY)"

mkdir -p dist
ZIP="dist/ZBSEye-$(date +%Y%m%d).zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✅ $ZIP ($(du -h "$ZIP" | cut -f1))"
echo ""
echo "Install on the recipient: unpack into /Applications."
echo "  macOS 15+: launch → refused → System Settings → Privacy & Security → \"Open Anyway\"."
echo "  macOS ≤14: right-click → Open. For techies: xattr -dr com.apple.quarantine /Applications/ZBS Eye.app"
echo ""
echo "⚠️  If the previous build was signed differently (ad-hoc → \"ZBS Eye Dev\"), macOS will ONCE reset"
echo "   TCC permissions: in System Settings → Privacy & Security TURN OFF and back on ZBSEye in"
echo "   Screen Recording (the toggle looks enabled — re-toggling is mandatory), then Microphone."
