#!/bin/bash
# Deterministic call-recorder qualification. The default fixture mode never launches the app,
# asks for TCC, captures media, or downloads a model. Physical qualification is a separate,
# explicit operator gate against the installed stably signed app.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:---fixtures}"
TEMP_DERIVED_DATA=""

cleanup_temp_derived_data() {
  if [[ -n "$TEMP_DERIVED_DATA" && -d "$TEMP_DERIVED_DATA" ]]; then
    rm -rf -- "$TEMP_DERIVED_DATA"
  fi
}
trap cleanup_temp_derived_data EXIT INT TERM

fail() {
  echo "❌ $1"
  exit 1
}

fixture_gate() {
  command -v xcodegen >/dev/null || fail "xcodegen is required"
  command -v jq >/dev/null || fail "jq is required"
  command -v rg >/dev/null || fail "ripgrep is required"

  xcodegen generate >/dev/null
  # Default verification is disposable and cannot silently refill the project
  # with gigabytes of rebuildable data. An explicit override opts into a
  # persistent reusable cache and is never deleted by this script.
  local derived
  if [[ -n "${ZBS_EYE_CALL_DERIVED_DATA_PATH:-}" ]]; then
    derived="$ZBS_EYE_CALL_DERIVED_DATA_PATH"
  else
    derived="$(mktemp -d "${TMPDIR:-/tmp}/zbseye-call-tests.XXXXXX")"
    TEMP_DERIVED_DATA="$derived"
  fi
  local selected=(
    -only-testing:ZBSEyeTests/AIComputeCoordinatorTests
    -only-testing:ZBSEyeTests/AudioIngressPublisherTests
    -only-testing:ZBSEyeTests/AudioSettingsStoreTests
    -only-testing:ZBSEyeTests/AutomaticCallBannerPresentationTests
    -only-testing:ZBSEyeTests/AutomaticCallCaptureLifecycleTests
    -only-testing:ZBSEyeTests/AutomaticRetentionAdmissionTests
    -only-testing:ZBSEyeTests/BrowserCallAdmissionIntegrationTests
    -only-testing:ZBSEyeTests/BrowserCallSurfaceInspectorTests
    -only-testing:ZBSEyeTests/CallAPITests
    -only-testing:ZBSEyeTests/CallAutomationDispatcherTests
    -only-testing:ZBSEyeTests/CallAutomationOutboxTests
    -only-testing:ZBSEyeTests/CallAutomationPayloadTests
    -only-testing:ZBSEyeTests/CallAutomationStoreTests
    -only-testing:ZBSEyeTests/CallAudioProcessEvidenceTests
    -only-testing:ZBSEyeTests/CallRecordingAdmissionPolicyTests
    -only-testing:ZBSEyeTests/CallAudioWindowAssemblerTests
    -only-testing:ZBSEyeTests/CallCoordinatorTests
    -only-testing:ZBSEyeTests/CallDatabaseTests
    -only-testing:ZBSEyeTests/CallDetectionPolicyTests
    -only-testing:ZBSEyeTests/CallEvidenceQueryServiceTests
    -only-testing:ZBSEyeTests/CallExportTests
    -only-testing:ZBSEyeTests/CallFinalPromotionTests
    -only-testing:ZBSEyeTests/CallMediaMutationRecoveryTests
    -only-testing:ZBSEyeTests/CallPresentationStateTests
    -only-testing:ZBSEyeTests/CallPrivacyIntentJournalTests
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
    -only-testing:ZBSEyeTests/CallVideoQueueTests
    -only-testing:ZBSEyeTests/CaptureSessionPolicyTests
    -only-testing:ZBSEyeTests/CoreAudioMicListenerLifecycleTests
    -only-testing:ZBSEyeTests/DiarizationHelperCommandTests
    -only-testing:ZBSEyeTests/MCPCallEvidenceRoutingTests
    -only-testing:ZBSEyeTests/MCPHistorySearchRoutingTests
    -only-testing:ZBSEyeTests/MCPReadOnlyDatabaseTests
    -only-testing:ZBSEyeTests/MCPReadinessServiceTests
    -only-testing:ZBSEyeTests/MeetingDetectorSurfaceTrustTests
    -only-testing:ZBSEyeTests/NativeCallSurfaceInspectorTests
    -only-testing:ZBSEyeTests/ReleaseConfigurationTests
    -only-testing:ZBSEyeTests/RecordingMaintenanceAdmissionTests
    -only-testing:ZBSEyeTests/RecordingStoreLowDiskTests
    -only-testing:ZBSEyeTests/RetentionManagerTests
    -only-testing:ZBSEyeTests/SettingsPresentationTests
    -only-testing:ZBSEyeTests/ScreenshotPriorityYieldGateTests
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
- Qualified ZIP filename: REQUIRED BEFORE CHECKING ANY ROW
- Qualified ZIP SHA-256: REQUIRED BEFORE CHECKING ANY ROW
- Qualified manifest filename: REQUIRED BEFORE CHECKING ANY ROW
- Qualified manifest SHA-256: REQUIRED BEFORE CHECKING ANY ROW
- Report location: local build artifact; do not commit personal media or transcripts
EOF

  cat >> "$report" <<'EOF'

## Three-mode Call and Call-video gates for 0.9.0 (25)

- [ ] **Don't record:** an eligible external microphone owner creates no Call row, audio, or video; manual Start offers Audio only / Audio and video / Cancel without changing the global mode
- [ ] Switching an active Call to **Don't record** immediately ends and saves it once, then disarms automatic admission until the mode changes again
- [ ] **Audio only:** a 15-minute real Call has continuous independent microphone and system PCM evidence, no Call video rows or files, and no Timeline screen/AX/OCR/HEIC work
- [ ] **Audio and video:** a 30-minute real Call has the same continuous independent audio plus hardware-only video at no more than 1920×1080 and 15 fps, with cursor and no camera
- [ ] Audio physically starts before the first video span; an unavailable hardware encoder leaves audio recording and reports `Audio complete · Video unavailable`
- [ ] Audio → video → audio → video changes create no audio restart, duplicate Call, unexplained audio gap, or reordered chunk; video spans and disabled intervals match the switch times
- [ ] Video stays bound to the display selected when authoritative Call audio starts, including when video is enabled later or focus moves to another display
- [ ] Disconnecting the selected display records an exact video gap and never switches to another display silently; reconnect/re-enable recovery preserves the same Call audio
- [ ] Repeated native screenshots during Call video physically stop every Eye-owned screen stream for the full quiet window, create disjoint exact video gaps, and never stop or delay either audio leg
- [ ] Native screenshot p95 and max are measured against an Eye-off baseline; every relevant arm is at most +250 ms and has zero error, empty, stale, or new-permission-prompt attempts
- [ ] Timeline stays visually silent for every active Call mode; no OCR, AX, or HEIC work appears while Call audio owns capture
- [ ] Two-monitor start/focus/disconnect cases, lock/unlock, and sleep/wake preserve the selected display contract and record every unavailable interval honestly
- [ ] Low-disk pressure drops or stops video before audio, never allows software encoding, and preserves explicit gaps/status without `telemetryOverflow` or `consumerOverflow`
- [ ] Crash/relaunch preserves authoritative PCM, finalized video fragments, pending rollback evidence, exact spans/gaps, and one recoverable Call generation
- [ ] Deleting a Call or time range removes its audio and video through the journaled operation without touching another Call; Keep Media removes the whole oldest Call
- [ ] Trimming physically rebuilds affected MP4 fragments, publishes one new generation, and removes the superseded bytes before the new generation is visible
- [ ] Export contains standard sequential MP4 fragments, original microphone/system tracks, mixed AAC copies where available, and a manifest whose hashes match every exported byte
- [ ] Call Detail, REST, and MCP agree on recording mode, video state, actual resolution, spans, gaps, and authorized `call-video-segment:<id>` references without absolute paths
- [ ] The complete Call window contains zero unexplained audio discontinuities, `telemetryOverflow`, or `consumerOverflow`; any occurrence blocks installation, merge, and release

## Existing automatic-Call regression gates

- [ ] ChatGPT through Krisp starts exactly one automatic Call from microphone activity
- [ ] Wi-Fi disabled before or during that Call does not affect detection, local capture, or saved evidence
- [ ] End & save commits once; the 30-second timeout commits once; neither surface offers Undo
- [ ] This wasn’t a call erases only that automatic Call and suppresses it until microphone idle
- [ ] A user-excluded app creates no Call; removing the exclusion re-arms current mic activity
- [ ] Muting and unmuting inside the app does not split the Call or create a duplicate
- [ ] Switching microphone or output device keeps one Call and reports any unavailable track as degraded
- [ ] Sleep then wake neither records the locked session nor loses automatic microphone detection after unlock
- [ ] Restarting coreaudiod reinstalls input-running listeners; the two-second poll covers the restart window
- [ ] Quitting and relaunching Eye recovers the interrupted automatic Call without loss or duplicate finalization
- [ ] Short mic-only smoke with Screen Recording globally off
- [ ] Short mic+system smoke with system audio enabled
- [ ] 60-minute mic+system call, at least 10 Bookmarks
- [ ] 120-minute mic+system call, at least 10 Bookmarks
- [ ] Device/sample-rate change produces an explicit source epoch/gap without splitting the Call
- [ ] End during checkpoint and immediate quit after Bookmark recover honestly
- [ ] Helper kill/retry preserves finalized chunks and one final revision
- [ ] GUI RSS/CPU, helper peak/exit RSS, queue depth, gaps, and disk growth recorded
- [ ] Database/chunk/transcript/search/export reconciliation passes
- [ ] Unified log, server.log, diagnostics, and helper stderr contain no seeded content/path/token marker
- [ ] Final preferred transcript is unique; Bookmark timestamps remain available

## Results

Pending manual execution on the exact reverse-verified installed release candidate. Automated tests, a signed
artifact, or a partially checked section do not change this result.
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
