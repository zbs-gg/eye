#!/bin/bash
# Qualifies one installed, notarized ZBS Eye candidate against the native
# macOS screenshot path. The operator owns every app transition; this script
# only observes process state and takes disposable screenshots.
set -euo pipefail
cd "$(dirname "$0")/.."

PROTOCOL_ID="capture-coexistence-v2"
EXPECTED_APP="/Applications/ZBS Eye.app"
EXPECTED_BUNDLE_ID="gg.zbs.eye"
EXPECTED_TEAM_ID="44N4NZ86S5"
CHATGPT_EXECUTABLE="/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
CHRONICLE_EXECUTABLE="/Applications/ChatGPT.app/Contents/Resources/codex_chronicle"
WARMUP_COUNT=5
MEASURED_COUNT=100
P95_ATTRIBUTABLE_LIMIT_MS=50
ACTIVE_MAX_DELTA_LIMIT_MS=100
BASELINE_P95_DRIFT_LIMIT_MS=50
BASELINE_MAX_DRIFT_LIMIT_MS=100
ABSOLUTE_MAX_LIMIT_MS=500
ATTEMPT_LIMIT_MS=500
RANDOM_DELAY_MIN_MS=100
RANDOM_DELAY_MAX_MS=900
PHASES=(baseline-a eye baseline-b chatgpt-chronicle baseline-c eye-chronicle baseline-d eye-chronicle-call baseline-e)

APP=""
MANIFEST=""
DATA_ROOT=""
EVIDENCE_BASE="${HOME}/Library/Application Support/ZBS Eye Qualification/capture-coexistence"
SESSION=""
ACTIVE_SHOT=""
SELF_TEST=0
CALL_ATTESTED_BEFORE=0
CALL_ATTESTED_AFTER=0

usage() {
  /bin/echo "Usage: scripts/verify-capture-coexistence.sh --app \"/Applications/ZBS Eye.app\" --data-root PATH [options]"
  /bin/echo ""
  /bin/echo "  --manifest PATH       Exact adjacent release manifest. If omitted, find one"
  /bin/echo "                        unique matching manifest in dist/."
  /bin/echo "  --data-root PATH      Canonical data root used by the installed candidate."
  /bin/echo "                        Required; health is read only through its port file."
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
    chatgpt-chronicle) /bin/echo "chatgptChronicle" ;;
    baseline-c) /bin/echo "baselineC" ;;
    eye-chronicle) /bin/echo "eyeChronicle" ;;
    baseline-d) /bin/echo "baselineD" ;;
    eye-chronicle-call) /bin/echo "eyeChronicleCall" ;;
    baseline-e) /bin/echo "baselineE" ;;
    *) return 1 ;;
  esac
}

summary_value() {
  /usr/bin/awk -F '\t' -v phase="$2" -v column="$3" '$1 == phase { print $column }' "$1"
}

validate_summary_table() {
  /usr/bin/awk -F '\t' '
    NR == 1 {
      if ($0 != "phase\tp50_ms\tp95_ms\tmax_ms\terror_count\tempty_count\tstale_count") bad = 1
      next
    }
    $1 !~ /^(baseline-a|eye|baseline-b|chatgpt-chronicle|baseline-c|eye-chronicle|baseline-d|eye-chronicle-call|baseline-e)$/ { bad = 1 }
    NF != 7 || seen[$1]++ { bad = 1 }
    {
      for (column = 2; column <= 7; column += 1) {
        if ($column !~ /^[0-9]+$/) bad = 1
      }
    }
    END { exit(bad || NR != 10 ? 1 : 0) }
  ' "$1"
}

validate_log_table() {
  /usr/bin/awk -F '\t' '
    NR == 1 {
      if ($0 != "phase\tscreenshot_manager\tremote_queue_enqueue\tstream_output_missing\tstream_started") bad = 1
      next
    }
    $1 !~ /^(baseline-a|eye|baseline-b|chatgpt-chronicle|baseline-c|eye-chronicle|baseline-d|eye-chronicle-call|baseline-e)$/ { bad = 1 }
    NF != 5 || seen[$1]++ { bad = 1 }
    {
      for (column = 2; column <= 5; column += 1) {
        if ($column !~ /^[0-9]+$/) bad = 1
      }
    }
    END { exit(bad || NR != 10 ? 1 : 0) }
  ' "$1"
}

summarize_phase() {
  local phase="$1"
  local input="${SESSION}/${phase}.tsv"
  local sorted="${SESSION}/.${phase}.sorted"
  /usr/bin/tail -n +2 "$input" | /usr/bin/awk -F '\t' '$3 ~ /^[0-9]+$/ {print $3}' \
    | /usr/bin/sort -n > "$sorted"
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
  local errors empty stale
  errors=$(/usr/bin/awk -F '\t' '$4 == "error" {count += 1} END {print count + 0}' "$input")
  empty=$(/usr/bin/awk -F '\t' '$4 == "empty" {count += 1} END {print count + 0}' "$input")
  stale=$(/usr/bin/awk -F '\t' '$4 == "stale" {count += 1} END {print count + 0}' "$input")
  /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$phase" "$p50" "$p95" "$maximum" "$errors" "$empty" "$stale"
}

classify_summary() {
  local summary="$1"
  local logs="$2"
  if ! validate_summary_table "$summary" || ! validate_log_table "$logs"; then
    /bin/echo "invalid"
    return
  fi
  local baseline
  for baseline in baseline-a baseline-b baseline-c baseline-d baseline-e; do
    [ -n "$(summary_value "$summary" "$baseline" 3)" ] || {
      /bin/echo "invalid"
      return
    }
    if [ "$(summary_value "$summary" "$baseline" 5)" -ne 0 ] \
      || [ "$(summary_value "$summary" "$baseline" 6)" -ne 0 ] \
      || [ "$(summary_value "$summary" "$baseline" 7)" -ne 0 ] \
      || [ "$(summary_value "$summary" "$baseline" 4)" -gt "$ABSOLUTE_MAX_LIMIT_MS" ]; then
      /bin/echo "upstream-blocked"
      return
    fi
  done

  local left_baseline right_baseline
  while IFS=$'\t' read -r left_baseline right_baseline; do
    local left_p95 right_p95 left_max right_max p95_drift max_drift
    left_p95=$(summary_value "$summary" "$left_baseline" 3)
    right_p95=$(summary_value "$summary" "$right_baseline" 3)
    left_max=$(summary_value "$summary" "$left_baseline" 4)
    right_max=$(summary_value "$summary" "$right_baseline" 4)
    p95_drift=$((left_p95 > right_p95 ? left_p95 - right_p95 : right_p95 - left_p95))
    max_drift=$((left_max > right_max ? left_max - right_max : right_max - left_max))
    if [ "$p95_drift" -gt "$BASELINE_P95_DRIFT_LIMIT_MS" ] \
      || [ "$max_drift" -gt "$BASELINE_MAX_DRIFT_LIMIT_MS" ]; then
      /bin/echo "invalid"
      return
    fi
  done <<'BASELINES'
baseline-a	baseline-b
baseline-b	baseline-c
baseline-c	baseline-d
baseline-d	baseline-e
BASELINES

  local phase
  for phase in "${PHASES[@]}"; do
    [ -n "$(summary_value "$logs" "$phase" 2)" ] || {
      /bin/echo "invalid"
      return
    }
    if [[ "$phase" == baseline-* ]] || [ "$phase" = "chatgpt-chronicle" ]; then
      if [ "$(summary_value "$logs" "$phase" 2)" -ne 0 ] \
        || [ "$(summary_value "$logs" "$phase" 3)" -ne 0 ] \
        || [ "$(summary_value "$logs" "$phase" 4)" -ne 0 ] \
        || [ "$(summary_value "$logs" "$phase" 5)" -ne 0 ]; then
        /bin/echo "invalid"
        return
      fi
    else
      if [ "$(summary_value "$logs" "$phase" 2)" -ne 0 ] \
        || [ "$(summary_value "$logs" "$phase" 3)" -ne 0 ] \
        || [ "$(summary_value "$logs" "$phase" 4)" -ne 0 ] \
        || [ "$(summary_value "$logs" "$phase" 5)" -ne 1 ]; then
        /bin/echo "Eye no-go"
        return
      fi
    fi
  done

  if [ "$(summary_value "$summary" chatgpt-chronicle 5)" -ne 0 ] \
    || [ "$(summary_value "$summary" chatgpt-chronicle 6)" -ne 0 ] \
    || [ "$(summary_value "$summary" chatgpt-chronicle 7)" -ne 0 ]; then
    /bin/echo "upstream-blocked"
    return
  fi

  local active left right failure_result
  while IFS=$'\t' read -r active left right failure_result; do
    [ -n "$active" ] || continue
    if [ "$(summary_value "$summary" "$active" 5)" -ne 0 ] \
      || [ "$(summary_value "$summary" "$active" 6)" -ne 0 ] \
      || [ "$(summary_value "$summary" "$active" 7)" -ne 0 ]; then
      /bin/echo "$failure_result"
      return
    fi

    local active_p95 left_p95 right_p95 attributable_p95
    active_p95=$(summary_value "$summary" "$active" 3)
    left_p95=$(summary_value "$summary" "$left" 3)
    right_p95=$(summary_value "$summary" "$right" 3)
    attributable_p95=$((active_p95 - (left_p95 + right_p95) / 2))
    if [ "$attributable_p95" -gt "$P95_ATTRIBUTABLE_LIMIT_MS" ]; then
      /bin/echo "$failure_result"
      return
    fi

    local active_max left_max right_max adjacent_max
    active_max=$(summary_value "$summary" "$active" 4)
    left_max=$(summary_value "$summary" "$left" 4)
    right_max=$(summary_value "$summary" "$right" 4)
    adjacent_max=$((left_max > right_max ? left_max : right_max))
    if [ "$active_max" -gt "$ABSOLUTE_MAX_LIMIT_MS" ] \
      || [ "$active_max" -gt $((adjacent_max + ACTIVE_MAX_DELTA_LIMIT_MS)) ]; then
      /bin/echo "$failure_result"
      return
    fi
  done <<'ARMS'
eye	baseline-a	baseline-b	Eye no-go
chatgpt-chronicle	baseline-b	baseline-c	upstream-blocked
eye-chronicle	baseline-c	baseline-d	Eye no-go
eye-chronicle-call	baseline-d	baseline-e	Eye no-go
ARMS

  /bin/echo "pass"
}

write_fixture_summary() {
  local path="$1"
  shift
  /usr/bin/printf 'phase\tp50_ms\tp95_ms\tmax_ms\terror_count\tempty_count\tstale_count\n' > "$path"
  while [ "$#" -gt 0 ]; do
    /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$path"
    shift 7
  done
}

write_fixture_logs() {
  local path="$1"
  /usr/bin/printf 'phase\tscreenshot_manager\tremote_queue_enqueue\tstream_output_missing\tstream_started\n' > "$path"
  local phase starts
  for phase in "${PHASES[@]}"; do
    starts=0
    case "$phase" in eye|eye-chronicle|eye-chronicle-call) starts=1 ;; esac
    /usr/bin/printf '%s\t0\t0\t0\t%s\n' "$phase" "$starts" >> "$path"
  done
}

write_passing_fixture_summary() {
  write_fixture_summary "$1" \
    baseline-a 80 100 140 0 0 0 eye 90 130 180 0 0 0 baseline-b 85 110 150 0 0 0 \
    chatgpt-chronicle 95 140 190 0 0 0 baseline-c 80 105 145 0 0 0 \
    eye-chronicle 95 145 200 0 0 0 baseline-d 80 100 140 0 0 0 \
    eye-chronicle-call 100 145 210 0 0 0 baseline-e 85 105 150 0 0 0
}

mutate_fixture_cell() {
  local path="$1" phase="$2" column="$3" value="$4" next="${1}.next"
  /usr/bin/awk -F '\t' -v OFS='\t' -v phase="$phase" -v column="$column" -v value="$value" \
    '$1 == phase { $column = value } { print }' "$path" > "$next"
  /bin/mv "$next" "$path"
}

run_self_test() {
  local root
  root=$(/usr/bin/mktemp -d -t zbseye-capture-protocol.XXXXXX)
  trap "/bin/rm -rf \"${root}\"" EXIT
  local summary="${root}/summary.tsv" logs="${root}/log-summary.tsv"
  write_fixture_logs "$logs"
  write_passing_fixture_summary "$summary"
  [ "$(classify_summary "$summary" "$logs")" = "pass" ] || return 1

  mutate_fixture_cell "$summary" baseline-a 4 501
  [ "$(classify_summary "$summary" "$logs")" = "upstream-blocked" ] || return 1

  write_passing_fixture_summary "$summary"
  mutate_fixture_cell "$summary" eye 3 180
  [ "$(classify_summary "$summary" "$logs")" = "Eye no-go" ] || return 1

  write_passing_fixture_summary "$summary"
  mutate_fixture_cell "$summary" chatgpt-chronicle 3 200
  [ "$(classify_summary "$summary" "$logs")" = "upstream-blocked" ] || return 1

  write_passing_fixture_summary "$summary"
  mutate_fixture_cell "$summary" baseline-a 3 10
  mutate_fixture_cell "$summary" baseline-b 3 400
  [ "$(classify_summary "$summary" "$logs")" = "invalid" ] || return 1

  write_passing_fixture_summary "$summary"
  mutate_fixture_cell "$summary" eye 4 251
  [ "$(classify_summary "$summary" "$logs")" = "Eye no-go" ] || return 1

  local column
  for column in 5 6 7; do
    write_passing_fixture_summary "$summary"
    mutate_fixture_cell "$summary" eye "$column" 1
    [ "$(classify_summary "$summary" "$logs")" = "Eye no-go" ] || return 1
  done
  write_passing_fixture_summary "$summary"
  mutate_fixture_cell "$summary" baseline-c 5 1
  [ "$(classify_summary "$summary" "$logs")" = "upstream-blocked" ] || return 1

  for column in 2 3 4; do
    write_passing_fixture_summary "$summary"
    write_fixture_logs "$logs"
    mutate_fixture_cell "$logs" eye "$column" 1
    [ "$(classify_summary "$summary" "$logs")" = "Eye no-go" ] || return 1
  done
  write_fixture_logs "$logs"
  mutate_fixture_cell "$logs" eye 5 0
  [ "$(classify_summary "$summary" "$logs")" = "Eye no-go" ] || return 1
  write_fixture_logs "$logs"
  mutate_fixture_cell "$logs" baseline-a 5 1
  [ "$(classify_summary "$summary" "$logs")" = "invalid" ] || return 1

  write_passing_fixture_summary "$summary"
  write_fixture_logs "$logs"
  /usr/bin/awk -F '\t' '$1 != "baseline-e"' "$summary" > "${summary}.next"
  /bin/mv "${summary}.next" "$summary"
  [ "$(classify_summary "$summary" "$logs")" = "invalid" ] || return 1
  write_passing_fixture_summary "$summary"
  /usr/bin/awk -F '\t' '$1 == "eye" { print }' "$summary" > "${summary}.duplicate"
  /bin/cat "${summary}.duplicate" >> "$summary"
  /bin/rm -f "${summary}.duplicate"
  [ "$(classify_summary "$summary" "$logs")" = "invalid" ] || return 1
  write_passing_fixture_summary "$summary"
  /usr/bin/awk -F '\t' '$1 == "eye" { print }' "$logs" > "${logs}.duplicate"
  /bin/cat "${logs}.duplicate" >> "$logs"
  /bin/rm -f "${logs}.duplicate"
  [ "$(classify_summary "$summary" "$logs")" = "invalid" ] || return 1

  is_single_pid 123 || return 1
  ! is_single_pid "" || return 1
  ! is_single_pid 0 || return 1
  ! is_single_pid "123,124" || return 1
  ! is_single_pid "12x" || return 1
  [ "$(eye_pid_from_snapshot '123||')" = "123" ] || return 1
  ! eye_pid_from_snapshot '123,124||' >/dev/null || return 1
  validate_eye_pid_expectation 0 "" || return 1
  ! validate_eye_pid_expectation 0 123 || return 1
  validate_eye_pid_expectation 1 123 || return 1
  ! validate_eye_pid_expectation 1 "" || return 1
  ! validate_eye_pid_expectation 1 "123,124" || return 1

  local listener_pids
  [ -z "$(/usr/bin/printf 'f7\n' | parse_listener_pids)" ] || return 1
  listener_pids=$(/usr/bin/printf 'p123\nf7\np123\np456\n' | parse_listener_pids)
  [ "$listener_pids" = "123,456" ] || return 1
  listener_pid_set_matches_eye 123 123 || return 1
  ! listener_pid_set_matches_eye 123 "" || return 1
  ! listener_pid_set_matches_eye 123 456 || return 1
  ! listener_pid_set_matches_eye 123 "123,456" || return 1

  [ "$(eye_log_predicate 123)" = "processIdentifier == 123" ] || return 1
  ! eye_log_predicate "ZBS Eye" >/dev/null || return 1
  ! eye_log_predicate "123 OR process == *" >/dev/null || return 1

  DATA_ROOT="${root}/data-root"
  /bin/mkdir "$DATA_ROOT"
  ! read_eye_port >/dev/null || return 1
  /usr/bin/printf 'not-a-port\n' > "${DATA_ROOT}/port"
  ! read_eye_port >/dev/null || return 1
  /usr/bin/printf '8731\n' > "${DATA_ROOT}/port"
  [ "$(read_eye_port)" = "8731" ] || return 1
  /bin/ln -sf "${DATA_ROOT}/port" "${DATA_ROOT}/port-link"
  /bin/mv "${DATA_ROOT}/port" "${DATA_ROOT}/real-port"
  /bin/ln -s "${DATA_ROOT}/real-port" "${DATA_ROOT}/port"
  ! read_eye_port >/dev/null || return 1

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
  local canonical requested_data_root
  canonical="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
  [ "$canonical" = "$EXPECTED_APP" ] || die_usage "physical gate requires ${EXPECTED_APP}"
  APP="$canonical"
  [ -d "$DATA_ROOT" ] || die_usage "data root does not exist: $DATA_ROOT"
  requested_data_root="$DATA_ROOT"
  DATA_ROOT="$(cd "$requested_data_root" && pwd -P)" \
    || die_usage "data root cannot be resolved: $requested_data_root"
  [ -d "$DATA_ROOT" ] || die_usage "canonical data root is unavailable: $DATA_ROOT"
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
    baseline-a|baseline-b|baseline-c|baseline-d|baseline-e)
      /bin/echo "Quit ZBS Eye, ChatGPT, and Chronicle. Keep this script running in Terminal."
      ;;
    eye)
      /bin/echo "Launch the exact installed ZBS Eye candidate. Keep ChatGPT and Chronicle quit."
      ;;
    chatgpt-chronicle)
      /bin/echo "Quit ZBS Eye. Launch ChatGPT and Chronicle."
      ;;
    eye-chronicle)
      /bin/echo "Launch the exact installed ZBS Eye candidate and Chronicle. Keep ChatGPT quit."
      ;;
    eye-chronicle-call)
      /bin/echo "Launch the exact installed ZBS Eye candidate, ChatGPT, and Chronicle."
      /bin/echo "Start one real ChatGPT call and confirm Eye shows both microphone and system tracks active."
      ;;
  esac
  /bin/echo "Keep this Terminal window fully visible: its changing marker is the freshness witness."
}

exact_command_pids() {
  /bin/ps -axo pid=,command= | /usr/bin/awk -v executable="$1" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
      if ($0 == executable) print pid
    }
  ' | /usr/bin/sort -n | /usr/bin/paste -sd, -
}

is_single_pid() {
  case "$1" in
    ""|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

eye_pid_from_snapshot() {
  local snapshot="$1" eye_pids chatgpt_pids chronicle_pids
  IFS='|' read -r eye_pids chatgpt_pids chronicle_pids <<< "$snapshot"
  is_single_pid "$eye_pids" || return 1
  /bin/echo "$eye_pids"
}

read_eye_port() {
  local port_file="${DATA_ROOT}/port" port
  [ -f "$port_file" ] && [ ! -L "$port_file" ] || return 1
  port=$(/bin/cat "$port_file" 2>/dev/null) || return 1
  case "$port" in
    ""|*[!0-9]*) return 1 ;;
  esac
  [ "${#port}" -le 5 ] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  /bin/echo "$port"
}

parse_listener_pids() {
  /usr/bin/awk '/^p[0-9]+$/ { print substr($0, 2) }' \
    | /usr/bin/sort -n -u \
    | /usr/bin/paste -sd, -
}

listener_pids_for_port() {
  local port="$1" output
  output=$(/usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN -Fp 2>/dev/null || true)
  /usr/bin/printf '%s\n' "$output" | parse_listener_pids
}

listener_pid_set_matches_eye() {
  local expected_pid="$1" listener_pids="$2"
  is_single_pid "$expected_pid" && [ "$listener_pids" = "$expected_pid" ]
}

validate_eye_pid_expectation() {
  local want_eye="$1" eye_pids="$2"
  if [ "$want_eye" -eq 1 ]; then
    is_single_pid "$eye_pids"
  else
    [ -z "$eye_pids" ]
  fi
}

eye_log_predicate() {
  is_single_pid "$1" || return 1
  /usr/bin/printf 'processIdentifier == %s\n' "$1"
}

capture_phase_process_state() {
  local eye_pids chatgpt_pids chronicle_pids
  eye_pids=$(exact_command_pids "$APP/Contents/MacOS/ZBS Eye")
  chatgpt_pids=$(exact_command_pids "$CHATGPT_EXECUTABLE")
  # Require the Chronicle main process itself. Its --screen-capture-child is
  # deliberately not sufficient evidence for the requested arm.
  chronicle_pids=$(exact_command_pids "$CHRONICLE_EXECUTABLE")
  /usr/bin/printf '%s|%s|%s\n' "$eye_pids" "$chatgpt_pids" "$chronicle_pids"
}

record_phase_process_state() {
  local phase="$1" checkpoint="$2" snapshot="$3"
  local eye_pids chatgpt_pids chronicle_pids
  IFS='|' read -r eye_pids chatgpt_pids chronicle_pids <<< "$snapshot"
  /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
    "$phase" "$checkpoint" "$eye_pids" "$chatgpt_pids" "$chronicle_pids" \
    >> "${SESSION}/process-state.tsv"
}

validate_eye_capture_health() {
  local eye_pid="$1"
  local health_file="${SESSION}/.eye-health.json"
  local port listener_pids capturing state status
  is_single_pid "$eye_pid" || return 1
  port=$(read_eye_port) || return 1
  listener_pids=$(listener_pids_for_port "$port")
  listener_pid_set_matches_eye "$eye_pid" "$listener_pids" || return 1
  /bin/rm -f "$health_file"
  if ! /usr/bin/curl --silent --fail --max-time 1 \
    "http://127.0.0.1:${port}/health" -o "$health_file"; then
    /bin/rm -f "$health_file"
    return 1
  fi
  # Close the small ownership race around curl: a recycled port cannot turn a
  # foreign listener's JSON into candidate health evidence.
  listener_pids=$(listener_pids_for_port "$port")
  if ! listener_pid_set_matches_eye "$eye_pid" "$listener_pids"; then
    /bin/rm -f "$health_file"
    return 1
  fi
  status=$(/usr/bin/plutil -extract status raw -o - "$health_file" 2>/dev/null || true)
  capturing=$(/usr/bin/plutil -extract capturing raw -o - "$health_file" 2>/dev/null || true)
  state=$(/usr/bin/plutil -extract captureState raw -o - "$health_file" 2>/dev/null || true)
  /bin/rm -f "$health_file"
  [ "$status" = "ok" ] && [ "$capturing" = "true" ] && [ "$state" = "healthy" ]
}

validate_phase_state() {
  local phase="$1"
  local snapshot="${2:-}"
  [ -n "$snapshot" ] || snapshot=$(capture_phase_process_state)
  local want_eye=0 want_chatgpt=0 want_chronicle=0
  case "$phase" in
    eye) want_eye=1 ;;
    chatgpt-chronicle) want_chatgpt=1; want_chronicle=1 ;;
    eye-chronicle) want_eye=1; want_chronicle=1 ;;
    eye-chronicle-call) want_eye=1; want_chatgpt=1; want_chronicle=1 ;;
  esac
  local eye_pids chatgpt_pids chronicle_pids
  IFS='|' read -r eye_pids chatgpt_pids chronicle_pids <<< "$snapshot"
  # Absence is established before any baseline is measured. Active arms are
  # stricter: exactly one GUI process from the installed executable is allowed.
  validate_eye_pid_expectation "$want_eye" "$eye_pids" || return 1
  local has_chatgpt=0 has_chronicle=0
  [ -z "$chatgpt_pids" ] || has_chatgpt=1
  [ -z "$chronicle_pids" ] || has_chronicle=1
  [ "$has_chatgpt" -eq "$want_chatgpt" ] \
    && [ "$has_chronicle" -eq "$want_chronicle" ] || return 1
  if [ "$want_eye" -eq 1 ]; then
    validate_eye_capture_health "$eye_pids" || return 1
  fi
}

attest_two_track_call() {
  local checkpoint="$1" answer
  /bin/echo "Confirm the real call is live and Eye shows both microphone and system tracks (${checkpoint})."
  /bin/echo "Type exactly: TWO TRACKS ACTIVE"
  IFS= read -r answer
  [ "$answer" = "TWO TRACKS ACTIVE" ]
}

random_delay_ms() {
  local raw span
  raw=$(/usr/bin/od -An -N4 -tu4 /dev/urandom | /usr/bin/tr -d ' ')
  span=$((RANDOM_DELAY_MAX_MS - RANDOM_DELAY_MIN_MS + 1))
  /bin/echo $((RANDOM_DELAY_MIN_MS + raw % span))
}

sleep_milliseconds() {
  /bin/sleep "$(/usr/bin/awk -v ms="$1" 'BEGIN { printf "%.3f", ms / 1000 }')"
}

take_disposable_screenshot() {
  local previous_fingerprint="$1"
  local start end width height dimensions normalized
  SHOT_STATUS="error"
  SHOT_LATENCY_MS=0
  SHOT_FINGERPRINT=""
  ACTIVE_SHOT="${SESSION}/.capture-current.png"
  normalized="${SESSION}/.capture-current.bmp"
  /bin/rm -f "$ACTIVE_SHOT"
  /bin/rm -f "$normalized"
  start=$(now_ms)
  if ! run_with_deadline_ms "$ATTEMPT_LIMIT_MS" \
    /usr/sbin/screencapture -x -m -t png "$ACTIVE_SHOT" >/dev/null 2>&1; then
    end=$(now_ms)
    SHOT_LATENCY_MS=$((end - start))
    /bin/rm -f "$ACTIVE_SHOT" "$normalized"
    ACTIVE_SHOT=""
    return
  fi
  end=$(now_ms)
  SHOT_LATENCY_MS=$((end - start))
  if [ ! -s "$ACTIVE_SHOT" ]; then
    SHOT_STATUS="empty"
    /bin/rm -f "$ACTIVE_SHOT" "$normalized"
    ACTIVE_SHOT=""
    return
  fi
  if ! dimensions=$(/usr/bin/sips -g pixelWidth -g pixelHeight "$ACTIVE_SHOT" 2>/dev/null); then
    /bin/rm -f "$ACTIVE_SHOT" "$normalized"
    ACTIVE_SHOT=""
    return
  fi
  width=$(/bin/echo "$dimensions" | /usr/bin/awk '/pixelWidth:/ {print $2}')
  height=$(/bin/echo "$dimensions" | /usr/bin/awk '/pixelHeight:/ {print $2}')
  if [ "${width:-0}" -le 0 ] || [ "${height:-0}" -le 0 ]; then
    /bin/rm -f "$ACTIVE_SHOT" "$normalized"
    ACTIVE_SHOT=""
    return
  fi
  if ! /usr/bin/sips -s format bmp "$ACTIVE_SHOT" --out "$normalized" >/dev/null 2>&1; then
    /bin/rm -f "$ACTIVE_SHOT" "$normalized"
    ACTIVE_SHOT=""
    return
  fi
  SHOT_FINGERPRINT=$(sha256_file "$normalized")
  SHOT_STATUS="ok"
  if [ -n "$previous_fingerprint" ] && [ "$SHOT_FINGERPRINT" = "$previous_fingerprint" ]; then
    SHOT_STATUS="stale"
  fi
  /bin/rm -f "$ACTIVE_SHOT" "$normalized"
  ACTIVE_SHOT=""
}

measure_phase() {
  local phase="$1"
  local output="${SESSION}/${phase}.tsv"
  /usr/bin/printf 'attempt\tdelay_ms\tlatency_ms\tstatus\n' > "$output"
  /bin/echo "Warming up ${phase} (${WARMUP_COUNT})..."
  local i delay previous_fingerprint=""
  for ((i = 1; i <= WARMUP_COUNT; i += 1)); do
    delay=$(random_delay_ms)
    /usr/bin/printf '\033[2K\rEye screenshot freshness: %s warmup %03d' "$phase" "$i"
    sleep_milliseconds "$delay"
    take_disposable_screenshot "$previous_fingerprint"
    [ "$SHOT_STATUS" = "ok" ] || { /bin/echo ""; return 1; }
    previous_fingerprint="$SHOT_FINGERPRINT"
  done
  /bin/echo ""
  /bin/echo "Measuring ${phase} (${MEASURED_COUNT})..."
  for ((i = 1; i <= MEASURED_COUNT; i += 1)); do
    delay=$(random_delay_ms)
    /usr/bin/printf '\033[2K\rEye screenshot freshness: %s attempt %03d' "$phase" "$i"
    sleep_milliseconds "$delay"
    take_disposable_screenshot "$previous_fingerprint"
    /usr/bin/printf '%s\t%s\t%s\t%s\n' \
      "$i" "$delay" "$SHOT_LATENCY_MS" "$SHOT_STATUS" >> "$output"
    if [ -n "$SHOT_FINGERPRINT" ]; then previous_fingerprint="$SHOT_FINGERPRINT"; fi
  done
  /bin/echo ""
}

failure_result_for_phase() {
  case "$1" in
    baseline-*|chatgpt-chronicle) /bin/echo "upstream-blocked" ;;
    eye|eye-chronicle|eye-chronicle-call) /bin/echo "Eye no-go" ;;
    *) /bin/echo "invalid" ;;
  esac
}

count_log_token() {
  /usr/bin/awk -v token="$2" 'index($0, token) { count += 1 } END { print count + 0 }' "$1"
}

collect_phase_log_counts() {
  local phase="$1" start_time="$2" end_time="$3" eye_pid="${4:-}"
  local scratch="${SESSION}/.eye-unified-log"
  if [ -z "$eye_pid" ]; then
    # The baseline/control arms have already proved that the exact installed
    # Eye process is absent. There is therefore no candidate PID to query.
    /usr/bin/printf '%s\t0\t0\t0\t0\n' "$phase" \
      >> "${SESSION}/log-summary.tsv"
    return 0
  fi
  local predicate
  predicate=$(eye_log_predicate "$eye_pid") || return 1
  if ! /usr/bin/log show --style compact --info --debug \
    --start "$start_time" --end "$end_time" \
    --predicate "$predicate" > "$scratch" 2>/dev/null; then
    /bin/rm -f "$scratch"
    return 1
  fi
  local screenshot_manager remote_queue missing_output stream_started
  screenshot_manager=$(count_log_token "$scratch" "SCScreenshotManager")
  remote_queue=$(count_log_token "$scratch" "_SCRemoteQueue_Enqueue")
  missing_output=$(count_log_token "$scratch" "stream output NOT found")
  stream_started=$(count_log_token "$scratch" "eye_screen_stream_started")
  /bin/rm -f "$scratch"
  /usr/bin/printf '%s\t%s\t%s\t%s\t%s\n' \
    "$phase" "$screenshot_manager" "$remote_queue" "$missing_output" "$stream_started" \
    >> "${SESSION}/log-summary.tsv"
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
  /usr/bin/plutil -insert randomDelayMinMs -integer "$RANDOM_DELAY_MIN_MS" "$plist"
  /usr/bin/plutil -insert randomDelayMaxMs -integer "$RANDOM_DELAY_MAX_MS" "$plist"
  /usr/bin/plutil -insert p95AttributableLimitMs -integer "$P95_ATTRIBUTABLE_LIMIT_MS" "$plist"
  /usr/bin/plutil -insert activeMaxDeltaLimitMs -integer "$ACTIVE_MAX_DELTA_LIMIT_MS" "$plist"
  /usr/bin/plutil -insert baselineP95DriftLimitMs -integer "$BASELINE_P95_DRIFT_LIMIT_MS" "$plist"
  /usr/bin/plutil -insert baselineMaxDriftLimitMs -integer "$BASELINE_MAX_DRIFT_LIMIT_MS" "$plist"
  /usr/bin/plutil -insert absoluteMaxLimitMs -integer "$ABSOLUTE_MAX_LIMIT_MS" "$plist"
  /usr/bin/plutil -insert attemptLimitMs -integer "$ATTEMPT_LIMIT_MS" "$plist"
  if [ "$CALL_ATTESTED_BEFORE" -eq 1 ] && [ "$CALL_ATTESTED_AFTER" -eq 1 ]; then
    /usr/bin/plutil -insert twoTrackCallAttested -bool true "$plist"
  else
    /usr/bin/plutil -insert twoTrackCallAttested -bool false "$plist"
  fi
  [ -z "$failed_phase" ] || /usr/bin/plutil -insert failedPhase -string "$failed_phase" "$plist"
  if [ -f "$summary" ]; then
    /usr/bin/plutil -insert metrics -dictionary "$plist"
    local phase key p50 p95 maximum errors empty stale
    for phase in "${PHASES[@]}"; do
      key=$(phase_key "$phase")
      p50=$(summary_value "$summary" "$phase" 2)
      p95=$(summary_value "$summary" "$phase" 3)
      maximum=$(summary_value "$summary" "$phase" 4)
      errors=$(summary_value "$summary" "$phase" 5)
      empty=$(summary_value "$summary" "$phase" 6)
      stale=$(summary_value "$summary" "$phase" 7)
      [ -n "$p50" ] || continue
      /usr/bin/plutil -insert "metrics.${key}" -dictionary "$plist"
      /usr/bin/plutil -insert "metrics.${key}.p50Ms" -integer "$p50" "$plist"
      /usr/bin/plutil -insert "metrics.${key}.p95Ms" -integer "$p95" "$plist"
      /usr/bin/plutil -insert "metrics.${key}.maxMs" -integer "$maximum" "$plist"
      /usr/bin/plutil -insert "metrics.${key}.errorCount" -integer "$errors" "$plist"
      /usr/bin/plutil -insert "metrics.${key}.emptyCount" -integer "$empty" "$plist"
      /usr/bin/plutil -insert "metrics.${key}.staleCount" -integer "$stale" "$plist"
    done
  fi
  local log_summary="${SESSION}/log-summary.tsv"
  if [ -f "$log_summary" ]; then
    /usr/bin/plutil -insert logChecks -dictionary "$plist"
    local phase key screenshot_manager remote_queue missing_output stream_started
    for phase in "${PHASES[@]}"; do
      key=$(phase_key "$phase")
      screenshot_manager=$(summary_value "$log_summary" "$phase" 2)
      remote_queue=$(summary_value "$log_summary" "$phase" 3)
      missing_output=$(summary_value "$log_summary" "$phase" 4)
      stream_started=$(summary_value "$log_summary" "$phase" 5)
      [ -n "$screenshot_manager" ] || continue
      /usr/bin/plutil -insert "logChecks.${key}" -dictionary "$plist"
      /usr/bin/plutil -insert "logChecks.${key}.scScreenshotManager" -integer "$screenshot_manager" "$plist"
      /usr/bin/plutil -insert "logChecks.${key}.remoteQueueEnqueue" -integer "$remote_queue" "$plist"
      /usr/bin/plutil -insert "logChecks.${key}.streamOutputMissing" -integer "$missing_output" "$plist"
      /usr/bin/plutil -insert "logChecks.${key}.screenStreamStarted" -integer "$stream_started" "$plist"
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
  /usr/bin/printf 'phase\tscreenshot_manager\tremote_queue_enqueue\tstream_output_missing\tstream_started\n' \
    > "${SESSION}/log-summary.tsv"
  /usr/bin/printf 'phase\tcheckpoint\teye_pids\tchatgpt_pids\tchronicle_pids\n' \
    > "${SESSION}/process-state.tsv"
  trap '/bin/rm -f "${ACTIVE_SHOT:-}" "${SESSION:-}/.capture-current.bmp" "${SESSION:-}/.eye-unified-log"' EXIT

  /bin/echo "Candidate verified. No app will be launched or quit by this script."
  /bin/echo "Private metrics: ${SESSION}"
  local phase phase_log_start phase_log_end phase_process_before phase_process_after phase_eye_pid
  for phase in "${PHASES[@]}"; do
    /bin/echo ""
    /bin/echo "Phase: ${phase}"
    phase_log_start=$(/bin/date '+%Y-%m-%d %H:%M:%S')
    phase_instructions "$phase"
    /bin/echo "Press Return when that exact state is visible."
    IFS= read -r _
    phase_process_before=$(capture_phase_process_state)
    record_phase_process_state "$phase" before "$phase_process_before"
    if ! validate_phase_state "$phase" "$phase_process_before"; then
      write_result "invalid" "$phase"
      /bin/echo "Result: invalid (process state did not match the bracket)."
      exit 1
    fi
    phase_eye_pid=$(eye_pid_from_snapshot "$phase_process_before" || true)
    if [ "$phase" = "eye-chronicle-call" ]; then
      if ! attest_two_track_call "before measurement"; then
        write_result "invalid" "$phase"
        /bin/echo "Result: invalid (two-track call was not attested before measurement)."
        exit 1
      fi
      CALL_ATTESTED_BEFORE=1
    fi
    if ! measure_phase "$phase"; then
      local failure
      failure=$(failure_result_for_phase "$phase")
      /bin/sleep 1
      phase_log_end=$(/bin/date '+%Y-%m-%d %H:%M:%S')
      collect_phase_log_counts \
        "$phase" "$phase_log_start" "$phase_log_end" "$phase_eye_pid" || failure="invalid"
      write_result "$failure" "$phase"
      /bin/echo "Result: ${failure} (screenshot attempt failed or was undecodable)."
      exit 1
    fi
    phase_process_after=$(capture_phase_process_state)
    record_phase_process_state "$phase" after "$phase_process_after"
    if ! validate_phase_state "$phase" "$phase_process_after" \
      || [ "$phase_process_after" != "$phase_process_before" ]; then
      write_result "invalid" "$phase"
      /bin/echo "Result: invalid (process identity, PID set, or capture health changed during the arm)."
      exit 1
    fi
    if [ "$phase" = "eye-chronicle-call" ]; then
      if ! attest_two_track_call "after measurement"; then
        write_result "invalid" "$phase"
        /bin/echo "Result: invalid (two-track call was not attested after measurement)."
        exit 1
      fi
      CALL_ATTESTED_AFTER=1
    fi
    /bin/sleep 1
    phase_log_end=$(/bin/date '+%Y-%m-%d %H:%M:%S')
    if ! collect_phase_log_counts \
      "$phase" "$phase_log_start" "$phase_log_end" "$phase_eye_pid"; then
      write_result "invalid" "$phase"
      /bin/echo "Result: invalid (Eye unified-log checks could not be read)."
      exit 1
    fi
  done

  local summary="${SESSION}/summary.tsv"
  /usr/bin/printf 'phase\tp50_ms\tp95_ms\tmax_ms\terror_count\tempty_count\tstale_count\n' > "$summary"
  for phase in "${PHASES[@]}"; do
    summarize_phase "$phase" >> "$summary" || {
      write_result "invalid" "$phase"
      /bin/echo "Result: invalid (incomplete measured phase)."
      exit 1
    }
  done
  local result
  result=$(classify_summary "$summary" "${SESSION}/log-summary.tsv")
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
    --data-root)
      [ "$#" -ge 2 ] || die_usage "--data-root requires a path"
      DATA_ROOT="$2"
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
  [ -z "$APP" ] && [ -z "$MANIFEST" ] && [ -z "$DATA_ROOT" ] \
    || die_usage "--self-test cannot be combined with physical options"
  run_self_test
  exit 0
fi

[ -n "$APP" ] || die_usage "--app is required"
[ -n "$DATA_ROOT" ] || die_usage "--data-root is required"
run_physical_gate
