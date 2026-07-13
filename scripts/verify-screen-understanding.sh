#!/bin/bash
# Offline screen-understanding evaluation gate. This script never downloads a model or publishes raw data.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="fixtures"
DATASET_ROOT=""
ANNOTATION_ROOT=""
SOURCE_ANNOTATION_ROOT=""
CORRECTNESS_AUDIT_ROOT=""
AGGREGATE_ROOT=""
FINAL_AUDIT_ROOT=""
FINAL_JUDGMENTS=""
MODEL_ROOT=""
RESULT_ROOT=""
METHODS=""
SOURCE_ROOT=""
OUTPUT_ROOT=""
TRACE_CALENDAR=""
TRACE_TIME_ZONE=""
TRACE_NOW_MS=""
TRACE_MINIMUM_ELAPSED_MS=""
TRACE_MINIMUM_ACTIVITY_COUNT=""

usage() {
  printf '%s\n' \
    "Usage: scripts/verify-screen-understanding.sh [mode] [roots]" \
    "" \
    "  --fixtures              Run protocol/privacy/adapter/scorer fixture tests (default)." \
    "  --prepare-dataset       Build and run the headless private dataset preparer." \
    "  --quality-matrix        Run the locked private quality matrix." \
    "  --performance-matrix    Run the locked product-footprint matrix." \
    "  --source-root PATH      Explicit read-only ZBS Eye data root for preparation." \
    "  --output-root PATH      Explicit new private corpus root for preparation." \
    "  --trace-calendar gregorian  Locked trace calendar for preparation." \
    "  --trace-time-zone IANA  Locked IANA trace time zone for preparation." \
    "  --trace-now-ms UNIX_MS  Locked preparation cutoff in Unix milliseconds." \
    "  --trace-minimum-elapsed-ms N  Locked minimum elapsed trace coverage." \
    "  --trace-minimum-activity-count N  Locked minimum trace activity count." \
    "  --dataset-root PATH     Explicit sealed private corpus root for a physical gate." \
    "  --annotation-root PATH  Explicit sealed canonical annotation root." \
    "  --source-annotation-root PATH  Explicit source annotation evidence root." \
    "  --correctness-audit-root PATH  Explicit correctness-audit evidence root." \
    "  --aggregate-root PATH    Explicit correctness aggregate evidence root." \
    "  --final-audit-root PATH  Explicit final-reference audit evidence root." \
    "  --final-judgments PATH   Explicit final-reference judgments file." \
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

require_clean_source() {
  git diff-index --quiet HEAD -- || die "$1 requires a clean tracked source tree"
  [ -z "$(git ls-files --others --exclude-standard -- '*.swift' '*.py' '*.json' '*.sh')" ] \
    || die "$1 requires no untracked executable or benchmark source files"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fixtures) MODE="fixtures" ;;
    --prepare-dataset) MODE="prepare" ;;
    --quality-matrix) MODE="quality" ;;
    --performance-matrix) MODE="performance" ;;
    --source-root)
      [ "$#" -ge 2 ] || die "--source-root requires a path"
      SOURCE_ROOT="$2"
      shift
      ;;
    --output-root)
      [ "$#" -ge 2 ] || die "--output-root requires a path"
      OUTPUT_ROOT="$2"
      shift
      ;;
    --trace-calendar)
      [ "$#" -ge 2 ] || die "--trace-calendar requires gregorian"
      TRACE_CALENDAR="$2"
      shift
      ;;
    --trace-time-zone)
      [ "$#" -ge 2 ] || die "--trace-time-zone requires an IANA identifier"
      TRACE_TIME_ZONE="$2"
      shift
      ;;
    --trace-now-ms)
      [ "$#" -ge 2 ] || die "--trace-now-ms requires Unix milliseconds"
      TRACE_NOW_MS="$2"
      shift
      ;;
    --trace-minimum-elapsed-ms)
      [ "$#" -ge 2 ] || die "--trace-minimum-elapsed-ms requires a positive integer"
      TRACE_MINIMUM_ELAPSED_MS="$2"
      shift
      ;;
    --trace-minimum-activity-count)
      [ "$#" -ge 2 ] || die "--trace-minimum-activity-count requires a positive integer"
      TRACE_MINIMUM_ACTIVITY_COUNT="$2"
      shift
      ;;
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
    --source-annotation-root)
      [ "$#" -ge 2 ] || die "--source-annotation-root requires a path"
      SOURCE_ANNOTATION_ROOT="$2"
      shift
      ;;
    --correctness-audit-root)
      [ "$#" -ge 2 ] || die "--correctness-audit-root requires a path"
      CORRECTNESS_AUDIT_ROOT="$2"
      shift
      ;;
    --aggregate-root)
      [ "$#" -ge 2 ] || die "--aggregate-root requires a path"
      AGGREGATE_ROOT="$2"
      shift
      ;;
    --final-audit-root)
      [ "$#" -ge 2 ] || die "--final-audit-root requires a path"
      FINAL_AUDIT_ROOT="$2"
      shift
      ;;
    --final-judgments)
      [ "$#" -ge 2 ] || die "--final-judgments requires a path"
      FINAL_JUDGMENTS="$2"
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

if [ "$MODE" = "prepare" ]; then
  [ -n "$SOURCE_ROOT" ] || die "prepare-dataset requires --source-root"
  [ -d "$SOURCE_ROOT" ] || die "prepare-dataset source root must be a directory"
  [ -n "$OUTPUT_ROOT" ] || die "prepare-dataset requires --output-root"
  [ ! -e "$OUTPUT_ROOT" ] || die "prepare-dataset output root must not exist"
  [ -d "$(dirname "$OUTPUT_ROOT")" ] || die "prepare-dataset output parent must be a directory"
  [ "$TRACE_CALENDAR" = "gregorian" ] \
    || die "prepare-dataset requires --trace-calendar gregorian"
  [ -n "$TRACE_TIME_ZONE" ] || die "prepare-dataset requires --trace-time-zone"
  [ -n "$TRACE_NOW_MS" ] || die "prepare-dataset requires --trace-now-ms"
  [ -n "$TRACE_MINIMUM_ELAPSED_MS" ] \
    || die "prepare-dataset requires --trace-minimum-elapsed-ms"
  [ -n "$TRACE_MINIMUM_ACTIVITY_COUNT" ] \
    || die "prepare-dataset requires --trace-minimum-activity-count"
  require_clean_source "prepare-dataset"
  REPOSITORY_ROOT="$(pwd -P)"
  SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd -P)"
  OUTPUT_ROOT="$(cd "$(dirname "$OUTPUT_ROOT")" && pwd -P)/$(basename "$OUTPUT_ROOT")"
  case "$SOURCE_ROOT/:$OUTPUT_ROOT/" in
    *"$REPOSITORY_ROOT/"*) die "prepare-dataset private roots must be outside the repository" ;;
  esac
  DATASET_DERIVED_DATA="$(mktemp -d -t zbseye-screen-dataset.XXXXXX)"
  DATASET_BUILD_LOG="$DATASET_DERIVED_DATA/build.log"
  trap 'rm -rf -- "$DATASET_DERIVED_DATA"' EXIT
  xcodegen generate >/dev/null
  set +e
  xcodebuild \
    -project ZBSEye.xcodeproj \
    -scheme ScreenUnderstandingDatasetCLI \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DATASET_DERIVED_DATA" \
    -clonedSourcePackagesDirPath build/DerivedData/SourcePackages \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    build >"$DATASET_BUILD_LOG" 2>&1
  DATASET_BUILD_STATUS=$?
  set -e
  [ "$DATASET_BUILD_STATUS" -eq 0 ] || {
    grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$DATASET_BUILD_LOG" >&2 || true
    die "ScreenUnderstandingDatasetCLI build failed"
  }
  DATASET_CLI="$DATASET_DERIVED_DATA/Build/Products/Release/ScreenUnderstandingDatasetCLI"
  [ -x "$DATASET_CLI" ] || die "ScreenUnderstandingDatasetCLI product is missing"
  "$DATASET_CLI" \
    --source-root "$SOURCE_ROOT" \
    --output-root "$OUTPUT_ROOT" \
    --repository-root "$REPOSITORY_ROOT" \
    --trace-calendar "$TRACE_CALENDAR" \
    --trace-time-zone "$TRACE_TIME_ZONE" \
    --trace-now-ms "$TRACE_NOW_MS" \
    --trace-minimum-elapsed-ms "$TRACE_MINIMUM_ELAPSED_MS" \
    --trace-minimum-activity-count "$TRACE_MINIMUM_ACTIVITY_COUNT"
  exit 0
fi

if [ "$MODE" = "quality" ]; then
  [ -n "$DATASET_ROOT" ] && [ -d "$DATASET_ROOT" ] || die "physical gate requires --dataset-root"
  [ -n "$ANNOTATION_ROOT" ] && [ -d "$ANNOTATION_ROOT" ] \
    || die "physical gate requires --annotation-root"
  [ -n "$SOURCE_ANNOTATION_ROOT" ] && [ -d "$SOURCE_ANNOTATION_ROOT" ] \
    || die "physical gate requires --source-annotation-root"
  [ -n "$CORRECTNESS_AUDIT_ROOT" ] && [ -d "$CORRECTNESS_AUDIT_ROOT" ] \
    || die "physical gate requires --correctness-audit-root"
  [ -n "$AGGREGATE_ROOT" ] && [ -d "$AGGREGATE_ROOT" ] \
    || die "physical gate requires --aggregate-root"
  [ -n "$FINAL_AUDIT_ROOT" ] && [ -d "$FINAL_AUDIT_ROOT" ] \
    || die "physical gate requires --final-audit-root"
  [ -n "$FINAL_JUDGMENTS" ] && [ -f "$FINAL_JUDGMENTS" ] \
    && [ ! -L "$FINAL_JUDGMENTS" ] \
    || die "physical gate requires --final-judgments"
  [ -n "$METHODS" ] || die "physical gate requires --methods"
  [ -n "$RESULT_ROOT" ] && [ -d "$RESULT_ROOT" ] \
    || die "physical gate requires --result-root"
  DATASET_ROOT="$(cd "$DATASET_ROOT" && pwd -P)"
  ANNOTATION_ROOT="$(cd "$ANNOTATION_ROOT" && pwd -P)"
  SOURCE_ANNOTATION_ROOT="$(cd "$SOURCE_ANNOTATION_ROOT" && pwd -P)"
  CORRECTNESS_AUDIT_ROOT="$(cd "$CORRECTNESS_AUDIT_ROOT" && pwd -P)"
  AGGREGATE_ROOT="$(cd "$AGGREGATE_ROOT" && pwd -P)"
  FINAL_AUDIT_ROOT="$(cd "$FINAL_AUDIT_ROOT" && pwd -P)"
  FINAL_JUDGMENTS="$(cd "$(dirname "$FINAL_JUDGMENTS")" && pwd -P)/$(basename "$FINAL_JUDGMENTS")"
  if [ -n "$MODEL_ROOT" ]; then
    [ -d "$MODEL_ROOT" ] || die "--model-root is not a directory"
    MODEL_ROOT="$(cd "$MODEL_ROOT" && pwd -P)"
  fi
  RESULT_ROOT="$(cd "$RESULT_ROOT" && pwd -P)"
  [ "$(stat -f '%OLp' "$RESULT_ROOT")" = "700" ] \
    || die "result root must have owner-only mode 700"
  REPOSITORY_ROOT="$(pwd -P)"
  case "$DATASET_ROOT:$ANNOTATION_ROOT:$SOURCE_ANNOTATION_ROOT:$CORRECTNESS_AUDIT_ROOT:$AGGREGATE_ROOT:$FINAL_AUDIT_ROOT:$FINAL_JUDGMENTS:$MODEL_ROOT:$RESULT_ROOT" in
    *"$REPOSITORY_ROOT"*) die "private/model/result roots must be outside the repository" ;;
  esac
  git diff-index --quiet HEAD -- || die "physical gate requires a clean tracked source tree"
  [ -z "$(git ls-files --others --exclude-standard -- '*.swift' '*.py' '*.json' '*.sh')" ] \
    || die "physical gate requires no untracked executable or benchmark source files"
  /usr/bin/python3 tools/screen-understanding-bench/runner/run_quality.py \
    --dataset-root "$DATASET_ROOT" \
    --annotation-root "$ANNOTATION_ROOT" \
    --source-annotation-root "$SOURCE_ANNOTATION_ROOT" \
    --correctness-audit-root "$CORRECTNESS_AUDIT_ROOT" \
    --aggregate-root "$AGGREGATE_ROOT" \
    --final-audit-root "$FINAL_AUDIT_ROOT" \
    --final-judgments "$FINAL_JUDGMENTS" \
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
  -clonedSourcePackagesDirPath build/DerivedData/SourcePackages \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
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

/usr/bin/python3 -m unittest discover -s tools/screen-understanding-bench/common -p 'test_*.py'
/usr/bin/python3 -m unittest discover -s tools/screen-understanding-bench/adapters -p 'test_*.py'
/usr/bin/python3 -m unittest discover -s tools/screen-understanding-bench/annotation -p 'test_*.py'
/usr/bin/python3 -m unittest discover -s tools/screen-understanding-bench/mapping -p 'test_*.py'
/usr/bin/python3 -m unittest discover -s tools/screen-understanding-bench/runner -p 'test_*.py'
/usr/bin/python3 -m unittest discover -s tools/screen-understanding-bench/sandbox -p 'test_*.py'
