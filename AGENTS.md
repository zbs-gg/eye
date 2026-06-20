# AGENTS.md — гид для агентов и ревьюверов

Этот файл — для AI-агентов и людей, которые впервые открывают репозиторий, чтобы понять/проверить/
доработать код. Читается за 5 минут и экономит часы. Build-детали — в [`BUILD.md`](BUILD.md).

> **Бренд продукта — «ZBS Eye».** Внутренний коднейм в коде — `ZBSEye`: Xcode-таргет/схема `ZBSEye`,
> типы `ZBSEyeDatabase`/`ZBSEyeHTTPServer`/…, бинарь `ZBS Eye.app`, подпись «ZBS Eye Dev». Это норма
> (бренд ≠ кодовое имя) — НЕ переименовывай идентификаторы. Снаружи (bundle id `gg.zbs.eye`, display
> name, пути данных `~/…/ZBS Eye`, тексты) — везде «ZBS Eye».

## Что это

**ZBS Eye** (коднейм `ZBSEye`) — нативный macOS-рекордер «вечной памяти»: непрерывно пишет, что происходит на компьютере
(экран + accessibility-текст/OCR + аудио с транскрипцией), индексирует и отдаёт через локальный REST
+ MCP. **100% локально, без облака, без аккаунта.** Лёгкая нативная альтернатива screenpipe (который
ушёл на подписку + облако).

- Swift 6 (strict concurrency = `complete`), SwiftUI, target macOS 15+.
- Хранилище: GRDB (`DatabasePool` + WAL) + FTS5 (external-content) + sqlite-vec (статически слинкован).
- Поиск: гибрид FTS + семантика (multilingual-e5-small, 384-dim) через RRF.
- ~9 300 строк Swift. Без App Sandbox (Hardened Runtime) — иначе SCK + cross-app AX + локальный сервер
  невозможны. Self-signed подпись «ZBS Eye Dev» (без платного Apple Developer аккаунта).

## Сборка и запуск

```bash
xcodegen generate                                 # project.yml → ZBSEye.xcodeproj (исходники — глоб папки ZBSEyeApp/)
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Debug build
bash scripts/make-signing-cert.sh                 # ОДИН раз: self-signed cert → стабильный TCC (см. грабли)
bash scripts/build-release.sh                     # Release + подпись + e5-модель в бандл + zip
```

CLI-режимы (один бинарь): `--mcp` (MCP stdio), `--import-screenpipe`, `--relocate <path>`,
`--backup-now`, `--backup-verify <file>`.

## Карта архитектуры (`ZBSEyeApp/`)

| Папка | Что |
|---|---|
| `App/` | `ZBSEyeMain` (@main, диспатч CLI/GUI), `ZBSEyeApp` (Scene + AppDelegate), `AppEnvironment` (владелец графа сервисов, `bootstrap()`) |
| `Capture/` | `CaptureCoordinator` (цикл захвата, режимы idle/active/burst), `FramePipeline` (capture+HEIC+phash, ОДИН actor), `AXReader` (accessibility-извлечение, dedicated thread, per-PID health) |
| `Audio/` | `AudioCoordinator`, mic/system engines, `VADSegmenter`, `TranscriptionService` (SFSpeech on-device) |
| `Data/` | `ZBSEyeDatabase` (pool + миграции), `StorageManager` (media), **`StorageLocation`** (единый резолвер пути — см. инварианты), `StorageRelocation` (перенос), `BackupManager` (iCloud), `RetentionManager`, `IngestService` (единственный writer) |
| `Search/` | `SearchService` (FTS+vector RRF), `EmbeddingService` (e5), `TimelineService`, `VectorBackfill` |
| `Server/` | `ZBSEyeHTTPServer` (FlyingFox REST, 127.0.0.1, Bearer), `KeychainStore`, DTO |
| `MCP/` | `ZBSEyeMCPServer` (stdio, проксирует в GUI-инстанс) |
| `Pipes/` | `ScreenpipeImporter` (импорт истории), `DailySummaryService`, `ExportService` |
| `State/` | `@MainActor @Observable` сторы (Recording/Permissions/Storage/Backup/…) |
| `Views/` | SwiftUI (Timeline, Settings, онбординг) |

## Инварианты (нарушишь — сломаешь)

1. **Один источник пути к данным — `StorageLocation`.** БД, media, port-файл, server.log, pipes — ВСЁ
   резолвится через `StorageLocation.dataRoot()/databaseURL()/mediaDirectory()/portURL()`. НЕ хардкодь
   `Application Support/ZBSEye`. Это нужно, чтобы relocate (перенос на внешний SSD) и вспомогательные
   процессы (`--mcp`, `--backup-now`) видели одно место. Исключения: iCloud-бэкап и пользовательский
   экспорт — намеренно отдельные пути.
2. **Один writer — `IngestService`.** Не-Sendable (`CVPixelBuffer`/`CMSampleBuffer`/`AXUIElement`/`VNRequest`)
   живут и умирают внутри одного actor; наружу — только Sendable.
3. **FTS5 external-content:** `snippet()`/`bm25()` считать в подзапросе ЧИСТО по FTS-таблице. Добавишь
   условие по joined-таблице (`c.ts BETWEEN …`) в тот же SELECT — SQLite теряет FTS-контекст
   («unable to use function snippet»). Паттерн `WITH hits AS (… FROM text_fts WHERE MATCH … LIMIT N)`.
4. **Localhost-only + auth на всё кроме `/health`.** Bearer-токен в Keychain. Никакого egress.
5. **Retention по умолчанию ВЕЧНО** (`RetentionPolicy.defaultDays = 0`). `prune(0)` = «вечно», НЕ
   «удалить всё старше 0 дней» (footgun-гвард в `RetentionManager.prune`).

## Грабли (на них уже наступили — не наступай снова)

- **e5 = mean-pooling, не CLS.** `swift-embeddings .encode()` возвращает CLS — для retrieval это ×3+
  хуже на cross-lingual. Берём mean.
- **Keychain — data-protection, НЕ legacy.** `KeychainStore` использует `kSecUseDataProtectionKeychain`.
  Legacy file-keychain ВЕШАЕТ main-thread на ACL-промпте при чтении токена, созданного другой подписью
  (после переустановки ре-подписанного app) → bootstrap зависает навечно.
- **Стабильный TCC = стабильная подпись.** Self-signed «ZBS Eye Dev» + установка в `/Applications`
  (не DerivedData). `designated requirement` пинит leaf-cert → права переживают ребилды. Ловушки:
  `bash set -u` ест первый байт многобайтового символа рядом с `«$VAR»` (фикс — `${VAR}`); p12-импорт
  требует системного `/usr/bin/openssl` (LibreSSL), не Homebrew OpenSSL 3.x; доверие в user-домене без
  sudo; SPM-зависимости при явной identity требуют `CODE_SIGN_STYLE=Manual`.
- **Живую SQLite НЕЛЬЗЯ в iCloud Drive** (WAL-рассинхрон + выгрузка файлов = corruption). В iCloud
  уезжает только сжатый снапшот через `pool.backup(to:)` (online backup, консистентно под WAL).
- **Перенос/бэкап живой базы — `pool.backup(to:)`, НЕ копия файла** (file cp на середине checkpoint =
  битая база). media — copy-not-move (старое место цело до verify+flip).
- **Захват на паузе во время relocate** (`pauseForMaintenance` + дренаж in-flight), иначе граничный
  кадр/аудио-сегмент осиротеет (вне backup-снапшота / вне копии media).
- **screenpipe AX-дерево часто пустое на Electron** — отсюда adaptive AX-first + OCR-fallback per-app,
  не «победили Electron». OCR — равноправный путь, не редкий fallback.

## Как ревьюить (где живёт риск)

1. **Data-loss** (главное): любой путь, где 50k+ кадров могут потеряться/осиротеть/разойтись. Смотри
   `StorageRelocation` (copy-not-move? verify ДО flip?), `BackupManager` (online backup консистентен?),
   `StorageLocation` (том недоступен → НЕ стартуем на legacy «с нуля», анти-split-brain), retention.
2. **Swift 6 concurrency:** actor-изоляция, Sendable на границах, `@unchecked Sendable` только в явных
   мостах, блокирующие C-вызовы (AX) — на dedicated thread, не в cooperative-пуле.
3. **Security:** auth на всё кроме `/health`, path-traversal в отдаче кадров/файлов (числовой id →
   lookup, граница media-директории), нет egress.
4. **Honest state:** UI не врёт (иконка записи, статусы прав, «занято»).

Проверка: `xcodebuild … build` зелёный. Тестов-таргета пока нет (NB для ревьювера — верификация была
live: REST-батарея, MCP, sqlite-сверка; см. историю коммитов с пометками «live»).

## Статус (что работает)

Работает и проверено вживую: захват экрана (HEIC + AX/OCR), аудио + транскрипция, гибрид-поиск
(cross-lingual), таймлайн, REST + MCP, импорт из screenpipe, retention, **relocatable хранилище**,
**iCloud-бэкап** (сжатый, keep-N, на выходе), трекинг размера, daily-summary pipe, экспорт.

Отложено: тест-таргет (XCTest); source_id для мультимонитор-дедупа (~0.15% кадров, задокументировано
в `ScreenpipeImporter`); нотаризация (нет платного аккаунта — установка через «Open Anyway»).
