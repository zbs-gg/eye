#!/bin/bash
# Deterministic call-automation qualification. This never launches ZBS Eye, captures media,
# asks for TCC permissions, downloads a model, or sends traffic beyond numeric loopback.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $1"
  exit 1
}

command -v xcodegen >/dev/null || fail "xcodegen is required"
command -v python3 >/dev/null || fail "python3 is required"

DERIVED_DATA_PATH="${ZBS_EYE_CALL_AUTOMATION_DERIVED_DATA_PATH:-build/CallAutomationDerivedData}"

xcodegen generate >/dev/null

selected=(
  -only-testing:ZBSEyeTests/CallAutomationDispatcherTests
  -only-testing:ZBSEyeTests/CallAutomationOutboxTests
  -only-testing:ZBSEyeTests/CallAutomationPayloadTests
  -only-testing:ZBSEyeTests/CallAutomationStoreTests
  -only-testing:ZBSEyeTests/CallDatabaseTests
  -only-testing:ZBSEyeTests/LoopbackWebhookTransportTests
)

xcodebuild -quiet \
  -project ZBSEye.xcodeproj \
  -scheme ZBSEyeUnitTests \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  test "${selected[@]}"

python3 -m unittest scripts.tests.test_call_automation_receiver
python3 -m py_compile examples/call-automation-receiver.py

if rg -n 'URLSession\.shared' ZBSEyeApp/Automations/LoopbackWebhookTransport.swift; then
  fail "call automation must use its hardened loopback-only transport"
fi

if rg -n -i '"(transcript|audio|screenshot|relativePath|authorization|bearer)"' \
    ZBSEyeApp/Automations/CallAutomationPayload.swift; then
  fail "call automation payload contains a forbidden content-bearing field"
fi

echo "PASS: call automation fixture gate green (local-only, no app launch, no TCC, no model download)"
