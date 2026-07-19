#!/bin/bash
# Deterministic call-recorder qualification. The default fixture mode never launches the app,
# asks for TCC, captures media, or downloads a model. Physical qualification is a separate,
# explicit operator gate against the installed stably signed app.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:---fixtures}"

fail() {
  echo "❌ $1"
  exit 1
}

fixture_gate() {
  command -v xcodegen >/dev/null || fail "xcodegen is required"
  command -v jq >/dev/null || fail "jq is required"
  command -v rg >/dev/null || fail "ripgrep is required"

  xcodegen generate >/dev/null
  local derived="build/DerivedData"
  local selected=(
    -only-testing:ZBSEyeTests/AIComputeCoordinatorTests
    -only-testing:ZBSEyeTests/AudioIngressPublisherTests
    -only-testing:ZBSEyeTests/AutomaticRetentionAdmissionTests
    -only-testing:ZBSEyeTests/CallAPITests
    -only-testing:ZBSEyeTests/CallAutomationDispatcherTests
    -only-testing:ZBSEyeTests/CallAutomationOutboxTests
    -only-testing:ZBSEyeTests/CallAutomationPayloadTests
    -only-testing:ZBSEyeTests/CallAutomationStoreTests
    -only-testing:ZBSEyeTests/CallAudioWindowAssemblerTests
    -only-testing:ZBSEyeTests/CallCoordinatorTests
    -only-testing:ZBSEyeTests/CallDatabaseTests
    -only-testing:ZBSEyeTests/CallEvidenceQueryServiceTests
    -only-testing:ZBSEyeTests/CallExportTests
    -only-testing:ZBSEyeTests/CallFinalPromotionTests
    -only-testing:ZBSEyeTests/CallMediaMutationRecoveryTests
    -only-testing:ZBSEyeTests/CallPresentationStateTests
    -only-testing:ZBSEyeTests/CallRecordingStoreTests
    -only-testing:ZBSEyeTests/CallRecoveryTests
    -only-testing:ZBSEyeTests/CallRedactionTests
    -only-testing:ZBSEyeTests/CallReleaseQualificationTests
    -only-testing:ZBSEyeTests/CallRetentionTests
    -only-testing:ZBSEyeTests/CallSearchTests
    -only-testing:ZBSEyeTests/CallSpoolTests
    -only-testing:ZBSEyeTests/CallStorageRelocationTests
    -only-testing:ZBSEyeTests/CallTimelineTests
    -only-testing:ZBSEyeTests/CallTranscriptProjectionTests
    -only-testing:ZBSEyeTests/CallTranscriptWorkerTests
    -only-testing:ZBSEyeTests/DiarizationHelperCommandTests
    -only-testing:ZBSEyeTests/MCPCallEvidenceRoutingTests
    -only-testing:ZBSEyeTests/MCPHistorySearchRoutingTests
    -only-testing:ZBSEyeTests/MCPReadOnlyDatabaseTests
    -only-testing:ZBSEyeTests/MCPReadinessServiceTests
    -only-testing:ZBSEyeTests/ReleaseConfigurationTests
    -only-testing:ZBSEyeTests/RetentionManagerTests
    -only-testing:ZBSEyeTests/SpeakerDiarizationModelManifestTests
    -only-testing:ZBSEyeTests/SpeakerDiarizationWorkerTests
    -only-testing:ZBSEyeTests/LoopbackWebhookTransportTests
    -only-testing:ZBSEyeTests/SystemAudioCaptureLifecycleTests
    -only-testing:ZBSEyeTests/TranscriptOverlapReconcilerTests
    -only-testing:ZBSEyeTests/WhisperHelperCommandTests
    -only-testing:ZBSEyeTests/WhisperModelLifecycleTests
  )

  xcodebuild -quiet \
    -project ZBSEye.xcodeproj \
    -scheme ZBSEyeUnitTests \
    -configuration Debug \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO \
    test "${selected[@]}"

  sed -n '/^    {"openapi"/,/^    """#/p' ZBSEyeApp/Server/ZBSEyeHTTPServer.swift \
    | sed '$d' \
    | jq -e '.openapi == "3.0.3" and (.paths["/v1/calls"] != null) and (.paths["/v1/call/evidence"] != null)' \
      >/dev/null || fail "call OpenAPI contract is invalid"

  local logging_scope=(
    ZBSEyeApp/App/ZBSEyeMain.swift
    ZBSEyeApp/App/AppEnvironment.swift
    ZBSEyeApp/Calls
    ZBSEyeApp/Audio/AudioCoordinator.swift
    ZBSEyeApp/Audio/AudioIngressPublisher.swift
    ZBSEyeApp/Audio/AudioPipeline.swift
    ZBSEyeApp/Audio/SystemAudioCaptureEngine.swift
    ZBSEyeApp/Capture/CaptureCoordinator.swift
    ZBSEyeApp/MCP/ZBSEyeMCPServer.swift
    ZBSEyeApp/Server/ZBSEyeHTTPServer.swift
  )
  if rg -n -F '\(error)' "${logging_scope[@]}"; then
    fail "raw Error interpolation can leak paths or native details"
  fi
  if rg -n 'Log\.[A-Za-z]+.*(transcript|relativePath|manifest|arguments|authorization|token)' \
      ZBSEyeApp/Calls ZBSEyeApp/Audio/AudioIngressPublisher.swift; then
    fail "call logs contain forbidden content-bearing fields"
  fi

  echo "✅ call fixture gate green: no app launch, no capture, no TCC, no model download"
}

physical_preflight() {
  [ -z "${CI:-}" ] || fail "physical qualification is forbidden in CI"
  [ "${ZBS_EYE_CALL_PHYSICAL_GATE:-}" = "YES" ] || {
    echo "Physical qualification is deliberately opt-in."
    echo "Run only when ready: ZBS_EYE_CALL_PHYSICAL_GATE=YES $0 --physical-preflight"
    exit 2
  }

  local app="/Applications/ZBS Eye.app"
  [ -d "$app" ] || fail "install the release candidate at /Applications/ZBS Eye.app first"
  codesign --verify --strict --verbose=2 "$app" || fail "installed app signature is invalid"
  if pgrep -f 'DerivedData.*/ZBS Eye.app' >/dev/null; then
    fail "a DerivedData app is running; quit it before permission-sensitive qualification"
  fi

  local report_dir="build/CallRecordingPhysical"
  local report="$report_dir/REPORT.md"
  mkdir -p "$report_dir"
  local revision
  revision="$(git rev-parse HEAD)"
  local cdhash
  cdhash="$(codesign -dvvv "$app" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
  cat > "$report" <<EOF
# ZBS Eye call recording physical qualification

- Source revision: $revision
- Installed candidate CDHash: $cdhash
- Report location: local build artifact; do not commit personal media or transcripts

## Operator gates

- [ ] Short mic-only smoke with Screen Recording globally off
- [ ] Short mic+system smoke with system audio enabled
- [ ] 60-minute mic+system call, at least 10 Bookmarks
- [ ] 120-minute mic+system call, at least 10 Bookmarks
- [ ] Device/sample-rate change produces an explicit source epoch/gap
- [ ] End during checkpoint and immediate quit after Bookmark recover honestly
- [ ] Helper kill/retry and app relaunch preserve finalized chunks and one final revision
- [ ] GUI RSS/CPU, helper peak/exit RSS, queue depth, gaps, and disk growth recorded
- [ ] Database/chunk/transcript/search/export reconciliation passes
- [ ] Unified log, server.log, diagnostics, and helper stderr contain no seeded content/path/token marker
- [ ] Final preferred transcript is unique; Bookmark timestamps remain available

## Results

Pending manual execution on the installed release candidate.
EOF

  echo "✅ physical preflight green; no recording was started"
  echo "   Checklist: $report"
  echo "   Use only synthetic/non-personal speech for a publishable report."
}

case "$MODE" in
  --fixtures) fixture_gate ;;
  --physical-preflight) physical_preflight ;;
  *)
    echo "Usage: $0 [--fixtures | --physical-preflight]"
    exit 2
    ;;
esac
