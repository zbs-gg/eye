#!/bin/bash
# Fail-closed release provenance gate. Production releases must come from a clean
# checkout whose HEAD is the freshly fetched canonical GitHub main, with a new
# semantic version and monotonically increasing build number.
set -euo pipefail

SCRIPT_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
REPOSITORY="${SCRIPT_ROOT}"
MODE="full"
FIXTURE_MODE=0

fail() {
  echo "❌ Release preflight failed: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/release-preflight.sh [--verify-only]

Production mode always fetches canonical origin/main and release tags.

Test-only hook:
  ZBSEYE_RELEASE_PREFLIGHT_FIXTURE=1 \
  ZBSEYE_RELEASE_PREFLIGHT_FIXTURE_REMOTE=/path/to/bare.git \
    scripts/release-preflight.sh --fixture /path/to/candidate
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --verify-only)
      MODE="verify-only"
      shift
      ;;
    --fixture)
      [ "${ZBSEYE_RELEASE_PREFLIGHT_FIXTURE:-}" = "1" ] || \
        fail "--fixture is a test-only hook and requires ZBSEYE_RELEASE_PREFLIGHT_FIXTURE=1."
      [ "$#" -ge 2 ] || fail "--fixture requires a repository path."
      FIXTURE_MODE=1
      REPOSITORY="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

[ -d "${REPOSITORY}" ] || fail "repository does not exist: ${REPOSITORY}"
cd "${REPOSITORY}"
TOP_LEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || fail "not a Git worktree: ${REPOSITORY}"
TOP_LEVEL=$(cd "${TOP_LEVEL}" && pwd -P)
[ "${TOP_LEVEL}" = "$(pwd -P)" ] || fail "run from the repository root, not a nested directory."

# Porcelain includes staged, unstaged, and nonignored untracked files. Ignored
# build output is intentionally excluded.
DIRTY_STATE=$(git status --porcelain=v1 --untracked-files=all)
[ -z "${DIRTY_STATE}" ] || {
  printf '%s\n' "${DIRTY_STATE}" >&2
  fail "dirty worktree (tracked, staged, or nonignored untracked files present)."
}

git config --get remote.origin.url >/dev/null 2>&1 || fail "missing required origin remote."
ORIGIN_URL=$(git config --get remote.origin.url)

normalize_github_remote() {
  local url="$1"
  local path=""
  case "${url}" in
    git@github.com:*) path="${url#git@github.com:}" ;;
    ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
    https://github.com/*) path="${url#https://github.com/}" ;;
    *) return 1 ;;
  esac
  path="${path%%\?*}"
  path="${path%%#*}"
  path="${path%/}"
  path="${path%.git}"
  printf '%s' "${path}" | tr '[:upper:]' '[:lower:]'
}

NORMALIZED_ORIGIN=$(normalize_github_remote "${ORIGIN_URL}") || \
  fail "origin is not a canonical GitHub SSH/HTTPS remote: ${ORIGIN_URL}"
[ "${NORMALIZED_ORIGIN}" = "zbs-gg/eye" ] || \
  fail "origin does not match canonical repository zbs-gg/eye: ${ORIGIN_URL}"

if [ "${FIXTURE_MODE}" -eq 1 ]; then
  FETCH_SOURCE="${ZBSEYE_RELEASE_PREFLIGHT_FIXTURE_REMOTE:-}"
  [ -n "${FETCH_SOURCE}" ] || fail "fixture mode requires ZBSEYE_RELEASE_PREFLIGHT_FIXTURE_REMOTE."
else
  FETCH_SOURCE="origin"
fi

echo "▸ Refreshing canonical main and release tags…"
if ! git fetch --quiet --force --prune --prune-tags "${FETCH_SOURCE}" \
  '+refs/heads/main:refs/remotes/origin/main' \
  '+refs/tags/*:refs/tags/*'; then
  fail "fresh fetch of canonical main and release tags failed; release identity is ambiguous."
fi

SOURCE_REVISION=$(git rev-parse --verify HEAD 2>/dev/null) || fail "candidate HEAD is missing."
MAIN_REVISION=$(git rev-parse --verify refs/remotes/origin/main 2>/dev/null) || \
  fail "fresh fetch did not produce origin/main."

if [ "${SOURCE_REVISION}" != "${MAIN_REVISION}" ]; then
  if git merge-base --is-ancestor "${SOURCE_REVISION}" "${MAIN_REVISION}" 2>/dev/null; then
    fail "candidate HEAD is behind freshly fetched origin/main."
  elif git merge-base --is-ancestor "${MAIN_REVISION}" "${SOURCE_REVISION}" 2>/dev/null; then
    fail "candidate HEAD is ahead of freshly fetched origin/main."
  else
    fail "candidate HEAD is divergent from freshly fetched origin/main."
  fi
fi

if [ "${MODE}" = "verify-only" ]; then
  [ "${FIXTURE_MODE}" -eq 0 ] || fail "--verify-only is production-only."
  echo "✅ release preflight verify-only passed: HEAD is freshly fetched canonical origin/main (${SOURCE_REVISION})."
  exit 0
fi

project_value() {
  local file="$1"
  local target="$2"
  local key="$3"
  awk -v target="${target}" -v key="${key}" '
    $0 == "targets:" { inTargets = 1; next }
    !inTargets { next }
    $0 == "  " target ":" { inTarget = 1; next }
    inTarget && /^  [^ ]/ { exit }
    inTarget {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (index(line, key ":") == 1) {
        sub(/^[^:]+:[[:space:]]*/, "", line)
        sub(/[[:space:]]*#.*/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        gsub(/^"|"$/, "", line)
        gsub(/^\047|\047$/, "", line)
        print line
        exit
      }
    }
  ' "${file}"
}

read_identity() {
  local file="$1"
  local label="$2"
  local app_version app_build test_version test_build
  app_version=$(project_value "${file}" "ZBSEye" "MARKETING_VERSION")
  app_build=$(project_value "${file}" "ZBSEye" "CURRENT_PROJECT_VERSION")
  test_version=$(project_value "${file}" "ZBSEyeTests" "MARKETING_VERSION")
  test_build=$(project_value "${file}" "ZBSEyeTests" "CURRENT_PROJECT_VERSION")
  [ -n "${app_version}" ] && [ -n "${app_build}" ] && \
    [ -n "${test_version}" ] && [ -n "${test_build}" ] || \
    fail "${label} is missing app/test version or build settings."
  [ "${app_version}" = "${test_version}" ] && [ "${app_build}" = "${test_build}" ] || \
    fail "${label} app and test targets disagree (${app_version}/${app_build} vs ${test_version}/${test_build})."
  printf '%s %s\n' "${app_version}" "${app_build}"
}

semver_valid() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

semver_greater_than() {
  local left="$1"
  local right="$2"
  local l_major l_minor l_patch r_major r_minor r_patch
  IFS=. read -r l_major l_minor l_patch <<< "${left}"
  IFS=. read -r r_major r_minor r_patch <<< "${right}"
  if (( 10#${l_major} != 10#${r_major} )); then
    (( 10#${l_major} > 10#${r_major} ))
    return
  fi
  if (( 10#${l_minor} != 10#${r_minor} )); then
    (( 10#${l_minor} > 10#${r_minor} ))
    return
  fi
  (( 10#${l_patch} > 10#${r_patch} ))
}

read -r CANDIDATE_VERSION CANDIDATE_BUILD < <(read_identity "project.yml" "candidate")
semver_valid "${CANDIDATE_VERSION}" || fail "candidate version is not strict X.Y.Z semver: ${CANDIDATE_VERSION}"
[[ "${CANDIDATE_BUILD}" =~ ^[1-9][0-9]*$ ]] || fail "candidate build is not a positive integer: ${CANDIDATE_BUILD}"

EXPECTED_VERSION="${ZBSEYE_PREFLIGHT_EXPECT_VERSION:-${CANDIDATE_VERSION}}"
EXPECTED_BUILD="${ZBSEYE_PREFLIGHT_EXPECT_BUILD:-${CANDIDATE_BUILD}}"
[ "${CANDIDATE_VERSION}" = "${EXPECTED_VERSION}" ] && [ "${CANDIDATE_BUILD}" = "${EXPECTED_BUILD}" ] || \
  fail "candidate ${CANDIDATE_VERSION} (${CANDIDATE_BUILD}) does not match intended ${EXPECTED_VERSION} (${EXPECTED_BUILD})."

CANDIDATE_TAG="v${CANDIDATE_VERSION}"
if git show-ref --verify --quiet "refs/tags/${CANDIDATE_TAG}"; then
  fail "candidate tag ${CANDIDATE_TAG} already exists; published release identities are immutable."
fi

LATEST_VERSION=""
LATEST_TAG=""
while IFS= read -r tag; do
  version="${tag#v}"
  semver_valid "${version}" || continue
  if [ -z "${LATEST_VERSION}" ] || semver_greater_than "${version}" "${LATEST_VERSION}"; then
    LATEST_VERSION="${version}"
    LATEST_TAG="${tag}"
  fi
done < <(git tag --list 'v*')

[ -n "${LATEST_TAG}" ] || fail "no actual X.Y.Z release baseline tag was found after the fresh fetch."
semver_greater_than "${CANDIDATE_VERSION}" "${LATEST_VERSION}" || \
  fail "candidate version ${CANDIDATE_VERSION} must be newer than release baseline ${LATEST_VERSION}."

BASELINE_PROJECT=$(mktemp "${TMPDIR:-/tmp}/zbseye-release-baseline.XXXXXX")
trap 'rm -f "${BASELINE_PROJECT:-}"' EXIT
git show "${LATEST_TAG}:project.yml" > "${BASELINE_PROJECT}" 2>/dev/null || \
  fail "release baseline ${LATEST_TAG} does not contain project.yml."
read -r BASELINE_VERSION BASELINE_BUILD < <(read_identity "${BASELINE_PROJECT}" "release baseline ${LATEST_TAG}")
[ "${BASELINE_VERSION}" = "${LATEST_VERSION}" ] || \
  fail "release baseline tag ${LATEST_TAG} disagrees with project version ${BASELINE_VERSION}."
[[ "${BASELINE_BUILD}" =~ ^[1-9][0-9]*$ ]] || \
  fail "release baseline build is not a positive integer: ${BASELINE_BUILD}"
(( 10#${CANDIDATE_BUILD} > 10#${BASELINE_BUILD} )) || \
  fail "candidate build ${CANDIDATE_BUILD} must be newer than release baseline build ${BASELINE_BUILD}."

echo "✅ release preflight passed: clean canonical main ${SOURCE_REVISION}, ${CANDIDATE_VERSION} (${CANDIDATE_BUILD}) > ${LATEST_TAG} (${BASELINE_BUILD})."
