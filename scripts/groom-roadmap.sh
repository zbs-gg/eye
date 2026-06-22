#!/bin/bash
# Bi-daily roadmap groom для ZBS Eye. Запускает headless claude по workspace/groom/INSTRUCTIONS.md,
# ЛОГИРУЕТ эксперимент в workspace/groom/ledger.jsonl (модель/ризонинг/токены/стоимость/решения —
# для «ревью ревью» + откат через git), доставляет короткий дайджест в Telegram через elle-outbox,
# коммитит бэклог. Активируется launchd'ом (~раз в 2 дня) ИЛИ вручную: bash scripts/groom-roadmap.sh
#
# Эксперимент-ручки (env): GROOM_MODEL (default opus), GROOM_EXTRA (доп. директива в промпт).
set -uo pipefail
export PATH="/Users/nikshilov/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
REPO=/Users/nikshilov/ai/slishu
cd "$REPO" || exit 1

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ); DAY=$(date +%Y-%m-%d); RUN=$(date +%Y%m%d-%H%M)
MODEL="${GROOM_MODEL:-opus}"
mkdir -p workspace/groom/runs
LOG="workspace/groom/runs/$RUN.log"
rm -f workspace/groom/last-run.json

# AUTH-фикс: под launchd `claude -p` не видит live OAuth-токен → 401. Тянем свежий токен из login-
# keychain каждый прогон (в ~/.claude/.credentials.json он протухает за часы; keychain канонический).
# Два service-name: новый билд мигрировал на per-install «…-11775413» рядом со старым. Берём первый.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  for _svc in "Claude Code-credentials" "Claude Code-credentials-11775413"; do
    _tok=$(security find-generic-password -s "$_svc" -w 2>/dev/null \
      | python3 -c "import sys,json;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
    [ -n "$_tok" ] && { export CLAUDE_CODE_OAUTH_TOKEN="$_tok"; break; }
  done
fi
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo "[$TS] WARN: keychain OAuth token not resolved — claude -p likely 401" >>"$LOG"

OUTBOX="/Users/nikshilov/.openclaw/persistent/scripts/elle-outbox-enqueue.py"
PROMPT=$(cat <<PROMPT_EOF
$(cat workspace/groom/INSTRUCTIONS.md)

=== ПРОГОН СЕЙЧАС ($DAY) ===
Выполни bi-daily груминг строго по инструкции выше. Это ЭКСПЕРИМЕНТ в формате ultracode×workflow:
используй Workflow-инструмент (параллельные агенты — usage из БД ZBS Eye + конкуренты + git/claude-mem
→ синтез), если доступен в headless; иначе сделай инлайн. Токены жги разумно — не ради процесса.

В КОНЦЕ ОБЯЗАТЕЛЬНО, по порядку:
1. Перезапиши workspace/ROADMAP.md (грумленый) и workspace/groom/digest-$DAY.md (полный, с evidence).
2. Запиши workspace/groom/last-run.json (ровно этот JSON-объект):
   {"decisions":[{"action":"add|change|done|drop","item":"...","priority":"P0|P1|P2","evidence":"usage|competitor|chat|git"}],
    "inputs":{"git_range":"...","usage_top_apps":["..."],"competitor_sources":["..."]},
    "digest_delivered":false,"summary":"1-2 строки что изменилось"}
3. Достань КОРОТКИЙ дайджест (5-8 строк, формат из инструкции) в workspace/groom/short-$DAY.md и доставь:
   HOME=/Users/nikshilov/.openclaw python3 "$OUTBOX" --delivery-key "eye-roadmap-$DAY" --target-type chat --target-id "-1001872343564" --topic-id "3128" --source-job "eye_roadmap_groom" --text-file "$REPO/workspace/groom/short-$DAY.md"
   Если enqueue вернул "enqueued:..." — поправь digest_delivered:true в last-run.json.
4. git add workspace/ROADMAP.md workspace/groom/ && git commit -m "roadmap groom $DAY" (ветка roadmap-groom, НЕ main; push не обязателен).
Если за 2 дня нет значимых изменений — честно одной строкой в дайджесте, не выдумывай.
${GROOM_EXTRA:-}
PROMPT_EOF
)

echo "[$TS] groom start model=$MODEL" >>"$LOG"
START=$(date +%s)
RESULT=$(claude -p "$PROMPT" --output-format json --dangerously-skip-permissions --model "$MODEL" < /dev/null 2>>"$LOG")
END=$(date +%s)
printf '%s' "$RESULT" > "workspace/groom/runs/$RUN.json"

# ЛОГ эксперимента в ledger (стоимость/токены из claude json + решения из last-run.json + commit sha)
python3 "$REPO/scripts/groom-ledger.py" "$RESULT" "$TS" "$MODEL" "$((END-START))" >>"$LOG" 2>&1
echo "[$(date -u +%H:%M:%SZ)] groom done ($((END-START))s) — см. $LOG" >>"$LOG"
