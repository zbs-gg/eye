#!/bin/bash
# Build → Developer ID signing → Hardened Runtime → Apple NOTARIZATION → staple.
# Goal: distribution OUTSIDE the App Store (like Rewind / screenpipe — the App Store is incompatible with cross-app AX under sandbox).
# A notarized build passes Gatekeeper CLEANLY (double-click launch, no "Open Anyway") and the signature
# is STABLE — all the self-signed cdhash/TCC churn is gone.
#
# REQUIRES once (see docs/NOTARIZE.md):
#   1. A paid Apple Developer Program ($99/year).
#   2. A "Developer ID Application" cert in the keychain (NOT "Apple Development"! that's a different type).
#   3. A notarytool profile:
#        xcrun notarytool store-credentials zbseye-notary \
#          --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
#
# Overridable: ZBSEYE_NOTARY_PROFILE (notarytool profile name).
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${ZBSEYE_NOTARY_PROFILE:-zbseye-notary}"
ENTITLEMENTS="ZBSEyeApp/ZBSEye.entitlements"
DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/ZBS Eye.app"

# ── 0. find the Developer ID identity + team from the keychain ──
DEVID_LINE=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 || true)
if [ -z "${DEVID_LINE}" ]; then
  echo "❌ No \"Developer ID Application\" cert in the keychain."
  echo "   You currently have \"Apple Development\" — that's a DIFFERENT type, you can't notarize with it."
  echo "   Get an Apple Developer Program (\$99) and create a Developer ID cert. Steps: docs/NOTARIZE.md"
  exit 1
fi
IDENTITY=$(echo "${DEVID_LINE}" | sed -E 's/.*"(Developer ID Application: [^"]+)".*/\1/')
TEAM=$(echo "${IDENTITY}" | sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/; s/.*\(([A-Z0-9]+)\)$/\1/')
echo "▸ Signature: ${IDENTITY}  (team ${TEAM})"

# check the notarytool profile BEFORE the long build
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  echo "❌ notarytool profile \"${NOTARY_PROFILE}\" is not configured (or the credentials expired)."
  echo "   xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <id> --team-id ${TEAM} --password <app-spec-pwd>"
  echo "   Details: docs/NOTARIZE.md"
  exit 1
fi

# ── 1. Release build + Hardened Runtime (--options runtime) + secure timestamp ──
xcodegen generate
rm -rf "${APP}"
set +e
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Release \
  -derivedDataPath "${DERIVED}" \
  CODE_SIGN_IDENTITY="${IDENTITY}" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="${TEAM}" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  build 2>&1 | grep -E "error:|warning:|BUILD"
XC=${PIPESTATUS[0]}; set -e
[ "${XC}" -eq 0 ] || { echo "❌ xcodebuild failed (exit ${XC})"; exit 1; }
[ -d "${APP}" ] || { echo "❌ \"ZBS Eye.app\" did not build"; exit 1; }

# ── 2. bundle the e5 model into the app (as in build-release.sh) — first-run offline ──
MODEL_CACHE="${HOME}/Library/Application Support/ZBS Eye/models/models/intfloat/multilingual-e5-small"
if [ -d "${MODEL_CACHE}" ]; then
  mkdir -p "${APP}/Contents/Resources/models/intfloat"
  ditto "${MODEL_CACHE}" "${APP}/Contents/Resources/models/intfloat/multilingual-e5-small"
  echo "✅ e5 model bundled ($(du -sh "${MODEL_CACHE}" | cut -f1))"
else
  echo "ℹ️  e5 cache not found — first-run will download (~300MB)"
fi

# ── 3. re-sign the app after inserting the model: Hardened Runtime + timestamp + entitlements ──
# Nested code (frameworks/dylibs/bundles) is already signed in the build with runtime+timestamp and hasn't changed;
# the model was added to Contents/Resources of the app itself, so we re-stamp ONLY the top bundle.
codesign --force --timestamp --options runtime --entitlements "${ENTITLEMENTS}" --sign "${IDENTITY}" "${APP}"
codesign --verify --strict --verbose=2 "${APP}" && echo "✅ Signature valid (Developer ID + Hardened Runtime)"

# ── 4. notarization (Apple checks for 5–15 min) ──
mkdir -p dist
ZIP="dist/ZBSEye-notarized-$(date +%Y%m%d).zip"
ditto -c -k --keepParent "${APP}" "${ZIP}"
echo "▸ Submitting to Apple notarytool (--wait, usually 2–10 min)…"
xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait

# ── 5. staple the ticket into the app + Gatekeeper check ──
xcrun stapler staple "${APP}"
echo "▸ Gatekeeper:"
spctl -a -vvv -t exec "${APP}" 2>&1 | grep -iE "accepted|rejected|source=" || true
# final zip — with the already-stapled .app (an offline recipient passes Gatekeeper)
rm -f "${ZIP}"; ditto -c -k --keepParent "${APP}" "${ZIP}"
echo ""
echo "✅ ${ZIP} — notarized + stapled."
echo "   Install on the recipient: unpack into /Applications, launch by DOUBLE-CLICK (no \"Open Anyway\")."
echo "   Permissions (Screen Recording / Accessibility / Mic) are granted once; the signature is stable — rebuilds do NOT break them."
