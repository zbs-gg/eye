#!/bin/bash
# Deterministic Local AI verification gate.
#
# Ordinary fixture/contract checks never need model weights. Real MLX runtime
# and quality checks are opt-in and must point at an already verified local
# model directory; this script deliberately has no code path that downloads a
# model or retries a failed quality run.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: scripts/verify-local-ai.sh [options]

  --fixture             Run the deterministic Local AI fixture/contract suite (default).
  --all-fixtures        Run every ZBSEyeTests test without real model weights.
  --runtime-smoke       Also run MLXRuntimeSmokeTests against a local model directory.
  --quality-gate        Run only LocalAIQualityGateV9Tests, fully offline.
                        Requires an explicit --model-dir PATH.
  --quality-probe       Run the fixed 8-case V9 preflight (24 attempts), fully
                        offline. Requires an explicit --model-dir PATH and
                        writes a non-qualifying probe report.
  --performance-gate    Run only MLXRuntimeQualificationTests, fully offline,
                        serially, once, in Release. Requires an explicit
                        --model-dir PATH and writes a raw JSON report.
  --model-dir PATH      Existing local model directory for a model-backed check.
                        ZBS_EYE_MODEL_DIR may be used for --runtime-smoke only.
  -h, --help            Show this help.

No option downloads model weights or retries a failed quality run. An explicit
model-backed check without its required valid local directory exits with status 2.
EOF
}

die_usage() {
  echo "❌ $1" >&2
  echo >&2
  usage >&2
  exit 2
}

RUN_ALL_FIXTURES=0
RUN_RUNTIME_SMOKE=0
RUN_QUALITY_GATE=0
RUN_QUALITY_PROBE=0
RUN_PERFORMANCE_GATE=0
MODEL_DIR="${ZBS_EYE_MODEL_DIR:-}"
MODEL_DIR_WAS_EXPLICIT=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fixture)
      RUN_ALL_FIXTURES=0
      ;;
    --all-fixtures)
      RUN_ALL_FIXTURES=1
      ;;
    --runtime-smoke)
      RUN_RUNTIME_SMOKE=1
      ;;
    --quality-gate)
      RUN_QUALITY_GATE=1
      ;;
    --quality-probe)
      RUN_QUALITY_PROBE=1
      ;;
    --performance-gate)
      RUN_PERFORMANCE_GATE=1
      ;;
    --model-dir)
      [ "$#" -ge 2 ] || die_usage "--model-dir requires a path"
      MODEL_DIR="$2"
      MODEL_DIR_WAS_EXPLICIT=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown option: $1"
      ;;
  esac
  shift
done

MODEL_GATE_COUNT=$((RUN_QUALITY_GATE + RUN_QUALITY_PROBE + RUN_PERFORMANCE_GATE))
if [ "$MODEL_GATE_COUNT" -gt 1 ]; then
  die_usage "--quality-gate, --quality-probe, and --performance-gate are mutually exclusive"
fi
if [ "$MODEL_GATE_COUNT" -eq 1 ] && [ "$RUN_RUNTIME_SMOKE" -eq 1 ]; then
  die_usage "quality/performance gates cannot be combined with --runtime-smoke"
fi
if [ "$MODEL_GATE_COUNT" -eq 1 ] && [ "$RUN_ALL_FIXTURES" -eq 1 ]; then
  die_usage "quality/performance gates cannot be combined with --all-fixtures"
fi

if [ "$MODEL_GATE_COUNT" -eq 1 ]; then
  GATE_NAME="--quality-gate"
  if [ "$RUN_QUALITY_PROBE" -eq 1 ]; then
    GATE_NAME="--quality-probe"
  elif [ "$RUN_PERFORMANCE_GATE" -eq 1 ]; then
    GATE_NAME="--performance-gate"
  fi
  [ "$MODEL_DIR_WAS_EXPLICIT" -eq 1 ] || die_usage "$GATE_NAME requires an explicit --model-dir PATH"
  [ -n "$MODEL_DIR" ] || die_usage "$GATE_NAME requires --model-dir PATH"
  [ -d "$MODEL_DIR" ] || die_usage "local model directory does not exist: $MODEL_DIR"
  MODEL_DIR="$(cd "$MODEL_DIR" && pwd -P)"
elif [ "$RUN_RUNTIME_SMOKE" -eq 1 ]; then
  [ -n "$MODEL_DIR" ] || die_usage "--runtime-smoke requires --model-dir PATH or ZBS_EYE_MODEL_DIR"
  [ -d "$MODEL_DIR" ] || die_usage "local model directory does not exist: $MODEL_DIR"
  MODEL_DIR="$(cd "$MODEL_DIR" && pwd -P)"
elif [ -n "$MODEL_DIR" ]; then
  echo "ℹ️  ZBS_EYE_MODEL_DIR is set, but runtime smoke is disabled without --runtime-smoke"
  MODEL_DIR=""
fi

# These are defense-in-depth contracts for the runtime test. The test must load
# ZBS_EYE_MODEL_DIR directly and must never resolve a Hub repository identifier.
export ZBS_EYE_ALLOW_MODEL_DOWNLOADS=0
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
PHYSICAL_RELEASE_COUNT=$((RUN_RUNTIME_SMOKE + RUN_QUALITY_GATE + RUN_QUALITY_PROBE + RUN_PERFORMANCE_GATE))
SOURCE_REVISION="$(git rev-parse --verify HEAD 2>/dev/null || true)"
SOURCE_TREE_STATE="clean"
if ! git diff-index --quiet HEAD -- || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  SOURCE_TREE_STATE="dirty"
fi
if [ "$PHYSICAL_RELEASE_COUNT" -gt 0 ] && [ "$SOURCE_TREE_STATE" != "clean" ]; then
  die_usage "physical gate requires a clean source tree"
fi
SWIFT_COMPILER_VERSION="$(xcrun swiftc --version 2>/dev/null | head -n 1)"
XCODE_VERSION="$(xcodebuild -version | paste -sd ' ' -)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
if [ "$PHYSICAL_RELEASE_COUNT" -gt 0 ] && ! [[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  die_usage "physical gate build requires a full git source revision"
fi
if [ "$RUN_RUNTIME_SMOKE" -eq 1 ] || [ "$MODEL_GATE_COUNT" -eq 1 ]; then
  export ZBS_EYE_MODEL_DIR="$MODEL_DIR"
else
  unset ZBS_EYE_MODEL_DIR || true
fi
if [ "$RUN_QUALITY_GATE" -eq 1 ]; then
  export ZBS_EYE_LOCAL_AI_QUALITY_GATE=1
else
  unset ZBS_EYE_LOCAL_AI_QUALITY_GATE || true
fi
if [ "$RUN_QUALITY_PROBE" -eq 1 ]; then
  export ZBS_EYE_LOCAL_AI_QUALITY_PROBE=1
else
  unset ZBS_EYE_LOCAL_AI_QUALITY_PROBE || true
fi
if [ "$RUN_PERFORMANCE_GATE" -eq 1 ]; then
  export ZBS_EYE_LOCAL_AI_PERFORMANCE_GATE=1
else
  unset ZBS_EYE_LOCAL_AI_PERFORMANCE_GATE || true
fi

xcodegen generate

DERIVED="${ZBS_EYE_LOCAL_AI_DERIVED_DATA:-build/LocalAIDerivedData}"
RESOLVED="ZBSEye.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
LOG="$(mktemp -t zbseye-local-ai.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

PURE_TEST_SUITES=(
  "AIProviderContractTests"
  "AIProviderPersistenceTests"
  "BuiltInModelManifestTests"
  "BuiltInModelVerifierTests"
  "BuiltInModelLifecycleTests"
  "BuiltInModelJournalTests"
  "BuiltInDownloadClientTests"
  "BuiltInModelManagerTests"
  "BuiltInModelStoreTests"
  "BuiltInModelFailureMessageTests"
  "IngestWriteBarrierTests"
  "DatabaseWriterMaintenanceGateTests"
  "RecordingMaintenanceAdmissionTests"
  "AIComputeCoordinatorTests"
  "LocalInferenceServiceTests"
  "SearchSemanticPolicyTests"
  "RelocatableAssetTreeTests"
  "StorageLocationTests"
  "StorageRelocationPolicyTests"
  "BuiltInModelRuntimeSupportTests"
  "MLXLocalRuntimeDriverTests"
  "ProviderHTTPAdapterTests"
  "AskServiceTests"
  "AskStoreTests"
  "AIConsumerGenerationTests"
  "LLMRouterTests"
  "ClaudeCodeAdapterTests"
  "CodexAppServerClientTests"
  "ProcessProviderConnectionTests"
  "AIProviderProcessStoreTests"
  "AIModelsPresentationTests"
  "LocalAIContextPolicyTests"
  "LocalAIOutputContractTests"
  "LocalAIAnswerToolContractTests"
  "LocalAIEvalProtocolTests"
  "LocalAIPerformanceProtocolTests"
  "LocalAIPhysicalGateEnvironmentTests"
)

TEST_FILTERS=()
for suite in "${PURE_TEST_SUITES[@]}"; do
  TEST_FILTERS+=("-only-testing:ZBSEyeTests/${suite}")
done

if [ "$RUN_QUALITY_GATE" -eq 1 ]; then
  TEST_FILTERS=("-only-testing:ZBSEyeTests/LocalAIQualityGateV9Tests/testReleaseEnglishRussianFourConsumerQuality")
elif [ "$RUN_QUALITY_PROBE" -eq 1 ]; then
  TEST_FILTERS=("-only-testing:ZBSEyeTests/LocalAIQualityGateV9Tests/testBoundedEnglishRussianFourConsumerProbe")
elif [ "$RUN_PERFORMANCE_GATE" -eq 1 ]; then
  TEST_FILTERS=("-only-testing:ZBSEyeTests/MLXRuntimeQualificationTests")
elif [ "$RUN_ALL_FIXTURES" -eq 1 ]; then
  TEST_FILTERS=()
elif [ "$RUN_RUNTIME_SMOKE" -eq 1 ]; then
  TEST_FILTERS+=("-only-testing:ZBSEyeTests/MLXRuntimeSmokeTests")
fi

CONFIGURATION="Debug"
# Xcode 26 can leave an otherwise-successful empty parallel worker alive after
# the unhosted bundle finishes, so xcodebuild never returns. This gate values a
# deterministic result over a few seconds of fan-out.
XCODE_TEST_OPTIONS=("-parallel-testing-enabled" "NO")
if [ "$PHYSICAL_RELEASE_COUNT" -gt 0 ]; then
  CONFIGURATION="Release"
  XCODE_TEST_OPTIONS=(
    "-parallel-testing-enabled" "NO"
  )
fi

set +e
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  ZBS_EYE_MODEL_DIR="$MODEL_DIR" \
  ZBS_EYE_LOCAL_AI_QUALITY_GATE="${ZBS_EYE_LOCAL_AI_QUALITY_GATE:-}" \
  ZBS_EYE_LOCAL_AI_QUALITY_PROBE="${ZBS_EYE_LOCAL_AI_QUALITY_PROBE:-}" \
  ZBS_EYE_LOCAL_AI_PERFORMANCE_GATE="${ZBS_EYE_LOCAL_AI_PERFORMANCE_GATE:-}" \
  ZBS_EYE_SOURCE_REVISION="$SOURCE_REVISION" \
  ZBS_EYE_SOURCE_TREE_STATE="$SOURCE_TREE_STATE" \
  ZBS_EYE_SWIFT_COMPILER_VERSION="$SWIFT_COMPILER_VERSION" \
  ZBS_EYE_XCODE_VERSION="$XCODE_VERSION" \
  ZBS_EYE_SDK_VERSION="$SDK_VERSION" \
  "${XCODE_TEST_OPTIONS[@]}" \
  "${TEST_FILTERS[@]}" test >"$LOG" 2>&1
XC_STATUS=$?
set -e

grep -E "error:|warning:|Test Suite|Executed|TEST (SUCCEEDED|FAILED)" "$LOG" || true
[ "$XC_STATUS" -eq 0 ] || {
  echo "❌ Local AI tests failed (exit $XC_STATUS); full log: $LOG" >&2
  trap - EXIT
  exit "$XC_STATUS"
}
grep -q "\*\* TEST SUCCEEDED \*\*" "$LOG" || {
  echo "❌ xcodebuild exited successfully without TEST SUCCEEDED; full log: $LOG" >&2
  trap - EXIT
  exit 1
}

require_suite_ran_without_skip() {
  local suite="$1"
  grep -Fq "Test Suite '$suite'" "$LOG" || {
    echo "❌ $suite did not run; full log: $LOG" >&2
    trap - EXIT
    exit 1
  }
  if grep -Eiq "${suite}.*skipp" "$LOG"; then
    echo "❌ $suite was skipped; full log: $LOG" >&2
    trap - EXIT
    exit 1
  fi
}

if [ "$MODEL_GATE_COUNT" -eq 0 ]; then
  for suite in "${PURE_TEST_SUITES[@]}"; do
    require_suite_ran_without_skip "$suite"
  done
fi

if [ "$RUN_PERFORMANCE_GATE" -eq 1 ]; then
  require_suite_ran_without_skip "MLXRuntimeQualificationTests"
  if grep -Eiq "MLXRuntimeQualificationTests.*skipp|Executed 1 test, with 1 test skipped" "$LOG"; then
    echo "❌ MLXRuntimeQualificationTests was skipped; full log: $LOG" >&2
    trap - EXIT
    exit 1
  fi
fi

if [ "$RUN_RUNTIME_SMOKE" -eq 1 ]; then
  require_suite_ran_without_skip "MLXRuntimeSmokeTests"
  if grep -Eiq "MLXRuntimeSmokeTests.*skipp|Executed 1 test, with 1 test skipped" "$LOG"; then
    echo "❌ MLXRuntimeSmokeTests was skipped; full log: $LOG" >&2
    trap - EXIT
    exit 1
  fi
fi

if [ "$RUN_QUALITY_GATE" -eq 1 ]; then
  require_suite_ran_without_skip "LocalAIQualityGateV9Tests"
  if grep -Eiq "LocalAIQualityGateV9Tests.*skipp|Executed 1 test, with 1 test skipped" "$LOG"; then
    echo "❌ LocalAIQualityGateV9Tests was skipped; full log: $LOG" >&2
    trap - EXIT
    exit 1
  fi
fi

if [ "$RUN_QUALITY_PROBE" -eq 1 ]; then
  require_suite_ran_without_skip "LocalAIQualityGateV9Tests"
  if grep -Eiq "LocalAIQualityGateV9Tests.*skipp|Executed 1 test, with 1 test skipped" "$LOG"; then
    echo "❌ LocalAIQualityGateV9Tests bounded probe was skipped; full log: $LOG" >&2
    trap - EXIT
    exit 1
  fi
fi

[ -f "$RESOLVED" ] || {
  echo "❌ Swift package lockfile was not generated: $RESOLVED" >&2
  exit 1
}

require_pin() {
  local identity="$1"
  local version="$2"
  if ! grep -A8 "\"identity\" : \"${identity}\"" "$RESOLVED" | grep -q "\"version\" : \"${version}\""; then
    echo "❌ Expected ${identity} ${version} in $RESOLVED" >&2
    exit 1
  fi
}

require_pin "mlx-swift-lm" "3.31.4"
require_pin "mlx-swift" "0.31.4"
require_pin "swift-transformers" "1.3.3"

if [ "$RUN_PERFORMANCE_GATE" -eq 1 ]; then
  echo "✅ Local AI performance gate green (offline Release, serial, single run: $MODEL_DIR)"
elif [ "$RUN_QUALITY_GATE" -eq 1 ]; then
  echo "✅ Local AI V9 quality gate green (offline Release, single run: $MODEL_DIR)"
elif [ "$RUN_QUALITY_PROBE" -eq 1 ]; then
  echo "✅ Local AI V9 bounded quality probe green (offline Release, 8 cases, 24 attempts, non-qualifying: $MODEL_DIR)"
elif [ "$RUN_RUNTIME_SMOKE" -eq 1 ]; then
  echo "✅ Local AI contracts + MLX runtime smoke green (offline: $MODEL_DIR)"
elif [ "$RUN_ALL_FIXTURES" -eq 1 ]; then
  echo "✅ All Local AI fixtures green (no model weights used)"
else
  echo "✅ Local AI U1-U3 contracts, persistence, provisioning, context, output, and protocols green (no model weights used)"
fi
