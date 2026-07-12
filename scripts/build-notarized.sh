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
DERIVED="build/DerivedData"
ARCHIVE="build/ZBSEye.xcarchive"
EXPORT_DIR="build/DeveloperIDExport"
EXPORT_OPTIONS="build/ExportOptions-DeveloperID.plist"
EXPORT_METHOD="developer-id"
APP="$EXPORT_DIR/ZBS Eye.app"

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

# ── 1. Archive with Xcode-managed capabilities, then export as Developer ID ──
xcodegen generate
rm -rf "${ARCHIVE}" "${EXPORT_DIR}" "${EXPORT_OPTIONS}"
set +e
xcodebuild archive -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Release \
  -archivePath "${ARCHIVE}" \
  -derivedDataPath "${DERIVED}" \
  -onlyUsePackageVersionsFromResolvedFile \
  -allowProvisioningUpdates \
  CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="${TEAM}" \
  ENABLE_HARDENED_RUNTIME=YES \
  2>&1 | grep -E "error:|warning:|ARCHIVE"
XC=${PIPESTATUS[0]}; set -e
[ "${XC}" -eq 0 ] || { echo "❌ xcodebuild archive failed (exit ${XC})"; exit 1; }

plutil -create xml1 "${EXPORT_OPTIONS}"
plutil -insert method -string "${EXPORT_METHOD}" "${EXPORT_OPTIONS}"
plutil -insert signingStyle -string automatic "${EXPORT_OPTIONS}"
plutil -insert teamID -string "${TEAM}" "${EXPORT_OPTIONS}"
plutil -insert stripSwiftSymbols -bool YES "${EXPORT_OPTIONS}"
xcodebuild -exportArchive \
  -archivePath "${ARCHIVE}" \
  -exportPath "${EXPORT_DIR}" \
  -exportOptionsPlist "${EXPORT_OPTIONS}" \
  -allowProvisioningUpdates

[ -d "${APP}" ] || { echo "❌ \"ZBS Eye.app\" did not build"; exit 1; }
PROFILE="${APP}/Contents/embedded.provisionprofile"
[ -f "${PROFILE}" ] || {
  echo "❌ Xcode did not embed a Developer ID provisioning profile."
  echo "   Enable Keychain Sharing for gg.zbs.eye in the Apple Developer portal, then retry."
  exit 1
}

# ── 2. bundle the e5 model into the app (as in build-release.sh) — first-run offline ──
MODEL_CACHE="${HOME}/Library/Application Support/ZBS Eye/models/models/intfloat/multilingual-e5-small"
if [ -d "${MODEL_CACHE}" ]; then
  mkdir -p "${APP}/Contents/Resources/models/intfloat"
  ditto "${MODEL_CACHE}" "${APP}/Contents/Resources/models/intfloat/multilingual-e5-small"
  echo "✅ e5 model bundled ($(du -sh "${MODEL_CACHE}" | cut -f1))"
else
  echo "ℹ️  e5 cache not found — first-run will download (~300MB)"
fi

# ── 3. re-sign the app after inserting the model: preserve provisioned entitlements ──
# Nested code (frameworks/dylibs/bundles) is already signed in the build with runtime+timestamp and hasn't changed;
# the model was added to Contents/Resources of the app itself, so we re-stamp ONLY the top bundle.
codesign --force --timestamp --options runtime \
  --preserve-metadata=entitlements,requirements \
  --sign "${IDENTITY}" "${APP}"
codesign --verify --strict --verbose=2 "${APP}" && echo "✅ Signature valid (Developer ID + Hardened Runtime)"

SIGNED_ENTITLEMENTS=$(mktemp)
trap 'rm -f "${SIGNED_ENTITLEMENTS}"' EXIT
codesign -d --entitlements :- "${APP}" > "${SIGNED_ENTITLEMENTS}" 2>/dev/null
EXPECTED_ACCESS_GROUP="${TEAM}.gg.zbs.eye"
ACTUAL_ACCESS_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "${SIGNED_ENTITLEMENTS}" 2>/dev/null || true)
[ "${ACTUAL_ACCESS_GROUP}" = "${EXPECTED_ACCESS_GROUP}" ] || {
  echo "❌ Signed app is missing the provisioned Keychain access group ${EXPECTED_ACCESS_GROUP}."
  exit 1
}

# ── 4. notarization (Apple checks for 5–15 min) ──
mkdir -p dist
ZIP="dist/ZBSEye-notarized-$(date +%Y%m%d).zip"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"
echo "▸ Submitting to Apple notarytool (--wait, usually 2–10 min)…"
xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait

# ── 5. staple the ticket into the app + Gatekeeper check ──
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"
echo "▸ Gatekeeper:"
GATEKEEPER_OUTPUT=$(spctl -a -vvv -t exec "${APP}" 2>&1) || {
  echo "${GATEKEEPER_OUTPUT}"
  echo "❌ Gatekeeper rejected the notarized app."
  exit 1
}
echo "${GATEKEEPER_OUTPUT}"
echo "${GATEKEEPER_OUTPUT}" | grep -qi "accepted" || {
  echo "❌ Gatekeeper did not report an accepted app."
  exit 1
}
# final zip — with the already-stapled .app (an offline recipient passes Gatekeeper)
rm -f "${ZIP}"; ditto -c -k --keepParent "${APP}" "${ZIP}"
echo ""
echo "✅ ${ZIP} — notarized + stapled."
echo "   Install on the recipient: unpack into /Applications, launch by DOUBLE-CLICK (no \"Open Anyway\")."
echo "   Permissions (Screen Recording / Accessibility / Mic) are granted once; the signature is stable — rebuilds do NOT break them."
