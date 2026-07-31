#!/bin/bash
# Qualifies one installed, notarized ZBS Eye candidate against the native
# macOS screenshot path. The operator owns every app transition; this script
# only observes process state and takes disposable screenshots.
set -euo pipefail
cd "$(dirname "$0")/.."

PROTOCOL_ID="capture-coexistence-v1"
EXPECTED_APP="/Applications/ZBS Eye.app"
EXPECTED_BUNDLE_ID="gg.zbs.eye"
EXPECTED_TEAM_ID="44N4NZ86S5"
WARMUP_COUNT=5
MEASURED_COUNT=40
P95_DELTA_LIMIT_MS=200
ATTEMPT_LIMIT_MS=1000
CONTROL_DRIFT_LIMIT_MS=200
PHASES=(baseline-a eye baseline-b codex baseline-c eye-codex baseline-d)

APP=""
MANIFEST=""
EVIDENCE_BASE="${HOME}/Library/Application Support/ZBS Eye Qualification/capture-coexistence"
SESSION=""
ACTIVE_SHOT=""
SELF_TEST=0

usage() {
  /bin/echo "Usage: scripts/verify-capture-coexistence.sh --app \"/Applications/ZBS Eye.app\" [options]"
  /bin/echo ""
  /bin/echo "  --manifest PATH       Exact adjacent release manifest. If omitted, find one"
  /bin/echo "                        unique matching manifest in dist/."
  /bin/echo "  --evidence-root PATH  Private output base outside the repository."
  /bin/echo "  --self-test           Exercise metrics and classification with synthetic data."
  /bin/echo "  -h, --help            Show this help."
}

die_usage() {
  /bin/echo "ERROR: $1" >&2
  /bin/echo "" >&2
  usage >&2
  exit 2
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

manifest_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

now_ms() {
  /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf("%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000)'
}

run_with_deadline_ms() {
  local limit_ms="$1"
  shift
  "$@" &
  local child=$! deadline
  deadline=$(( $(now_ms) + limit_ms ))
  while /bin/kill -0 "$child" >/dev/null 2>&1; do
    if [ "$(now_ms)" -ge "$deadline" ]; then
      /bin/kill -TERM "$child" >/dev/null 2>&1 || true
      /bin/sleep 0.02
      /bin/kill -KILL "$child" >/dev/null 2>&1 || true
      wait "$child" >/dev/null 2>&1 || true
      return 124
    fi
    /bin/sleep 0.02
  done
  wait "$child"
}

phase_key() {
  case "$1" in
    baseline-a) /bin/echo "baselineA" ;;
    eye) /bin/echo "eye" ;;
    baseline-b) /bin/echo "baselineB" ;;
    codex) /bin/echo "codex" ;;
    baseline-c) /bin/echo "baselineC" ;;
    eye-codex) /bin/echo "eyeCodex" ;;
    baseline-d) /bin/echo "baselineD" ;;
    *) return 1 ;;
  esac
}

summary_value() {
  /usr/bin/awk -F '\t' -v phase="$2" -v column="$3" '$1 == phase { print $column }' "$1"
}

summarize_phase() {
  local phase="$1"
  local input="${SESSION}/${phase}.tsv"
  local sorted="${SESSION}/.${phase}.sorted"
  /usr/bin/tail -n +2 "$input" | /usr/bin/awk -F '\t' '{print $2}' | /usr/bin/sort -n > "$sorted"
  local count
  count=$(/usr/bin/wc -l < "$sorted" | /usr/bin/tr -d ' ')
  [ "$count" -eq "$MEASURED_COUNT" ] || return 1
  local p50_rank=$(( (count * 50 + 99) / 100 ))
  local p95_rank=$(( (count * 95 + 99) / 100 ))
  local p50 p95 maximum
  p50=$(/usr/bin/sed -n "${p50_rank}p" "$sorted")
  p95=$(/usr/bin/sed -n "${p95_rank}p" "$sorted")
  maximum=$(/usr/bin/tail -n 1 "$sorted")
  /bin/rm -f "$sorted"
  /usr/bin/printf '%s\t%s\t%s\t%s\n' "$phase" "$p50" "$p95" "$maximum"
}

classify_summary() {
  local summary="$1"
  local a b c d eye codex both
  a=$(summary_value "$summary" baseline-a 3)
  eye=$(summary_value "$summary" eye 3)
  b=$(summary_value "$summary" baseline-b 3)
  codex=$(summary_value "$summary" codex 3)
  c=$(summary_value "$summary" baseline-c 3)
  both=$(summary_value "$summary" eye-codex 3)
  d=$(summary_value "$summary" baseline-d 3)
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] || {
    /bin/echo "invalid"
    return
  }

  local control_min control_max
  control_min=$(/usr/bin/printf '%s\n' "$a" "$b" "$c" "$d" | /usr/bin/sort -n | /usr/bin/head -n 1)
  control_max=$(/usr/bin/printf '%s\n' "$a" "$b" "$c" "$d" | /usr/bin/sort -n | /usr/bin/tail -n 1)
  if [ $((control_max - control_min)) -gt "$CONTROL_DRIFT_LIMIT_MS" ]; then
    /bin/echo "invalid"
    return
  fi

  local baseline_max codex_max eye_max both_max
  baseline_max=$(/usr/bin/awk -F '\t' '$1 ~ /^baseline-/ { if ($4 > max) max = $4 } END { print max + 0 }' "$summary")
  codex_max=$(summary_value "$summary" codex 4)
  eye_max=$(summary_value "$summary" eye 4)
  both_max=$(summary_value "$summary" eye-codex 4)
  if [ "$baseline_max" -gt "$ATTEMPT_LIMIT_MS" ] || [ "$codex_max" -gt "$ATTEMPT_LIMIT_MS" ]; then
    /bin/echo "upstream-blocked"
    return
  fi
  if [ "$eye_max" -gt "$ATTEMPT_LIMIT_MS" ] || [ "$both_max" -gt "$ATTEMPT_LIMIT_MS" ]; then
    /bin/echo "Eye no-go"
    return
  fi

  local eye_baseline=$(( (a + b) / 2 ))
  local codex_baseline=$(( (b + c) / 2 ))
  local both_baseline=$(( (c + d) / 2 ))
  if [ $((eye - eye_baseline)) -gt "$P95_DELTA_LIMIT_MS" ]; then
    /bin/echo "Eye no-go"
    return
  fi
  if [ $((codex - codex_baseline)) -gt "$P95_DELTA_LIMIT_MS" ]; then
    /bin/echo "upstream-blocked"
    return
  fi
  if [ $((both - both_baseline)) -gt "$P95_DELTA_LIMIT_MS" ]; then
    /bin/echo "Eye no-go"
    return
  fi
  /bin/echo "pass"
}

write_fixture_summary() {
  local path="$1"
  shift
  /usr/bin/printf 'phase\tp50_ms\tp95_ms\tmax_ms\n' > "$path"
  while [ "$#" -gt 0 ]; do
    /usr/bin/printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$path"
    shift 4
  done
}

run_self_test() {
  local root
  root=$(/usr/bin/mktemp -d -t zbseye-capture-protocol.XXXXXX)
  trap "/bin/rm -rf \"${root}\"" EXIT
  local summary="${root}/summary.tsv"
  write_fixture_summary "$summary" \
    baseline-a 80 100 140 eye 100 150 190 baseline-b 85 110 150 \
    codex 95 140 180 baseline-c 80 105 145 eye-codex 105 160 200 \
    baseline-d 80 100 140
  [ "$(classify_summary "$summary")" = "pass" ] || return 1
  write_fixture_summary "$summary" \
    baseline-a 80 100 140 eye 100 150 190 baseline-b 85 110 150 \
    codex 95 140 180 baseline-c 80 105 145 eye-codex 105 160 200 \
    baseline-d 400 450 480
  [ "$(classify_summary "$summary")" = "invalid" ] || return 1
  write_fixture_summary "$summary" \
    baseline-a 80 100 140 eye 350 500 700 baseline-b 85 110 150 \
    codex 95 140 180 baseline-c 80 105 145 eye-codex 105 160 200 \
    baseline-d 80 100 140
  [ "$(classify_summary "$summary")" = "Eye no-go" ] || return 1
  write_fixture_summary "$summary" \
    baseline-a 80 100 140 eye 100 150 190 baseline-b 85 110 150 \
    codex 350 500 700 baseline-c 80 105 145 eye-codex 105 160 200 \
    baseline-d 80 100 140
  [ "$(classify_summary "$summary")" = "upstream-blocked" ] || return 1
  if run_with_deadline_ms 25 /bin/sleep 1; then
    return 1
  fi
  /bin/echo "capture coexistence protocol self-test: ok"
}

find_matching_manifest() {
  local executable_hash="$1"
  local matches=()
  local candidate
  for candidate in dist/*.manifest.json; do
    [ -f "$candidate" ] || continue
    if [ "$(manifest_value "$candidate" executableSHA256)" = "$executable_hash" ]; then
      matches+=("$candidate")
    fi
  done
  [ "${#matches[@]}" -eq 1 ] || return 1
  /bin/echo "${matches[0]}"
}

verify_candidate() {
  [ -d "$APP" ] || die_usage "installed app does not exist: $APP"
  local canonical
  canonical="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
  [ "$canonical" = "$EXPECTED_APP" ] || die_usage "physical gate requires ${EXPECTED_APP}"
  [ -f "$APP/Contents/Info.plist" ] || die_usage "installed app has no Info.plist"
  local executable="$APP/Contents/MacOS/ZBS Eye"
  [ -x "$executable" ] || die_usage "installed app executable is missing"
  local executable_hash
  executable_hash=$(sha256_file "$executable")
  if [ -z "$MANIFEST" ]; then
    MANIFEST=$(find_matching_manifest "$executable_hash") \
      || die_usage "pass the unique release --manifest matching the installed executable"
  fi
  [ -f "$MANIFEST" ] || die_usage "manifest does not exist: $MANIFEST"
  MANIFEST="$(cd "$(dirname "$MANIFEST")" && pwd -P)/$(basename "$MANIFEST")"

  local tree_state="clean"
  if ! git diff-index --quiet HEAD -- || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    tree_state="dirty"
  fi
  [ "$tree_state" = "clean" ] || die_usage "physical gate requires a clean source tree"
  [ "$(manifest_value "$MANIFEST" sourceTreeState)" = "clean" ] \
    || die_usage "manifest sourceTreeState must be clean"
  [ "$(manifest_value "$MANIFEST" sourceRevision)" = "$(git rev-parse --verify HEAD)" ] \
    || die_usage "manifest source revision does not match HEAD"

  local bundle version build
  bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
  build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
  [ "$bundle" = "$EXPECTED_BUNDLE_ID" ] || die_usage "unexpected bundle identifier: $bundle"
  [ "$(manifest_value "$MANIFEST" bundleIdentifier)" = "$bundle" ] || die_usage "manifest bundle mismatch"
  [ "$(manifest_value "$MANIFEST" version)" = "$version" ] || die_usage "manifest version mismatch"
  [ "$(manifest_value "$MANIFEST" build)" = "$build" ] || die_usage "manifest build mismatch"

  local signing team cdhash requirement
  signing=$(codesign -dvvv "$APP" 2>&1)
  team=$(/usr/bin/sed -n 's/^TeamIdentifier=//p' <<< "$signing")
  cdhash=$(/usr/bin/sed -n 's/^CDHash=//p' <<< "$signing")
  requirement=$(codesign -d -r- "$APP" 2>&1 | /usr/bin/sed -n 's/^designated => //p')
  [ "$team" = "$EXPECTED_TEAM_ID" ] || die_usage "unexpected signing team: $team"
  [ "$(manifest_value "$MANIFEST" teamIdentifier)" = "$team" ] || die_usage "manifest team mismatch"
  [ "$(manifest_value "$MANIFEST" cdHash)" = "$cdhash" ] || die_usage "manifest CDHash mismatch"
  [ "$(manifest_value "$MANIFEST" designatedRequirement)" = "$requirement" ] \
    || die_usage "manifest designated requirement mismatch"
  [ "$(manifest_value "$MANIFEST" executableSHA256)" = "$executable_hash" ] \
    || die_usage "manifest executable hash mismatch"
  [ "$(manifest_value "$MANIFEST" notarized)" = "true" ] || die_usage "manifest does not attest notarization"
  [ "$(manifest_value "$MANIFEST" stapled)" = "true" ] || die_usage "manifest does not attest stapling"
  [ "$(manifest_value "$MANIFEST" gatekeeperAccepted)" = "true" ] \
    || die_usage "manifest does not attest Gatekeeper acceptance"
  codesign --verify --strict --verbose=2 "$APP" >/dev/null
  xcrun stapler validate "$APP" >/dev/null
  spctl -a -t exec "$APP" >/dev/null 2>&1 || die_usage "Gatekeeper rejected the installed app"

  local artifact zip_path
  artifact=$(manifest_value "$MANIFEST" artifact)
  zip_path="$(dirname "$MANIFEST")/${artifact}"
  [ -f "$zip_path" ] || die_usage "release archive adjacent to manifest is missing"
  [ "$(manifest_value "$MANIFEST" zipSHA256)" = "$(sha256_file "$zip_path")" ] \
    || die_usage "release archive hash mismatch"
}

phase_instructions() {
  case "$1" in
    baseline-a|baseline-b|baseline-c|baseline-d)
      /bin/echo "Quit ZBS Eye and Codex. Keep this script running in Terminal."
      ;;
    eye)
      /bin/echo "Launch the exact installed ZBS Eye candidate. Keep Codex quit."
      ;;
    codex)
      /bin/echo "Quit ZBS Eye and launch Codex."
      ;;
    eye-codex)
      /bin/echo "Launch both the exact installed ZBS Eye candidate and Codex."
      ;;
  esac
}

process_running() {
  /usr/bin/pgrep -x "$1" >/dev/null 2>&1
}

validate_eye_capture_health() {
  local health_file="${SESSION}/.eye-health.json"
  local port capturing state
  for port in 8731 8732 11435 8088; do
    if /usr/bin/curl --silent --fail --max-time 1 \
      "http://127.0.0.1:${port}/health" -o "$health_file"; then
      capturing=$(/usr/bin/plutil -extract capturing raw -o - "$health_file" 2>/dev/null || true)
      state=$(/usr/bin/plutil -extract captureState raw -o - "$health_file" 2>/dev/null || true)
      if [ "$capturing" = "true" ] && [ "$state" = "healthy" ]; then
        /bin/rm -f "$health_file"
        return 0
      fi
    fi
  done
  /bin/rm -f "$health_file"
  return 1
}

validate_phase_state() {
  local phase="$1"
  local want_eye=0 want_codex=0
  case "$phase" in
    eye) want_eye=1 ;;
    codex) want_codex=1 ;;
    eye-codex) want_eye=1; want_codex=1 ;;
  esac
  local has_eye=0 has_codex=0
  process_running "ZBS Eye" && has_eye=1
  process_running "Codex" && has_codex=1
  [ "$has_eye" -eq "$want_eye" ] && [ "$has_codex" -eq "$want_codex" ] || return 1
  if [ "$want_eye" -eq 1 ]; then
    local pid command
    pid=$(/usr/bin/pgrep -x "ZBS Eye" | /usr/bin/head -n 1)
    command=$(/bin/ps -p "$pid" -o command=)
    [[ "$command" == "$APP/Contents/MacOS/ZBS Eye"* ]] || return 1
    validate_eye_capture_health || return 1
  fi
}

take_disposable_screenshot() {
  local output="$1"
  local start end width height
  ACTIVE_SHOT="${SESSION}/.capture-current.png"
  /bin/rm -f "$ACTIVE_SHOT"
  start=$(now_ms)
  run_with_deadline_ms "$ATTEMPT_LIMIT_MS" \
    /usr/sbin/screencapture -x -t png "$ACTIVE_SHOT" >/dev/null 2>&1 || return 1
  end=$(now_ms)
  [ -s "$ACTIVE_SHOT" ] || return 1
  local dimensions
  dimensions=$(/usr/bin/sips -g pixelWidth -g pixelHeight "$ACTIVE_SHOT" 2>/dev/null) || return 1
  width=$(/bin/echo "$dimensions" | /usr/bin/awk '/pixelWidth:/ {print $2}')
  height=$(/bin/echo "$dimensions" | /usr/bin/awk '/pixelHeight:/ {print $2}')
  [ "${width:-0}" -gt 0 ] && [ "${height:-0}" -gt 0 ] || return 1
  /bin/rm -f "$ACTIVE_SHOT"
  ACTIVE_SHOT=""
  /bin/echo $((end - start)) > "$output"
}

measure_phase() {
  local phase="$1"
  local output="${SESSION}/${phase}.tsv"
  /usr/bin/printf 'attempt\tlatency_ms\n' > "$output"
  /bin/echo "Warming up ${phase} (${WARMUP_COUNT})..."
  local i latency_file="${SESSION}/.latency"
  for ((i = 1; i <= WARMUP_COUNT; i += 1)); do
    take_disposable_screenshot "$latency_file" || return 1
  done
  /bin/echo "Measuring ${phase} (${MEASURED_COUNT})..."
  for ((i = 1; i <= MEASURED_COUNT; i += 1)); do
    take_disposable_screenshot "$latency_file" || return 1
    /usr/bin/printf '%s\t%s\n' "$i" "$(< "$latency_file")" >> "$output"
    /usr/bin/printf '.'
  done
  /bin/echo ""
  /bin/rm -f "$latency_file"
}

failure_result_for_phase() {
  case "$1" in
    baseline-*|codex) /bin/echo "upstream-blocked" ;;
    eye|eye-codex) /bin/echo "Eye no-go" ;;
    *) /bin/echo "invalid" ;;
  esac
}

write_result() {
  local result="$1"
  local failed_phase="${2:-}"
  local summary="${SESSION}/summary.tsv"
  local plist="${SESSION}/result.plist"
  local json="${SESSION}/result.json"
  /usr/bin/plutil -create xml1 "$plist"
  /usr/bin/plutil -insert protocolID -string "$PROTOCOL_ID" "$plist"
  /usr/bin/plutil -insert result -string "$result" "$plist"
  /usr/bin/plutil -insert sourceRevision -string "$(manifest_value "$MANIFEST" sourceRevision)" "$plist"
  /usr/bin/plutil -insert version -string "$(manifest_value "$MANIFEST" version)" "$plist"
  /usr/bin/plutil -insert build -string "$(manifest_value "$MANIFEST" build)" "$plist"
  /usr/bin/plutil -insert teamIdentifier -string "$(manifest_value "$MANIFEST" teamIdentifier)" "$plist"
  /usr/bin/plutil -insert cdHash -string "$(manifest_value "$MANIFEST" cdHash)" "$plist"
  /usr/bin/plutil -insert warmupCount -integer "$WARMUP_COUNT" "$plist"
  /usr/bin/plutil -insert measuredCount -integer "$MEASURED_COUNT" "$plist"
  /usr/bin/plutil -insert p95DeltaLimitMs -integer "$P95_DELTA_LIMIT_MS" "$plist"
  /usr/bin/plutil -insert attemptLimitMs -integer "$ATTEMPT_LIMIT_MS" "$plist"
  [ -z "$failed_phase" ] || /usr/bin/plutil -insert failedPhase -string "$failed_phase" "$plist"
  if [ -f "$summary" ]; then
    /usr/bin/plutil -insert metrics -dictionary "$plist"
    local phase key p50 p95 maximum
    for phase in "${PHASES[@]}"; do
      key=$(phase_key "$phase")
      p50=$(summary_value "$summary" "$phase" 2)
      p95=$(summary_value "$summary" "$phase" 3)
      maximum=$(summary_value "$summary" "$phase" 4)
      [ -n "$p50" ] || continue
      /usr/bin/plutil -insert "metrics.${key}" -dictionary "$plist"
      /usr/bin/plutil -insert "metrics.${key}.p50Ms" -integer "$p50" "$plist"
      /usr/bin/plutil -insert "metrics.${key}.p95Ms" -integer "$p95" "$plist"
      /usr/bin/plutil -insert "metrics.${key}.maxMs" -integer "$maximum" "$plist"
    done
  fi
  /usr/bin/plutil -convert json -o "$json" "$plist"
  /bin/rm -f "$plist"
  /bin/chmod 600 "$json"
}

run_physical_gate() {
  [ -t 0 ] || die_usage "run the physical gate interactively from Terminal, not from an app-owned terminal"
  verify_candidate
  mkdir -p "$EVIDENCE_BASE"
  chmod 700 "$EVIDENCE_BASE"
  EVIDENCE_BASE="$(cd "$EVIDENCE_BASE" && pwd -P)"
  local repo_root
  repo_root="$(pwd -P)"
  case "${EVIDENCE_BASE}/" in
    "${repo_root}/"*) die_usage "evidence root must stay outside the repository" ;;
  esac
  local stamp source_short
  stamp=$(/bin/date -u '+%Y%m%dT%H%M%SZ')
  source_short=$(manifest_value "$MANIFEST" sourceRevision | /usr/bin/cut -c1-12)
  SESSION="${EVIDENCE_BASE}/${stamp}-${source_short}"
  [ ! -e "$SESSION" ] || die_usage "qualification session already exists"
  mkdir "$SESSION"
  chmod 700 "$SESSION"
  umask 077
  /bin/cp "$MANIFEST" "${SESSION}/artifact.manifest.json"
  trap '/bin/rm -f "${ACTIVE_SHOT:-}" "${SESSION:-}/.latency"' EXIT

  /bin/echo "Candidate verified. No app will be launched or quit by this script."
  /bin/echo "Private metrics: ${SESSION}"
  local phase
  for phase in "${PHASES[@]}"; do
    /bin/echo ""
    /bin/echo "Phase: ${phase}"
    phase_instructions "$phase"
    /bin/echo "Press Return when that exact state is visible."
    IFS= read -r _
    if ! validate_phase_state "$phase"; then
      write_result "invalid" "$phase"
      /bin/echo "Result: invalid (process state did not match the bracket)."
      exit 1
    fi
    if ! measure_phase "$phase"; then
      local failure
      failure=$(failure_result_for_phase "$phase")
      write_result "$failure" "$phase"
      /bin/echo "Result: ${failure} (screenshot attempt failed or was undecodable)."
      exit 1
    fi
    if ! validate_phase_state "$phase"; then
      write_result "invalid" "$phase"
      /bin/echo "Result: invalid (process or capture health changed during the arm)."
      exit 1
    fi
  done

  local summary="${SESSION}/summary.tsv"
  /usr/bin/printf 'phase\tp50_ms\tp95_ms\tmax_ms\n' > "$summary"
  for phase in "${PHASES[@]}"; do
    summarize_phase "$phase" >> "$summary" || {
      write_result "invalid" "$phase"
      /bin/echo "Result: invalid (incomplete measured phase)."
      exit 1
    }
  done
  local result
  result=$(classify_summary "$summary")
  case "$result" in
    pass|"Eye no-go"|upstream-blocked|invalid) ;;
    *) result="invalid" ;;
  esac
  write_result "$result"
  /bin/echo ""
  /bin/echo "Result: ${result}"
  /bin/echo "Next: complete the native-shortcut, prompt-count, recovery, and soak checklist in docs/CAPTURE_COEXISTENCE.md."
  [ "$result" = "pass" ]
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      [ "$#" -ge 2 ] || die_usage "--app requires a path"
      APP="$2"
      shift
      ;;
    --manifest)
      [ "$#" -ge 2 ] || die_usage "--manifest requires a path"
      MANIFEST="$2"
      shift
      ;;
    --evidence-root)
      [ "$#" -ge 2 ] || die_usage "--evidence-root requires a path"
      EVIDENCE_BASE="$2"
      shift
      ;;
    --self-test)
      SELF_TEST=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die_usage "unknown option: $1" ;;
  esac
  shift
done

if [ "$SELF_TEST" -eq 1 ]; then
  [ -z "$APP" ] && [ -z "$MANIFEST" ] || die_usage "--self-test cannot be combined with physical options"
  run_self_test
  exit 0
fi

[ -n "$APP" ] || die_usage "--app is required"
run_physical_gate
