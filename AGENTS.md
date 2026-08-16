# AGENTS.md — guide for agents and reviewers

This file is for AI agents and people opening the repository for the first time, to understand/verify/
extend the code. It reads in 5 minutes and saves hours. Build details are in [`BUILD.md`](BUILD.md).

> **The product brand is "ZBS Eye".** The internal codename in the code is `ZBSEye`: the Xcode target/scheme
> `ZBSEye`, types `ZBSEyeDatabase`/`ZBSEyeHTTPServer`/…, the binary `ZBS Eye.app`, the signature "ZBS Eye Dev".
> That's normal (brand ≠ code name) — do NOT rename identifiers. Externally (bundle id `gg.zbs.eye`, display
> name, data paths `~/…/ZBS Eye`, text) it's "ZBS Eye" everywhere.
> Compact in-app sentences may use the established `Eye` shorthand after the product context is clear.

## What it is

**ZBS Eye** (codename `ZBSEye`) is a native macOS "eternal memory" recorder: it continuously records what
happens on the computer (screen + accessibility text/OCR + audio with transcription), indexes it, and serves
it over a local REST + MCP surface. Capture and storage are **100% local, with no account required.** Optional
generative providers may receive explicitly approved text excerpts after the user connects and consents; raw
screenshots, audio, and file paths stay local. A light, native alternative to the
proprietary equivalents (which moved to subscription + cloud).

- Swift 6 (strict concurrency = `complete`), SwiftUI, target macOS 15+.
- Storage: GRDB (`DatabasePool` + WAL) + FTS5 (external-content) + sqlite-vec (statically linked).
- Search: hybrid FTS + semantics (multilingual-e5-small, 384-dim) via RRF.
- ~77,800 lines of Swift. No App Sandbox (Hardened Runtime) — otherwise SCK + cross-app AX + a local server
  are impossible. Public artifacts use Developer ID + notarization; self-signed "ZBS Eye Dev" is only the
  local fallback when a paid Apple Developer identity is unavailable.

## Build and run

```bash
xcodegen generate                                 # project.yml → ZBSEye.xcodeproj (sources globbed from ZBSEyeApp/)
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Debug build
bash scripts/make-signing-cert.sh                 # ONCE: self-signed cert → stable TCC (see gotchas)
bash scripts/build-release.sh                     # Release + sign + bundle the e5 model + zip
```

CLI modes (single binary): `--mcp-read-only` (new least-privilege MCP setup), legacy `--mcp` / explicit
`--mcp-full` (full MCP), `--import-history`, `--relocate <path>`,
`--backup-now`, `--backup-verify <file>`.

## Architecture map (`ZBSEyeApp/`)

| Folder | What |
|---|---|
| `App/` | `ZBSEyeMain` (@main, CLI/GUI dispatch), `ZBSEyeApp` (Scene + AppDelegate), `AppEnvironment` (owns the service graph, `bootstrap()`) |
| `Capture/` | `CaptureCoordinator`, one persistent low-rate `ScreenCaptureStream`, meaningful-input scheduling, `FramePipeline` (HEIC+phash+OCR, ONE actor), `SCKResourceCoordinator`, screenshot-priority yield, capture health/recovery, `AXReader` (dedicated thread, per-PID health) |
| `Audio/` | `AudioCoordinator`, microphone engine, Core Audio process-tap system engine, `VADSegmenter`, `TranscriptionService` (SFSpeech on-device); system audio owns no screen stream |
| `Meeting/` | `MeetingDetector`, CoreAudio process evidence, native/browser enrichment, exact automatic-Call admission and suppression |
| `Calls/` | `CallCoordinator`, crash-forward audio/video evidence, separate Call video + AAC post-process, Whisper/diarization, query/projection and privacy deletion |
| `Data/` | `ZBSEyeDatabase` (pool + migrations), `StorageManager` (media), **`StorageLocation`** (the single path resolver — see invariants), `StorageRelocation` (move), `BackupManager` (iCloud), `RetentionManager`, `IngestService` (the only writer) |
| `Search/` | `SearchService` (FTS+vector RRF), `EmbeddingService` (e5), past-only visual Timeline lookup, `VectorBackfill` |
| `Server/` | `ZBSEyeHTTPServer` (FlyingFox REST, 127.0.0.1, Bearer), `KeychainStore`, DTO |
| `MCP/` | `ZBSEyeMCPServer` (stdio, proxies into the GUI instance) |
| `Automations/` | `HistoryImporter`, Timeline Review collection/persistence, scheduling audit, `ExportService` |
| `State/` | `@MainActor @Observable` stores (Recording/Permissions/Storage/Backup/…) |
| `Views/` | SwiftUI (Timeline, Settings, onboarding) |

## Invariants (break them and you break things)

1. **A single source of the data path — `StorageLocation`.** The DB, media, the port file, server.log,
   automations — EVERYTHING is resolved through `StorageLocation.dataRoot()/databaseURL()/mediaDirectory()/portURL()`.
   Do NOT hardcode `Application Support/ZBS Eye`. This is needed so relocate (move to an external SSD) and
   helper processes (`--mcp`, `--backup-now`) see one place. Exceptions: the iCloud backup and user export —
   intentionally separate paths.
2. **One writer — `IngestService`.** Non-Sendable (`CVPixelBuffer`/`CMSampleBuffer`/`AXUIElement`/`VNRequest`)
   live and die inside a single actor; only Sendable leaves it.
3. **FTS5 external-content:** compute `snippet()`/`bm25()` in a subquery PURELY over the FTS table. Add a
   condition over a joined table (`c.ts BETWEEN …`) to the same SELECT and SQLite loses the FTS context
   ("unable to use function snippet"). Pattern: `WITH hits AS (… FROM text_fts WHERE MATCH … LIMIT N)`.
4. **Capture/storage remain local; egress is narrow and consent-gated.** REST is localhost-only with auth on
   everything except `/health`; the bearer token stays in the data-protection Keychain. Only an explicitly
   connected generative provider may receive the named consumer's approved text excerpts. Never send raw media,
   file paths, credentials, or history for an unapproved/background consumer.
5. **Keep Media is the only automatic retention contract.** Fresh empty profiles start at 5 GB; upgrades never
   shorten retention without an explicit selection and authoritative reconciliation. `Forever` closes automatic
   deletion. Critically low disk pauses capture for every policy and never overrides the selected retention promise.
6. **One screen stream at a time; bounded latest-wins work.** Normal screen capture uses one low-rate persistent
   ScreenCaptureKit stream, not a new screenshot request per cycle. A native screenshot signal is the sole
   user-priority exception: Eye stops only this screen stream for the quiet window and recreates one on the next
   ordinary visual intent; microphone and system audio continue. App switches always request moments; clicks,
   scroll-stop (350 ms), and typing-pause (700 ms) do so when listen-event access already exists, without a new
   permission request. The three-second fallback remains. The observer carries only an
   opaque reason—never keys, text, pointer coordinates, or clipboard contents—and frequent input shares a
   1.5-second heavy-work floor. Expensive AX/OCR/HEIC work retains at most one processing intent and one pending
   intent; a newer trigger replaces the pending one. `SCKResourceCoordinator` serializes the complete asynchronous
   start/update/stop operation across the Timeline screen and Call-video streams. System audio uses a separate
   Core Audio process tap and must never create a ScreenCaptureKit video leg.
7. **Native screenshots get a best-effort, permission-neutral physical yield.** Eye observes Shift-Command-3/4/5 and
   their Control variants through a listen-only event tap only when macOS already permits it, and also watches
   the exact native screenshot helper processes. Either signal drops pending heavy work, stops Eye's physical
   screen stream, and opens a short quiet window without stopping Call audio. Eye never requests a new Input
   Monitoring/Accessibility grant for this, never consumes the shortcut, and fails open when early hotkey
   observation is unavailable; do not describe this as a guaranteed intercept.
8. **Automatic Calls are microphone-owned and have a separate privacy list.** Any eligible external microphone
   initiator can open a local Call; exact `Don’t auto-record these apps` bundle IDs affect only this admission and
   do not hide the app from screen history. Krisp is relay-only: it may participate but cannot start, name, or keep
   a Call alive. The exact `codex_chronicle` helper is ignored before owner folding. Timeline audio and
   `Pause Timeline` do not disarm automatic Calls; the Calls mode `Don't record` and privacy pause do. A detected end waits 30 seconds, offering `End & save`
   or destructive `This wasn’t a call`; there is no post-end Undo. While any Call owns physical audio, Call audio
   has absolute capture priority: Timeline closes visual admission and stops its screen stream/HEIC/OCR work until
   both Call audio legs have physically stopped. Missing images are acceptable; dropped Call audio is not.
9. **Call mode is explicit and audio always wins.** `off`, `audio`, and `audio_video` are separate from Timeline
   audio settings. Call video is a fixed-display, hardware-only, latest-wins stream capped at 1080p/15 fps; it
   starts only after audio, may drop frames, and yields physically to native screenshots. It never restarts or
   backpressures microphone/system audio. System audio uses an app-owned private Core Audio process tap and tears
   down its exact tap and aggregate-device IDs; it has no ScreenCaptureKit display leg. On macOS 26.1, excluding
   Eye's process while it holds microphone input silently zeroes the global tap, so the tap does not use process
   exclusion and Eye must not play media while a Call owns audio.
   Background AAC mux work is lease-cancelled as soon as another Call starts
   and retries only after physical audio stops; recovery verifies the generation-bound segment hash before deleting
   a `.silent-backup`. Upgrades default existing Calls to audio and never enable video silently.

## Gotchas (already stepped on — don't again)

- **e5 = mean-pooling, not CLS.** `swift-embeddings .encode()` returns CLS — for retrieval that's 3×+ worse
  cross-lingually. We take the mean.
- **Keychain — data-protection, NOT legacy.** `KeychainStore` uses `kSecUseDataProtectionKeychain`. The
  legacy file keychain HANGS the main thread on an ACL prompt when reading a token created by a different
  signature (after reinstalling a re-signed app) → bootstrap hangs forever.
- **Stable TCC = a stable signature.** Self-signed "ZBS Eye Dev" + installing into `/Applications` (not
  DerivedData). The `designated requirement` pins the leaf cert → permissions survive rebuilds. Traps:
  `bash set -u` eats the first byte of a multibyte character next to `"$VAR"` (fix — `${VAR}`); p12 import
  needs the system `/usr/bin/openssl` (LibreSSL), not Homebrew OpenSSL 3.x; trust in the user domain without
  sudo; SPM dependencies with an explicit identity require `CODE_SIGN_STYLE=Manual`.
- **A live SQLite MUST NOT go into iCloud Drive** (WAL desync + file eviction = corruption). Only a compressed
  snapshot goes to iCloud via `pool.backup(to:)` (online backup, consistent under WAL).
- **Moving/backing up the live database — `pool.backup(to:)`, NOT a file copy** (a file cp mid-checkpoint =
  a broken DB). media — copy-not-move (the old location is intact until verify+flip).
- **Capture is paused during relocate** (`pauseForMaintenance` + draining in-flight), otherwise a boundary
  frame/audio segment is orphaned (outside the backup snapshot / outside the media copy).
- **The AX tree is often empty on Electron apps** — hence adaptive AX-first + OCR-fallback per-app, not
  "we beat Electron". OCR is an equal path, not a rare fallback.
- **Static pixels are healthy.** The persistent stream proves liveness from current complete/idle compositor
  events, not from pixel changes. A real stall or start/update/stop failure opens a durable coverage interval and
  bounded Eye-owned retries after 1/3/10 seconds; exhaustion becomes `repairRequired`. Repair never changes TCC,
  relaunches another app, or restarts a global macOS capture service.

## How to review (where the risk lives)

1. **Data loss** (the main thing): any path where 50k+ frames could be lost/orphaned/split. Look at
   `StorageRelocation` (copy-not-move? verify BEFORE flip?), `BackupManager` (is the online backup consistent?),
   `StorageLocation` (volume unavailable → do NOT start on legacy "from scratch", anti-split-brain), retention.
2. **Swift 6 concurrency:** actor isolation, Sendable at boundaries, `@unchecked Sendable` only in explicit
   bridges, blocking C calls (AX) on a dedicated thread, not in the cooperative pool.
3. **Security:** auth on everything except `/health`, path traversal in serving frames/files (numeric id →
   lookup, the media-directory boundary), no egress.
4. **Honest state:** the UI doesn't lie (the recording icon, permission statuses, "busy").
5. **Capture coexistence:** a healthy Eye must not make native screenshots slow, stale, or unavailable under
   ChatGPT/Chronicle/two-track-call contention; check one screen stream at a time, a physical screenshot-priority
   yield, bounded restart after the quiet window, lifecycle recovery, and durable coverage gaps.
6. **Automatic-Call privacy:** verify exact mic-owner attribution, relay/excluded-helper behavior, the separate
   audio exclusion list, hard `Don't record`/privacy boundaries, one terminal owner, and crash-forward erase/finalize.

Check both the build and the unhosted `ZBSEyeUnitTests` target. Pure production policies are shared into
that target explicitly so verification does not launch an ad-hoc `gg.zbs.eye` app or churn the installed
app's TCC grants. `.github/workflows/macos-ci.yml` repeats the full unhosted suite, GUI build, Call fixture, and
capture protocol self-test on Xcode 26.5 without app launch or signing. Distribution and OS-integration changes
still require installed-app REST/MCP/SQLite dogfood; CI is never physical qualification.

## Status (what works)

Previously verified live product baseline: screen capture (HEIC + AX/OCR), audio + transcription, hybrid search
(cross-lingual), Timeline, REST + MCP, history import, 5 GB fresh-profile retention with explicit
**Forever**, **relocatable storage**, **iCloud backup** (compressed, keep-N, on exit), size tracking, daily summary,
and export.

Current source after that public baseline adds Timeline Review: a day/seven-day side panel, internal v16
storage, daily/weekday/weekly scheduling, optional Markdown/Obsidian export, and provider-reported token usage.
Review is intentionally limited to authenticated Codex or Claude Code subscription models; it never selects
an API-key provider. This source change is not part of the already-published `0.8.0 (22)` qualification and
must not be described as publicly released. A local Developer ID-signed `0.8.0 (23)` candidate from the current
dirty source was installed on 2026-08-12 and reported healthy against the existing data root. Its Call-audio
priority still requires evidence from a real dual-track Call; the candidate is neither notarized nor public.
Current `0.9.0 (35)` source adds three-mode Calls and first-class Call video, then replaces the hidden
ScreenCaptureKit leg used for system audio with a Core Audio process tap. Installed diagnostics 26 through 28
created continuous but all-zero system PCM. A signed physical probe isolated the remaining cause: on macOS 26.1
the aggregate device must receive the tap list in its creation dictionary and then have the same list reasserted
and confirmed as a property before IO starts. Installed build 29 still produced zeroes because excluding Eye while
it held microphone input silently zeroed the global tap; the same signed probe captured real sound with microphone
input active and no process exclusion. Installed build 31 proved that the decoded Core Audio callback itself was
still all-zero. Its exported Info.plist was missing the required system-audio and screen-capture privacy reasons:
Xcode silently omitted those newer keys from a generated plist even though the build settings named them. Build 32
uses an explicit plist and makes the notarized-build script reject either missing key. Installed build 32 then
captured real system audio without gaps, but a Call-video probe exposed another release blocker: Timeline was paused,
so its lifecycle had stopped the shared native-screenshot observer; three native captures took 1.79–2.16 seconds
against a 0.36–0.40-second Eye-off baseline. Build 33 keeps that permission-neutral observer alive for the app
lifetime so Call video receives the early hotkey edge independently of Timeline. Installed build 33 proved that
edge and recorded a native-screenshot video gap without an audio gap, but its optional AAC mux failed because
AVAudioFile rejects an explicit 64 kbps encoder property at the authoritative 16 kHz sample rate (`!dat`). Build 34
removed that setting but still gave the temporary movie a non-media extension; AVFoundation exported it and then
refused to verify it. Build 35 uses a real temporary MP4, verifies both tracks before replacement, and clears only
that transient degradation after every segment is muxed. Real microphone content, physical hotkey latency, live
mode switching, and the remaining coexistence matrix are still mandatory.

The exact Developer ID + notarized `0.8.0 (22)` artifact is public stable/latest as of 2026-08-08. It includes the
persistent latest-wins screen stream, microphone-owned automatic Calls, meaningful visual moments, immediate
Timeline refresh, past-only image selection, a bounded seven-image filmstrip/cache, and representative Activity
images without changing the database, media format, REST, MCP, privacy, or Calls. The exact artifact was installed
locally, reported healthy, wrote a Timeline frame, and coexisted with one successful native 3840x2160 screenshot.
The larger screenshot matrix, normal-use soak, and long physical Call checks were not completed before publication
and must not be described as passed.

Deferred: source_id for multi-monitor dedup (~0.15% of frames, documented in `HistoryImporter`).

**Distribution — Developer ID + notarization (NOT the App Store).** The App Store requires App Sandbox,
under which cross-app AX (the core) is impossible + a "records everything" profile gets rejected — so, like
Rewind/screenpipe, the target is a notarized Developer ID outside the App Store. The pipeline is ready:
`scripts/build-notarized.sh` (Hardened Runtime + Developer ID + timestamp + notarytool + staple), cert/cred
setup — `docs/NOTARIZE.md`. Release qualification binds an exact version/build/source ZIP to its manifest,
reverse-verifies the draft download, and exercises the installed artifact across unlocked capture and a real
lock → unlock transition before publication. `scripts/build-release.sh` remains only the self-signed local
fallback ("Open Anyway"; its cdhash/TCC churn is exactly what notarization removes).
