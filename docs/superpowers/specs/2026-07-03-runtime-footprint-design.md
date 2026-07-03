# Runtime footprint reduction — design

**Problem (measured live, PID 46184, ~9h uptime, DB 58 473 frames):** ZBS Eye's runtime footprint is heavy —
`phys_footprint_peak = 1351 MB` on launch, settling to ~740 MB (RSS 390–450 MB) — and CPU spikes to ~74% on
launch. The bundled 449 MB model on **disk** is NOT the problem (that's static). The **runtime** cost is:

1. **`IOSurface` ≈ 550 MB resident** (384 regions, 535 MB swapped = stale-but-retained) — screen-capture frame
   buffers. Root causes: (a) capture at full native Retina resolution (`cfg.width = display.width`); (b) one
   shared `CIContext` with default intermediate caching, **`clearCaches()` never called** → GPU textures pile up.
2. **e5 model ≈ 150 MB (neural/ANE) resident 24/7** — because `IngestService` embeds **every** captured frame in
   the hot path, so the model is never released. Plus two `EmbeddingService` instances (ingest + search).
3. **Launch CPU 74%** — model warmup (449 MB fp32 → MLTensor/ANE) + live per-frame embed + Vision OCR
   (`.accurate` + auto-language). `VectorBackfill` is caught up (57191/57191) and already deferred 30 s @ `.utility`.

## Goals / non-goals
- **Goal:** cut steady RAM ~740 MB → ~300 MB and smooth the launch peak/CPU, with low regression risk. Local-first
  is untouched (no new egress, no behavior change beyond the two below).
- **Accepted tradeoffs:** (a) a just-captured frame becomes **semantically** searchable a few seconds later
  (FTS is instant, always); (b) screenshots are stored at a capped resolution (max 2560 px) — less pixel detail in
  old frames; OCR already downscales, so text quality is unaffected.
- **Non-goals:** FTS5-only default / opt-in model / quantization (separate positioning decisions, not this PR).

## Changes (ranked by impact-per-effort)

### 1. `FramePipeline` — CIContext memory [S, highest leverage, ~0 risk]
- Init `CIContext(mtlDevice:options:)` with `[.cacheIntermediates: false, .name: "ZBSEyeFramePipeline"]`.
- Call `ciContext.clearCaches()` at the end of every `process()` path (via `defer`).
- (`autoreleasepool` deemed unnecessary — `cacheIntermediates:false` + per-frame `clearCaches()` already release the
  IOSurface-backed intermediates, and wrapping the async/early-return control flow added risk for no measured gain.)
  Targets the ~550 MB IOSurface region directly.

### 2. Cap capture resolution [M, behavior change — approved]
- Add `maxCaptureDim: CGFloat = 2560` to `CaptureConfig`.
- In `process()`, if `max(display.width, display.height) > maxCaptureDim`, scale `cfg.width/height` down
  proportionally so SCK renders a smaller frame directly (smaller IOSurface **and** smaller HEIC → DB grows slower).
- Store the actual captured (scaled) width/height in `ProcessedFrame` / DB. phash + dedup run on the scaled image.

### 3. Move embedding out of the hot path + continuous indexer + unload-on-idle [S/M]
- `IngestService`: stop embedding on ingest. Screen frames and transcripts are written **without** a vector; drop
  the `embedder` dependency from `IngestService`. (Vectors are filled by the indexer below.)
- `EmbeddingService`: add `func unload()` (`bundle = nil`) to release the model from RAM on idle.
- Repurpose `VectorBackfill` → a **continuous indexer**: `run()` loops until cancelled. Each round drains
  frames-with-text-without-vector newest-first (pages of 300, 2 s between pages), then transcripts; when a page
  reaches already-indexed territory (`fresh.isEmpty`) the backlog is caught up → **`embedder.unload()`** and sleep
  `idleRescanSec = 20 s`, then rescan. During active use it keeps finding work and stays hot; when the user goes
  idle it releases the model. Remove the `maxTs` snapshot gate (the indexer now owns ALL embedding, including new
  frames). Keep the `WHERE EXISTS` guards + incremental `have` set.

### 4. Launch smoothing [S]
- Backfill/indexer already starts 30 s post-launch @ `.utility` — keep. The unconditional warmup embed becomes
  lazy: the model loads only when a round actually has items to embed (deferring the 449 MB load off the launch path).

## Files
- `ZBSEyeApp/Capture/FramePipeline.swift` (#1, #2)
- `ZBSEyeApp/Capture/CaptureConfig.swift` (#2)
- `ZBSEyeApp/Search/EmbeddingService.swift` (#3 — `unload()`)
- `ZBSEyeApp/Search/VectorBackfill.swift` (#3 — continuous indexer)
- `ZBSEyeApp/Data/IngestService.swift` (#3 — drop inline embed)
- `ZBSEyeApp/App/AppEnvironment.swift` (#3/#4 — wiring)

## Verification
- Build green (`xcodegen` not needed — no new files).
- Measure on the live process before/after: `footprint`/`vmmap` RSS + IOSurface region; expect IOSurface to stop
  accumulating and steady RSS to drop materially.
- FTS search still instant; a new frame gets a vector within ~20 s (search finds it by FTS immediately regardless).
- Capture still works (frames written, dedup intact) at the capped resolution.
