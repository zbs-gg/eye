---
name: eye-diagnose
description: Pull live state from the user's running ZBS Eye without touching it — diagnostics over MCP stdio, REST /health, unified logs by subsystem, and safe read-only queries against the live database (located via lsof, storage may be relocated). Use when debugging "something is broken" on a real install.
---

# eye-diagnose — read the live state of a running Eye, safely

Four independent probes, cheapest first. None of them writes anything, none of them launches the GUI.

## 1. MCP `get_diagnostics` (stdio)

The installed binary doubles as an MCP server (`--mcp`). macOS has **no `timeout` command**, so run it
in the background, capture the PID of the probe you launched, and kill **only that PID** when done.
Never `pkill -f -- '--mcp'`: it would also kill the user's own persistent `ZBS Eye --mcp` server (the
one your MCP client is connected to) and any third-party `--mcp` tool.

```bash
BIN="/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye"
req=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_diagnostics","arguments":{}}}')
"$BIN" --mcp <<<"$req" > /tmp/eye-diagnostics.out 2>/dev/null &
PROBE=$!                          # the exact process we started — kill only this one
sleep 5; kill "$PROBE" 2>/dev/null
cat /tmp/eye-diagnostics.out
```

`get_diagnostics` returns: app version, macOS version, applied DB migrations, table counts, recording
state. Other useful tools on the same server: `get_status`, `search_history`, `get_timeline`.

## 2. REST `/health` (no auth needed)

The GUI instance runs a localhost REST server; the port lives in a `port` file in the data root
(find the data root in step 4 — storage may be relocated):

```bash
ROOT="<data root from lsof, e.g. .../ZBS Eye>"
curl -s "http://127.0.0.1:$(cat "$ROOT/port")/health"
# → {"status":"ok","version":"...","capturing":true}
```

No response = the GUI instance is not running (or the server failed — check `$ROOT/server.log`).
All other `/v1/*` routes need a Bearer token stored in the app's data-protection Keychain — you cannot
read it from the CLI; use the MCP tools instead (the MCP process reads the token itself).

## 3. Unified logs (subsystem `gg.zbs.eye`)

```bash
log show --last 30m --info --predicate 'subsystem == "gg.zbs.eye"' | tail -100
# narrower: category IN {app, capture, ingest, audio, server, retention}
log show --last 2h --info --predicate 'subsystem == "gg.zbs.eye" AND category == "capture"'
```

This is the first place to look for "recording died overnight" — crashes, permission losses, and
engine restarts all log here.

## 4. The live database — locate via lsof, read-only always

The user may have relocated storage (external SSD), so **never assume**
`~/Library/Application Support/ZBS Eye`. Ask the running process what it has open — match by command
name (`-c`), not by PID:

```bash
# `lsof -c` catches every "ZBS Eye" process. Don't use `lsof -p "$(pgrep -x 'ZBS Eye')"`:
# when the GUI and an --mcp helper are both live, pgrep returns a newline-joined PID list that
# `lsof -p` rejects → empty result → a silent fall back to a stale copy on relocated installs.
DB="$(lsof -c "ZBS Eye" 2>/dev/null | grep -o '/.*zbseye\.sqlite$' | head -1)"
# Empty (app not running, or a relocated install)? ASK the user where storage lives — do NOT
# assume ~/Library/Application Support/ZBS Eye, it is stale after a relocation.
[ -n "$DB" ] || { echo "live DB not found via lsof — ask the user for the path"; return 2>/dev/null || exit 1; }
```

Open **read-only, immutable** — never take a lock on, never write to, the live DB (the GUI is the
single writer):

```bash
sqlite3 "file:${DB}?mode=ro&immutable=1" "
  SELECT identifier FROM grdb_migrations;                       -- schema level
  SELECT COUNT(*) FROM screen_captures;                          -- total frames
  SELECT datetime(MAX(ts)/1000,'unixepoch') FROM screen_captures;-- last capture (UTC)
  SELECT COUNT(*) FROM embed_queue;                              -- semantic-index backlog
  SELECT COUNT(*) FROM embed_queue WHERE attempts > 0;           -- stuck embeds
"
```

Note: `immutable=1` reads a snapshot and ignores WAL locking — perfect for diagnosis, slightly stale
by design. If numbers look impossible, re-run; do not switch to a writable connection.

## What "healthy" looks like

- `/health` answers with `capturing:true` (or a deliberate pause).
- `MAX(ts)` on `screen_captures` is within the last few minutes while capturing.
- `embed_queue` count drains over time (fresh frames get vectors within ~20 s when idle).
- No repeating `error`-level lines in the `capture`/`ingest` log categories.

Cross-check any finding against the user's words, then move to `eye-build` + a fix, and validate SQL
suspicions on a scratch DB via `eye-db-validate` — not on the live one.
