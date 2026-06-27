# ZBSEye — build

The project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`ZBSEye.xcodeproj` is in `.gitignore` — not committed).

## Requirements
- macOS 15+ (developed on 26 Tahoe), Xcode 26+, Swift 6.
- `brew install xcodegen`

## Build
```bash
xcodegen generate                 # generate ZBSEye.xcodeproj from project.yml
open ZBSEye.xcodeproj             # → Xcode → Cmd+R
# or from the CLI:
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Debug build
```

A one-shot build + sign check is in `scripts/verify.sh` (xcodegen → xcodebuild Debug).

## Architecture
```
ZBSEyeApp/
  App/        ZBSEyeApp (@main), AppEnvironment (@Observable root)
  Capture/    CaptureCoordinator, FramePipeline (capture+HEIC+phash), AXReader
  Audio/      AudioCoordinator, mic/system engines, VADSegmenter, TranscriptionService
  Data/       ZBSEyeDatabase, StorageLocation, StorageManager, BackupManager, RetentionManager, IngestService
  Search/     SearchService (FTS+vector RRF), EmbeddingService (e5), TimelineService, VectorBackfill
  Server/     ZBSEyeHTTPServer (FlyingFox REST, 127.0.0.1, Bearer), KeychainStore
  MCP/        ZBSEyeMCPServer (stdio)
  Automations/ HistoryImporter, DailySummaryService, ExportService, CartographerService
  State/      *Store.swift — @Observable @MainActor
  Views/      Sidebar, Timeline, Activities, Ask, Cartographer, Achievements, Settings, MenuBar, Components
  ZBSEye.entitlements  — Hardened Runtime WITHOUT App Sandbox
```
Swift 6 strict concurrency = `complete`. Deployment target macOS 15.0.

See [`AGENTS.md`](AGENTS.md) for the architecture map, invariants, and gotchas.
