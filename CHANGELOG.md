# Changelog

All notable changes to ZBS Eye. The format follows Added / Changed / Fixed sections.

## [Unreleased] — 2026-07-03

### Added
- **Self-repair bootstrap: a dev workspace for your agent + a harness that ships in the repo.**
  "Something wrong?" now has a second action — **"Set up a dev workspace (for your agent)"** — which
  copies a long bootstrap prompt (with your problem description + on-device diagnostics): the agent
  confirms a directory, clones the public repo, checks the toolchain (Xcode, xcodegen), verifies a
  green Release build, and works with the harness bundled in the repo. New in-repo harness: a root
  `CLAUDE.md` (build/verify rules any coding agent needs: xcodegen-first, the TCC hard rule — never
  debug-launch over the installed app, scratch-DB SQL validation, read-only live-DB access via lsof),
  five `.claude/skills/` (`eye-build`, `eye-diagnose`, `eye-db-validate`, `eye-review-loop`,
  `eye-release`), a hostile `swift6-reviewer` subagent, and a find→verify
  `eye-adversarial-review` workflow. README gets an "Own it" section; both prompts and the new UI
  strings are localized (EN + RU).
- **AI Models + Connections overhaul (local-first, bring-your-own-AI).** A new sidebar section
  **"AI Models"** picks WHICH model processes history excerpts (Ask / Daily Insights / day summary):
  one-click Connect for **LM Studio / Ollama** (+ any custom localhost OpenAI-compatible server), and
  cloud providers — **OpenRouter / Anthropic / OpenAI** — as an explicit opt-in: API key in the
  Keychain, "Get a key…" links, model pickers from each provider's live `/models`, a CLOUD badge and a
  consent alert ("excerpts of your screen history leave this Mac; recordings and index stay local")
  that must be confirmed before a cloud provider can become active. Exactly ONE active processing
  model across providers; the legacy local-LLM config migrates automatically. Egress stays
  default-deny: local providers must be localhost, a consented cloud provider is allowed exactly one
  host (its official API), keys are never attached to localhost requests and never logged.
  **Connections** is now agent access only: Local REST API (status, real port, Bearer token
  reveal/copy, ready-made curl examples) + MCP (exact command, Claude Desktop / Cursor config
  snippets, tool list). The summaries **Destination** folder moved to Automations. README/ABOUT
  updated to the local-first + BYO-AI framing; RU translations for all new strings.

### Changed
- **Activities are now meaningful blocks, not raw app sessions.** The day reads as "what you were
  plausibly doing": consecutive app sessions less than 15 minutes apart merge into one block with a
  time range, top apps by share and a label — dominant app + dominant topic (browser host / cleaned
  window title), plus an optional local-LLM one-liner ("Working on ZBS Eye: Xcode, GitHub, docs")
  when a model is connected and consented — cached per block, heuristic-only otherwise. System shells
  (loginwindow, screen saver, Dock, Control Center, Notification Center…) no longer count as
  "activity" in Activities or usage stats: Activities, top apps, active minutes, context switches and
  the busiest-hour histogram all treat them as idle gaps via one shared `SystemAppFilter`. Blocks expand into the
  underlying app sessions; a "Show system events" toggle (default off) reveals the filtered entries
  for debugging.
- **Much lighter at runtime (RAM/CPU).** Measured live, Eye sat at ~740 MB (peaking ~1.35 GB) and spiked
  CPU on launch. Root causes fixed, none touching the local-first design:
  - **Capture memory.** The shared `CIContext` was never cleared, piling up ~550 MB of stale GPU frame
    surfaces (IOSurface). Now `cacheIntermediates:false` + `clearCaches()` per frame reclaim it.
  - **Capture resolution.** Frames were captured at full native Retina/5K resolution. They're now capped
    to a 2560 px longest side (SCK renders smaller directly) — a ~2–4× smaller surface **and** HEIC, so
    the DB grows slower too. OCR already downscaled, so recognized text is unaffected.
  - **HEIC quality tuned.** The stored-frame HEIC quality was untuned (≈0.8, near-lossless). Now a
    configurable `heicQuality` (default 0.6) — ~19% smaller frames on real captures, no visible loss
    (OCR runs on the live frame before encode, so recognition is unaffected).
  - **Embedding off the hot path.** Ingest used to embed **every** captured frame inline, keeping the
    ~150 MB e5 model resident 24/7. Embedding now runs in a single continuous background indexer that
    **unloads the model when idle**; a fresh frame gets its semantic vector within ~20 s (full-text
    search is instant regardless).
- **Self-repair, everywhere + over MCP.** The "Something not working?" flow is now first-class: a
  main-window toolbar button + a menu-bar item + Settings, all opening a shared `SelfRepairView`. An
  agent connected to Eye's MCP server can also pull live state with the new **`get_diagnostics`** tool
  (version, macOS, DB migrations + counts, recording state) → read the public source and fix it.
- **Usage stats (Progress tab).** A personal, on-device breakdown of how you spent the last 7 days —
  where the time went (browsers split by real site, not lumped), minutes/active day, context switches,
  busiest hour. Dogfoods the same site-aware attribution as Daily Insights.
- **Self-repair (Settings → "Something not working?").** Since the source is public and yours, a broken
  thing has a path: describe the problem → Eye collects on-device diagnostics and copies a ready-to-run
  **repair prompt for your own AI agent** (read the source, reproduce, fix), or opens a **pre-filled
  GitHub issue** in one click. No more dead end when something breaks.
- **Browser history import.** ZBS Eye now reads each browser's own local history DB (Dia, Arc, Chrome,
  Edge, Brave — Chromium format; Safari — needs Full Disk Access) and imports the **real URLs + visit
  times + titles** into a `browser_visits` table (FTS-searchable). This fills a gap: Dia/Arc don't
  expose the URL via Accessibility, so screen capture had no URL for them at all. 100% on-device (reads
  a WAL-safe copy of the browser's DB, writes only to your local DB — nothing leaves the machine),
  incremental (per-source cursor), toggle + "Import now" in Settings.

### Fixed
- **Browser-history hardening (Pro review).** Stable per-source cursor (was a per-process-random
  `hashValue` that re-imported every launch); consistent DB snapshot via SQLite backup API (+
  integrity-checked file-copy fallback, not a torn WAL copy); per-format cursor precision (Safari
  fractional seconds no longer dup-loop); cursor never stalls on an all-filtered batch; **never
  backfills a privacy-pause window** (`PrivacyPauseLog`) and "Import now" is gated by the toggle/pause;
  honest inserted-count; Full-Disk-Access failures surfaced in Settings. Audio: an explicit mode change
  now clears a stale manual override, so **"Off" is a hard stop** (no recording-while-UI-says-off trap).
  MeetingDetector resolves a mic-holding helper/renderer pid up to its owning app (fewer missed calls).
  `hostFromURL` uses URLComponents (ports/creds/IPv6/IDN/uppercase-scheme). Daily Insights recovers the
  real host for URL-hiding browsers (Dia/Arc) from imported history, so they split by site not page
  title. Downgrade guard: a DB written by a newer build is detected, never erased.
- **Browser is no longer shown as your "top app".** Activity time in a browser (Dia, Safari, Chrome,
  Arc…) is now attributed per **site/page**, not lumped under the browser — "Dia" becomes "Dia ·
  github.com", "Dia · Google Gemini", etc. Uses the URL host when available, and the tab/window title
  when the browser doesn't expose a URL (Dia/Arc). Surfaces in Daily Insights' top-apps.

### Changed
- Renamed the in-app **"Cartographer"** feature to **"Daily Insights"** (nav + view), to disambiguate
  from the standalone Cartographer person-mapping project.

## [Unreleased] — 2026-07-01

### Added
- **Meetings-only audio (new default).** Audio capture is now a tri-state mode — **off /
  meetings-only (default) / always**. In meetings-only the capture engine is fully stopped when no
  call is detected and auto-starts when one begins, so no audio files are written outside meetings
  (disk saved). A call is detected on-device when a known meeting app (Zoom, Teams, FaceTime, Discord,
  Slack, Webex, Skype) is actively using the microphone — no new permission. A menu-bar **Force audio
  on/off** overrides the mode for the session. Existing installs move to meetings-only; anyone who had
  audio turned off stays off. Known limit: a call that lives only in a browser tab (Google Meet /
  Zoom web) isn't auto-detected — use Force audio on for those.

### Changed
- Screen capture is unaffected — it still records continuously; only audio is gated by the mode.

## [Unreleased] — 2026-06-25

### Fixed
- **Live-recording crash (self-AX reentrancy).** While actively recording, ZBS Eye stayed frontmost →
  `CaptureCoordinator` inspected its own process → `AXReader` read our own SwiftUI tree → `kAXValue` on our
  `Slider` synchronously called its `@MainActor Binding.get` (`TimelineView.swift:294`) right on the
  `AXReader` serial queue → `dispatch_assert_queue(main)` → `EXC_BREAKPOINT`. It crashed inside
  `AXCore.perform`, before returning from `await` — so no executor hop helped. The diagnosis came from a Pro
  review. Fix: `guard pid != ownPID` in `runCycle` + a guard in `AXReader.extract/titleOnly`; AX reading by
  role (text → value/title/selected, chrome → title/desc, otherwise nothing — we don't poke `kAXValue` on
  non-text); `Bundle.main` is excluded from ScreenCaptureKit (the timeline doesn't record itself);
  `MainActor.preconditionIsolated()` after the AX branch. A dead-end attempt with a custom `SerialExecutor` was reverted.

### Added
- **LLM model picker from LM Studio/Ollama.** In "Connections" the "Model" field is now a `Picker` from the
  models actually loaded (`GET /v1/models`), not free text input. Auto-load on open, auto-select the first
  available, fallback input + ↻ if the server is silent.
- **Developer ID notarization pipeline** (`scripts/build-notarized.sh` + `docs/NOTARIZE.md`): build with
  Hardened Runtime → Developer ID signature + a secure timestamp → `notarytool submit --wait` → `stapler
  staple` → a Gatekeeper check. The output is a notarized `dist/ZBSEye-notarized-*.zip` (double-click to
  launch, no "Open Anyway"; the signature is stable — rebuilds don't reset TCC permissions).

### Changed
- **Distribution decision: Developer ID + notarization, NOT the Mac App Store.** The App Store requires App
  Sandbox, under which cross-app Accessibility is impossible (the core of text extraction), and an "eternal
  memory, records everything" profile is rejected on privacy — so, like Rewind/screenpipe, distribution is
  outside the App Store. AGENTS.md/README updated.
