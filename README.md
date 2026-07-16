<div align="center">

<img src="docs/hero.gif" alt="ZBS Eye — the all-seeing eye of your Mac, in ASCII" width="720">

# ZBS Eye

**Eternal memory for your Mac.** Continuously records what happens on your computer — and lets you
find any moment in seconds. 100% local, no cloud, no account.

> 👁 **One Eye to remember them all.**
> It sees every screen. It hears every sound. It keeps everything.
> And it tells no one — because all of it stays with you.

</div>

---

## What it is

ZBS Eye quietly keeps an "eternal memory" of your work at the computer:

- **Screen** → accessibility text (accurate and battery-friendly) + OCR where AX is unavailable, frames in HEIC.
- **Audio** → system audio (calls, meetings, video) and microphone → on-device transcription.
  **Meetings-only by default**: audio is captured only while a call is detected (a meeting app is
  using the mic), the engine is fully off otherwise — saving disk. Switch to always / off, or force
  it on/off from the menu bar.
  For a call you explicitly want to keep, press **Start Call**: Eye records microphone and system audio
  as separate durable sources until **End Call**. **Bookmark** schedules a local checkpoint transcript
  without interrupting either source; the optional one-click Whisper Large V3 Turbo model produces the
  preferred whole-call transcript after the call.
- **Search** → hybrid full-text + semantic (cross-lingual: search in one language, find another),
  a scrubbable timeline, frames served as images.
- **Access for AI agents** → a local REST + read-only MCP surface so LLMs/agents can find Call Envelopes,
  bookmarks, source health, and paginated transcript evidence without scraping the UI.
- **Built-in local AI, with provider choice** → one click downloads a verified on-device model for Ask,
  Daily Insights, summaries, and activity labels. Or choose Codex, OpenRouter, Anthropic, Kimi, GLM,
  MiMo, OpenAI, Claude Code, Ollama, or LM Studio. Providers own their model lists; cloud and signed-in
  CLI providers receive history excerpts only after an explicit, recipient-specific opt-in.

Capture, index and storage stay on the device — zero egress, no subscription, no account. AI is
local-first: cloud providers exist only behind an explicit per-provider opt-in and receive prompt
excerpts, never your recordings.

## Why

The "personal computer memory" category was orphaned: the leader was acquired by a big corporation, and
the nearest alternatives moved to a subscription ($25–50/mo) plus a mandatory cloud. ZBS Eye is a light,
native alternative that **never goes to the cloud** — your activity history is too personal to hand off.

| | ZBS Eye | proprietary alternatives |
|---|---|---|
| Cloud / account | ✅ not required | ❌ mandatory |
| Subscription | ✅ free | ❌ $25–50/mo |
| Accumulated memory | ✅ yours, local | ❌ behind a paywall |
| Stack | ✅ native Swift/SwiftUI | ❌ web wrapper (Electron/Tauri) |

## Features

- 🎥 **Screen capture** — AX text + OCR, HEIC, perceptual-hash dedup, adaptive per-app (AX where it works,
  OCR where it doesn't).
- 🎙️ **Audio + transcription** — system + microphone, VAD, on-device speech. **Meetings-only by
  default** (auto-detected on-device) — records during calls, off otherwise to save disk; always / off
  modes + a menu-bar force on/off.
- 🔖 **Explicit call recording** — Start / Bookmark / End in one compact strip. Bookmark never pauses
  recording; it creates a provisional local checkpoint, while an optional 1.62 GB Whisper model performs
  the final whole-call pass after End. Mic-only calls remain valid and clearly report the missing source.
- 🔍 **Hybrid search** — FTS5 + multilingual-e5 (384-dim) via RRF; cross-lingual.
- 🕰️ **Timeline** — scrub through time, frame + text + app/URL, a player.
- 🔌 **REST + MCP** — a local API (127.0.0.1, Bearer token) for agents; MCP over stdio. Call tools are
  read-only, use typed IDs, never return absolute paths, and cannot select another database or storage root.
- 🧠 **Built-in local AI** — the headline path in "AI Models" downloads a pinned, verified MLX model and
  then runs fully offline on supported Macs. The same provider-first screen keeps real choice: Codex,
  OpenRouter, Anthropic, Kimi, GLM, MiMo, OpenAI, Claude Code, and separate Ollama / LM Studio connections.
  A recommendation lives inside its provider and never silently changes the active provider/model pair.
- ♾️ **Storage** — no age cutoff with a small **5 GB local media budget** on fresh installs; choose
  **Forever · no limit** to keep media until you delete it; **move to an external SSD** in one click;
  **iCloud auto-backup** (a compressed snapshot, without uploading the live database); size tracking.
- 📥 **Import previous history** — bring your accumulated history (text + metadata) over.
- 📝 **Automations** — daily summary to a file/Obsidian; export.
- 🔒 **Privacy** — pause per app, delete by time range, all local.
- 📊 **Usage stats** — an on-device breakdown of the last 7 days: where the time actually went (browsers
  split by **real site**, not lumped as one app), active minutes/day, context switches, busiest hour.
  Front-and-center on the Daily Insights screen.
- 🧭 **Daily Insights** — a daily local-LLM read of your activity (2–3 concrete observations), on-device.
- 🛠️ **Self-repair** — something broke? Describe it and Eye hands **your own AI agent** a ready-to-run
  fix prompt (it reads the public source and fixes it), or opens a pre-filled GitHub issue. No dead ends.
  Reachable from a **main-window button**, the **menu bar**, and Settings; agents can also pull live state
  over MCP (`get_diagnostics`).

### Calls, without turning Eye into a CRM

Eye's job is to preserve and expose trustworthy local evidence. It does not show a live transcript,
build a call map, manage contacts, join meetings as a bot, infer speaker identity inside the system track,
or inspect your calendar. Those are consumers that can use Eye's authenticated REST/MCP evidence later;
they are not part of this tiny recorder.

## Own it: fix and extend Eye with your agent

ZBS Eye assumes you have your own coding agent (Claude Code, Cursor, …) — so a broken or missing
thing is never a dead end. The flow:

1. Something breaks → click **"Something wrong?"** (toolbar / menu bar / Settings), describe it.
2. Eye collects on-device diagnostics and copies a prompt for your agent — a **quick repair prompt**,
   or **"Set up a dev workspace"** for a longer job.
3. The workspace prompt has your agent clone this repo — which ships with a **ready-made harness**:
   `CLAUDE.md` + [`AGENTS.md`](AGENTS.md) (rules, invariants, gotchas), `.claude/skills/`
   (`eye-build`, `eye-diagnose`, `eye-db-validate`, `eye-review-loop`, `eye-release`), a hostile
   `swift6-reviewer` subagent, and a find→verify review workflow.
4. Your agent reproduces the bug, fixes it, self-reviews, and opens a PR — or just builds you a
   feature nobody else needs. Your recorder, your rules.

## Install

<div align="center">
<img src="docs/open-anyway.png" alt="macOS Gatekeeper — click Open Anyway" width="640">
</div>

**ZBS Eye is not in the Mac App Store — and can't be.** Reading other apps' screens (cross-app
Accessibility) and a "record everything" profile don't fit the App Sandbox the App Store requires. So
macOS may show the dialog above on first launch. **It's expected and safe — click "Open Anyway"**
(it's outside the App Store, not malware). Want certainty? **Ask your own agent to read the source and
do a security review first** — it's all here, nothing to hide.

**Release — notarized Developer ID (double-click to launch, no "Open Anyway"):**

1. Build it: `bash scripts/build-notarized.sh` (needs a "Developer ID Application" certificate +
   a notarytool profile — one-time setup in [`docs/NOTARIZE.md`](docs/NOTARIZE.md)).
2. Use only the exact version/build/source ZIP path and matching `.manifest.json` path printed by the script,
   then run `bash scripts/verify-release-artifact.sh "$ZIP" "$MANIFEST"`. The verifier checks the hashes and
   independently pins the actual Developer ID Team, designated requirement, CDHash, stapled ticket, and
   Gatekeeper result. Never select a release asset by wildcard or by "newest file".
3. Unzip that verified exact ZIP into `/Applications` and launch with a **double-click** (Gatekeeper passes
   it, even offline — the ticket is stapled).
4. Before publishing, qualify the installed artifact in both directions: prove an ordinary unlocked app
   creates a new moment, then lock the Mac long enough for several capture intervals and prove no new moment
   is written; after unlock, prove capture resumes with an ordinary app and zero `loginwindow` / screen-saver
   rows. Restore the previous recording setting when done. The complete gate is in
   [`docs/NOTARIZE.md`](docs/NOTARIZE.md).
5. Grant **Screen Recording** + **Accessibility** (optionally Microphone) once. The notarized signature
   is stable: rebuilds do NOT reset permissions.

**Dev build without a paid account (self-signed):** `bash scripts/make-signing-cert.sh` (once) →
`bash scripts/build-release.sh` → unzip into `/Applications` → launch → **System Settings → Privacy &
Security → "Open Anyway"**. Downside: changing the signature sometimes resets TCC permissions (notarization removes this).

**Full product description** — [`docs/ABOUT.md`](docs/ABOUT.md). Build details — [`BUILD.md`](BUILD.md).
Architecture and contributor/agent guide — [`AGENTS.md`](AGENTS.md). Distribution — [`docs/NOTARIZE.md`](docs/NOTARIZE.md).

## Privacy

- Everything on the device. The server listens only on `127.0.0.1`; everything except `/health` requires
  a Bearer token (in the Keychain). No outbound traffic by default.
- Built-in AI is local-first and offline after its one-time model download. If you deliberately activate
  a cloud, broker, or signed-in CLI provider in "AI Models", ZBS Eye names the real recipient and asks for
  scoped consent before sending generation excerpts. Recordings, the index, and storage never leave the
  Mac; API credentials live in the data-protection Keychain.
- The iCloud backup (optional, on by default if iCloud is present) goes out as a **compressed snapshot** —
  the live database stays local (you must not put a live SQLite file in iCloud Drive — corruption).
- A password or sensitive conversation captured by accident can be wiped by time range or by app.

## Tech

Swift 6 (strict concurrency), SwiftUI, macOS 15+ · GRDB (DatabasePool + WAL) + FTS5 + sqlite-vec ·
ScreenCaptureKit · Accessibility API · Vision OCR · SFSpeech · whisper.cpp · multilingual-e5 (swift-embeddings) ·
MLX Swift LM (built-in generation) · FlyingFox (REST) · MCP swift-sdk · Hardened Runtime without App Sandbox.

## Status

Working: capture (screen + audio), hybrid search, timeline, REST + MCP, import of previous history,
retention (5 GB local media budget by default, with explicit Forever), relocatable storage, iCloud backup, size tracking, daily summary,
export, and one global provider/model pair for Ask, Daily Insights, summaries, and generated labels.
Explicit Call Envelopes, uninterrupted Bookmark checkpoints, optional post-call Whisper transcription,
preferred-only call search, and read-only agent evidence are implemented; physical 60/120-minute release
qualification is tracked separately and must pass before this call feature is declared field-qualified.
The default path is a one-click built-in local model on qualified hardware; external local and cloud
providers remain choices. Distribution — **notarized Developer ID** (`scripts/build-notarized.sh`).

## License

Private project `zbs-gg`. © 2026.

---

<div align="center">

```
                              -==++=::.
                               :=##%###+=:
                                 .:+#@%%%#=:
                :-==++++++=---===:..:-#@@%%*:
             :+*#*+++++===+*####*++=:.:-#@##*:
           -*#+=====------==++*#%%***=:.:=%*+=
         .*#=-==---::.. .:--===++*@%++:   :*=--
        .*#--+::-.          :=--+++%%-.    .- .
        +%=-+:--              -=:*=+@*  :
        ##:+=:=                =:=*-%%:
        ##:+-.=                =:=*-%#.  .
     .  +@=-+:=-              --:+==%+
        .#%==+:-=.          .--:==-##.  .
         .*%+-==----:.  .::----=-+#*.
           -*#+====--------====+#*- .
             :+***+++====+++*##+:
                :-==++**++==-:
```

**`Z B S   E Y E`** — _it sees everything. it remembers everything. and it all stays with you._ 👁

</div>
