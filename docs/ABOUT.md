# What ZBS Eye is — the full description

> In one sentence: **ZBS Eye is the "eternal memory" of your Mac.** It continuously and quietly records
> what happens on the computer (screen + sound), makes sense of it, and lets you find, review, and analyze
> any moment of your digital life — **100% local, no cloud, no account, no subscription.**

The codename in the code is `ZBSEye` (types, target, the binary `ZBS Eye.app`). Externally it's "ZBS Eye" everywhere.

---

## 1. Why it exists at all

A person spends most of the day at the computer, yet almost none of it survives: you close a tab and the
thought is gone, a call conversation is forgotten, "where did I see this three weeks ago" can't be recalled.
A "personal computer memory" category appeared, but it was orphaned and spoiled: the leader was acquired by
a big corporation (features were cut), and the remaining alternatives are on a **$25–50/mo subscription** with
a **mandatory cloud** — where the most personal thing you have, the history of what you do, goes.

ZBS Eye takes this niche from the opposite stance: **everything stays with you.** A light, native alternative
that never goes to the cloud — because your activity history is too personal to hand off anywhere. This isn't
a temporary marketing position, it's an architectural principle (see §4).

**Two product goals:**
1. **Memory after the fact** — record everything, search like a human, review, make sense of it. The core (here now).
2. **A live prompter** — real-time hints over a call/work. A future layer on top of the existing pipeline.

---

## 2. What it does (features)

### Capture
- **Screen** → accessibility text (accurate and battery-friendly) + OCR where AX is unavailable (GPU
  renderers, canvas, some Electron); frames in HEIC with perceptual-hash dedup (identical screens aren't
  duplicated). Adaptive per-app: AX where the app exposes semantics, OCR where it doesn't; decided at runtime by content quality.
- **Audio** → system audio (calls, meetings, video) and microphone → **on-device** transcription (SFSpeech),
  with VAD (we don't transcribe silence/music).

### Sense-making (not just raw data, but structure)
- **Scenes / "Day in activities"** — frames are grouped into **activity scenes**: "VS Code, 14:00–14:25,
  editing AXReader" instead of a thousand separate frames. You see how the day breaks into blocks. Instead of
  a raw OCR dump on the right — a **clean scene summary** (app, window/URL, key topics; LLM enhancement optional).
- **Cartographer** — a daily AI insight: a local LLM looks at the day's activity (top apps, context switches,
  topics) and gives **2–3 concrete observations/tips** (self-improvement). On-device only. In the future — a
  single loop with Pulse/Atlas.

### Search and navigation
- **Hybrid search** — full-text (FTS5) + semantic (multilingual-e5, 384-dim) via RRF.
  **Cross-lingual**: search in one language, find another (and vice versa).
- **Timeline** — scrub through time, activity density, a 1×/2×/4× player, day/hour/10-min zoom, frames served
  as images. Smooth: frame crossfade, a soft scrubber, micro-animations (respecting Reduce Motion).
- **"Ask"** — ask your memory a question → hybrid search finds fragments → a **local LLM** answers with
  citation links (click → jump on the timeline). A local equivalent of "Ask Rewind". The model is chosen from
  what's actually loaded in **LM Studio / Ollama** (the list comes from `/v1/models`).

### Rewards and progress
- **Gamification** — day streaks, milestones (1k/5k/10k/… frames), "memory age", progress to the next
  milestone; on reaching a milestone — a subtle visual reward (an aurora shimmer). The longer you use it, the richer the memory.

### Access for AI agents
- **Local REST** (127.0.0.1, a Bearer token on everything except `/health`) + **MCP** (stdio) — so LLMs/agents
  (Claude Desktop, Cursor) can work with your memory as a tool. Zero egress.

### Storage and data
- **Retention is FOREVER by default** (an explicit choice — otherwise days/size).
- **Move to an external SSD** in one click (relocatable; the live DB is moved via an online backup, with no frame loss).
- **iCloud auto-backup** — a compressed snapshot (you must not put a live SQLite into iCloud — corruption).
- **Import previous history** (e.g. from ~/.screenpipe) — bring what you've accumulated over.
- **Automations** — daily summary to a file/Obsidian; export a day/everything.
- **Privacy** — pause per app, exclusions, delete by time range; the app does not record itself.

---

## 3. Principles (never broken)

- **Zero egress.** The server listens only on `127.0.0.1`; everything except `/health` is behind a Bearer token (in the Keychain).
- **Zero accounts, zero subscription, zero telemetry.** That IS the product.
- **AI is local only** (LM Studio / Ollama / mlx_lm.server on localhost). No cloud presets.
- **The default is to record everything**, but the human is in charge: pause, app exclusions, delete a range.
- **Native and lightweight.** Swift/SwiftUI, Apple Silicon hardware acceleration, minimal dependencies —
  as opposed to heavy web wrappers (Electron/Tauri).

---

## 4. How it works (architecture and stack)

- **Platform:** Swift 6 (strict concurrency = `complete`), SwiftUI, target macOS 15+, Apple Silicon. ~10k lines of Swift.
- **Concurrency:** `@MainActor @Observable` stores for the UI; actors for data/capture; one logical writer
  (`IngestService`); non-Sendable (`CVPixelBuffer`/`AXUIElement`/…) live and die inside a single actor.
- **Storage:** GRDB (`DatabasePool` + WAL) + **FTS5** (external-content) + **sqlite-vec** (statically linked —
  notarization without a loadable extension). A single path resolver `StorageLocation` (relocate-aware).
- **Capture:** ScreenCaptureKit (HEIC, perceptual-hash), Accessibility API on a dedicated thread (cross-app,
  per-PID health), Vision OCR (multilingual, ANE). AXReader does NOT inspect its own process (otherwise self-AX
  reentrancy crashes SwiftUI on a foreign thread — a real bug, fixed).
- **Audio:** CoreAudio process tap (system) + microphone, a VAD segmenter, SFSpeech on-device.
- **Search:** SearchService (FTS+vector RRF), EmbeddingService (multilingual-e5, **mean-pooling** — not CLS,
  otherwise 3× worse cross-lingually), temporal shards.
- **Server:** FlyingFox REST (`/v1`, 127.0.0.1, Bearer, path-traversal hardening) + MCP swift-sdk (stdio).
- **Package security:** **Hardened Runtime WITHOUT App Sandbox** (the sandbox is incompatible with cross-app
  AX + a local server). Minimal entitlements.

One binary — several modes: GUI, `--mcp`, `--import-history`, `--relocate`, `--backup-now`, `--backup-verify`.

---

## 5. Distribution — Developer ID + notarization (NOT the App Store)

The App Store requires App Sandbox, under which **cross-app Accessibility is impossible** (the core of text
extraction), and an "eternal memory, records everything" profile is almost guaranteed to be rejected on
privacy. So, like Rewind/screenpipe, ZBS Eye is distributed **outside the App Store** — as a notarized
Developer ID build (`scripts/build-notarized.sh`): it launches with a double-click without "Open Anyway",
the signature is stable (permissions survive updates). Setup — `docs/NOTARIZE.md`.

---

## 6. Place in the Garden ecosystem

ZBS Eye lives in `~/dev/ai/Garden/eye` alongside the other products of the family (Atlas, Cartographer, Pulse,
Garden-app) — each a separate repo (`zbs-gg/eye`). It currently runs autonomously and locally; later
"Cartographer" connects to **Pulse / Atlas** into a single sense-making loop (Mac memory → insights → actions),
staying faithful to the "everything on-device" principle.

---

## 7. Status

**Working and verified live:** capture (screen + audio), hybrid search (cross-lingual), timeline (smooth),
scenes/"Day in activities", "Ask" (RAG over a local LLM with a model picker from LM Studio), Cartographer
(daily insights), progress/milestones, REST + MCP, history import, retention (forever), relocatable storage,
iCloud backup, daily summary, export. A notarized Developer ID release exists.

**Deferred:** a test target (XCTest), Sparkle auto-updates, deep integration of Cartographer with Pulse/Atlas,
the v1.5 "live prompter" (a real-time overlay).

Strategy and priorities — in [`ROADMAP.md`](../ROADMAP.md). Architecture and the contributor guide — in [`AGENTS.md`](../AGENTS.md).
