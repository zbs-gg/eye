# ZBSEye — build

The project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`ZBSEye.xcodeproj` is in `.gitignore`). The one intentional tracked exception is its SwiftPM
`Package.resolved`: XcodeGen preserves it, and every scripted build requires those exact package revisions.

## Requirements
- macOS 15+ (developed on 26 Tahoe), Xcode 26+, Swift 6.
- `brew install xcodegen`
- The built-in local model is not needed to compile or run ordinary tests. Real-model qualification is
  opt-in and uses an already downloaded, manifest-verified directory; see [`docs/LOCAL_AI.md`](docs/LOCAL_AI.md).
- Call recording works without speech or speaker models. Optional Whisper and FluidAudio speaker assets are
  downloaded and checksum-verified only after the person asks for them; fixture tests never download weights.

## Build
```bash
xcodegen generate                 # generate ZBSEye.xcodeproj from project.yml
open ZBSEye.xcodeproj             # → Xcode → Cmd+R
# or from the CLI:
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Debug build
```

A one-shot unsigned verification build is in `scripts/verify.sh` (xcodegen → strict-concurrency Debug build).
It deliberately does not create or launch an ad-hoc signed app, so routine verification cannot churn the
stable TCC identity of the installed release.

The test target uses tiny fixtures and never downloads model weights:

```bash
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEyeUnitTests -configuration Debug test CODE_SIGNING_ALLOWED=NO
bash scripts/verify-local-ai.sh --all-fixtures
bash scripts/verify-call-recording.sh --fixtures
bash scripts/verify-call-automation.sh
bash scripts/verify-capture-coexistence.sh --self-test
```

## Architecture
```
ZBSEyeApp/
  App/        ZBSEyeApp (@main), AppEnvironment (@Observable root)
  Capture/    Persistent screen stream, latest-wins FramePipeline, SCKResourceCoordinator, screenshot priority, AXReader
  Audio/      AudioCoordinator, mic/system engines, VADSegmenter, TranscriptionService
  Meeting/    CoreAudio mic-owner listener, initiator/relay resolution, automatic Call detection
  Calls/      CallCoordinator, lifecycle policy, dual-source spool, Calls projection, Whisper/diarization helpers
  Data/       ZBSEyeDatabase, StorageLocation, StorageManager, BackupManager, RetentionManager, IngestService
  Search/     SearchService (FTS+vector RRF), EmbeddingService (e5), TimelineService, VectorBackfill
  Server/     ZBSEyeHTTPServer (FlyingFox REST, 127.0.0.1, Bearer), KeychainStore
  MCP/        ZBSEyeMCPServer (stdio)
  Automations/ HistoryImporter, DailySummaryService, ExportService, CartographerService
  State/      *Store.swift — @Observable @MainActor
  Views/      Timeline workspace, Ask, Achievements, focused Settings, MenuBar, Components
  ZBSEye.entitlements  — Hardened Runtime WITHOUT App Sandbox
```
Swift 6 strict concurrency = `complete`. Deployment target macOS 15.0.

See [`AGENTS.md`](AGENTS.md) for the architecture map, invariants, and gotchas.

## Call recorder runtime and model

The shipping source pins two independent artifacts:

- Runtime: official `whisper.cpp` `v1.9.1` XCFramework in `Packages/ZBSEyeWhisper/Package.swift`, SwiftPM
  checksum `8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c`.
- Model: `ggml-large-v3-turbo.bin` at immutable revision
  `98aa99a0a9db05ae2342309f5096248665f7cba3`, expected size `1,624,555,275` bytes and SHA-256
  `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69`.

The model is not bundled or installed by default. It lives below the configured relocatable data root at
`ai/speech/v1`, outside the call-evidence retention budget, and can be removed without deleting recordings.
The helper is an isolated `--whisper-job` mode of the same signed ZBS Eye executable; there is no unsigned
downloaded helper binary. It receives one immutable manifest and writes one bounded atomic result, while the
GUI remains the only database writer.

`scripts/verify-call-recording.sh --fixtures` is deterministic and does not launch the app, capture media,
request TCC permissions, or download weights. Permission-sensitive qualification is deliberately separate:

```bash
ZBS_EYE_CALL_PHYSICAL_GATE=YES scripts/verify-call-recording.sh --physical-preflight
```

That command only verifies the installed stable signature and creates an ignored local checklist. The operator
then verifies real mic-triggered starts, Krisp relay and user exclusions, the 30-second save/delete lifecycle,
offline saving, mute/device/lock/`coreaudiod`/relaunch recovery, short mic-only and dual-track Calls, and the
60-minute and 120-minute synthetic Calls against `/Applications/ZBS Eye.app`. Personal audio/transcripts and
the local physical report are never committed.

## Capture coexistence release gate

Screen-capture changes also require the exact installed notarized candidate to pass the operator-driven gate
documented in [`docs/CAPTURE_COEXISTENCE.md`](docs/CAPTURE_COEXISTENCE.md). Its protocol self-test is safe in
ordinary development, but the physical nine-arm bracket must run from Terminal because Eye, ChatGPT, and
Chronicle must be genuinely absent in baseline arms:

```bash
bash scripts/verify-capture-coexistence.sh \
  --app "/Applications/ZBS Eye.app" \
  --data-root "/absolute/path/to/the/current/ZBS Eye data root" \
  --manifest "dist/ZBSEye-<version>-<build>-<sha>-notarized.manifest.json"
```

The listen-only shortcut observer never requests a new TCC permission. If the existing grant is unavailable,
Eye fails open and yields through the later screenshot-helper process signal; manual shortcut freshness remains
a required release check. Automated fixtures do not replace the physical shortcut matrix, lifecycle/recovery
matrix, 30-minute churn, or two-hour installed soak.

### Optional speaker diarization

The app pins FluidAudio `0.15.5` (commit `19600a485baa4998812e4654b70d2bab8f2c9949`) and the
`FluidInference/speaker-diarization-coreml` model revision
`1ed7a662fdc7109e36d822db793ee6eebdaf8594`. The exact 21-file, 21,599,417-byte manifest is verified before
use. It is not bundled or installed by default. Processing runs offline through `--diarization-job` in the
same signed executable; the GUI process remains the only database writer, and helper output contains timed
anonymous clusters rather than embeddings.

The physical qualification command is intentionally opt-in and requires an already verified local model
directory plus synthetic/public PCM. Aggregate results and limitations are in
[`docs/CALL_DIARIZATION_QUALIFICATION.md`](docs/CALL_DIARIZATION_QUALIFICATION.md); no private corpus is
committed.
