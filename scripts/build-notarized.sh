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
EXPECTED_TEAM="44N4NZ86S5"
EXPECTED_BUNDLE_ID="gg.zbs.eye"
DERIVED="${ZBSEYE_NOTARIZED_DERIVED_DATA_PATH:-build/NotarizedDerivedData}"
ARCHIVE="build/ZBSEye.xcarchive"
EXPORT_DIR="build/DeveloperIDExport"
EXPORT_OPTIONS="build/ExportOptions-DeveloperID.plist"
EXPORT_METHOD="developer-id"
APP="$EXPORT_DIR/ZBS Eye.app"

[ -z "${XCODE_XCCONFIG_FILE:-}" ] || {
  echo "❌ XCODE_XCCONFIG_FILE must be unset for a qualified release build."
  exit 1
}

# Provenance must be proven before project generation or archive work can
# mutate ignored build output. This gate freshly fetches canonical main/tags.
PREFLIGHT_OUTPUT=$(bash scripts/release-preflight.sh)
printf '%s\n' "${PREFLIGHT_OUTPUT}"
QUALIFIED_IDENTITY=""
while IFS= read -r line; do
  case "${line}" in
    ZBSEYE_RELEASE_PREFLIGHT_IDENTITY=*) QUALIFIED_IDENTITY="${line#*=}" ;;
  esac
done <<< "${PREFLIGHT_OUTPUT}"
[ -n "${QUALIFIED_IDENTITY}" ] || {
  echo "❌ Release preflight did not return a qualified identity."
  exit 1
}
IFS=: read -r QUALIFIED_VERSION QUALIFIED_BUILD QUALIFIED_REVISION <<< "${QUALIFIED_IDENTITY}"

SOURCE_REVISION=$(git rev-parse --verify HEAD)
[ "${SOURCE_REVISION}" = "${QUALIFIED_REVISION}" ] || {
  echo "❌ Candidate HEAD changed after release preflight."
  exit 1
}
SOURCE_SHORT=$(git rev-parse --short=12 HEAD)

# ── 0. find the Developer ID identity + team from the keychain ──
DEVID_LINES=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" \
  | grep "(${EXPECTED_TEAM})" || true)
DEVID_COUNT=$(printf '%s\n' "${DEVID_LINES}" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "${DEVID_COUNT}" -ne 1 ]; then
  echo "❌ Expected exactly one Developer ID Application identity for team ${EXPECTED_TEAM}; found ${DEVID_COUNT}."
  exit 1
fi
DEVID_LINE="${DEVID_LINES}"
if [ -z "${DEVID_LINE}" ]; then
  echo "❌ No \"Developer ID Application\" cert in the keychain."
  echo "   You currently have \"Apple Development\" — that's a DIFFERENT type, you can't notarize with it."
  echo "   Get an Apple Developer Program (\$99) and create a Developer ID cert. Steps: docs/NOTARIZE.md"
  exit 1
fi
IDENTITY=$(echo "${DEVID_LINE}" | sed -E 's/.*"(Developer ID Application: [^"]+)".*/\1/')
TEAM=$(echo "${IDENTITY}" | sed -E 's/.*\(([A-Z0-9]+)\)".*/\1/; s/.*\(([A-Z0-9]+)\)$/\1/')
[ "${TEAM}" = "${EXPECTED_TEAM}" ] || { echo "❌ Unexpected signing team ${TEAM}."; exit 1; }
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
xcodebuild -resolvePackageDependencies \
  -project ZBSEye.xcodeproj -scheme ZBSEye \
  -derivedDataPath "${DERIVED}" \
  -onlyUsePackageVersionsFromResolvedFile
TRANSCRIBE_FRAMEWORK="${DERIVED}/SourcePackages/artifacts/zbseyewhisper/CTranscribe/TranscribeCpp.xcframework/macos-arm64_x86_64/CTranscribe.framework"
bash scripts/repair-transcribe-framework.sh "${TRANSCRIBE_FRAMEWORK}"
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
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP}/Contents/Info.plist")
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist")
[ "${VERSION}" = "${QUALIFIED_VERSION}" ] && [ "${BUILD_NUMBER}" = "${QUALIFIED_BUILD}" ] || {
  echo "❌ Exported app identity ${VERSION} (${BUILD_NUMBER}) differs from preflight-qualified ${QUALIFIED_VERSION} (${QUALIFIED_BUILD})."
  exit 1
}
[ "${BUNDLE_ID}" = "${EXPECTED_BUNDLE_ID}" ] || {
  echo "❌ Exported app bundle identifier ${BUNDLE_ID} differs from ${EXPECTED_BUNDLE_ID}."
  exit 1
}
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
MANIFEST_PLIST=""
trap 'rm -f "${SIGNED_ENTITLEMENTS}" "${MANIFEST_PLIST:-}"' EXIT
codesign -d --entitlements :- "${APP}" > "${SIGNED_ENTITLEMENTS}" 2>/dev/null
EXPECTED_ACCESS_GROUP="${TEAM}.gg.zbs.eye"
ACTUAL_ACCESS_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "${SIGNED_ENTITLEMENTS}" 2>/dev/null || true)
[ "${ACTUAL_ACCESS_GROUP}" = "${EXPECTED_ACCESS_GROUP}" ] || {
  echo "❌ Signed app is missing the provisioned Keychain access group ${EXPECTED_ACCESS_GROUP}."
  exit 1
}
ACTUAL_AUDIO_INPUT=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "${SIGNED_ENTITLEMENTS}" 2>/dev/null || true)
[ "${ACTUAL_AUDIO_INPUT}" = "true" ] || {
  echo "❌ Signed app is missing com.apple.security.device.audio-input=true."
  exit 1
}
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "${SIGNED_ENTITLEMENTS}" >/dev/null 2>&1; then
  echo "❌ Release app must not carry com.apple.security.get-task-allow."
  exit 1
fi
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "${SIGNED_ENTITLEMENTS}" >/dev/null 2>&1; then
  echo "❌ Release app must not enable App Sandbox."
  exit 1
fi

SIGNING_DETAILS=$(codesign -dvv "${APP}" 2>&1)
if [[ "${SIGNING_DETAILS}" != *"TeamIdentifier=${EXPECTED_TEAM}"* ]]; then
  echo "❌ Final app TeamIdentifier is not ${EXPECTED_TEAM}."
  exit 1
fi
if [[ "${SIGNING_DETAILS}" != *"flags="*"runtime"* ]]; then
  echo "❌ Final app is missing Hardened Runtime."
  exit 1
fi
CANDIDATE_REQUIREMENT=$(codesign -d -r- "${APP}" 2>&1 | sed -n 's/^designated => //p')
[ -n "${CANDIDATE_REQUIREMENT}" ] || { echo "❌ Could not read the candidate designated requirement."; exit 1; }
if [ -d "/Applications/ZBS Eye.app" ]; then
  INSTALLED_REQUIREMENT=$(codesign -d -r- "/Applications/ZBS Eye.app" 2>&1 | sed -n 's/^designated => //p')
  [ "${INSTALLED_REQUIREMENT}" = "${CANDIDATE_REQUIREMENT}" ] || {
    echo "❌ Candidate designated requirement differs from the installed stable identity."
    exit 1
  }
fi

# ── 4. notarization (Apple checks for 5–15 min) ──
mkdir -p dist
ARTIFACT_STEM="ZBSEye-${VERSION}-${BUILD_NUMBER}-${SOURCE_SHORT}-notarized"
ZIP="dist/${ARTIFACT_STEM}.zip"
MANIFEST="dist/${ARTIFACT_STEM}.manifest.json"
SUBMISSION_ZIP="build/${ARTIFACT_STEM}-submission.zip"
[ ! -e "${ZIP}" ] && [ ! -e "${MANIFEST}" ] || {
  echo "❌ Refusing to overwrite an existing release artifact for this source revision."
  exit 1
}
rm -f "${SUBMISSION_ZIP}"
# Close the long-build TOCTOU window before any bytes leave the Mac. This also
# rechecks that the candidate tag has not appeared since the first preflight.
FINAL_PREFLIGHT_OUTPUT=$(bash scripts/release-preflight.sh --verify-only)
printf '%s\n' "${FINAL_PREFLIGHT_OUTPUT}"
FINAL_QUALIFIED_IDENTITY=""
while IFS= read -r line; do
  case "${line}" in
    ZBSEYE_RELEASE_PREFLIGHT_IDENTITY=*) FINAL_QUALIFIED_IDENTITY="${line#*=}" ;;
  esac
done <<< "${FINAL_PREFLIGHT_OUTPUT}"
[ "${FINAL_QUALIFIED_IDENTITY}" = "${QUALIFIED_IDENTITY}" ] || {
  echo "❌ Release identity changed during the qualified build."
  exit 1
}
ditto -c -k --keepParent "${APP}" "${SUBMISSION_ZIP}"
echo "▸ Submitting to Apple notarytool (--wait, usually 2–10 min)…"
RELEASE_EVIDENCE_ROOT="${ZBSEYE_RELEASE_EVIDENCE_DIR:-${HOME}/Library/Application Support/ZBS Eye Maintainer/Release Evidence}"
PREVIOUS_UMASK=$(umask)
umask 077
mkdir -p "${RELEASE_EVIDENCE_ROOT}"
chmod 700 "${RELEASE_EVIDENCE_ROOT}"
EVIDENCE_DIR="${RELEASE_EVIDENCE_ROOT}/${ARTIFACT_STEM}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -m 700 "${EVIDENCE_DIR}"
NOTARY_SUBMISSION_JSON="${EVIDENCE_DIR}/notary-submission.json"
NOTARY_LOG="${EVIDENCE_DIR}/notary-log.json"

set +e
xcrun notarytool submit "${SUBMISSION_ZIP}" \
  --keychain-profile "${NOTARY_PROFILE}" \
  --wait \
  --output-format json > "${NOTARY_SUBMISSION_JSON}"
NOTARY_SUBMIT_STATUS=$?
set -e
chmod 600 "${NOTARY_SUBMISSION_JSON}"
cat "${NOTARY_SUBMISSION_JSON}"
[ "${NOTARY_SUBMIT_STATUS}" -eq 0 ] || {
  echo "❌ notarytool submit failed (exit ${NOTARY_SUBMIT_STATUS}). Evidence retained at ${EVIDENCE_DIR}"
  exit 1
}

NOTARY_STATUS=$(/usr/bin/plutil -extract status raw -expect string -o - "${NOTARY_SUBMISSION_JSON}" 2>/dev/null || true)
NOTARY_SUBMISSION_ID=$(/usr/bin/plutil -extract id raw -expect string -o - "${NOTARY_SUBMISSION_JSON}" 2>/dev/null || true)
[ "${NOTARY_STATUS}" = "Accepted" ] || {
  echo "❌ Apple notarization status is ${NOTARY_STATUS:-missing}, expected Accepted. Evidence retained at ${EVIDENCE_DIR}"
  exit 1
}
[ -n "${NOTARY_SUBMISSION_ID}" ] || {
  echo "❌ Accepted notary response did not contain a submission ID. Evidence retained at ${EVIDENCE_DIR}"
  exit 1
}

xcrun notarytool log \
  --keychain-profile "${NOTARY_PROFILE}" \
  "${NOTARY_SUBMISSION_ID}" \
  "${NOTARY_LOG}"
chmod 600 "${NOTARY_LOG}"
[ -s "${NOTARY_LOG}" ] || {
  echo "❌ Apple returned an empty notarization log. Evidence retained at ${EVIDENCE_DIR}"
  exit 1
}
NOTARY_EVIDENCE=$(bash scripts/validate-notary-evidence.sh "${NOTARY_SUBMISSION_JSON}" "${NOTARY_LOG}") || {
  echo "❌ Apple notarization evidence failed validation. Evidence retained at ${EVIDENCE_DIR}"
  exit 1
}
IFS=$'\t' read -r VALIDATED_NOTARY_STATUS VALIDATED_SUBMISSION_ID NOTARY_LOG_SHA256 <<< "${NOTARY_EVIDENCE}"
[ "${VALIDATED_NOTARY_STATUS}" = "${NOTARY_STATUS}" ] && \
  [ "${VALIDATED_SUBMISSION_ID}" = "${NOTARY_SUBMISSION_ID}" ] || {
  echo "❌ Apple submission and reviewed log identity disagree. Evidence retained at ${EVIDENCE_DIR}"
  exit 1
}
umask "${PREVIOUS_UMASK}"
echo "✅ Apple notarization Accepted (${NOTARY_SUBMISSION_ID})."
echo "✅ Private release evidence retained at ${EVIDENCE_DIR}"

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
if [[ "${GATEKEEPER_OUTPUT}" != *"accepted"* ]]; then
  echo "❌ Gatekeeper did not report an accepted app."
  exit 1
fi
# final zip — with the already-stapled .app (an offline recipient passes Gatekeeper)
ditto -c -k --keepParent "${APP}" "${ZIP}"
ZIP_SHA256=$(shasum -a 256 "${ZIP}" | awk '{print $1}')
EXECUTABLE="${APP}/Contents/MacOS/ZBS Eye"
EXECUTABLE_SHA256=$(shasum -a 256 "${EXECUTABLE}" | awk '{print $1}')
CDHASH=$(codesign -dvvv "${APP}" 2>&1 | sed -n 's/^CDHash=//p')
[ -n "${CDHASH}" ] || {
  echo "❌ Could not read the candidate CDHash."
  exit 1
}
MANIFEST_PLIST="${MANIFEST}.plist.tmp"
rm -f "${MANIFEST_PLIST}"
/usr/bin/plutil -create xml1 "${MANIFEST_PLIST}"
/usr/bin/plutil -insert artifact -string "$(basename "${ZIP}")" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert version -string "${VERSION}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert build -string "${BUILD_NUMBER}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert bundleIdentifier -string "${BUNDLE_ID}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert sourceRevision -string "${SOURCE_REVISION}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert sourceTreeState -string clean "${MANIFEST_PLIST}"
/usr/bin/plutil -insert teamIdentifier -string "${EXPECTED_TEAM}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert cdHash -string "${CDHASH}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert designatedRequirement -string "${CANDIDATE_REQUIREMENT}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert zipSHA256 -string "${ZIP_SHA256}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert executableSHA256 -string "${EXECUTABLE_SHA256}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert notaryStatus -string "${NOTARY_STATUS}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert notarySubmissionID -string "${NOTARY_SUBMISSION_ID}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert notaryLogSHA256 -string "${NOTARY_LOG_SHA256}" "${MANIFEST_PLIST}"
/usr/bin/plutil -insert hardenedRuntime -bool YES "${MANIFEST_PLIST}"
/usr/bin/plutil -insert audioInputEntitlement -bool YES "${MANIFEST_PLIST}"
/usr/bin/plutil -insert appSandbox -bool NO "${MANIFEST_PLIST}"
/usr/bin/plutil -insert getTaskAllow -bool NO "${MANIFEST_PLIST}"
/usr/bin/plutil -insert notarized -bool YES "${MANIFEST_PLIST}"
/usr/bin/plutil -insert stapled -bool YES "${MANIFEST_PLIST}"
/usr/bin/plutil -insert gatekeeperAccepted -bool YES "${MANIFEST_PLIST}"
/usr/bin/plutil -convert json -o "${MANIFEST}" "${MANIFEST_PLIST}"
rm -f "${MANIFEST_PLIST}"
MANIFEST_PLIST=""
rm -f "${SUBMISSION_ZIP}"
echo ""
echo "✅ ${ZIP} — notarized + stapled."
echo "✅ ${MANIFEST} — exact candidate identity and hashes."
echo "   Install on the recipient: unpack into /Applications, launch by DOUBLE-CLICK (no \"Open Anyway\")."
echo "   Permissions (Screen Recording / Accessibility / Mic) are granted once; the signature is stable — rebuilds do NOT break them."
