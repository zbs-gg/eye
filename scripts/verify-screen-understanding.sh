#!/bin/bash
# Offline screen-understanding evaluation gate. This script never downloads a model or publishes raw data.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="fixtures"
DATASET_ROOT=""
ANNOTATION_ROOT=""
MODEL_ROOT=""
RESULT_ROOT=""
METHODS=""

usage() {
  printf '%s\n' \
    "Usage: scripts/verify-screen-understanding.sh [mode] [roots]" \
    "" \
    "  --fixtures              Run protocol/privacy/adapter/scorer fixture tests (default)." \
    "  --quality-matrix        Run the locked private quality matrix." \
    "  --performance-matrix    Run the locked product-footprint matrix." \
    "  --dataset-root PATH     Explicit sealed private corpus root for a physical gate." \
    "  --annotation-root PATH  Explicit sealed canonical annotation root." \
    "  --methods IDS           Comma-separated adapter IDs to run, in declared order." \
    "  --model-root PATH       Explicit sealed model/runtime root for a physical gate." \
    "  --result-root PATH      Explicit owner-only private result root for a physical gate." \
    "" \
    "Quality mode preflights only selected methods; built-ins do not require a model root."
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fixtures) MODE="fixtures" ;;
    --quality-matrix) MODE="quality" ;;
    --performance-matrix) MODE="performance" ;;
    --dataset-root)
      [ "$#" -ge 2 ] || die "--dataset-root requires a path"
      DATASET_ROOT="$2"
      shift
      ;;
    --annotation-root)
      [ "$#" -ge 2 ] || die "--annotation-root requires a path"
      ANNOTATION_ROOT="$2"
      shift
      ;;
    --methods)
      [ "$#" -ge 2 ] || die "--methods requires comma-separated adapter IDs"
      METHODS="$2"
      shift
      ;;
    --model-root)
      [ "$#" -ge 2 ] || die "--model-root requires a path"
      MODEL_ROOT="$2"
      shift
      ;;
    --result-root)
      [ "$#" -ge 2 ] || die "--result-root requires a path"
      RESULT_ROOT="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export ZBS_EYE_ALLOW_MODEL_DOWNLOADS=0
export PYTHONDONTWRITEBYTECODE=1
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy || true

if [ "$MODE" = "quality" ]; then
  [ -n "$DATASET_ROOT" ] && [ -d "$DATASET_ROOT" ] || die "physical gate requires --dataset-root"
  [ -n "$ANNOTATION_ROOT" ] && [ -d "$ANNOTATION_ROOT" ] \
    || die "physical gate requires --annotation-root"
  [ -n "$METHODS" ] || die "physical gate requires --methods"
  [ -n "$RESULT_ROOT" ] && [ -d "$RESULT_ROOT" ] \
    || die "physical gate requires --result-root"
  DATASET_ROOT="$(cd "$DATASET_ROOT" && pwd -P)"
  ANNOTATION_ROOT="$(cd "$ANNOTATION_ROOT" && pwd -P)"
  if [ -n "$MODEL_ROOT" ]; then
    [ -d "$MODEL_ROOT" ] || die "--model-root is not a directory"
    MODEL_ROOT="$(cd "$MODEL_ROOT" && pwd -P)"
  fi
  RESULT_ROOT="$(cd "$RESULT_ROOT" && pwd -P)"
  [ "$(stat -f '%OLp' "$RESULT_ROOT")" = "700" ] \
    || die "result root must have owner-only mode 700"
  REPOSITORY_ROOT="$(pwd -P)"
  case "$DATASET_ROOT:$ANNOTATION_ROOT:$MODEL_ROOT:$RESULT_ROOT" in
    *"$REPOSITORY_ROOT"*) die "private/model/result roots must be outside the repository" ;;
  esac
  git diff-index --quiet HEAD -- || die "physical gate requires a clean tracked source tree"
  [ -z "$(git ls-files --others --exclude-standard -- '*.swift' '*.py' '*.json' '*.sh')" ] \
    || die "physical gate requires no untracked executable or benchmark source files"
  /usr/bin/python3 tools/screen-understanding-bench/runner/run_quality.py \
    --dataset-root "$DATASET_ROOT" \
    --annotation-root "$ANNOTATION_ROOT" \
    --result-root "$RESULT_ROOT" \
    --methods "$METHODS"
  exit 0
fi

if [ "$MODE" = "performance" ]; then
  [ -n "$DATASET_ROOT" ] && [ -d "$DATASET_ROOT" ] || die "physical gate requires --dataset-root"
  [ -n "$MODEL_ROOT" ] && [ -d "$MODEL_ROOT" ] || die "physical gate requires --model-root"
  [ -n "$RESULT_ROOT" ] && [ -d "$RESULT_ROOT" ] || die "physical gate requires --result-root"
  DATASET_ROOT="$(cd "$DATASET_ROOT" && pwd -P)"
  MODEL_ROOT="$(cd "$MODEL_ROOT" && pwd -P)"
  RESULT_ROOT="$(cd "$RESULT_ROOT" && pwd -P)"
  REPOSITORY_ROOT="$(pwd -P)"
  case "$DATASET_ROOT:$MODEL_ROOT:$RESULT_ROOT" in
    *"$REPOSITORY_ROOT"*) die "private/model/result roots must be outside the repository" ;;
  esac
  [ "$(stat -f '%OLp' "$RESULT_ROOT")" = "700" ] \
    || die "result root must have owner-only mode 700"
  git diff-index --quiet HEAD -- || die "physical gate requires a clean tracked source tree"
  [ -z "$(git ls-files --others --exclude-standard -- '*.swift' '*.py' '*.json' '*.sh')" ] \
    || die "physical gate requires no untracked executable or benchmark source files"
  if jq -e '.adapters[] | select(.status == "security-unsupported")' \
      tools/screen-understanding-bench/adapters/manifest.json >/dev/null; then
    printf '%s\n' \
      "security-unsupported: the inherited OS sandbox boundary is not proven; private matrix not started" >&2
    exit 3
  fi
  die "physical performance runner is unavailable until sandbox qualification passes"
fi

jq empty \
  docs/evals/screen-understanding-v1.json \
  docs/evals/screen-understanding-sandbox-qualification-2026-07-13.json \
  docs/evals/screen-understanding-status-2026-07-13.json \
  tools/screen-understanding-bench/adapters/manifest.json \
  tools/screen-understanding-bench/schemas/labels.schema.json \
  tools/screen-understanding-bench/schemas/normalized-result.schema.json \
  tools/screen-understanding-bench/schemas/public-aggregate.schema.json \
  tools/screen-understanding-bench/schemas/report.schema.json

xcodegen generate
LOG="$(mktemp -t zbseye-screen-understanding.XXXXXX)"
trap 'rm -f "$LOG"' EXIT
set +e
xcodebuild \
  -project ZBSEye.xcodeproj \
  -scheme ZBSEye \
  -configuration Debug \
  -derivedDataPath build/ScreenUnderstandingDerivedData \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  test \
  -only-testing:ZBSEyeTests/ScreenUnderstandingEvalProtocolTests \
  -only-testing:ZBSEyeTests/ScreenUnderstandingDatasetPolicyTests \
  -only-testing:ZBSEyeTests/ScreenUnderstandingDatasetPreparationTests \
  -only-testing:ZBSEyeTests/ScreenUnderstandingAdapterContractTests \
  -only-testing:ZBSEyeTests/ScreenUnderstandingVisionAdapterTests \
  -only-testing:ZBSEyeTests/ScreenUnderstandingScoringTests \
  -only-testing:ZBSEyeTests/ScreenUnderstandingPerformanceProtocolTests \
  -only-testing:ZBSEyeTests/ScreenUnderstandingBenchmarkTests >"$LOG" 2>&1
XC_STATUS=$?
set -e

grep -E "error:|warning:|Test Suite|Executed|TEST (SUCCEEDED|FAILED)" "$LOG" || true
[ "$XC_STATUS" -eq 0 ] || {
  printf 'error: screen-understanding Xcode tests failed (exit %s); full log: %s\n' \
    "$XC_STATUS" "$LOG" >&2
  trap - EXIT
  exit "$XC_STATUS"
}
grep -q "\*\* TEST SUCCEEDED \*\*" "$LOG" || {
  printf 'error: xcodebuild exited without TEST SUCCEEDED; full log: %s\n' "$LOG" >&2
  trap - EXIT
  exit 1
}

/usr/bin/python3 -m unittest discover -s tools/screen-understanding-bench/annotation -p 'test_*.py'
/usr/bin/python3 -m unittest discover -s tools/screen-understanding-bench/mapping -p 'test_*.py'
/usr/bin/python3 -m unittest discover -s tools/screen-understanding-bench/runner -p 'test_*.py'
