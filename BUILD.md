# Slishu — сборка

Проект генерируется из `project.yml` через [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`Slishu.xcodeproj` в `.gitignore` — не коммитится).

## Требования
- macOS 15+ (разработка на 26 Tahoe), Xcode 26+, Swift 6.
- `brew install xcodegen`

## Сборка
```bash
xcodegen generate                 # сгенерировать Slishu.xcodeproj из project.yml
open Slishu.xcodeproj             # → Xcode → Cmd+R
# или из CLI:
xcodebuild -project Slishu.xcodeproj -scheme Slishu -configuration Debug build
```

## Архитектура (Фаза 2, в работе)
```
SlishuApp/
  App/        SlishuApp (@main), AppEnvironment (@Observable корень)
  State/      *Store.swift — @Observable @MainActor (Permissions, Recording, Server)
  Services/   Permissions/PermissionChecker (реальные TCC-пробы)
  Views/      Sidebar, Timeline, Pipes, Connections, Settings, MenuBar, Components
  Slishu.entitlements  — Hardened Runtime БЕЗ App Sandbox
```
Swift 6 strict concurrency = `complete`. Deployment target macOS 15.0.

Дальше (по `workspace/PLAN.md`): FramePipelineActor (capture+encode+hash) · DB/FTS/retention ·
authenticated localhost REST · AX/OCR capture loop с telemetry · vector (sqlite-vec + shards) ·
Timeline/scrubber · Pipes · audio/transcription.

Harness-инструменты (отдельные SPM-пакеты, не часть app): `harness/electron-ax-smoke`,
`harness/sqlite-vec-bench`, `harness/sck-burst-bench`.
