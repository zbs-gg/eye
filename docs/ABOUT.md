# What ZBS Eye is — the full description

> In one sentence: **ZBS Eye is the "eternal memory" of your Mac.** It continuously and quietly records
> what happens on the computer (screen + sound), makes sense of it, and lets you find, review, and analyze
> any moment of your digital life. Capture, search, and storage are **100% local, with no account or subscription.**
> Optional AI providers receive only approved text excerpts after explicit consent.

The codename in the code is `ZBSEye` (types, target, the binary `ZBS Eye.app`). Externally it's "ZBS Eye" everywhere.

---

## 1. Why it exists at all

A person spends most of the day at the computer, yet almost none of it survives: you close a tab and the
thought is gone, a call conversation is forgotten, "where did I see this three weeks ago" can't be recalled.
A "personal computer memory" category appeared, but it was orphaned and spoiled: the leader was acquired by
a big corporation (features were cut), and the remaining alternatives are on a **$25–50/mo subscription** with
a **mandatory cloud** — where the most personal thing you have, the history of what you do, goes.

ZBS Eye takes this niche from the opposite stance: **your recorded history stays with you.** A light, native
alternative where capture, media, index, and search remain on the Mac. Optional AI is off by default; if you
enable an external provider, only the text excerpts needed for that action leave the machine after consent.

**Two product goals:**
1. **Memory after the fact** — record everything, search like a human, review, make sense of it. The core (here now).
2. **Evidence interoperability** — let local agents retrieve trustworthy bounded evidence without turning Eye into a CRM or live meeting workspace.

---

## 2. What it does (features)

### Capture
- **Screen** → accessibility text (accurate and battery-friendly) + OCR where AX is unavailable (GPU
  renderers, canvas, some Electron); frames in HEIC with perceptual-hash dedup (identical screens aren't
  duplicated). Adaptive per-app: AX where the app exposes semantics, OCR where it doesn't; decided at runtime by content quality.
- **Audio** → system audio (calls, meetings, video) and microphone → **on-device** transcription (SFSpeech),
  with VAD (we don't transcribe silence/music). An explicit **Call** mode keeps microphone and system audio
  as separate durable sources until End Call. Bookmark never stops recording: it schedules a local checkpoint
  transcript, while the preferred whole-call transcript is produced after the call by the optional one-click
  Whisper Large V3 Turbo model. The UI intentionally does not become a live meeting workspace.

### Sense-making (not just raw data, but structure)
- **Scenes / "Day in activities"** — frames are grouped into **activity scenes**: "VS Code, 14:00–14:25,
  editing AXReader" instead of a thousand separate frames. You see how the day breaks into blocks. Instead of
  a raw OCR dump on the right — a **clean scene summary** (app, window/URL, key topics; LLM enhancement optional).
- **Daily Insights** (formerly "Cartographer") — an optional daily AI insight: the model you chose in **Settings → AI**
  looks at the day's activity (top apps, context switches, topics) and gives **2–3 concrete
  observations/tips** (self-improvement). AI is off by default; local and external choices are explicit.
- **Usage stats** — an on-device breakdown of the last 7 days, front-and-center on the Daily Insights screen:
  where the time went (browsers split by **real site**, recovered from your own imported history, not lumped
  as one app), active minutes/day, context switches/day, busiest hour.
- **Self-repair** — because the source is public and you have your own agent, a broken thing isn't a dead end.
  Describe the problem → Eye collects on-device diagnostics and copies a ready-to-run repair prompt for your
  coding agent (read the source, reproduce, fix), or opens a pre-filled GitHub issue. For bigger jobs there's a
  second action — **"Set up a dev workspace"** — a bootstrap prompt that has your agent clone the repo, verify
  the toolchain and a green build, and use the harness that ships in it (`CLAUDE.md`/`AGENTS.md`, the
  `.claude` skills for build/diagnose/DB-validation/review/release, a hostile Swift 6 reviewer, an adversarial
  review workflow) — so the agent doesn't just fix this one bug, it can keep maintaining and extending Eye for
  you. Reachable from a main-window toolbar button, the menu bar, and Settings; an agent can also pull live
  state over MCP via the `get_diagnostics` tool.

### Search and navigation
- **Hybrid search** — full-text (FTS5) + semantic (multilingual-e5, 384-dim) via RRF.
  **Cross-lingual**: search in one language, find another (and vice versa).
- **Timeline** — scrub through time, activity density, a 1×/2×/4× player, day/hour/10-min zoom, frames served
  as images. Smooth: frame crossfade, a soft scrubber, micro-animations (respecting Reduce Motion).
- **"Ask"** — ask your memory a question → hybrid search finds fragments → your **processing model**
  answers with citation links (click → jump on the timeline). A local equivalent of "Ask Rewind".
  The model is picked in **Settings → AI**. One action can download ZBS Eye's verified built-in MLX model;
  external providers and OpenAI-compatible endpoints remain optional. Background summaries and activity
  labels each require their own explicit consent when the active provider is external.

### Rewards and progress
- **Gamification** — day streaks, milestones (1k/5k/10k/… frames), "memory age", progress to the next
  milestone; on reaching a milestone — a subtle visual reward (an aurora shimmer). The longer you use it, the richer the memory.

### Access for AI agents
- **Local REST** (127.0.0.1, a Bearer token on everything except `/health`) + **MCP** (stdio) — so Codex,
  Claude Code, and Claude Desktop can work with your memory as a local tool. Generated setup is read-only
  by default, uses no bearer token, and sends nothing outside the Mac.
- Call evidence uses one bounded read model on both surfaces: list/search Call Envelopes, read one envelope,
  paginate bookmarks, and paginate the preferred or bookmark transcript. IDs are typed (`call:…`,
  `bookmark:…`, `call-audio-chunk:…`); responses expose source health, coverage, revision state, and retryability,
  but never absolute paths or invented speaker identity. REST requires the existing Bearer token. Stdio MCP is
  an owner-launched signed-binary capability, resolves only the configured `StorageLocation`, and opens the
  database in enforced read-only mode; callers cannot provide another database or storage root.

### Storage and data
- **Keep Media has no age cutoff and is 5 GB on a fresh install.** 10/20/50 GB and **Forever** are explicit choices. Low disk
  pauses capture instead of silently deleting history.
- **Move to an external SSD** in one click (relocatable; the live DB is moved via an online backup, with no frame loss).
- **iCloud auto-backup** — a compressed snapshot (you must not put a live SQLite into iCloud — corruption).
- **Import previous history** (e.g. from ~/.screenpipe) — bring what you've accumulated over.
- **Automations** — daily summary to a file/Obsidian; export a day/everything.
- **Privacy** — pause per app, exclusions, delete by time range; the app does not record itself.

---

## 3. Principles (never broken)

- **Zero egress for capture, index and storage.** The server listens only on `127.0.0.1`; everything except `/health` is behind a Bearer token (in the Keychain). Recordings never leave the Mac.
- **Zero accounts, zero subscription, zero telemetry.** That IS the product.
- **AI off first; provider freedom stays real.** On qualified Macs one click installs a verified local model
  that works offline after download and needs no account, key, or server.
  External providers remain first-class choices. A recommendation is shown inside its provider and never
  activates itself. Cloud, broker, and signed-in CLI providers are behind explicit recipient- and
  scope-specific consent: they receive only the prompt excerpts needed for the chosen feature, never
  recordings or the index. Credentials live in the data-protection Keychain.
- **The default is to record everything**, but the human is in charge: pause, app exclusions, delete a range.
- **Native and lightweight.** Swift/SwiftUI, Apple Silicon hardware acceleration, minimal dependencies —
  as opposed to heavy web wrappers (Electron/Tauri).

---

## 4. How it works (architecture and stack)

- **Platform:** Swift 6 (strict concurrency = `complete`), SwiftUI, target macOS 15+, Apple Silicon.
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

One binary — several modes: GUI, `--mcp-read-only`, legacy/full `--mcp` and `--mcp-full`,
`--import-history`, `--relocate`, `--backup-now`, `--backup-verify`.

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
scenes/"Day in activities", "Ask" (RAG over the global provider/model pair), Daily Insights,
progress/milestones, REST + MCP, history
import, retention (5 GB media default with explicit Forever), relocatable storage, iCloud backup, daily summary, export. A notarized
Developer ID release exists.

**Implemented and deterministic-fixture qualified:** explicit Call Envelopes, uninterrupted Bookmark
checkpoints, optional post-call Whisper, preferred-only call search, and read-only REST/MCP evidence.
Installed-app short, 60-minute, and 120-minute physical gates remain before field qualification.

**Deferred:** Sparkle auto-updates and deep integration of Cartographer with Pulse/Atlas. Live transcription,
calendar automation, call maps, and CRM/call intelligence belong in another product, not Eye.

Strategy and priorities — in [`ROADMAP.md`](../ROADMAP.md). Architecture and the contributor guide — in [`AGENTS.md`](../AGENTS.md).
