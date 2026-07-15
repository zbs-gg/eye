#!/bin/bash
# Validate the two Apple notarytool JSON responses without contacting Apple.
# Prints one tab-separated identity line on success: status, submission ID,
# and SHA-256 of the reviewed log.
set -euo pipefail

fail() {
  echo "❌ Notary evidence validation failed: $*" >&2
  exit 1
}

[ "$#" -eq 2 ] || fail "usage: validate-notary-evidence.sh <submission.json> <log.json>"
SUBMISSION_JSON="$1"
NOTARY_LOG="$2"
[ -s "${SUBMISSION_JSON}" ] || fail "submission response is missing or empty."
[ -s "${NOTARY_LOG}" ] || fail "notarization log is missing or empty."

NOTARY_STATUS=$(/usr/bin/plutil -extract status raw -expect string -o - "${SUBMISSION_JSON}" 2>/dev/null) || \
  fail "submission response has no string status."
NOTARY_SUBMISSION_ID=$(/usr/bin/plutil -extract id raw -expect string -o - "${SUBMISSION_JSON}" 2>/dev/null) || \
  fail "submission response has no string ID."
[ "${NOTARY_STATUS}" = "Accepted" ] || fail "submission status is ${NOTARY_STATUS}, expected Accepted."
[ -n "${NOTARY_SUBMISSION_ID}" ] || fail "Accepted submission response has an empty ID."

NOTARY_LOG_STATUS=$(/usr/bin/plutil -extract status raw -expect string -o - "${NOTARY_LOG}" 2>/dev/null) || \
  fail "notarization log has no string status."
[ "${NOTARY_LOG_STATUS}" = "Accepted" ] || fail "log status is ${NOTARY_LOG_STATUS}, expected Accepted."
NOTARY_LOG_JOB_ID=$(/usr/bin/plutil -extract jobId raw -expect string -o - "${NOTARY_LOG}" 2>/dev/null) || \
  fail "notarization log has no string jobId."
SUBMISSION_ID_NORMALIZED=$(printf '%s' "${NOTARY_SUBMISSION_ID}" | tr '[:upper:]' '[:lower:]')
LOG_JOB_ID_NORMALIZED=$(printf '%s' "${NOTARY_LOG_JOB_ID}" | tr '[:upper:]' '[:lower:]')
[ "${LOG_JOB_ID_NORMALIZED}" = "${SUBMISSION_ID_NORMALIZED}" ] || \
  fail "notarization log jobId does not match the submission ID."

# Successful Apple logs may encode no issues as either [] or null. Accept only
# those two top-level shapes; every missing or differently typed value fails.
if /usr/bin/plutil -p "${NOTARY_LOG}" 2>/dev/null \
    | /usr/bin/awk '$0 == "  \"issues\" => <null>" { found = 1 } END { exit(found ? 0 : 1) }'; then
  NOTARY_LOG_ISSUES="[]"
else
  NOTARY_LOG_ISSUES=$(
    /usr/bin/plutil -extract issues json -expect array -o - "${NOTARY_LOG}" 2>/dev/null
  ) || fail "notarization log issues must be null or an array."
  if printf '%s' "${NOTARY_LOG_ISSUES}" | tr -d '[:space:]' | grep -q '"severity":"error"'; then
    fail "notarization log contains an error issue."
  fi
fi

NOTARY_LOG_SHA256=$(shasum -a 256 "${NOTARY_LOG}" | awk '{print $1}')
[[ "${NOTARY_LOG_SHA256}" =~ ^[0-9a-f]{64}$ ]] || fail "could not hash notarization log."
printf '%s\t%s\t%s\n' "${NOTARY_STATUS}" "${NOTARY_SUBMISSION_ID}" "${NOTARY_LOG_SHA256}"
