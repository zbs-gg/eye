@AGENTS.md

# CLAUDE.md — rules for coding agents working in this repo

Read [`AGENTS.md`](AGENTS.md) first: what the app is, the architecture map, invariants, and gotchas —
it is written for agents and is authoritative. This file only adds the build/verify rules that agents
keep re-learning the hard way, plus a map of the bundled harness.

**Bundled harness** (ships with the repo, use it):

- `.claude/skills/eye-build` — build + common-failure playbook
- `.claude/skills/eye-diagnose` — pull live state from a running Eye (MCP, REST, logs, live DB)
- `.claude/skills/eye-db-validate` — scratch-DB harness for migrations/triggers/queue SQL
- `.claude/skills/eye-review-loop` — the maintenance loop: branch → build → self-review → PR
- `.claude/skills/eye-release` — notarized release pipeline
- `.claude/agents/swift6-reviewer.md` — hostile Swift 6 / data-safety reviewer subagent
- `.claude/workflows/eye-adversarial-review.js` — find→verify review workflow over a diff

## Build

- `ZBSEye.xcodeproj` is **not tracked in git** — it is generated. Run `xcodegen generate` first, and
  re-run it after adding or removing any `.swift` file (`project.yml` globs sources from `ZBSEyeApp/`).
  Never commit `ZBSEye.xcodeproj`.
- Enable the `swift-lsp` plugin in this repo (it is off globally) so you get LSP diagnostics and
  jump-to-def while editing Swift here.
- Build command (the `CODE_SIGN_*` / `DEVELOPMENT_TEAM=""` overrides let it build on a machine with no
  Apple team — SPM deps like GRDB otherwise demand one; `-derivedDataPath` keeps the product path
  deterministic under `build/`):
  ```bash
  xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Release \
    -destination 'platform=macOS' -derivedDataPath build/DerivedData \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" build
  ```
- The CoreSimulator version-mismatch warning is noise. Judge the build by grepping the output for
  `error:` and `BUILD SUCCEEDED`.
- One-shot build gate: `bash scripts/verify.sh` (xcodegen → Debug build with ad-hoc Manual signing).

## TCC HARD RULE — never break the user's recording permissions

**NEVER launch a Debug or differently-signed build over the user's installed app.** macOS Screen
Recording permission is cdhash-strict: a build with a different signature launching under the same
bundle id silently breaks the user's live capture until they re-grant permissions. Test headlessly
instead:

1. Release build compile-checks (command above, or `scripts/verify.sh`).
2. SQL / migration / queue logic on a scratch DB (next section).
3. MCP stdio against the built binary (see `.claude/skills/eye-diagnose`).

The user re-installs through a properly signed build (`scripts/build-release.sh` self-signed, or
`scripts/build-notarized.sh` Developer ID) — that is their step, not yours.

## Scratch-DB validation (before shipping any SQL)

Validate migrations, triggers, and queue logic with `sqlite3` on a throwaway DB — never against the
user's live DB. Tiny example (dedup on the embed queue):

```bash
DB="$(mktemp -d)/scratch.sqlite"
sqlite3 "$DB" "
CREATE TABLE embed_queue(row_id INTEGER NOT NULL, kind INTEGER NOT NULL,
                         ts INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                         PRIMARY KEY(row_id, kind)) WITHOUT ROWID;
INSERT OR IGNORE INTO embed_queue(row_id, kind, ts) VALUES (1,0,100),(1,0,100);
SELECT COUNT(*) FROM embed_queue;"   # → 1 (dedup holds)
```

Full pattern with a worked example: `.claude/skills/eye-db-validate/SKILL.md`.

## Reading the user's live DB (diagnosis only)

- Locate it via `lsof` — the user may have relocated storage to an external SSD, so never assume
  `~/Library/Application Support/ZBS Eye`. Match by command name (`-c`), not by PID: more than one
  `ZBS Eye` process can be live at once (the GUI plus an `--mcp` helper), and `lsof -p` rejects the
  newline-joined multi-PID list a `pgrep` returns:
  ```bash
  lsof -c "ZBS Eye" 2>/dev/null | grep -o '/.*zbseye\.sqlite$' | head -1
  ```
  Empty result (app not running, or a relocated install)? **Ask the user for the DB path** — do not
  fall back to `~/Library`, it is stale after a storage relocation.
- Open strictly read-only: `sqlite3 "file:<path>?mode=ro&immutable=1" "<query>"`.
- **Never write to the live DB.** The GUI process is the single writer (GRDB `DatabasePool`,
  `IngestService`).

## Misc that bites

- macOS has **no `timeout` command**. To test the MCP server, launch the built binary with `--mcp` in
  the background, capture its PID (`PROBE=$!`), drive it over stdio, then `kill "$PROBE"` — never
  `pkill -f -- '--mcp'`, which would also kill the user's own `ZBS Eye --mcp` server and any other
  `--mcp` tool.
- Swift 6 strict concurrency is `complete`: actors own non-Sendable state (`CVPixelBuffer`,
  `AXUIElement`, … live and die inside one actor); UI state lives in `@MainActor @Observable` stores;
  the DB has a single logical writer via GRDB `DatabasePool`. Do not add a second writer, do not
  sprinkle `@unchecked Sendable`.
- This repo is **public**: English only in code/comments/docs; no secrets, no tokens, no personal
  absolute paths.
