# ZBSEye — build

The project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`ZBSEye.xcodeproj` is in `.gitignore`). The one intentional tracked exception is its SwiftPM
`Package.resolved`: XcodeGen preserves it, and every scripted build requires those exact package revisions.

## Requirements
- macOS 15+ (developed on 26 Tahoe), Xcode 26+, Swift 6.
- `brew install xcodegen`
- The built-in local model is not needed to compile or run ordinary tests. Real-model qualification is
  opt-in and uses an already downloaded, manifest-verified directory; see [`docs/LOCAL_AI.md`](docs/LOCAL_AI.md).
- Explicit call recording also works without a speech model. The optional Whisper model is downloaded and
  verified only after the person asks for it; fixture tests never download it.

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
```

## Architecture
```
ZBSEyeApp/
  App/        ZBSEyeApp (@main), AppEnvironment (@Observable root)
  Capture/    CaptureCoordinator, FramePipeline (capture+HEIC+phash), AXReader
  Audio/      AudioCoordinator, mic/system engines, VADSegmenter, TranscriptionService
  Calls/      CallCoordinator, durable dual-source spool, Bookmark/final jobs, Whisper helper, evidence read model
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
then runs the short, 60-minute, and 120-minute synthetic calls against `/Applications/ZBS Eye.app`; personal
audio/transcripts and the local physical report are never committed.
