#!/bin/bash
# transcribe.cpp v0.1.3's published XCFramework ZIP contains copies where a
# versioned macOS framework requires symlinks. SwiftPM verifies the pinned ZIP,
# but Xcode's Developer ID exporter correctly rejects the ambiguous bundle.
# Repair only that verified DerivedData copy before compilation; never mutate
# the upstream archive or ship the duplicated layout.
set -euo pipefail

fail() {
  echo "❌ CTranscribe framework repair failed: $*" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail "usage: repair-transcribe-framework.sh <exact CTranscribe.framework>"
FRAMEWORK="$1"
[ -d "${FRAMEWORK}" ] && [ ! -L "${FRAMEWORK}" ] || fail "framework is missing or is a symlink."

CANONICAL="${FRAMEWORK}/Versions/A"
CURRENT="${FRAMEWORK}/Versions/Current"
EXPECTED_EXECUTABLE_SHA256="9bb4ece5101e4efab3bc584e95a744c7c3ecc80295c463372b43b6d2232af8d5"
EXPECTED_INFO_SHA256="85aedf5ea0e39d59dec1e9419d12fdde8407514fe15ce3d1b826c601d0dee1ba"
EXPECTED_MODULEMAP_SHA256="d738d17e347c1efa780141f2dc3dead61aa53624d4378df10f123bcfbedfbd31"
EXPECTED_HEADER_SHA256="2b7c468b2153ebda9110840945fb83652148f787cb4cb0a4d049d1ee7c65bbda"

require_sha256() {
  local file="$1"
  local expected="$2"
  [ -f "${file}" ] && [ ! -L "${file}" ] || fail "missing canonical file: ${file}"
  local actual
  actual=$(shasum -a 256 "${file}" | awk '{print $1}')
  [ "${actual}" = "${expected}" ] || fail "unexpected upstream bytes: ${file}"
}

require_sha256 "${CANONICAL}/CTranscribe" "${EXPECTED_EXECUTABLE_SHA256}"
require_sha256 "${CANONICAL}/Resources/Info.plist" "${EXPECTED_INFO_SHA256}"
require_sha256 "${CANONICAL}/Modules/module.modulemap" "${EXPECTED_MODULEMAP_SHA256}"
require_sha256 "${CANONICAL}/Headers/transcribe.h" "${EXPECTED_HEADER_SHA256}"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "${CANONICAL}/Resources/Info.plist" 2>/dev/null || true)
[ "${BUNDLE_ID}" = "com.transcribe.CTranscribe" ] || fail "unexpected framework bundle identifier."

if [ -L "${CURRENT}" ]; then
  [ "$(readlink "${CURRENT}")" = "A" ] || fail "Versions/Current has an unexpected target."
  for name in CTranscribe Headers Modules Resources; do
    [ -L "${FRAMEWORK}/${name}" ] || fail "repaired ${name} entry is not a symlink."
    [ "$(readlink "${FRAMEWORK}/${name}")" = "Versions/Current/${name}" ] || \
      fail "repaired ${name} entry has an unexpected target."
  done
  codesign --verify --strict "${FRAMEWORK}" || fail "repaired framework signature is invalid."
  echo "✅ CTranscribe framework already has the canonical macOS symlink layout."
  exit 0
fi

# Refuse to transform anything except the exact duplicated v0.1.3 layout.
[ -d "${CURRENT}" ] && [ ! -L "${CURRENT}" ] || fail "unexpected Versions/Current layout."
diff -qr "${CURRENT}" "${CANONICAL}" >/dev/null || fail "Versions/Current differs from Versions/A."
cmp -s "${FRAMEWORK}/CTranscribe" "${CANONICAL}/CTranscribe" || \
  fail "top-level executable differs from Versions/A."
for name in Headers Modules Resources; do
  [ -d "${FRAMEWORK}/${name}" ] && [ ! -L "${FRAMEWORK}/${name}" ] || \
    fail "unexpected top-level ${name} layout."
  diff -qr "${FRAMEWORK}/${name}" "${CANONICAL}/${name}" >/dev/null || \
    fail "top-level ${name} differs from Versions/A."
done

rm -rf "${CURRENT}" \
  "${FRAMEWORK}/Headers" \
  "${FRAMEWORK}/Modules" \
  "${FRAMEWORK}/Resources"
rm -f "${FRAMEWORK}/CTranscribe"
ln -s A "${CURRENT}"
ln -s Versions/Current/CTranscribe "${FRAMEWORK}/CTranscribe"
ln -s Versions/Current/Headers "${FRAMEWORK}/Headers"
ln -s Versions/Current/Modules "${FRAMEWORK}/Modules"
ln -s Versions/Current/Resources "${FRAMEWORK}/Resources"

codesign --verify --strict "${FRAMEWORK}" || fail "framework signature is invalid after repair."
echo "✅ Repaired CTranscribe v0.1.3 framework symlinks in DerivedData."
