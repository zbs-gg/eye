# Changelog

All notable changes to ZBS Eye. The format follows Added / Changed / Fixed sections.

## [Unreleased] — 2026-07-02

### Added
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
