# Changelog

All notable changes to ZBS Eye. The format follows Added / Changed / Fixed sections.

## [0.7.0] — 2026-08-08

### Added
- Any external user application with active microphone input now starts one local automatic Call immediately,
  including ChatGPT, browsers, and unknown microphone owners. Public CoreAudio input-running events wake
  detection promptly, while the existing bounded poll remains as recovery after missed events or `coreaudiod`
  restarts. Krisp is an audio relay that may join an existing Call but cannot start, name, or hold one; the
  `codex_chronicle` capture helper is always excluded without excluding real ChatGPT or Codex calls.
- Audio settings now include a separate **Don’t auto-record these apps** list. The in-call **Never
  auto-record [App]** action adds the current app to that list and saves the Call without changing screen
  capture's **Private apps** list.
- Read-only MCP clients, including Hermes, can request a bounded, privacy-filtered activity summary with
  deterministic sessions, top apps, and tamper-resistant snapshot pagination.
- Authenticated capture status and leg-scoped repair are available through REST, with repair restricted to
  advanced/full MCP profiles.

### Changed
- Screen capture now uses one persistent low-rate ScreenCaptureKit stream with a bounded latest-wins pipeline.
  Focus changes and periodic ticks request the next fresh frame instead of starting one-shot screenshots or
  accumulating work, and screen/system-audio stream lifecycle is serialized.
- Known meeting surfaces now enrich Call source context instead of gating automatic recording. Multiple
  microphone owners, helper changes, and audio-device changes remain in one Call; microphone and system audio
  are both requested, and an unavailable track is reported as degraded.
- Automatic ending keeps the active Call open for 30 seconds. **End & save** commits it immediately,
  **This wasn’t a call** deletes the entire automatic Call, and returning microphone activity cancels the
  timer and continues the same Call. The timeout saves once, and saving remains entirely local without
  internet access.
- The user-facing audio mode is now named **Mic in use** (`Off / Mic in use / Always`); its stored raw value
  remains compatible with existing preferences.
- Screen and system-audio capture now recover independently with bounded retries. Search, Ask, Timeline,
  REST, and MCP disclose known coverage gaps so missing history is never presented as proof of inactivity.

### Fixed
- Native macOS screenshots now take priority over Eye processing. When listen-event access already exists,
  shortcut intent synchronously opens a short yield window; otherwise Eye falls back to observing screenshot
  helper processes without requesting a new permission. Both paths cancel pending AX/HEIC/OCR work and never
  restart the persistent Eye stream.
- Capture health is based on fresh stream generations, complete/idle frame events, and display time rather
  than changed pixels, so a static screen remains healthy while real stream stalls recover without overlap.
- Codex integration now admits the locally qualified signed `codex-cli 0.145.0` release with its exact
  native-binary hash while preserving the existing signature and package-layout checks.

### Removed
- Removed the post-save Undo phase, its 15-second recovery tail, and Undo actions from Call surfaces.

## [0.6.0] — 2026-07-31

### Added
- Optional Browser Bridge for Chrome, Dia, Arc, Edge, Brave, Vivaldi, Chromium, and compatible Chromium
  browsers on Mac. It adds visible rendered text from only the active tab in the focused window.
- A dedicated **Settings → Browser Capture** screen with live status, Chrome Web Store access, a bundled
  unpacked fallback, and a separate write-only Keychain token.

### Changed
- Browser text is accepted only after the extension authenticates the real loopback Eye process and confirms
  recording is active. The extension starts disabled and has no cloud or non-loopback endpoint.
- Capture prefers fresh rendered DOM, falls back to Accessibility, and limits OCR for canvas, PDF, and video
  pages to once every 30 seconds.

### Security
- Passwords, form values, hidden elements, scripts, styles, background tabs, stale documents, and mismatched
  browser snapshots are rejected before they can enter Timeline. Browser ingest credentials cannot read any
  history route.

## [0.5.4] — 2026-07-27

### Fixed
- Eye now discovers the Whisper model selected by current Handy releases, whose preferences live under
  `settings.selected_model`. The older top-level schema remains supported; conflicting shapes fail closed.
- The failed, never-published 0.5.3 candidate was withdrawn instead of replacing its notarized bytes.

## [0.5.3] — 2026-07-27 (withdrawn)

### Fixed
- Reusing Handy's downloaded Whisper model no longer starts Handy.app. Eye resolves the selected immutable
  Hugging Face cache snapshot itself and loads it inside Eye's existing short-lived helper process through
  the matching universal `transcribe.cpp` runtime. No model weights are copied or downloaded a second time.
- The failed, never-published 0.5.2 candidate was withdrawn instead of replacing its notarized bytes.
- This candidate was never published because its probe understood Handy's legacy flat settings shape but not
  the nested shape used by the installed app. Version 0.5.4 adds the real schema and live qualification.

## [0.5.2] — 2026-07-27 (withdrawn)

### Changed
- Call editing now uses one waveform range selector with visible handles, exact duration, source-specific
  previews, and quick tail selection. The destructive action says what it really does: permanently delete
  the selected audio while keeping the rest of the call on its original timeline.
- This candidate attempted to reuse Handy's downloaded model through Handy's file-transcription CLI.
  It was never published because invoking the app binary still surfaced Handy on macOS. Version 0.5.3
  replaces that path with direct model loading and never launches Handy.app.
- The system-audio preference now controls ordinary Timeline capture. Confirmed and manually started calls
  request separate microphone and system tracks whenever audio is enabled; `Audio Off` remains a hard stop.

### Fixed
- Chromium helper audio processes can resolve to their exact visible Chrome, Dia, or Edge root through the
  CoreAudio process bundle identifier, covering detached helper topology without broad process matching.
- Calls no longer claim that Whisper is missing when the compatible Handy backend is ready.
- The permission-free automatic-call banner stays above browser utility surfaces, so “Not a call”
  remains visible without activating Eye or requesting notification access.

## [0.5.1] — 2026-07-27

- Fixed Chrome, Dia, and Edge detection for the real Zoom Web client when Chromium exposes no
  `AXWebArea` at all. Eye now accepts only a fully traversed `Zoom Meeting` root window plus one
  corroborating window proxy carrying the same exact trusted `/wc/<meeting>/start` route alongside
  fresh two-sided browser audio; raw URLs and window titles remain transient and are never logged
  or stored.

### Added
- **OS-only Chromium call detection.** Chrome, Dia, and Edge can start local call capture for
  verified Google Meet, Zoom, and Microsoft Teams surfaces using CoreAudio plus bounded
  Accessibility evidence — without a browser extension, AppleScript, or another permission prompt.
- **Automatic, correctable browser-call capture.** In the Chromium path, Eye starts only when the same
  supported browser group has current microphone input and output, a trusted origin, and a real
  call-control. It shows a “Not a call” action that permanently stops and deletes that detected call.
  Normal automatic ending waits through a 30-second grace and then offers a separate 15-second Undo
  without splitting recording.
- **A focused Calls workspace.** Calls can be searched and opened independently of the full Timeline,
  played by source, trimmed permanently by an exact range, and opened back at their Timeline moment.
- **Optional per-call speaker separation.** A one-click, checksum-verified FluidAudio model assigns
  anonymous speakers locally. Names and interval corrections apply only to the current call; no reusable
  voiceprint is stored. REST, MCP, export, and the loopback automation report speaker readiness honestly.
- **Durable local call recording.** Start, Bookmark, and End create one Call Envelope with separately
  attributable microphone/system PCM. Bookmark schedules a local checkpoint transcript without pausing
  either source; End schedules one retryable whole-call transcript.
- **Optional post-call Whisper.** A separately installed, pinned Whisper Large V3 Turbo model produces
  checkpoint and final transcripts locally through a bounded helper process. It is not bundled, downloaded,
  or enabled by default, and there is no cloud fallback.
- **Frame-exact call privacy and portable export.** Deleting a time range preserves byte-identical audio
  outside the selection, marks the gap, and invalidates stale transcript/search state. History export adds
  stable Call Envelope manifests and optional verified current-generation audio.

### Changed
- Codex and Claude Code subprocess providers now admit the exact locally qualified signed releases
  (`codex-cli 0.144.6` and Claude Code `2.1.220`) with refreshed native-binary hashes.
- The post-call automation can fire a signed `call.processing.ready` event after both transcript and
  speaker work settle. Failed diarization is durable and retryable instead of looking permanently busy.
- **Known native-call limitation:** after **Not a call**, Eye suppresses the same native app/window
  until the old call control is authoritatively absent or the app/audio boundary ends. A back-to-back
  native call reusing that exact surface may need Manual Start. This privacy-first guard does not apply
  to the qualified Chromium path above.
- Calls appear as compact Timeline spans and localized details. Search exposes only the preferred transcript;
  authenticated REST and read-only MCP expose bounded typed evidence without absolute paths or invented
  speaker identity.
- The 5 GB Keep Media budget now includes call PCM. Active calls are protected, whole ended calls are removed
  oldest-first when needed, and startup reconciliation fails closed on missing, stale, or orphaned call media.

### Fixed
- MCP failure responses no longer interpolate raw system errors that could disclose local paths or native details.
- Confirmed Chromium calls no longer enter the end grace when browser output goes quiet while the
  microphone and exact trusted call control remain active. The last complete audio-carrier baseline is
  preserved so a later call still receives a new session boundary.
- Screen capture now resumes automatically after unlock even if macOS drops the distributed unlock
  notification, while failed or still-locked session queries continue to suspend capture fail-closed.
- Touch ID, SecurityAgent, authorizationhost, loginwindow, and screen-saver surfaces are rejected at
  the capture boundary, so their Accessibility text and pixels never enter new history records.

## [0.4.5] — 2026-07-15

### Fixed
- Restored normal capture in unlocked macOS sessions while keeping the lock-screen privacy gate fail-closed. macOS normally omits `CGSSessionScreenIsLocked` when unlocked; the app now accepts that shape only for a current on-console, login-complete session and rejects failed or malformed queries.

## [0.4.4] — 2026-07-15 (withdrawn)

### Fixed
- Capture now stays suspended across wake and screen-saver transitions until macOS reports a real unlock,
  preventing a delayed timer tick from recording the lock screen.
- `loginwindow` and screen-saver processes are rejected again at the final capture boundary, so an out-of-order
  session notification cannot put protected system-shell frames into history.

## [0.4.3] — 2026-07-15

### Fixed
- Timeline Scene details now stay bound to the visible moment, show an immediate one-moment fallback while
  grouping loads, and reject stale or same-time results from another capture.

### Changed
- Release qualification now proves a clean, freshly fetched `main` candidate with a monotonic version/build,
  then binds the exact notarized ZIP to its manifest and retained Apple notarization evidence.

## [0.4.2] — 2026-07-14

### Fixed
- REST `/health` and the MCP handshake now report the installed bundle version instead of a release literal.

## [0.4.1] — 2026-07-14

### Fixed
- Launching while the Mac is already locked now keeps screen capture suspended until the real unlock event,
  instead of retrying an unavailable display every few seconds and briefly showing a false restart warning.

## [0.4.0] — 2026-07-14

### Added
- **One-click built-in local AI.** On qualified Apple Silicon Macs, **ZBS Eye Local** downloads a pinned,
  verified MLX model after an explicit click and then powers Ask, Daily Insights, summaries, and generated
  activity labels offline — no LM Studio, Ollama, account, API key, or separate server required. Setup is
  resumable and honest about hardware, disk space, progress, verification, failures, and installed bytes;
  a failed replacement cannot destroy the last verified model.
- **Optional AI without a provider wall.** AI is Off by default and Eye remains useful without it. One compact
  setup flow offers an explicit one-click local model, local servers, signed-in Codex/Claude Code accounts,
  and supported API providers. Providers stay separate from their model choices; opening setup never connects,
  downloads, or activates anything.

### Changed
- Primary Codex/Claude MCP setup is now tokenless and read-only by default via `--mcp-read-only`, with bounded installed-app
  readiness checks and explicit opt-in for screenshot access or recording control.
- **Timeline-first workspace.** Timeline and Ask now share one compact workspace header with always-visible
  recording state. Activities is a Timeline representation, while Insights, Automations, Progress,
  Achievements, Appearance, and Settings open as focused secondary views and return without losing context.
- **Four focused Settings destinations.** Permissions, AI, Data Storage, and MCP & AI Tools replace the old
  settings maze. A single honest line reports current CPU, memory, and stored-data usage.
- **Paste-like media retention.** New installs keep up to 5 GB of captured media; 10/20/50 GB and Forever are
  explicit choices. Shrinking a limit asks before deleting old media, while low disk pauses capture and never
  silently deletes history to self-heal.
- Microphone and System Audio can now be controlled independently, including across low-disk pause and resume.
- Every generative consumer now goes through one cancellable router with selection revision, authorization,
  deterministic context budgets, and provider/model/locality provenance. Interactive Ask takes priority over
  background work; stale or revoked output is discarded.
- Cloud, broker, and signed-in CLI generation uses recipient- and scope-specific consent. Capture, recordings,
  search index, and storage stay local regardless of the selected processing provider.
- Local model assets follow the resolved storage root, are excluded from iCloud snapshots, preserve capture
  disk reserve, and coordinate inference/embedding work so recording never waits on generation.

## [0.2.1] — 2026-07-09

### Changed
- **AI Models: one active-model line + one switcher.** The screen no longer shows the active model in
  three competing places with a picker and a "Use this model" button on every provider. Now there's a
  single "Active model · Provider · Model" line with one menu that lists every available model grouped
  by connected provider; provider setup (connect / keys / OAuth) moved into a collapsed "Manage
  providers" group. "connected · N models" → the calmer "N models available".
- **Less jargon, more signal.**
  - Timeline: the capture-quality pills are now plain **Text captured / Partial / Read via OCR / No
    text** dots instead of "AX full / partial / sickPID"; the activity strip has a legend (screen vs
    audio); a deduped frame reads "Screen unchanged here" instead of an error badge.
  - Activities: "Segmenting…" → "Grouping your activity…", a visible **Open in Timeline** affordance, a
    one-line subtitle.
  - "Frames" → **"moments"** across Progress, milestones and the timeline.
- **Ask & Daily Insights work sooner.** Ask's example questions adapt to how much history you have;
  Daily Insights auto-generates on open for a local model (with a heuristic fallback when no model is
  set) — a cloud model still needs an explicit tap, so nothing leaves your Mac by surprise.
- **Menu bar:** an actionable low-disk row + a glanceable "moments · streak" line.

### Fixed
- Cancelling a cloud provider's consent no longer persists the model change; an active cloud model no
  longer disappears from the switcher after relaunch; menu bar and Ask no longer scan the full history
  on every open.

## [0.2.0] — 2026-07-05

### Added
- **Use your own Claude Code (no API key) + one-click OpenRouter; API keys demoted to Advanced.** The
  "AI Models" screen is reordered by least friction: **Local** (LM Studio / Ollama) first, then
  **Claude Code** — a new provider that runs the `claude` CLI you're *already signed into* as a local
  subprocess (`claude -p --output-format json`), so there's no key to paste. The binary is resolved at
  runtime (a GUI app doesn't inherit the shell `PATH`: well-known locations, then a login-shell
  `command -v`); the prompt goes in on stdin (never argv, never logged) and the request timeout is
  enforced by killing a runaway process. Because the CLI egresses to Anthropic via your login, it sits
  behind the **same cloud-consent gate** as the other cloud providers. Then **OpenRouter** (one-click
  Connect), and finally an **"Advanced — API keys & custom server"** disclosure (collapsed by default)
  holding the OpenAI / Anthropic key-paste cards and the custom-localhost endpoint. Key-pasting is no
  longer the front door. Each card gets a one-line "what this is" + a status dot. EN + RU strings.
  _(Deferred: a Codex provider — its exec mode is agentic/heavyweight and unfit as a plain completion
  backend, so no Codex UI ships here.)_
- **One-click Connect for OpenRouter (real OAuth, PKCE, no key pasting).** The OpenRouter card now has a
  prominent **"Connect OpenRouter"** button: it runs a genuine OAuth 2.0 Authorization Code + PKCE flow
  (SHA-256 `S256`), catches the callback on a temporary loopback listener bound to 127.0.0.1 on an
  ephemeral port, exchanges the code for an `sk-or-…` key and stores it in the Keychain — the same slot
  the manual field uses, so the model list loads and the card goes green automatically. The flow is
  cancellable, times out cleanly, always tears the listener down, and never logs the code/verifier/key.
  Pasting a key by hand stays as a fallback ("…or paste a key"). EN + RU strings.
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
- **OpenRouter OAuth hardening (review).** The callback now carries a random `state` nonce that the
  loopback must echo (mismatches are ignored, single-use guard intact); the PKCE verifier throws on an
  RNG failure instead of silently using zero entropy; the loopback bind has a timeout + cancellation +
  terminal-state handling so it can't hang or leak the socket; a late/cancelled sign-in can no longer
  clobber a newer attempt (monotonic attempt token); pasting a manual key cancels any in-flight OAuth
  (and a late success no-ops); and a stale `.failed` banner is cleared on card re-appear and on
  removing the key.
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

## [Pre-0.2.0] — 2026-07-01

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

## [0.1.0] — 2026-06-25

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
  staple` → a Gatekeeper check. The output is a notarized
  `dist/ZBSEye-<version>-<build>-<source>-notarized.zip` (double-click to launch, no "Open Anyway"; the
  signature is stable — rebuilds don't reset TCC permissions).

### Changed
- **Distribution decision: Developer ID + notarization, NOT the Mac App Store.** The App Store requires App
  Sandbox, under which cross-app Accessibility is impossible (the core of text extraction), and an "eternal
  memory, records everything" profile is rejected on privacy — so, like Rewind/screenpipe, distribution is
  outside the App Store. AGENTS.md/README updated.
