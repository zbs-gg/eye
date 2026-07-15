#!/bin/bash
# Verify downloaded release bytes against both the manifest and ZBS Eye's
# independently pinned Developer ID identity. No wildcard/"newest" selection.
set -euo pipefail

EXPECTED_TEAM="44N4NZ86S5"
EXPECTED_BUNDLE_ID="gg.zbs.eye"

fail() {
  echo "❌ Release artifact verification failed: $*" >&2
  exit 1
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || \
  fail "usage: verify-release-artifact.sh <exact.zip> <exact.manifest.json> [trusted-local.manifest.json]"
ZIP="$1"
MANIFEST="$2"
TRUSTED_MANIFEST="${3:-}"
[ -f "${ZIP}" ] || fail "ZIP does not exist: ${ZIP}"
[ -f "${MANIFEST}" ] || fail "manifest does not exist: ${MANIFEST}"
if [ -n "${TRUSTED_MANIFEST}" ]; then
  [ -f "${TRUSTED_MANIFEST}" ] || fail "trusted manifest does not exist: ${TRUSTED_MANIFEST}"
  cmp -s "${MANIFEST}" "${TRUSTED_MANIFEST}" || fail "downloaded manifest differs from the qualified local manifest."
fi

manifest_string() {
  /usr/bin/plutil -extract "$1" raw -expect string -o - "${MANIFEST}" 2>/dev/null || \
    fail "manifest field $1 is missing or not a string."
}

ARTIFACT=$(manifest_string artifact)
VERSION=$(manifest_string version)
BUILD_NUMBER=$(manifest_string build)
SOURCE_REVISION=$(manifest_string sourceRevision)
TEAM_IDENTIFIER=$(manifest_string teamIdentifier)
MANIFEST_CDHASH=$(manifest_string cdHash)
MANIFEST_REQUIREMENT=$(manifest_string designatedRequirement)
ZIP_SHA256=$(manifest_string zipSHA256)
EXECUTABLE_SHA256=$(manifest_string executableSHA256)
NOTARY_STATUS=$(manifest_string notaryStatus)
NOTARY_SUBMISSION_ID=$(manifest_string notarySubmissionID)
NOTARY_LOG_SHA256=$(manifest_string notaryLogSHA256)

[ "${ARTIFACT}" = "$(basename "${ZIP}")" ] || fail "manifest artifact does not name the supplied ZIP."
[ "${TEAM_IDENTIFIER}" = "${EXPECTED_TEAM}" ] || fail "manifest TeamIdentifier is not ${EXPECTED_TEAM}."
[ "${NOTARY_STATUS}" = "Accepted" ] || fail "manifest notarization status is not Accepted."
[[ "${SOURCE_REVISION}" =~ ^[0-9a-f]{40}$ ]] || fail "manifest sourceRevision is not a full Git SHA."
[[ "${ZIP_SHA256}" =~ ^[0-9a-f]{64}$ ]] || fail "manifest ZIP digest is invalid."
[[ "${EXECUTABLE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || fail "manifest executable digest is invalid."
[[ "${NOTARY_LOG_SHA256}" =~ ^[0-9a-f]{64}$ ]] || fail "manifest notary-log digest is invalid."
[ -n "${NOTARY_SUBMISSION_ID}" ] || fail "manifest notary submission ID is empty."

ACTUAL_ZIP_SHA256=$(shasum -a 256 "${ZIP}" | awk '{print $1}')
[ "${ACTUAL_ZIP_SHA256}" = "${ZIP_SHA256}" ] || fail "ZIP SHA-256 differs from manifest."

# Reject path traversal and every payload outside the one expected app bundle
# before extraction. The release ZIP is an app transport, not a general archive.
ARCHIVE_ENTRY_COUNT=0
while IFS= read -r entry; do
  [ -n "${entry}" ] || fail "ZIP contains an empty archive entry name."
  ARCHIVE_ENTRY_COUNT=$((ARCHIVE_ENTRY_COUNT + 1))
  case "${entry}" in
    "ZBS Eye.app/"|"ZBS Eye.app/"*) ;;
    *) fail "ZIP contains an unexpected archive entry outside ZBS Eye.app." ;;
  esac
  case "/${entry}" in
    *"/../"*|*"/.."|*"\\"*) fail "ZIP contains an unsafe archive entry path." ;;
  esac
done < <(/usr/bin/unzip -Z1 "${ZIP}")
[ "${ARCHIVE_ENTRY_COUNT}" -gt 0 ] || fail "ZIP contains no archive entries."

VERIFY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zbseye-release-verify.XXXXXX")
trap 'rm -rf "${VERIFY_DIR}"' EXIT
ditto -x -k "${ZIP}" "${VERIFY_DIR}"
APP="${VERIFY_DIR}/ZBS Eye.app"
EXECUTABLE="${APP}/Contents/MacOS/ZBS Eye"
[ -d "${APP}" ] && [ ! -L "${APP}" ] && [ -f "${EXECUTABLE}" ] || \
  fail "ZIP does not contain one real ZBS Eye.app bundle."

ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")
ACTUAL_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP}/Contents/Info.plist")
ACTUAL_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist")
[ "${ACTUAL_VERSION}" = "${VERSION}" ] && [ "${ACTUAL_BUILD}" = "${BUILD_NUMBER}" ] || \
  fail "app version/build differs from manifest."
[ "${ACTUAL_BUNDLE_ID}" = "${EXPECTED_BUNDLE_ID}" ] || \
  fail "actual app bundle identifier is not ${EXPECTED_BUNDLE_ID}."
ACTUAL_EXECUTABLE_SHA256=$(shasum -a 256 "${EXECUTABLE}" | awk '{print $1}')
[ "${ACTUAL_EXECUTABLE_SHA256}" = "${EXECUTABLE_SHA256}" ] || \
  fail "executable SHA-256 differs from manifest."

codesign --verify --strict --verbose=2 "${APP}"
SIGNING_DETAILS=$(codesign -dvvv "${APP}" 2>&1)
[[ "${SIGNING_DETAILS}" == *"TeamIdentifier=${EXPECTED_TEAM}"* ]] || \
  fail "actual app TeamIdentifier is not ${EXPECTED_TEAM}."
ACTUAL_CDHASH=$(printf '%s\n' "${SIGNING_DETAILS}" | sed -n 's/^CDHash=//p')
[ "${ACTUAL_CDHASH}" = "${MANIFEST_CDHASH}" ] || fail "actual CDHash differs from manifest."
ACTUAL_REQUIREMENT=$(codesign -d -r- "${APP}" 2>&1 | sed -n 's/^designated => //p')
[ "${ACTUAL_REQUIREMENT}" = "${MANIFEST_REQUIREMENT}" ] || \
  fail "actual designated requirement differs from manifest."

xcrun stapler validate "${APP}"
GATEKEEPER_OUTPUT=$(spctl -a -vvv -t exec "${APP}" 2>&1) || {
  printf '%s\n' "${GATEKEEPER_OUTPUT}" >&2
  fail "Gatekeeper rejected the extracted app."
}
[[ "${GATEKEEPER_OUTPUT}" == *"accepted"* ]] || fail "Gatekeeper did not report an accepted app."

echo "✅ Exact release artifact verified: ${ARTIFACT} — ${VERSION} (${BUILD_NUMBER}) @ ${SOURCE_REVISION}."
echo "✅ Publisher ${EXPECTED_TEAM}, designated requirement, CDHash, notarization, staple, Gatekeeper, and hashes match."
