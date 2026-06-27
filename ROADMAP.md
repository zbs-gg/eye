# ZBS Eye — Roadmap

**Eternal local memory for your Mac.** Continuously records screen and sound, lets you find any moment
in seconds. 100% on-device — no cloud, no account, no subscription.

This document is where we're going and why. For the current code state and architecture, see `AGENTS.md`.

---

## Why this exists at all

The "personal computer memory" category was orphaned: the main player was acquired by a big corporation,
and the rest are either cloud-based (your life moves onto someone else's servers) or moved to a $25–50/mo
subscription with a mandatory account. ZBS Eye takes this niche from the opposite stance: **everything stays with you.**

Two product goals:

1. **Replace personal memory after the fact** — record everything, search like a human, rewind time.
   This is the core (v1.0).
2. **Replace a live AI prompter in calls** — real-time hints over a conversation. A new layer on top of
   the existing audio pipeline (v1.5).

---

## Principles (never broken)

- **Zero egress.** The server listens only on `127.0.0.1`; everything except `/health` is behind a Bearer token.
- **Zero accounts, zero subscription, zero telemetry.** That IS the product, not a temporary stance.
- **AI is local only** (a local LLM). No "cloud presets by default".
- **Default is to record everything**, but give the person control: pause, exclusions, delete a range.
- **Native and lightweight.** Swift/SwiftUI, Apple Silicon hardware acceleration, minimal dependencies.

---

## Working now (verified live)

- Screen capture: ScreenCaptureKit → HEIC, accessibility text + OCR fallback, perceptual-hash dedup.
- Audio: microphone + system audio, VAD, on-device transcription (SFSpeech).
- Hybrid search: FTS5 + semantics (multilingual-e5, 384-dim) via RRF — **cross-lingual**.
- Timeline: scrubber, activity density, 1×/2×/4× player, day/hour/10-min zoom.
- Local REST + MCP for AI agents.
- Storage: retention (forever by default), move to external SSD, iCloud backup as a compressed snapshot,
  size tracking.
- Automations: daily summary (local LLM → file/Obsidian), export.

---

## v1.0 — "daily driver"

> Goal: you can run it 24/7 and **trust** it — nothing is lost silently, search finds everything, the
> first launch is clear. That's the bar at which the product stops "lying".
>
> **Status: effectively reached in code** (build verification is on the Mac, see below). Below, ✅ = done,
> 🟡 = partial/polish, ⏳ = deferred for a reason.

### 1. Recording reliability — ✅
- ✅ Transcription backfill: untranscribed segments (crash/fail) are delivered at startup
  (`AudioCoordinator.backfillUntranscribed`, 7-day window, file check).
- ✅ Diagnosability: `os.Logger` by category (`Log`), crash marker (clean-shutdown flag), server log.
- ✅ Real-time storage: a continuous retention timer + a size trigger; a disk guard before capture
  (`diskOK`/`freeBytes`) + emergency prune.

### 2. Capture depth — 🟡
- ✅ Multi-monitor: the display of the focused window is captured (`displayForFrontmostWindow`).
- ⏳ Polish (needs tuning on hardware): priority AX extraction instead of a full traversal, per-PID
  backoff (don't slow other apps), per-tile hash, titles/URLs for OCR-only windows.

### 3. Full search — ✅
- ✅ Time/app/type filters + pagination through `SearchService` → REST (`/v1/search`) → MCP
  (`search_history`); a vec shard filter by monthly buckets + recency-first.

### 4. Call memory — ✅
- ✅ Semantics over transcripts (vec_transcripts, cross-lingual: a query in one language finds a conversation in another).
- ✅ Audio on the timeline: a transcript panel + m4a playback (`AudioPlayerStore`).

### 5. Truly zero egress — ✅
- ✅ The embedding model is bundled (`scripts/build-release.sh`) — first-run with no network.

### 6. "Ask your memory" — ✅
- ✅ "Ask" section: question → hybrid search → a local LLM answers from fragments with links
  (`AskService`/`AskStore`/`AskView`). Fully on-device — a local equivalent of "Ask Rewind".
- ✅ LLM model picker from what's actually loaded in LM Studio/Ollama (`/v1/models`), not free text input.

### 7. Packaging for distribution — ✅
- ✅ Launch at login (`SMAppService`), first-run onboarding.
- ✅ **Notarization (Developer ID)** — `scripts/build-notarized.sh` (Hardened Runtime + Developer ID +
  notarytool + staple). Distribution **outside the App Store** (the sandbox would kill cross-app AX — the core).
  Double-click install, no "Open Anyway"; the signature is stable — rebuilds do NOT reset TCC. Cert setup — `docs/NOTARIZE.md`.
- ⏳ Auto-updates (Sparkle) and a test target (XCTest) — next.

### Deliberately deferred from v1 (with a reason)
- ⏳ **VAD "speech vs music"** — currently an energy (RMS) gate. A full music classifier risks muting
  speech (the worst failure for a recorder) and needs tuning on real audio — we'll do it after field tests.

**v1.0 readiness criterion:** a week of real 24/7 use with no silent losses; search finds both screen
text and conversations; the first launch on a fresh machine is completed without hints.

> **Built, notarized, working live** (2026-06-25): a notarized Developer ID build is installed, launches
> with a double-click, writes to an external SSD (50k+ frames). The live-recording crash (self-AX reentrancy)
> is fixed and verified live. For the formal "v1.0 check mark", what remains is: a test target (XCTest).

---

## v1.5 — "live prompter" (new epic)

> Goal: real-time hints during a call — something after-the-fact memory doesn't have.

- **Live overlay**: a lightweight window over the call.
- **Streaming transcript of both sides** (microphone = me, system audio = the other party) in real time.
- **A local LLM on the stream**: hints, answers, a running summary during the conversation.

The foundation is already there architecturally (mic+system audio pipeline, a local LLM, context search) —
what's needed is the real-time layer and the overlay window.

---

## v2.0 — ecosystem and polish

- **Scheduled automations** + notifications (currently manual only).
- **Connectors**: Obsidian / Notion / etc. as full destinations.
- **Extended export** of a day/everything (markdown + media) — "take your memory with you", against lock-in.
- **Speaker diarization** deeper than simple me/other-party labels.
- **Hotkeys, jump to date, app exclusions** — the small daily-comfort things.

---

## Deliberately NOT doing (this is a stance, not a TODO)

- Cloud, accounts, telemetry — never.
- An app blocklist by default — the default is "record everything", exclusions are opt-in only.
- Heavy models that heat the CPU — the lightness of the native stack is part of the product.
