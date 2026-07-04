---
name: eye-review-loop
description: The ZBS Eye maintenance loop — branch, code, build green, run the self-review checklist (Swift 6 isolation, GRDB single-writer, TCC, zero-egress, localization, data safety), then PR. Run this before opening ANY pull request in this repo.
---

# eye-review-loop — from change to reviewable PR

The loop is: **branch → code → build green → self-review → PR**. Never skip the self-review — this
repo has no test target yet, so the checklist plus a headless build IS the safety net.

## 1. Branch

```bash
git checkout -b fix/<short-description>   # or feat/, perf/, docs/
```

Never commit to `main` directly. One logical change per branch.

## 2. Code

Read the neighboring files first; match the existing style (terse English comments explaining WHY).
Consult `AGENTS.md` invariants before touching `Data/`, `Capture/`, or `Server/`.

## 3. Build green (headless — never launch the app)

```bash
xcodegen generate    # re-run after adding/removing .swift files
# CODE_SIGN_*/DEVELOPMENT_TEAM="" → ad-hoc signing (SPM deps build with no Apple team);
# -derivedDataPath → deterministic product path under build/.
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  build 2>&1 | grep -E "error:|BUILD"
```

`BUILD SUCCEEDED` required. SQL changes additionally get a scratch-DB run (`eye-db-validate`).

## 4. Self-review checklist (go through EVERY line)

**Swift 6 isolation**
- [ ] No new `@unchecked Sendable` (or it's an explicit, commented bridge with a reason).
- [ ] Non-Sendable values (`CVPixelBuffer`, `CMSampleBuffer`, `AXUIElement`, `VNRequest`, GRDB rows)
      never cross an actor boundary — they live and die inside one actor.
- [ ] UI state only in `@MainActor @Observable` stores; no view reads shared mutable state directly.
- [ ] Blocking C calls (AX, file IO loops) stay on their dedicated thread/actor, not the cooperative pool.

**GRDB single-writer**
- [ ] All writes go through the owning service (`IngestService` for capture data). No new
      `DatabasePool` writers; helper processes (`--mcp`) open with `runMigrations: false` and read only.
- [ ] Migrations are append-only and never erase user data. `snippet()`/`bm25()` computed purely over
      the FTS table (subquery pattern).
- [ ] Live-DB moves/backups use `pool.backup(to:)`, never a file copy.

**TCC / signing**
- [ ] Nothing in the change launches the app, re-signs it, or writes into `/Applications`.
- [ ] If the change affects entitlements/signing/bundle id — it's called out loudly in the PR body
      (permissions blast radius).

**Zero-egress**
- [ ] No new outbound network calls. Server stays on `127.0.0.1`; every route except `/health` checks
      the Bearer token.
- [ ] Any LLM call goes through the local-only guard (`isLocalOnly`) — no cloud presets, no telemetry.

**Localization**
- [ ] Every new user-facing string is in `ZBSEyeApp/Resources/Localizable.xcstrings` with a RU
      translation (match the existing JSON shape).
- [ ] User-facing text says "ZBS Eye" (brand), never internal type names.

**Hygiene**
- [ ] `ZBSEye.xcodeproj` not committed; no secrets/personal paths in the diff (public repo).
- [ ] `CHANGELOG.md` entry added under `## [Unreleased]`.
- [ ] Comments/docs in English.

## 5. Adversarial pass (recommended for non-trivial diffs)

Run the bundled hostile reviewer over your diff before pushing:

- subagent: `.claude/agents/swift6-reviewer.md` — give it `git diff main...HEAD`
- or the full find→verify workflow: `.claude/workflows/eye-adversarial-review.js`

Fix or consciously reject each confirmed finding (rejections get a one-line reason in the PR).

## 6. PR

```bash
git push -u origin HEAD
gh pr create --title "<what changed>" --body "<why + what was verified (build/scratch-DB/MCP) + checklist notes>"
```

PR body must state **how the change was verified headlessly** — reviewers here assume no one launched
the app (see the TCC rule in CLAUDE.md).
