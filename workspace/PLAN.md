# Slishu — чистая пересборка нативного macOS-рекордера (план)

## Context

**Что это.** Slishu — лёгкий локальный «вечная память»-рекордер для macOS: история всего, что
происходит на компе (экран + accessibility-текст + аудио), индексируется и отдаётся в LAM/LLM
через REST API и MCP. 100% локально, приватно. Цель — быть **легче и быстрее screenpipe** на Mac,
с нативным premium-интерфейсом.

**Почему пересобираем.** Предыдущую версию собрал Gemini-агент. Ядро (захват, БД, семантика,
REST, MCP) наполовину рабочее, но: Pipes/Connections — **чистые заглушки** (mock-данные, пустые
кнопки — ровно то, на что жаловался Никита); приложение **зависает** (рекурсивный обход
`AXUIElement` без таймаута на тяжёлых/Electron-деревьях); есть race conditions (состояние захвата,
выбор порта), возможные утечки `CVPixelBuffer`/`AVAudioEngine`, `try!` в MCP. Решение Никиты —
**чистая переписка с нуля** (архитектуру строим заново, проверенные низкоуровневые куски можно
переносить).

**Поправленная посылка (важно, влияет на дизайн).** Исходно считалось: «screenpipe на OCR, а
Slishu на accessibility — вот дифференциатор». По факту **screenpipe тоже accessibility-first**
(их доки: accessibility tree primary, OCR fallback; event-driven, поэтому 5–10% CPU). НО на
**Electron-приложениях** (VS Code, Obsidian, Slack, Telegram, Chrome — половина рабочего дня) у
screenpipe AX-дерево приходит пустым (Chromium строит его лениво, screenpipe не ставит флаги
`AXManualAccessibility`/`AXEnhancedUserInterface`) → он валится в дорогой OCR → ~147% CPU когда
Obsidian в фокусе (их issue #3002). **Настоящий дифференциатор Slishu:** (1) заставить
accessibility реально работать, включая Electron; (2) убрать Tauri/WebKit-обёртку (нативный
SwiftUI); (3) **event-driven вместо polling**. Тогда он честно легче, а не на бумаге.

**Решения Никиты по развилкам.** Чистая переписка с нуля · свой чистый REST API + MCP (без
legacy-контракта screenpipe) · транскрипция MLX Whisper turbo по умолчанию + сменный бэкенд ·
**сначала прогнать архитектуру через ChatGPT 5.5 Pro** (бандл для Pro).

**Целевая платформа:** Swift 6 (strict concurrency `complete`), SwiftUI, deployment target
macOS 15.0 (Observation + native async Vision), пользователь на macOS 26 Tahoe (Liquid Glass).

---

## Шаг 0 — Pro-ревью архитектуры (ДО написания кода)

Этот план = архитектура, которую ревьюит Pro. Порядок: одобряешь план → я гоню бандл (ниже,
Приложение A) через ChatGPT 5.5 Pro (skill `check-with-pro`, Playwright, без доп. трат сверх
подписки) → вношу правки от Pro в этот план → начинаю Фазу 1. Бандл уже собран в Приложении A.

---

## Целевая архитектура (синтез)

Единый принцип: **акторы Swift 6, value-типы `Sendable` на границах, один логический writer**.
`CVPixelBuffer`/`AXUIElement`/`CMSampleBuffer`/`VNRequest` никогда не пересекают границу актора —
потребляются на месте внутри `autoreleasepool`.

### A. Ядро захвата (event-driven) — заменяет `SlishuCapture`

- **CaptureCoordinator (@MainActor)** — владелец жизненного цикла, дебаунс, single-flight.
  Источники событий:
  - `WorkspaceEventSource` — `NSWorkspace.didActivateApplication` (смена фронт-аппа; здесь же
    ставим Electron-флаги и пересоздаём `AXObserver`), `screensDidSleep/Wake`,
    `sessionDidResignActive/BecomeActive` (lock → suspend).
  - `AXEventSource` — `AXObserver` на PID фронт-аппа: `kAXFocusedWindowChanged`,
    `kAXFocusedUIElementChanged`, `kAXValueChanged` (жёстко коалесится),
    `kAXTitleChanged`/`kAXMainWindowChanged`.
  - `InputEventSource` — listen-only `CGEvent.tapCreate` (keyDown/mouseUp/scroll) → только сбрасывает
    таймеры (typing-pause, scroll-settled), контент НЕ читает; graceful degrade на
    `NSEvent.addGlobalMonitorForEvents` если нет Input Monitoring-гранта.
  - Дебаунс 250 мс (0 для appActivated), rate-limit valueChanged ≥1.5 c, single-flight на дисплей.
- **FrameCapturer (actor)** — **`SCScreenshotManager.captureSampleBuffer` (on-demand single frame,
  macOS 14+), НЕ persistent `SCStream`**. В idle нет событий → нет захвата → CPU ≈ 0. `SCShareableContent`
  кешируется, рефреш по `didChangeScreenParameters`.
- **AXReaderActor (actor)** — обход БЕЗ зависаний: **wall-clock дедлайн 120 мс** (главный фикс) +
  `AXUIElementSetMessagingTimeout` 100 мс (второй фикс — синхронный IPC к зависшему аппу) +
  итеративный обход (стек, не рекурсия) + depth/node-cap + отмена по смене `generation`.
  **Electron-coercion:** на фронт-аппе ставим `AXManualAccessibility=true` И
  `AXEnhancedUserInterface=true` (оба — версия Chromium решает, какой нужен), ретрай при пустом
  дереве (400/1200 мс), per-PID кеш здоровья (`healthy`/`empty`/`ocrOnly`). Достаём `browser_url`
  из `AXWebArea`/omnibox для Safari/Chrome.
- **OCRFallbackActor (actor)** — Vision только когда AX пуст/недостаточен/недоступен (remote desktop,
  игры, canvas). Native async `RecognizeTextRequest` (macOS 15+) / `VNRecognizeTextRequest`,
  ru+en, ANE, `autoreleasepool`, отменяемый, **даунскейл через Metal перед OCR**, gate по dedup-хешу.
- **FrameEncoderActor (actor)** — единственный переиспользуемый `CIContext(mtlDevice:)`, HEIC через
  аппаратный кодек, **дедуп perceptual-hash (aHash/dHash 64-bit)** — хранит `UInt64`, НЕ
  предыдущий буфер (фикс back-pressure/утечки).
- **Smart pause** — emergent: нет событий = нет захвата. Явно: teardown источников на lock/sleep;
  idle = просто решедул fallback-тика; fullscreen+AX-empty → только fallback-тик.
- Контракт наружу — `ScreenCaptureRecord`/`AudioCaptureRecord` (Sendable) → `IngestService`.
  Захват НЕ трогает SQL/FTS/embeddings напрямую.

### B. Слой данных + поиск — заменяет `SlishuDatabase`/`SlishuSemanticSearch`

- **Схема GRDB v1:** `apps`, `screen_captures` (ts epoch-ms, app_id, window_title, browser_url,
  monitor_id, relative_path, w/h, bytes), `text_blocks` (capture_id, **source `ax`|`ocr`**, text,
  confidence, bbox?), `audio_captures`, `transcriptions` (сегменты с таймкодами, language, engine),
  `embeddings`. `DatabasePool` + WAL + PRAGMA (synchronous=NORMAL, mmap, busy_timeout, foreign_keys).
- **FTS5 external-content** (`content='text_blocks'`) с триггерами ai/ad/au — **без декартова
  произведения** (старый баг). Поиск дедупит `GROUP BY capture_id`, не `JOIN`-ом всех элементов.
  Альтернатива для простоты ранжирования — денормализованная `fts_text` на кадре.
- **Вектор: sqlite-vec (vec0)** загружается в GRDB через `sqlite3_auto_extension` в
  `prepareDatabase` — масштаб «месяцы 24/7» (сотни тыс.–млн строк) brute-force C+SIMD за десятки мс,
  фильтры по времени/app в том же SQL. **Страховка:** протокол `VectorIndex` с
  `AccelerateBruteForceIndex` (vDSP) если расширение не соберётся — проверить загрузку на целевом
  toolchain **рано** (главный техриск).
- **Эмбеддинги:** дефолт **multilingual-e5-small (384-dim) через MLX** (тот же рантайм, что Whisper;
  cross-lingual ru→en), сменный протокол `EmbeddingBackend` с `NLEmbedding` (нулевой вес) и bge-m3
  опциями. Все вектора L2-нормализованы. Модель фиксируется в `embeddings.model`+`dim`.
- **Гибридный поиск:** FTS (bm25) + semantic (vec) → **Reciprocal Rank Fusion** (k≈60, без калибровки
  шкал). Режимы `fts|semantic|hybrid` (default hybrid). Фильтры app/window/time/source.
- **IngestService (actor)** — ЕДИНСТВЕННЫЙ writer: пишет файл + `screen_captures`+`text_blocks` (триггеры
  наполняют FTS) + ставит embed; для аудио → в `TranscriptionService`. Убирает `Task.detached`-гонки.
- **RetentionManager (actor)** — прунинг по дням И размеру (GB), каскад + явный `DELETE` из vec0,
  orphan-sweep, FTS `optimize` + `wal_checkpoint(TRUNCATE)`, батчами. Релокация хранилища через
  **security-scoped bookmark** (не plain string — иначе сломается).

### C. REST + MCP — заменяет `SlishuServer`/`SlishuMCP`

- **Сервер: остаёмся на FlyingFox** (уже собран, лёгкий, async, SSE). Чинит: **Codable DTO вместо
  ручной сборки JSON-строк**; **динамический порт корректно** (различать `EADDRINUSE` от прочих
  ошибок; `self.server` ставить ПОСЛЕ успешного `start()`; дефолт **не 8080** — `8088`/`11435` или
  `port=0`; писать активный порт в `~/Library/Application Support/Slishu/port`).
- **Эндпоинты `/v1`:** `/health`, `/search` (q, mode, app, window, source, from/to, limit),
  `/timeline` (бакеты для скруббера), `/frames/{id}` (+`?thumb=1`, числовой id → lookup, не путь из
  URL), `/media/{filename}` (Range-стриминг + traversal-hardening regex+resolvedSymlinks+pathComponents),
  `/frames/{id}/context`, `/capture/toggle` (auth), `/settings/storage`, `/stats`. Bind только
  `127.0.0.1`, опциональный `Bearer` токен на мутации.
- **MCP: официальный `modelcontextprotocol/swift-sdk`** (запинить ревизию, не `branch: main`),
  **stdio (`Slishu --mcp` для Claude Desktop/Cursor) + SSE на `/mcp`**. Tools: `search_history`,
  `get_timeline`, `get_context_at`, `get_status`, `toggle_recording` — тонкие обёртки над общим
  `SearchService`/`TimelineService`. Никаких `try!` — ошибки → MCP error result.

### D. Транскрипция — заменяет `SlishuTranscriptionManager`

- **Протокол `TranscriptionBackend`** (async, отменяемый через `withTaskCancellationHandler`, прогресс),
  сегменты с таймкодами/языком.
- **`MLXWhisperBackend` (default)** — MLX Swift, `whisper-large-v3-turbo`, **warmUp один раз** (не
  перезагружать модель на чанк), decode m4a→PCM 16k mono, чанки 30 c, язык auto/ru/en. Модель не в
  бандле — качается по требованию (~1.5 ГБ).
- **Сменные:** `SFSpeechBackend` (нулевой вес, для слабых машин), `WhisperCppBackend`, `CloudBackend`
  (opt-in, помечен — нарушает «локально»). **`TranscriptionService (actor)`** — очередь, прогресс,
  смена движка из настроек, запись в БД (триггер наполняет `transcription_fts`).

### E. UI / оболочка — заменяет `ContentView`/`SlishuApp` (1531-строчный монолит → декомпозиция)

- **App shell:** `@main` с `Window(id:"main")` (не WindowGroup) + `MenuBarExtra(.window)` (живой
  glass-popover: toggle, счётчики, активный порт, варнинги прав, выход). Корневое состояние — один
  `@Observable AppEnvironment` через `.environment` (убираем 14-биндинговый антипаттерн). Счётчики —
  через **GRDB `ValueObservation`**, не `Timer.publish(1s)`. `LSUIElement=NO` по умолчанию + тумблер
  «скрывать из Dock» (runtime `setActivationPolicy`).
- **Онбординг прав:** `PermissionChecker` — чистые пробы: Screen (`CGPreflightScreenCaptureAccess`),
  Accessibility (`AXIsProcessTrusted`), Mic (`AVCaptureDevice.authorizationStatus`), Speech.
  Пошаговый flow + диагностическая панель в Settings (общий `PermissionRow`). **Правильная обработка
  -3801:** статус `.needsRestart` (право выдано, но `SCStream` надо пересоздать) → кнопки
  «Перезапустить захват»/«Перезапустить Slishu». Поллинг статусов 1.5 c (у TCC нет KVO).
- **Timeline + time-travel scrubber (keystone):** `TimelineStore` — **ось = время, не индекс массива**
  (старый грузил всю историю в массив — не масштабируется). `Canvas`-density-strip (высота =
  активность, цвет = доминирующий апп), draggable playhead с **debounced seek 60–80 мс** (thumbnail
  сразу, HEIC+OCR асинхронно), zoom День/Час/10мин, transport play/pause + 1×/2×/4× + step, crossfade
  между кадрами. Spotlight-поиск сверху **унифицирован со скруббером** (клик по хиту → playhead на
  его время), фильтры app/time/source, тумблер Полнотекст/Смысл.
- **Pipes — РЕАЛЬНЫЙ backend.** Модель: **декларативные scheduled local-LLM агенты (markdown+YAML +
  cron)**, как у screenpipe (НЕ JavaScriptCore в v1 — оставить `kind:script` как точку расширения).
  Пайп = папка `Pipes/<id>/` с `pipe.yaml`+`pipe.md`. `PipeScheduler` (cron, catch-up на wake) →
  `PipeRuntime.run` (resolve inputs из DB/REST → context → LLM Connection → output Connection →
  `pipe_runs` лог). Capability-list прав в yaml + явное согласие при установке. UI: грид с реальным
  toggle/статусом/nextRun, **рабочая «Настроить»** (schema-driven форма из `config:`), «Запустить
  сейчас», live-лог. 3 готовых пайпа (саммари дня → Obsidian; поиск по встречам → Notion/Slack;
  экспорт истории → файл). Миграция `v4_pipes` (`pipes`, `pipe_runs`).
- **Connections — РЕАЛЬНЫЙ backend.** Протокол `Connector` (test/write/query). Клиенты: Obsidian
  (vault bookmark), Ollama/MLX (localhost), Slack (webhook), Notion (internal token), File.
  **Секреты — Keychain (`kSecClassGenericPassword`, AfterFirstUnlock), НЕ UserDefaults** (явное
  требование Никиты). Auth v1 = api-key/token/webhook (OAuth позже за тем же enum). UI: реальный
  статус здоровья + **рабочая «Проверить подключение»** (`Connector.test()`), `SecureField`. Миграция
  `v5_connections` (только не-секретный конфиг). **Pipes зависят от Connections** — делать Connections
  раньше.
- **Settings:** Хранилище (путь+NSOpenPanel+bookmark, размер на диске, retention дни/GB) ·
  Транскрипция (движок MLX/SF/whisper.cpp) · Сервер (**показ реального активного порта**, base URL,
  рестарт) · Приватность (опциональная **пауза по приложению** — НЕ блэклист по умолчанию, Никита
  пишет всё) · Запуск при логине (`SMAppService.mainApp`) · О приложении (AppIcon из workspace).
- **Упаковка:** XcodeGen `project.yml` — deployment 15.0, Swift 6 `complete`, **Hardened Runtime БЕЗ
  App Sandbox** (SCK full-display + cross-app AX + локальный сервер + внешнее хранилище несовместимы с
  sandbox; так же shipping у Rewind/screenpipe-класса). Entitlements минимальные (audio-input,
  apple-events опц., allow-jit/disable-library-validation для MLX). Usage strings (+Speech). Подпись
  Developer ID + **нотаризация** (`notarytool`+`stapler`), DMG. AppIcon `.appiconset` из
  `workspace/slishu_isolated_icon_*.png` (изолированная сфера на белом — готовый источник 1024²).

---

## Целевая структура файлов

Чистая переписка с группировкой по папкам (вместо плоского `SlishuApp/*.swift`):
```
SlishuApp/
  App/         SlishuApp.swift, AppEnvironment.swift, AppLifecycle.swift
  Capture/     CaptureCoordinator, FrameCapturer, AXReaderActor, OCRFallbackActor,
               FrameEncoderActor, EventSources/*, CaptureConfig, CaptureRecord
  Data/        SlishuDatabase, Models/*, IngestService, RetentionManager, StorageManager,
               Vector/{VectorIndex,SqliteVecIndex,AccelerateBruteForceIndex}, Embedding/*
  Search/      SearchService, TimelineService
  Transcription/ TranscriptionBackend, MLXWhisperBackend, SFSpeechBackend, TranscriptionService
  Server/      SlishuHTTPServer, SlishuAPIDTO, Routes/*
  MCP/         SlishuMCPServer, Tools/*
  State/       *Store.swift (@Observable)
  Views/       Sidebar, Timeline, Pipes, Connections, Settings, Onboarding, MenuBar, Components
  Services/    Pipes/{PipeEngine,PipeScheduler,PipeRuntime}, Connections/ConnectorClients/*,
               Keychain/KeychainStore, Permissions/PermissionChecker
  Resources/   Assets.xcassets/AppIcon.appiconset, BundledPipes/
project.yml, Slishu.entitlements
```
Старые файлы из `workspace/` (отчёты, иконки) — оставить как есть, не трогать.

---

## Порядок реализации (фазы)

0. **Pro-ревью** (Приложение A) → правки в план.
1. **Каркас + БД-фундамент:** `project.yml` (Swift6/macOS15/entitlements), схема GRDB v1 + миграции
   (FTS-триггеры без декартова, убрать `eraseDatabaseOnSchemaChange`), **sqlite-vec загрузка** +
   `VectorIndex` с Accelerate-fallback (проверить рано!), `IngestService`, app-shell skeleton
   (`AppEnvironment`+stores+`NavigationSplitView`+MenuBar) поверх заглушек сервисов.
2. **Захват event-driven:** CaptureCoordinator + акторы, Electron-флаги, AX-таймауты, dedup,
   smart-pause. → пишет через `IngestService`. Профилировать CPU/RAM в idle и на Electron.
3. **Поиск:** `EmbeddingBackend` (старт NLEmbedding → MLX e5), `SearchService` (FTS+vec+RRF), DTO.
4. **REST `/v1`:** фикс порта, все эндпоинты, traversal-hardening, реальный порт в UI.
5. **Права + онбординг:** `PermissionChecker`/`PermissionsStore`, flow, -3801 → needsRestart.
6. **Timeline + scrubber:** `TimelineStore` (ось-время), `ScrubberView`, унифицированный Spotlight.
7. **Транскрипция:** `TranscriptionBackend` + `SFSpeechBackend` → `MLXWhisperBackend` (default),
   `TranscriptionService`, сменность движка в Settings.
8. **Connections:** `KeychainStore`, `Connector` + 5 клиентов, `v5`, UI + test.
9. **Pipes:** формат, `PipeEngine/Scheduler/Runtime`, `v4`, UI, 3 готовых пайпа.
10. **MCP:** официальный SDK, stdio (`--mcp`) + SSE, 5 tools, port-файл.
11. **Settings glue + RetentionManager** (прунинг/размер/bookmark/login).
12. **Упаковка:** entitlements, AppIcon, подпись + нотаризация, DMG.

После каждой фазы: `xcodebuild` зелёный + `post-commit-verifier` на нетривиальных коммитах
(правило harness). Бранч не `main`.

---

## Verification (end-to-end)

- **Сборка:** `xcodebuild -scheme Slishu build` зелёный после каждой фазы; финально — запуск `.app`.
- **Захват не виснет:** открыть Obsidian/VS Code/Slack в фокусе → подтвердить, что текст идёт из AX
  (`text_blocks.source='ax'`), а НЕ OCR; CPU в idle ≈ 0, на Electron — единицы %, не 147%.
  Instruments: нет роста RAM за час (нет утечки `CVPixelBuffer`/Vision/AVAudioEngine).
- **Права:** свежий запуск → онбординг проводит через Screen/Accessibility/Mic; искусственно отозвать
  Screen Recording → увидеть `.needsRestart` и рабочую кнопку перезапуска (нет вечного -3801).
- **Порт:** занять 8088 → сервер берёт следующий и показывает реальный порт в UI и `/health`.
- **Поиск:** ru-запрос по en-контенту («ошибки компиляции» → экран «build failed») находит через
  semantic; FTS находит точные строки; hybrid ранжирует. `curl /v1/search`.
- **Timeline:** скруббер плавно тянется по дню, кадр+текст+app/url подгружаются, play/pause идёт по
  времени (idle-промежутки проматываются).
- **Pipes:** «Запустить сейчас» на «Саммари дня» → реальная запись в Obsidian-vault через Connection;
  лог в `pipe_runs`.
- **Connections:** добавить Slack webhook → «Проверить» шлёт тестовое сообщение; токен в Keychain, не
  в UserDefaults (проверить `defaults read`/Keychain Access).
- **MCP:** подключить `Slishu --mcp` в Claude Desktop → `search_history`/`get_context_at` отвечают.
- **Прунинг:** выставить лимит → старые кадры+строки+файлы+вектора удаляются каскадно, orphan-sweep
  чистит висячие файлы.

---

## Главные риски

1. **sqlite-vec под Swift 6 toolchain** — проверить загрузку расширения в Фазе 1; держать
   Accelerate-fallback. 2. **MLX Whisper** — модель в actor, warmUp один раз, корректная отмена.
3. **Electron AX-флаги** — могут дать version-drift; кешировать per-PID health, OCR-fallback честный.
4. **AX messaging-timeout** — wall-clock дедлайн 120 мс это HARD-стоп, проверять первым в каждом узле.
5. **Hardened-runtime/нотаризация** — без sandbox; MAS отпадает (ожидаемо). 6. **Security-scoped
   bookmark** обязателен для внешнего хранилища. 7. **Swift 6 strict concurrency** с не-Sendable
   `CVPixelBuffer`/`AXUIElement` — строго внутри одного актора, узкие `@unchecked Sendable`-обёртки
   только в точке потребления.

---

## Приложение A — бандл для ChatGPT 5.5 Pro (Шаг 0)

Промпт, который пойдёт в Pro (вместе с этим планом как контекст):

> Я строю нативное macOS-приложение (Swift 6, SwiftUI, target 15+) — локальный «вечная
> память»-рекордер экрана+accessibility-текста+аудио, индексация + выдача в LLM через REST+MCP. Цель —
> легче/быстрее screenpipe (Rust+Tauri). Ниже моя целевая архитектура (event-driven захват на
> акторах, accessibility-first с Electron-coercion через AXManualAccessibility/AXEnhancedUserInterface,
> SCScreenshotManager on-demand вместо SCStream, GRDB+FTS5 external-content + sqlite-vec, MLX Whisper
> turbo, FlyingFox REST `/v1`, официальный MCP Swift SDK stdio+SSE, hardened-runtime без sandbox).
> Прежде чем я начну писать код, стресс-тесть архитектуру:
> 1. **Event-driven захват:** `SCScreenshotManager.captureSampleBuffer` on-demand vs persistent
>    `SCStream` — где подводные камни (cold-start latency, TCC, пропуск контента между событиями)?
>    Достаточно ли AX-нотификаций+input-tap, или нужен лёгкий fallback-поллинг?
> 2. **Electron accessibility:** реально ли `AXManualAccessibility`+`AXEnhancedUserInterface` дают
>    непустое дерево в актуальных VS Code/Slack/Obsidian/Telegram? Тайминги ленивой инициализации,
>    PID renderer vs main, риски на новых Chromium. Это ключевой дифференциатор — он держится?
> 3. **AX без зависаний:** wall-clock дедлайн 120 мс + `AXUIElementSetMessagingTimeout` 100 мс +
>    итеративный обход — закрывает ли это класс зависаний на тяжёлых деревьях? Что упускаю?
> 4. **Вектор-поиск на масштабе:** sqlite-vec (vec0, brute-force) для «месяцы 24/7» (1–3M строк) —
>    хватит ли латентности, или сразу нужен HNSW/другой индекс? Эмбеддинги multilingual-e5-small via
>    MLX vs NLEmbedding — оправдан ли вес?
> 5. **Swift 6 strict concurrency:** модель акторов с не-Sendable `CVPixelBuffer`/`AXUIElement`/
>    `CMSampleBuffer` — где `@unchecked Sendable` укусит, как безопаснее?
> 6. **Транскрипция MLX Whisper turbo:** резидентность модели, отмена, память при 24/7 — грабли?
> 7. **Hardened runtime без App Sandbox** для SCK+AX+локального сервера+внешнего хранилища +
>    нотаризация — правильный ли это путь дистрибуции, что сломается?
> 8. **Pipes:** декларативные cron+markdown+local-LLM агенты vs JavaScriptCore — что выбрать для v1?
> Назови конкретные грабли, неверные допущения и что бы ты изменил ДО написания кода. Не хвали — ищи,
> где архитектура треснет на проде.

Файлы для прикрепления к Pro: этот план + три полных дизайн-документа (ядро захвата / данные-API-MCP /
UI-плагины) из Plan-агентов (сохраню их в `workspace/` при старте Фазы 0).

---

## Заметка на после плана
- Сохранить project-memory о Slishu (видение, развилки, архитектурные решения) — сейчас нельзя
  (plan mode read-only).
