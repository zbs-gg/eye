# ZBSEye — сборка

Проект генерируется из `project.yml` через [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`ZBSEye.xcodeproj` в `.gitignore` — не коммитится).

## Требования
- macOS 15+ (разработка на 26 Tahoe), Xcode 26+, Swift 6.
- `brew install xcodegen`

## Сборка
```bash
xcodegen generate                 # сгенерировать ZBSEye.xcodeproj из project.yml
open ZBSEye.xcodeproj             # → Xcode → Cmd+R
# или из CLI:
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Debug build
```

## Архитектура (Фаза 2, в работе)
```
ZBSEyeApp/
  App/        ZBSEyeApp (@main), AppEnvironment (@Observable корень)
  State/      *Store.swift — @Observable @MainActor (Permissions, Recording, Server)
  Services/   Permissions/PermissionChecker (реальные TCC-пробы)
  Views/      Sidebar, Timeline, Automations, Connections, Settings, MenuBar, Components
  ZBSEye.entitlements  — Hardened Runtime БЕЗ App Sandbox
```
Swift 6 strict concurrency = `complete`. Deployment target macOS 15.0.

Дальше (по `workspace/PLAN.md`): FramePipelineActor (capture+encode+hash) · DB/FTS/retention ·
authenticated localhost REST · AX/OCR capture loop с telemetry · vector (sqlite-vec + shards) ·
Timeline/scrubber · Automations · audio/transcription.

Harness-инструменты (отдельные SPM-пакеты, не часть app): `harness/electron-ax-smoke`,
`harness/sqlite-vec-bench`, `harness/sck-burst-bench`.
