<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="ZBS Eye — tiny, local memory for your Mac">
</p>

<p align="center">
  <strong>macOS 15+</strong> · Swift 6 · local capture and index · optional AI · MIT
</p>

<p align="center">
  <a href="https://github.com/zbs-gg/eye/releases/latest"><strong>Download current stable release</strong></a>
  ·
  <a href="./BUILD.md">Build from source</a>
  ·
  <a href="./docs/ABOUT.md">Product details</a>
</p>

ZBS Eye is a tiny native recorder for people who want a searchable memory of their Mac without sending
their life to somebody else's cloud. It quietly captures screen moments, accessible text, OCR fallback,
microphone and optional system audio. Everything is indexed locally and can be explored in the Timeline,
opened as a call, searched in Ask, or read by your own agent over localhost.

> **Release status:** the public stable release is 0.6.0. This README also documents the 0.7.0 (build 21)
> source candidate, which is not public until its exact notarized artifact passes the physical release gates.

<p align="center">
  <img src="./assets/readme/product-proof.svg" width="100%"
       alt="Synthetic ZBS Eye example showing Timeline, Calls, and local agent evidence">
</p>

The example above is synthetic. No personal history, real meeting, URL, transcript, or participant name is
stored in this repository.

## One job, done quietly

Eye records useful evidence and gives it back. It is not a CRM, a calendar manager, or a meeting bot.

- **Timeline** combines screen frames, extracted text, app context, audio density, call spans, and bookmarks
  in one scrubbable view.
- **Calls** keeps meetings out of the all-day activity stream. Microphone and system audio remain separate;
  a bookmark schedules a checkpoint transcript without interrupting the recording.
- **Search** combines FTS5 with local multilingual semantic retrieval, so a query in one language can find
  evidence written in another.
- **REST and MCP** let local agents retrieve bounded, typed evidence instead of scraping the UI. The server
  binds to `127.0.0.1`; everything except `/health` requires a Keychain-backed Bearer token.
- **Storage stays yours.** Fresh installs use a 5 GB media budget. You can choose another cap, keep media
  forever, move the data root to an external SSD, or create consistent compressed backups.
- **Browser Bridge** optionally adds rendered text from the active Chromium tab when Accessibility cannot
  see it. It is off by default, authenticates the local app before extracting text, and never sends page data
  beyond this Mac.

Screen capture is adaptive: Accessibility text is the cheap first path, while Vision OCR handles apps whose
UI trees are empty. Images use HEIC and perceptual-hash deduplication. Static screens do not become thousands
of duplicate files. Eye keeps one low-rate capture stream and processes only the newest useful frame, so work
cannot accumulate behind a busy OCR pass. With listen-event access already available, Eye sees native screenshot
shortcuts early, cancels pending heavy work, and rejects any in-flight result that crosses the screenshot boundary;
otherwise the screenshot-helper fallback yields as soon as macOS exposes it. Already-running synchronous AX or
Vision work may finish in the background, but cannot be saved as an Eye frame. Eye never requests a new permission
for this and does not stop or rebuild its stream.

## Calls without a visible bot

Any eligible external application using the microphone starts one local Call immediately. This includes
native apps, browsers, ChatGPT, and unknown microphone owners; several owners and device or helper changes
stay inside the same Call. Krisp is treated as an audio relay: it may join an existing Call, but cannot start,
name, or keep one alive by itself. Eye also excludes its own processes, a narrow system list, and ChatGPT's
`codex_chronicle` capture helper. Known Zoom, Meet, and Teams signals may improve the saved source context, but
they never decide whether recording is allowed to start. Detection, recording, and saving do not require
internet access.

Eye requests separate microphone and system-audio tracks. If one track is unavailable, the Call remains
recording and reports the missing track instead of silently hiding the gap. `Audio Off`, privacy pause,
critically low disk, and storage relocation remain hard stops.

The main **Record Timeline / Pause Timeline** control governs ordinary screen and Timeline audio capture; it
does not disarm microphone-triggered Calls. Choose **Audio Off** or start a privacy pause when no automatic
Call should begin. Privacy pause remains available from the menu bar even while Timeline capture is paused.

Eye itself and a narrow list of macOS system daemons are always excluded. **Settings → Audio → Don’t
auto-record these apps** adds user-selected bundle identifiers to a separate audio exclusion list; this does
not change the existing **Private apps** list for screen capture. While a Call is recording, **Never
auto-record [App]** adds that app to the audio list and saves the current Call.

When microphone activity disappears, Eye keeps the same Call open for a 30-second grace. **End & save**
finishes it immediately; **This wasn’t a call** stops and permanently deletes the whole automatic Call. If
the microphone returns during the grace, the timer is cancelled and the same Call continues. With no action,
Eye saves once after 30 seconds. There is no post-save Undo; saved Calls can be opened or deleted in Calls.

Detection is local. Call context may retain a normalized service host and an opaque fingerprint hash, but
not the full URL or path, meeting code, window title, or participant names; detector diagnostics log neither
private form. The ordinary Timeline capture still records visible screen content and may locally retain
browser URL, title, and text.

Optional Whisper Large V3 Turbo can produce a whole-call transcript after the call. Optional local
diarization creates anonymous per-call speaker lanes; you may name or correct them for that call. Eye does
not keep a reusable voiceprint and does not show a live transcript.

## Optional Browser Bridge

Chrome, Dia, Arc, Edge, Brave, Vivaldi, Chromium, and compatible Chromium browsers can add visible rendered
page text to Timeline. Install [ZBS Eye Browser Bridge from the Chrome Web Store](https://chromewebstore.google.com/detail/zbs-eye-browser-bridge/dancgjefofjomhclpgmilholpnfadolf),
or use the bundled unpacked fallback from **Settings → Browser Capture**. Copy the separate write-only token,
then explicitly enable the extension. Safari is not supported.

The extension checks an HMAC proof from the real local Eye process and confirms recording is active before it
extracts DOM text. It ignores background tabs, password and form values, hidden elements, scripts, and styles.
Requests go only to loopback. See the [Browser Bridge privacy details](./docs/BROWSER_BRIDGE_PRIVACY.md).

## Local capture; AI only when you choose it

Recording, indexing, Timeline, Calls, search, REST, and MCP do not require an AI provider. AI starts off.
On qualified Apple Silicon hardware, one click can download the pinned ZBS Eye Local model. You may instead
connect a local server, signed-in CLI, or cloud API provider.

That choice changes only generation features such as Ask and Daily Insights. Before any non-local provider
receives a prompt excerpt, Eye names the recipient and asks for scoped consent. Raw recordings, the database,
and storage never become provider uploads. API credentials live in the macOS data-protection Keychain.

## Install

1. Open the [current stable release](https://github.com/zbs-gg/eye/releases/latest), download the notarized ZIP,
   move **ZBS Eye.app** to `/Applications`, and launch it.
2. Grant Screen Recording and Accessibility. Microphone is optional; system audio has its own switch.
3. Press **Record Timeline**. Open Timeline and change windows once to see the first moments appear.

ZBS Eye is distributed outside the Mac App Store because cross-app Accessibility and continuous capture are
incompatible with the App Sandbox. Release artifacts use Developer ID, Hardened Runtime, Apple notarization,
and a stapled ticket. Exact artifact verification is documented in [docs/NOTARIZE.md](./docs/NOTARIZE.md).
Maintainers must use the exact ZIP and matching `.manifest.json` path printed by the script, never select a
release asset by wildcard, and run `scripts/verify-release-artifact.sh` before installation or publication.

The app pauses on lock, display sleep, and system sleep. It resumes only after macOS reports a real unlocked
console session; `loginwindow` and screen-saver shells are rejected again at the final write boundary.

## Give your agent read-only memory

The installed binary can serve MCP over stdio:

```bash
"/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye" --mcp-read-only
```

Use that command in Codex, Claude Code, Claude Desktop, or another MCP client. Read-only mode exposes Timeline,
search, calls, bookmarks, source health, and paginated transcript evidence. Frame-image access and the global
capture toggle require the separate `--mcp-full` mode. For localhost integrations, inspect `GET /health`,
then use the authenticated REST surface described by the app's **MCP & AI Tools** settings.

## Build and review

```bash
xcodegen generate
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Debug build
```

The codebase is Swift 6 with strict concurrency, SwiftUI, ScreenCaptureKit, Vision, GRDB/SQLite, sqlite-vec,
whisper.cpp, FluidAudio, FlyingFox, and the Swift MCP SDK. Start with [AGENTS.md](./AGENTS.md) for architecture,
data-safety invariants, and review risks; use [BUILD.md](./BUILD.md) for the complete build path.

Privacy and data-loss review matter more here than feature count. Capture has one writer, every live
data-root path is resolved through `StorageLocation`, live SQLite is never copied directly, and the HTTP
surface is localhost-only with authentication. iCloud snapshots and user exports are intentional
out-of-root exceptions.

## License

[MIT](./LICENSE) © 2026 zbs-gg.
