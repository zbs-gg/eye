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
2. **Hand trustworthy local evidence to the tools you choose** — authenticated REST/MCP, without growing
   Eye into a CRM, calendar bot, or live meeting workspace.

---

## Principles (never broken)

- **Zero egress for capture, index, and storage.** The local server listens only on `127.0.0.1`; everything
  except `/health` is behind a Bearer token. History excerpts leave the Mac only after explicit consent to
  an activated external generation provider.
- **Zero accounts, zero subscription, zero telemetry.** That IS the product, not a temporary stance.
- **Built-in local AI is the shortest one-click path, never an automatic install.** External local, cloud,
  broker, and signed-in CLI providers remain deliberate choices; recommendations guide but never activate themselves.
- **Default is to record everything**, but give the person control: pause, exclusions, delete a range.
- **Native and lightweight.** Swift/SwiftUI, Apple Silicon hardware acceleration, minimal dependencies.

---

## Current product state

Previously verified live baseline:

- Screen capture: ScreenCaptureKit → HEIC, accessibility text + OCR fallback, perceptual-hash dedup.
- Audio: microphone + system audio, VAD, on-device transcription (SFSpeech).
- Hybrid search: FTS5 + semantics (multilingual-e5, 384-dim) via RRF — **cross-lingual**.
- Timeline: scrubber, activity density, 1×/2×/4× player, day/hour/10-min zoom.
- Local REST + MCP for AI agents.
- Storage: 5 GB Keep Media on a fresh profile, explicit 10/20/50 GB or Forever, move to external SSD, iCloud
  backup as a compressed snapshot, size tracking.
- Automations: daily summary (local LLM → file/Obsidian), export.
- Built-in local generation on qualified hardware, with one global provider/model pair and provider-owned
  model lists; Ollama and LM Studio remain separate alternatives.

Implemented and deterministically verified in the **`0.7.0 (21)` candidate**:

- Explicit Call Envelopes, the Calls library/detail, uninterrupted Bookmarks, optional local Whisper and
  per-call speaker processing, preferred-only search, and bounded read-only agent evidence.
- One persistent low-rate screen stream, bounded latest-wins processing (one active + one pending), and one
  coordinator serializing complete screen/system-audio ScreenCaptureKit lifecycle operations.
- Best-effort listen-only yield for native screenshot shortcuts with no new TCC prompt, plus exact native helper
  observation. Failure to observe an early keypress leaves the system shortcut untouched.
- Per-leg capture health, durable coverage gaps, bounded 1/3/10-second Eye-owned recovery, and explicit repair
  after exhaustion; static pixels alone never mean failure.
- Automatic Calls from eligible external microphone initiators, including while Timeline recording is paused.
  Krisp is relay-only, `codex_chronicle` is excluded, and the exact automatic-Call exclusion list is separate
  from screen privacy. Audio Off and privacy pause disarm Calls.
- A 30-second detected-end window with resumed-mic continuation, **End & save**, or destructive
  **This wasn’t a call**. There is no post-end Undo.

Build 21 is **not physically release-qualified yet**. A new exact notarized ZIP/manifest must pass the complete
capture-coexistence v2 bracket, native-shortcut and recovery matrix, 30-minute churn and two-hour installed soak,
plus the full automatic-Call physical checklist including 60- and 120-minute calls. Deterministic tests do not
replace those installed-artifact gates.

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
  (`diskOK`/`freeBytes`). Critically low disk pauses capture; it never overrides Keep Media by deleting history.
- ✅ Screen capture uses one persistent low-rate stream and latest-wins processing rather than per-cycle native
  screenshot requests or an unbounded work queue.
- ✅ Screen and system-audio start/update/stop operations cannot overlap; capture health records real gaps and
  retries only Eye-owned resources before asking for explicit repair.

### 2. Capture depth — 🟡
- ✅ Multi-monitor: the display of the focused window is captured (`displayForFrontmostWindow`).
- ✅ Native screenshot coexistence: listen-only, best-effort early yield plus exact helper observation, with no
  new permission prompt and no event interception.
- ⏳ Polish (needs tuning on hardware): priority AX extraction instead of a full traversal, per-PID
  backoff (don't slow other apps), per-tile hash, titles/URLs for OCR-only windows.

### 3. Full search — ✅
- ✅ Time/app/type filters + pagination through `SearchService` → REST (`/v1/search`) → MCP
  (`search_history`); a vec shard filter by monthly buckets + recency-first.

### 4. Call memory — ✅
- ✅ Semantics over transcripts (vec_transcripts, cross-lingual: a query in one language finds a conversation in another).
- ✅ Audio on the timeline: a transcript panel + m4a playback (`AudioPlayerStore`).
- ✅ Explicit Call Envelopes keep microphone/system evidence separate; Bookmark never stops capture.
- ✅ Optional Whisper Large V3 Turbo checkpoints + preferred whole-call final; no model required to record.
- ✅ Timeline/search/REST/MCP resolve one Call Envelope without duplicate provisional/final hits.
- ✅ Eligible external microphone use can start one automatic Call even while Timeline recording is paused;
  relay-only Krisp cannot own it, `codex_chronicle` is ignored, and audio-only exclusions do not alter screen history.
- ✅ A detected end has one 30-second grace owner. Returning microphone activity resumes the envelope;
  **End & save**, timeout save, and **This wasn’t a call** are single-owner terminal paths with no Undo.
- 🟡 Release qualification: deterministic fixtures pass; the exact installed build still needs the complete
  short/60/120-minute privacy, continuity, resource, restart, device-change, and recovery checklist.

### 5. Truly zero egress — ✅
- ✅ The embedding model is bundled (`scripts/build-release.sh`) — first-run with no network.

### 6. "Ask your memory" — ✅
- ✅ "Ask" section: question → hybrid search → the active processing model answers from fragments with
  links (`AskService`/`AskStore`/`AskView`). The built-in provider stays on-device; an external provider
  sees excerpts only after scoped consent.
- ✅ Provider-first "AI Models" screen: ZBS Eye Local is the one-click headline; models remain inside Codex,
  OpenRouter, Anthropic, direct providers, Ollama, and LM Studio rather than becoming peer providers.

### 7. Packaging for distribution — ✅
- ✅ Launch at login (`SMAppService`), first-run onboarding.
- ✅ **Notarization (Developer ID)** — `scripts/build-notarized.sh` (Hardened Runtime + Developer ID +
  notarytool + staple). Distribution **outside the App Store** (the sandbox would kill cross-app AX — the core).
  Double-click install, no "Open Anyway"; the signature is stable — rebuilds do NOT reset TCC. Cert setup — `docs/NOTARIZE.md`.
- ⏳ Auto-updates (Sparkle) — next.

### Deliberately deferred from v1 (with a reason)
- ⏳ **VAD "speech vs music"** — currently an energy (RMS) gate. A full music classifier risks muting
  speech (the worst failure for a recorder) and needs tuning on real audio — we'll do it after field tests.

**v1.0 readiness criterion:** a week of real 24/7 use with no silent losses; search finds both screen
text and conversations; the first launch on a fresh machine is completed without hints.

> **Historical installed-build evidence** (2026-06-25): a notarized Developer ID build was installed, launched
> with a double-click, writes to an external SSD (50k+ frames). The live-recording crash (self-AX reentrancy)
> is fixed and verified live. The release now also has a native XCTest target covering provider,
> provisioning, routing, adapter, and consumer contracts. This evidence does not qualify the later
> `0.7.0 (21)` candidate or its capture/automatic-Call changes.

---

## After v1 — keep the recorder small

Eye may improve evidence quality, resource use, export, and agent interoperability. The following are
explicitly deferred to another product/repository (for example AIOS), not a hidden Eye v1.5 epic:

- live streaming transcript or call overlay;
- calendar pre-arming / automatic meeting joining;
- call maps, summaries, action items, CRM/contact management, or sales intelligence;
- remote diarization or any cloud speech path;
- multi-speaker identity inference inside the system-audio track.

Eye's boundary is the useful one: record reliably, preserve gaps honestly, index after the fact, and let a
separate authorized agent consume the evidence.

---

## v2.0 — ecosystem and polish

- **Scheduled automations** + notifications (currently manual only).
- **Connectors**: Obsidian / Notion / etc. as full destinations.
- **Extended export** of a day/everything (markdown + media) — "take your memory with you", against lock-in.
- **Speech evidence quality/size benchmark** before considering any smaller runtime; no identity claims.
- **Hotkeys, jump to date, app exclusions** — the small daily-comfort things.

---

## Deliberately NOT doing (this is a stance, not a TODO)

- Cloud, accounts, telemetry — never.
- An app blocklist by default — the default is "record everything", exclusions are opt-in only.
- Heavy models that heat the CPU — the lightness of the native stack is part of the product.
- Live transcript, meeting workspace, calendar bot, call intelligence, or CRM features — another product.
- Alternative/quantized speech models until a reproducible accuracy/size/resource benchmark justifies one.
