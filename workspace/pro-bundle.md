# Slishu — бандл для архитектурного ревью (ChatGPT 5.5 Pro)

Этот файл самодостаточен: промпт + полный план + три дизайн-документа.
Можно прикрепить целиком как один файл или вставить текстом.

═══════════════════════════════════════════════════════════════════
## ПРОМПT (вставить как сообщение)
═══════════════════════════════════════════════════════════════════

Ты — principal-инженер macOS/Swift с опытом продакшн-приложений уровня Rewind/screenpipe (системный захват экрана 24/7, Accessibility API, ScreenCaptureKit, Core ML/MLX, локальные БД, нотаризация). Я НЕ хочу похвалы. Я хочу, чтобы ты нашёл, где архитектура треснет на проде, ДО того как я напишу хоть строку кода.

КОНТЕКСТ
Я строю нативное macOS-приложение Slishu (Swift 6, strict concurrency = complete, SwiftUI, deployment target macOS 15, я сам на macOS 26 Tahoe). Это лёгкий локальный «вечная память»-рекордер: история всего на компе (экран + accessibility-текст + аудио), индексация и выдача в LLM/LAM через свой REST API и MCP. 100% локально и приватно. Цель — быть честно легче и быстрее screenpipe (Rust + Tauri) именно на Mac, не на бумаге.

Поправленная посылка, на которой стоит дизайн: screenpipe тоже accessibility-first, НО на Electron-приложениях (VS Code, Obsidian, Slack, Telegram, Chrome) у него accessibility tree приходит пустым (Chromium строит его лениво, screenpipe не ставит флаги AXManualAccessibility/AXEnhancedUserInterface) → он валится в дорогой OCR → ~147% CPU когда Obsidian в фокусе (их issue #3002). Мой главный дифференциатор — заставить accessibility реально работать, включая Electron, + event-driven вместо polling, + нативный SwiftUI без Tauri/WebKit.

К этому промпту приложены: полный план (PLAN) и три детальных дизайн-документа — (1) ядро захвата, (2) данные/поиск/REST/MCP/транскрипция, (3) UI/права/плагины/упаковка. Прочитай их целиком, прежде чем отвечать.

ЗАДАЧА — стресс-тесть архитектуру по пунктам. По каждому: где конкретно сломается на проде, какие мои допущения неверны, что бы ты изменил ДО написания кода. Называй конкретные API, версии, тайминги, граничные случаи — не общие слова.

1. EVENT-DRIVEN ЗАХВАТ. Я выбрал SCScreenshotManager.captureSampleBuffer (on-demand single frame) вместо persistent SCStream, чтобы в idle было ноль работы. Подводные камни: cold-start latency первого кадра, TCC-поведение, пропуск контента МЕЖДУ событиями (анимации, входящие сообщения, видео). Достаточно ли AX-нотификаций (focused-window/value/title changed) + listen-only input-tap (typing-pause/click/scroll), или нужен лёгкий fallback-поллинг? На какой частоте? Где SCScreenshotManager хуже SCStream по энергии/латентности при частых событиях?

2. ELECTRON ACCESSIBILITY (ключевое — на этом стоит весь продукт). Реально ли установка AXManualAccessibility=true И AXEnhancedUserInterface=true на main-app AXUIElement даёт непустое дерево в АКТУАЛЬНЫХ (2025–2026) VS Code / Slack / Obsidian / Telegram-desktop / Chrome? Какие реальные тайминги ленивой инициализации дерева после установки флага (мои ретраи 400/1200мс — адекватны)? Проблема renderer-PID vs main-PID — как её правильно решать? Есть ли версии Chromium, где флаги переименованы/не работают? Какие side-effects (CPU самого Electron, поведение под VoiceOver-режимом, конфликты с реальным VoiceOver пользователя)? Этот дифференциатор держится или это мираж?

3. AX БЕЗ ЗАВИСАНИЙ. План: wall-clock дедлайн 120мс на обход + AXUIElementSetMessagingTimeout 100мс на app element + итеративный обход (стек, не рекурсия) + depth/node cap + отмена по generation. Закрывает ли это класс зависаний на тяжёлых деревьях (Chrome с сотней вкладок, IDE)? Что упускаю? Достаточно ли messaging-timeout, или synchronous IPC всё равно может залипнуть мимо него? Как читать большое дерево, не теряя важный текст из-за бюджета?

4. ВЕКТОР-ПОИСК НА МАСШТАБЕ. sqlite-vec (vec0, brute-force KNN) для «месяцы 24/7» = 1–3M строк эмбеддингов. Хватит ли латентности (целюсь в десятки мс), или нужен сразу HNSW/другой индекс? Реальные цифры brute-force на 1–3M × 384-dim на Apple Silicon? Загрузка sqlite-vec как loadable extension в GRDB под Swift 6 toolchain — какие грабли (SQLITE_ALLOW_LOAD_EXTENSION, статическая линковка sqlite3_vec_init, конфликт с системным SQLite)? Эмбеддинги multilingual-e5-small (384) via MLX vs системный NLEmbedding — оправдан ли вес ~120МБ ради cross-lingual ru→en retrieval?

5. SWIFT 6 STRICT CONCURRENCY. Модель: акторы (CaptureCoordinator @MainActor, FrameCapturer/AXReader/OCR/Encoder/Ingest/Server/MCP/Transcription — actor), value-DTO Sendable на границах, не-Sendable CVPixelBuffer/CMSampleBuffer/AXUIElement/VNRequest никогда не пересекают границу актора, обрабатываются в @unchecked Sendable обёртках только в точке потребления внутри autoreleasepool. Где этот подход меня укусит на практике? Где @unchecked Sendable — мина? Есть ли более безопасный паттерн для передачи кадра capture→encode без копии и без гонок?

6. ТРАНСКРИПЦИЯ MLX WHISPER TURBO. MLXWhisperBackend (whisper-large-v3-turbo) с резидентной моделью в actor (warmUp один раз, не перезагружать на чанк), чанки 30с, отмена через withTaskCancellationHandler. Грабли при 24/7: память GPU (модель резидентна постоянно vs выгружать в idle?), отмена в середине MLX-инференса, decode m4a→PCM 16k, деградация на длинных тишинах/музыке. Сменный бэкенд (MLX default, SFSpeechRecognizer/whisper.cpp/cloud) — разумно? Что выбрать дефолтом реально?

7. HARDENED RUNTIME БЕЗ APP SANDBOX. Для SCK (full-display) + cross-app Accessibility + локального TCP-сервера (FlyingFox) + хранилища на внешнем SSD я планирую Hardened Runtime ON, App Sandbox OFF, Developer ID + нотаризация (notarytool + stapler). Правильный ли это путь дистрибуции? Что сломается при нотаризации (entitlements allow-jit/disable-library-validation для MLX, audio-input, apple-events)? Подводные камни security-scoped bookmarks для внешнего хранилища без sandbox? Будет ли Gatekeeper/нотаризация ругаться на MLX-dylib/Metal?

8. PIPES (плагины). Выбор для v1: декларативные scheduled-агенты (markdown+YAML + cron, дёргают локальный REST + local LLM Ollama/MLX, пишут в коннекторы) ПРОТИВ JavaScriptCore-плагинов. Я склоняюсь к декларативным. Это правильно для расширяемости и безопасности, или я загоняю себя в угол и через месяц захочу настоящий код-рантайм? Как спроектировать формат, чтобы не переписывать его при добавлении script-пайпов?

ФОРМАТ ОТВЕТА: по каждому пункту — вердикт (держится / треснет / условно), конкретные грабли с API/версиями/таймингами, и что изменить ДО кода. В конце — топ-5 вещей, которые я почти наверняка недооценил, и 3 вещи, которые я могу безопасно упростить/выкинуть из v1. Если видишь архитектурную ошибку, которой нет в моих 8 вопросах — назови её отдельно.

═══════════════════════════════════════════════════════════════════
# ПРИЛОЖЕНИЕ 1 — PLAN (полный план пересборки)
═══════════════════════════════════════════════════════════════════

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

═══════════════════════════════════════════════════════════════════
# ПРИЛОЖЕНИЕ 2 — DESIGN: ядро захвата
═══════════════════════════════════════════════════════════════════

# Slishu Capture Core — Implementation Design (event-driven, Swift 6)

> Дизайн-документ от Plan-агента (ядро захвата). Часть бандла для ChatGPT 5.5 Pro (Шаг 0 плана).

## 0. Где это подключается к существующему коду

Текущий `SlishuCapture.swift` заменяется целиком. Подтверждённые дефекты, которые этот дизайн чинит:

- **Polling 0.5 fps** (`minimumFrameInterval = CMTime(value:1, timescale:0.5)` — математически сломано,
  timescale должен быть целым; реального интервала 2с не даёт). → event-driven on-demand capture.
- **Рекурсивный обход AX без таймаута** (`parseAccessibilityText`→`traverse`): неограниченная глубина,
  нет бюджета времени, синхронно на очереди SCK sample-handler. Это и есть «Obsidian-зависание». →
  budgeted background actor.
- **Гонка на состоянии захвата**: `_isCapturing` читается через `queue.sync`, но пишется в нескольких
  вложенных `queue.async` в `startCapture`; `stream`/`lastPixelBuffer` мутируются из completion
  handlers. Та же форма в `SlishuServer` (порт-гонка). → actor isolation.
- **`CIContext(options: nil)`** — софтверный контекст, не привязан к Metal. → один переиспользуемый
  Metal-`CIContext`.
- **`lastPixelBuffer` держит SCK `CVPixelBuffer`** между кадрами — back-pressure (queueDepth 5), риск
  buffer starvation. → хранить маленький perceptual hash, не буфер.
- **OCR на каждом кадре** безусловно рядом с AX. → OCR-as-true-fallback.

Слой данных (другой агент) экспонирует `IngestService`; мой DTO `CaptureRecord` ложится на схему.

## 1. Инвентарь типов / акторов

```
@MainActor  CaptureCoordinator          — владелец lifecycle, observers, debounce, оркестрация
            EventSource (protocol)       — эмитит CaptureTrigger
              ├ WorkspaceEventSource     — NSWorkspace app-activation + lock/sleep
              ├ AXEventSource            — AXObserver: focused-window/value/focus-changed
              └ InputEventSource         — CGEventTap listen-only: typing-pause / click / scroll-end
actor       FrameCapturer                — SCScreenshotManager on-demand single frame
actor       AXReaderActor                — budgeted AX traversal, Electron coercion, browser_url
actor       OCRFallbackActor             — Vision VNRecognizeTextRequest, cancellable
actor       FrameEncoderActor            — reusable Metal CIContext, HEIC encode, perceptual dedup
actor       CaptureWriter                — serializes CaptureRecord → data layer
            CaptureTrigger (enum)        — Sendable, почему захватываем
            CaptureRecord (struct)       — Sendable DTO в data layer
            CaptureConfig (struct)       — Sendable budgets/thresholds (DI, testable)
```

Каждый actor владеет одним куском не-Sendable leak-prone состояния. Ничего не пересекает границу
актора кроме Sendable-значений. `CVPixelBuffer` НИКОГДА не пересылается между акторами — потребляется
и кодируется внутри `FrameCapturer`→`FrameEncoderActor` в одной continuation. `CaptureCoordinator` —
`@MainActor` (AX observers, NSWorkspace, CGEventTap приходят на main runloop), делает только debounce
и dispatch в акторы.

## 2. Event-driven архитектура

### 2.1 Триггеры
```swift
enum CaptureTrigger: Sendable, Equatable {
    case appActivated(pid: pid_t, bundleID: String)
    case focusedWindowChanged(pid: pid_t)
    case focusedUIElementChanged(pid: pid_t)
    case valueChanged(pid: pid_t)         // жёстко коалесится
    case typingPause                      // нет keydown 700мс после активности
    case click
    case scrollSettled                    // нет scroll 400мс
    case fallbackTick                     // safety net, 30–60с
    case manualSnapshot                   // API/MCP
}
```

### 2.2 Источники
- **WorkspaceEventSource (@MainActor)**: `didActivateApplicationNotification` → `appActivated` (тут же
  пере-наводим `AXObserver` на новый PID и для Electron запускаем coercion §3.2);
  `screensDidSleep`/`sessionDidResignActive` (lock) → suspend; `didWake`/`sessionDidBecomeActive` →
  resume.
- **AXEventSource (@MainActor)**: один `AXObserver` на PID фронт-аппа (пересоздаётся на смене,
  НЕ держим N observers). Нотификации: `kAXFocusedWindowChanged`, `kAXFocusedUIElementChanged`,
  `kAXValueChanged` (на focused элементе, ЖЁСТКО коалесить — иначе шторм на каждый keystroke),
  `kAXMainWindowChanged`, `kAXTitleChanged`. Runloop source через `AXObserverGetRunLoopSource` на
  `CFRunLoopGetMain`.
- **InputEventSource (@MainActor)**: listen-only `CGEvent.tapCreate(.listenOnly, .cgSessionEventTap)`
  для keyDown/leftMouseUp/scrollWheel. Контент НЕ читает, только сбрасывает таймеры. Fallback на
  `NSEvent.addGlobalMonitorForEvents` если нет Input Monitoring гранта.

### 2.3 Debounce / coalescing
```
on trigger t:
    pendingTrigger = mergePriority(pendingTrigger, t)  // appActivated > focusedWindow > value/typing/scroll
    restart debounceTask (cancel previous):
        try await Task.sleep(for: .milliseconds(debounceWindow))  // 250мс default
        let trig = takePending(); await runCaptureCycle(trig)
```
- 250мс для AX/typing/scroll; **0мс (немедленно)** для `appActivated`. `valueChanged` доп. hard
  rate-limit ≥1.5с на окно.
- Coalescing key `(pid, windowID)`. Debounce — единственный cancellable `Task` на координаторе
  (main-actor, без локов).

### 2.4 On-demand frame: SCScreenshotManager, не SCStream
**Решение: `SCScreenshotManager.captureSampleBuffer(contentFilter:configuration:)` (macOS 14+) для
одиночных кадров, НЕ persistent `SCStream`.**
- `SCStream` — continuous pipeline (тёплая сессия, queueDepth буферов, polling). Для event-driven это
  чистый оверхед.
- `SCScreenshotManager` — один `CMSampleBuffer` на вызов, async, без тёплой сессии, GPU
  `CVPixelBuffer` для zero-copy. В idle: нет событий → нет захвата → нет сессии → CPU≈0.
- `SCShareableContent` кешируется, рефреш по `didChangeScreenParameters`.

```swift
actor FrameCapturer {
    private var cachedContent: SCShareableContent?
    func capture(displayIndex: Int, config: CaptureConfig) async throws -> CapturedFrame {
        let content = try await currentContent()
        let display = content.displays[displayIndex]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scfg = SCStreamConfiguration()
        scfg.width = display.width; scfg.height = display.height
        scfg.pixelFormat = kCVPixelFormatType_32BGRA
        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: scfg)
        return CapturedFrame(sampleBuffer: sample)  // потребляется немедленно, не хранится
    }
}
```

## 3. Accessibility без зависаний

### 3.1 Budgeted traversal на background actor
```swift
actor AXReaderActor {
    struct Budget: Sendable { var deadline: ContinuousClock.Instant; var maxDepth: Int; var maxNodes: Int }
    func extract(pid: pid_t, generation: UInt64, config: CaptureConfig) async -> AXExtraction?
}
struct AXExtraction: Sendable {
    var text: String; var windowTitle: String?; var browserURL: String?
    var nodeCount: Int; var hitBudgetLimit: Bool; var treeWasEmpty: Bool  // → OCR fallback
}
```
Жёсткие правила, убивающие зависание:
1. **Wall-clock deadline** (не только depth). `deadline = ContinuousClock.now + axBudget` (120мс
   default, max 250мс). Проверяется в начале каждого визита узла. **Главный фикс.**
2. **Depth cap** (60) и **node cap** (4000). Возвращают partial, не throw.
3. **Итеративный обход с явным стеком**, не рекурсия — ограниченная память, тривиальная отмена.
4. **`AXUIElementSetMessagingTimeout`** на app element (100мс). AX API — синхронный IPC к target app;
   зависший target блокирует `AXUIElementCopyAttributeValue` бесконечно без этого. **Второй
   критический фикс.**
5. **Отмена на смене фокуса**: каждый цикл несёт `generation: UInt64`. Проверка `Task.isCancelled`
   перед узлом и после `await`; координатор отменяет stale extraction при новом
   `appActivated`/`focusedWindowChanged`.
6. **Выбор атрибутов**: только value-bearing (`kAXValue`, `kAXTitle`, `kAXDescription`,
   `kAXPlaceholderValue`, `kAXSelectedText`), для контейнеров `kAXVisibleChildren`. Предпочитать
   subtree focused-окна (`kAXFocusedWindow`) над всем приложением.

### 3.2 Заставить Electron/Chromium вернуть дерево (главный дифференциатор)
Последовательность в `AXReaderActor` (праймится в `WorkspaceEventSource` на активации):
1. **Резолвить main app PID, не renderer PID.** `frontmostApplication.processIdentifier`. Для браузеров
   читать `kAXWindow` owner. Всегда `AXUIElementCreateApplication(mainAppPID)`.
2. **`AXManualAccessibility = true`** на app element (новый Chromium гейтит построение дерева за этим):
   `AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)`.
3. **`AXEnhancedUserInterface = true`** (старый VoiceOver-флаг, старые Electron). Ставим **оба** —
   правильный зависит от версии Chromium в конкретном Electron (VS Code/Slack/Telegram разные).
   Идемпотентно.
4. **Retry после ленивой инициализации.** Дерево не готово синхронно. Если `treeWasEmpty` — один retry
   через 400мс, потом 1200мс, максимум 2; затем сдаёмся в OCR. Флаги живут на время жизни процесса →
   следующие захваты того же аппа на тёплом дереве. **Кеш per-PID** `axHealthByPID`: подтверждённо
   non-empty → пропускаем флаги/ретраи; подтверждённо empty (canvas/игра) → `ocrOnly`, AX скипаем.
5. **Флаги на активации, не на захвате** — к моменту первого debounced захвата (~250мс) дерево уже
   построено.

### 3.3 browser_url через AX
- **Safari**: focused window → `kAXWebArea` → `kAXURL`. Fallback — address field (`kAXTextField` с URL).
- **Chrome/Chromium/Edge/Arc/Brave**: omnibox `AXTextField` `kAXValue` = видимый URL; надёжнее `AXURL`
  на web content area (тот же `AXEnhancedUserInterface`). Нормализуем (`https://` если omnibox срезал).
- `browserURL` → `CaptureRecord.browserURL`.

## 4. OCR как настоящий fallback
`OCRFallbackActor` запускает Vision **только** когда: `AXExtraction == nil`, ИЛИ `treeWasEmpty==true`
после ретраев (remote desktop, игры, canvas, Citrix/VNC), ИЛИ `hitBudgetLimit==true` И текст ниже
минимума.
```swift
actor OCRFallbackActor { func recognize(pixelBuffer: CVPixelBuffer, config: CaptureConfig) async -> [OCRLine] }
struct OCRLine: Sendable { var text: String; var confidence: Double; var rect: CGRect }
```
- **API**: native async `RecognizeTextRequest.perform(on:)` (macOS 15+, Sendable-friendly,
  cancellable); `VNRecognizeTextRequest` как baseline.
- `.accurate`, `usesLanguageCorrection=true`, `recognitionLanguages=["ru-RU","en-US"]`,
  `automaticallyDetectsLanguage=true`. Не форсить `usesCPUOnly` (ANE). `autoreleasepool` (фикс
  leak-класса).
- **Cancellable** через async-вариант. **Даунскейл перед OCR** через тот же Metal `CIContext`
  (`CILanczosScaleTransform`) — главное снижение стоимости. Никогда не grayscale на CPU.
- OCR доп. gated dedup-хешем (§5): near-duplicate → пропускаем OCR целиком.

## 5. Хранение кадров и дедуп
```swift
actor FrameEncoderActor {
    private let metalDevice = MTLCreateSystemDefaultDevice()!
    private let ciContext: CIContext           // CIContext(mtlDevice:) — создан ОДИН раз
    private var lastHashByDisplay: [Int: PerceptualHash] = [:]
    func encodeIfNew(_ buffer: CVPixelBuffer, displayIndex: Int, config: CaptureConfig) async -> EncodedFrame?
}
struct EncodedFrame: Sendable { var heicData: Data; var relativePath: String; var phash: UInt64 }
```
- **Переиспользуемый Metal CIContext** — один раз в init, никогда не пересоздаём.
- **HEIC через аппаратный кодек**: `ciContext.heif10Representation(of:...)` в `Data` (не на диск
  напрямую — нужны байты для writer + REST).
- **Dedup — perceptual hash, не 16×16 frame-diff.** 64-bit aHash/dHash из 8×8 grayscale даунскейла
  (Metal). Хранить только хеш (`UInt64`), не буфер (фикс retention). Duplicate если
  `hammingDistance ≤ dedupThreshold` (3 бита). На дубле: пропустить HEIC+OCR, но если app/window
  сменились — эмитить лёгкий text-only record (timeline непрерывен).
- **Имя/локация**: `mediaDirectory` (relocatable via bookmark). `screen_<ISO8601>_<display>.heic`.
  Encoder отдаёт байты+relativePath; `CaptureWriter` пишет файл рядом с DB-insert (вместе коммитятся,
  нет orphan при сбое insert — дыра старого кода).

## 6. Swift 6 concurrency
- **Strict concurrency on.** `SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY complete`,
  `deploymentTarget 15.0`.
- Никаких shared mutable singletons с ручными `DispatchQueue.sync`. Каждый флаг — actor-isolated.
  `CaptureCoordinator` (@MainActor) — единый источник «capturing». Структурно убирает обе гонки.
  Тот же рецепт для `SlishuServer` (сделать actor).
- **Sendable-дисциплина**: все DTO — Sendable value types. `CVPixelBuffer`/`CMSampleBuffer`/
  `AXUIElement`/`VNRequest` никогда не actor-state, обрабатываются в `@unchecked Sendable` тонких
  обёртках только в точке потребления, внутри `autoreleasepool`.
- **UI bridge**: координатор публикует `@Observable @MainActor CaptureState`.

### Backpressure (лавина событий)
1. Debounce+coalesce на координаторе.
2. **Single-flight на дисплей**: `inFlight: [Int: Task]`. Если цикл для дисплея N идёт и приходит
   триггер — НЕ стартуем второй, ставим `pendingRecapture` бит; по завершении — ровно один ещё. Max
   один in-flight + один queued на дисплей.
3. value-change rate limit (1.5с) и OCR gated dedup-хешем.

### Leak/buffer гигиена
- `CVPixelBuffer` в `autoreleasepool`, не retained. Нет поля `lastPixelBuffer` — заменён `UInt64`.
- Vision requests per-call в `autoreleasepool`. `AXObserver` предыдущего аппа `CFRunLoopRemoveSource`
  + release на каждой смене.

## 7. Smart pause (emergent + явный)
- **Lock/sleep**: `sessionDidResignActive`/`screensDidSleep` → `.suspended`: teardown CGEventTap +
  AXObserver, cancel fallback tick. Wake → re-arm.
- **Idle > N мин**: вместо polling-таймера — отсутствие input-событий. `lastInputAt`. Fallback tick
  (единственный таймер): если `now-lastInputAt > idleThreshold` (3 мин) — ничего, решедул. Опц. один
  capture на idle-entry.
- **Fullscreen video/game**: AX frame == display frame И app `ocrOnly` → rate до fallback tick.
  Видео dedup-скипается. В fullscreen чуть поднять `dedupThreshold`.

## 8. Энергоэффективность
- **Idle = ноль работы**: нет SCStream-сессии, единственный coalesced fallback tick (cheap idle check
  + reschedule). Главный выигрыш над continuous pipeline screenpipe.
- **QoS**: FrameCapturer/Encoder `.utility`; AXReaderActor `.userInitiated`; OCR `.utility`; Writer
  `.utility`; Coordinator @MainActor.
- **GPU/ANE offload**: HEIC (VideoToolbox HW HEVC), CIContext scaling (Metal), Vision (ANE). CPU
  холодный.
- Fallback tick адаптивен: 30с при активности → 60–120с при idle.

## 9. Data flow: событие → запись
```
[NSWorkspace.didActivateApplication] → WorkspaceEventSource (@MainActor)
    set AXManualAccessibility + AXEnhancedUserInterface (Electron); rebuild AXObserver
        ↓
   CaptureCoordinator.onTrigger(.appActivated) (@MainActor) — bump generation; merge+debounce (immediate)
        ↓
   runCaptureCycle(trigger, generation) — single-flight на дисплей
    ├─ AXReaderActor.extract(pid, generation)   [budget 120мс, cancel on newer gen] → AXExtraction?
    ├─ FrameCapturer.capture(display) → CVPixelBuffer → FrameEncoderActor.encodeIfNew (phash dedup; nil=dup)
    └─ if AX empty/insufficient AND frame new: OCRFallbackActor.recognize (Vision, ru+en, ANE)
        ↓
   assemble CaptureRecord → CaptureWriter.write (actor; HEIC файл + DB txn вместе) → IngestService
```
Cancellation: (a) перед/после каждого AX-узла; (b) перед Vision perform; (c) весь цикл отменяется на
новой generation. Timeouts: AX wall-clock 120мс + messaging 100мс; SCK capture в `withThrowingTaskGroup`
+ 2с watchdog.

## 10. Контракт с data layer
```swift
public struct CaptureRecord: Sendable {
    public let timestamp: Date
    public let displayIndex: Int
    public let monitorID: String
    public let bundleID: String
    public let appName: String
    public let windowTitle: String?
    public let browserURL: String?
    public let heicData: Data?            // nil при dedup context-only record
    public let relativePath: String?
    public let perceptualHash: UInt64
    public let accessibilityText: String?
    public let ocrLines: [OCRLineRecord]
    public let textSource: TextSource     // .accessibility | .ocr | .mixed | .none
    public let axHitBudgetLimit: Bool
    public let axTreeWasEmpty: Bool
}
public struct OCRLineRecord: Sendable {
    public let text: String; public let confidence: Double
    public let left, top, width, height: Double  // normalized, top-left
}
public enum TextSource: String, Sendable { case accessibility, ocr, mixed, none }
```
Writer (data agent): в ОДНОЙ GRDB write-транзакции — upsert apps, insert screen_captures
(window_title/browser_url), insert OCRLineRecord→text_blocks, один консолидированный FTS-row
(accessibilityText ⊕ ocr ⊕ browser host). HEIC пишется внутри success-пути, нет orphan при сбое.
Embedding — detached background task по `captureId`. Рекомендация: колонка `text_source` чтобы доказать
AX-first.

## 11. CaptureConfig (DI, testable)
```swift
public struct CaptureConfig: Sendable {
    var debounceMs = 250; var appActivatedDebounceMs = 0; var valueChangeMinIntervalMs = 1500
    var axBudgetMs = 120; var axMessagingTimeoutS = 0.1; var axMaxDepth = 60; var axMaxNodes = 4000
    var axRetries = 2; var axRetryDelaysMs = [400, 1200]
    var dedupHammingThreshold = 3; var ocrMinAXTextLength = 24
    var ocrLanguages = ["ru-RU","en-US"]; var idleThresholdS = 180; var fallbackTickS = 30
    var ocrDownscaleMaxDimension = 2200
}
```

## 12. Критические Apple API
- `SCScreenshotManager.captureSampleBuffer/.captureImage` — macOS 14+. Primary frame source.
- `SCShareableContent`/`SCContentFilter`/`SCStreamConfiguration` — 12.3+/13+. Кешируется.
- `AXObserverCreate/AddNotification/GetRunLoopSource`, `kAXFocusedWindowChanged` и т.д. — требует
  Accessibility TCC.
- `AXUIElementSetMessagingTimeout` — критический анти-hang.
- `"AXManualAccessibility"`/`"AXEnhancedUserInterface"` через `AXUIElementSetAttributeValue` —
  Electron-активация (дифференциатор). Не формальные константы, CFString-литералы.
- `kAXURLAttribute`/`AXWebArea` `AXURL` — browser URL.
- `VNRecognizeTextRequest` (10.15+) / native async `RecognizeTextRequest.perform(on:)` (15+).
- `CIContext(mtlDevice:)`/`CIImage(cvPixelBuffer:)`/`heif10Representation` — Metal + HEIC HW codec.
- `NSWorkspace.didActivateApplication`/`screensDidSleep/Wake`/`sessionDidResignActive/BecomeActive`;
  `NSApplication.didChangeScreenParameters`.
- `CGEvent.tapCreate(.cgSessionEventTap, .listenOnly)` (+Input Monitoring) с
  `NSEvent.addGlobalMonitorForEvents` fallback. `CGEventSource.secondsSinceLastEventType` — idle.
- Swift 6: `swiftLanguageMode 6`, strict concurrency complete, `deploymentTarget 14.0→15.0`.

## 13. Конкретные риски
1. **AXManualAccessibility side-effects / version drift** — может спайкнуть CPU самого Electron; кеш
   per-PID health, mark ocrOnly, OCR fallback честный, держать оба флага.
2. **AX messaging-timeout всё ещё фронтит синхронный IPC** — worst-case wall-clock budget (120мс) это
   реальная гарантия, проверять первым в каждом узле.
3. **SCScreenshotManager permission/cold-start** — первый вызов медленный/всплывает -3801; держать
   TCC-детект, `hasTCCError` на CaptureState.
4. **Perceptual-hash false negatives** (dark-mode toggle, маленький важный диф типа пришедшего
   сообщения) — комбинировать phash с AX/title change: текст изменился → пишем даже если phash=dup.
5. **CGEvent tap требует отдельный Input Monitoring грант** — graceful degrade на AX+Workspace.
6. **Multi-display** — single-flight per display, hash per display. По умолчанию активный дисплей
   (энергия), конфигурируемо.
7. **Swift 6 strict concurrency** с не-Sendable типами — строго внутри одного актора, узкие
   `@unchecked Sendable` только на границе потребления.
8. **Fallback-tick + событие совпадение** — single-flight+coalesce покрывает, но tick должен идти
   через тот же `onTrigger` debounce, не звать `runCaptureCycle` напрямую.
9. **Server port race (pre-existing)** — тот же класс бага; сделать `SlishuServer` actor.

═══════════════════════════════════════════════════════════════════
# ПРИЛОЖЕНИЕ 3 — DESIGN: данные / поиск / REST / MCP / транскрипция
═══════════════════════════════════════════════════════════════════

# Slishu — Дизайн слоёв данных, поиска, REST, MCP и транскрипции

> Дизайн-документ от Plan-агента (данные/поиск/API/MCP/транскрипция). Часть бандла для ChatGPT 5.5 Pro.

## 0. Отправная точка (баги старого кода)
- `SlishuDatabase`: GRDB 6.29, DatabasePool, WAL, миграции; но `eraseDatabaseOnSchemaChange` в DEBUG,
  нет retention, нет `windowTitle/browserUrl/source`, FTS-триггеры неполные (текст вставляется руками).
- `SlishuSemanticSearch`: NLEmbedding + ручной косинус, brute-force, медленно.
- `SlishuServer`: FlyingFox; **баг порт-поиска** (`self.server` ставится ДО `start()`); нет различения
  EADDRINUSE; ручная сборка JSON строками.
- `SlishuMCP`: ручной JSON-RPC, `try!` в `safeSerialize`, 3 инструмента, нет stdio.
- `SlishuTranscriptionManager`: жёстко SFSpeechRecognizer, нет протокола, нет MLX, нет отмены/очереди.
- `Package.resolved` уже содержит официальный MCP SDK + eventsource → SSE доступен.

## 1. Схема SQLite (GRDB)

### 1.1 Решения
- **Единая `text_blocks`** (вместо `ocr_elements`) с полем `source` (`ax`|`ocr`) — убирает костыль
  «AX-текст как фейковый OCR-элемент с bbox=0».
- **FTS5 синхронизируется ТОЛЬКО триггерами** (content-rowid), не ручными INSERT — убирает рассинхрон
  и декартово произведение.
- **external content FTS5** (`content='text_blocks', content_rowid='id'`) — индекс без дублирования
  текста, ~50% экономии.
- Время — **Unix epoch INTEGER (мс)**, не ISO-строка.

### 1.2 DDL (миграция v1)
```sql
CREATE TABLE apps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    bundle_id TEXT NOT NULL UNIQUE, name TEXT NOT NULL);

CREATE TABLE screen_captures (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL,                       -- epoch ms
    app_id INTEGER REFERENCES apps(id) ON DELETE SET NULL,
    window_title TEXT, browser_url TEXT,
    monitor_id TEXT NOT NULL, relative_path TEXT NOT NULL,
    width INTEGER, height INTEGER, bytes INTEGER);
CREATE INDEX idx_sc_ts ON screen_captures(ts);
CREATE INDEX idx_sc_app_ts ON screen_captures(app_id, ts);

CREATE TABLE text_blocks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    capture_id INTEGER NOT NULL REFERENCES screen_captures(id) ON DELETE CASCADE,
    source TEXT NOT NULL,                      -- 'ax' | 'ocr'
    text TEXT NOT NULL, confidence REAL NOT NULL DEFAULT 1.0,
    bbox_x REAL, bbox_y REAL, bbox_w REAL, bbox_h REAL);
CREATE INDEX idx_tb_capture ON text_blocks(capture_id);

CREATE TABLE audio_captures (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL, relative_path TEXT NOT NULL,
    duration_sec REAL NOT NULL, channel TEXT NOT NULL DEFAULT 'mic');
CREATE INDEX idx_ac_ts ON audio_captures(ts);

CREATE TABLE transcriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    audio_id INTEGER NOT NULL REFERENCES audio_captures(id) ON DELETE CASCADE,
    text TEXT NOT NULL, language TEXT NOT NULL, speaker TEXT,
    start_offset REAL, end_offset REAL, engine TEXT NOT NULL);
CREATE INDEX idx_tr_audio ON transcriptions(audio_id);

CREATE TABLE embeddings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,                        -- 'screen' | 'audio'
    ref_id INTEGER NOT NULL, model TEXT NOT NULL, dim INTEGER NOT NULL,
    vector BLOB NOT NULL,                      -- Float32 LE, нормализованный
    UNIQUE(kind, ref_id, model));
CREATE INDEX idx_emb_ref ON embeddings(kind, ref_id);
```

### 1.3 FTS5 external-content + триггеры БЕЗ декартова
```sql
CREATE VIRTUAL TABLE text_fts USING fts5(
    text, content='text_blocks', content_rowid='id',
    tokenize="unicode61 remove_diacritics 2");
CREATE TRIGGER text_blocks_ai AFTER INSERT ON text_blocks BEGIN
    INSERT INTO text_fts(rowid, text) VALUES (new.id, new.text); END;
CREATE TRIGGER text_blocks_ad AFTER DELETE ON text_blocks BEGIN
    INSERT INTO text_fts(text_fts, rowid, text) VALUES('delete', old.id, old.text); END;
CREATE TRIGGER text_blocks_au AFTER UPDATE ON text_blocks BEGIN
    INSERT INTO text_fts(text_fts, rowid, text) VALUES('delete', old.id, old.text);
    INSERT INTO text_fts(rowid, text) VALUES (new.id, new.text); END;
-- аналогично transcription_fts на transcriptions
```
**Фикс старого бага:** поиск `FROM text_fts JOIN text_blocks tb ON tb.id=text_fts.rowid JOIN
screen_captures c ON c.id=tb.capture_id WHERE text_fts MATCH ?`. Связь rowid→id строго 1:1. Дедуп
кадров `GROUP BY c.id` с `MIN(rank)`, не JOIN-ом всех элементов (который давал N×M).
Альтернатива — денормализованная `fts_text` прямо в `screen_captures` (FTS 1:1 к кадру by
construction); `text_blocks` остаётся для bbox/highlight.

### 1.4 GRDB конфиг
```swift
var config = Configuration()
config.qos = .utility; config.maximumReaderCount = 5
config.prepareDatabase { db in
    try db.execute(sql: "PRAGMA journal_mode = WAL")
    try db.execute(sql: "PRAGMA synchronous = NORMAL")
    try db.execute(sql: "PRAGMA busy_timeout = 5000")
    try db.execute(sql: "PRAGMA cache_size = -20000")     // ~20 MB
    try db.execute(sql: "PRAGMA mmap_size = 268435456")   // 256 MB
    try db.execute(sql: "PRAGMA foreign_keys = ON")
    SlishuVectorExtension.loadIfEnabled(db)               // sqlite-vec
}
let pool = try DatabasePool(path: dbURL.path, configuration: config)
```
`DatabasePool` (не Queue) обязателен: capture пишет 24/7, REST/MCP читают параллельно. Убрать
`eraseDatabaseOnSchemaChange` (или гейтить `SLISHU_DEV_WIPE`). Миграции аддитивные.

## 2. Векторный поиск

### 2.1 Сравнение для «месяцы 24/7» (сотни тыс.–млн строк)
| Подход | 1M векторов | Память | Вердикт |
|---|---|---|---|
| BLOB + brute-force в Swift (текущий) | секунды, чтение сотен МБ | высокая | не масштабируется |
| BLOB + Accelerate (vDSP/BNNS) + пред-норм | 50–150мс на 1M @384 если mmap | средняя | переходный вариант, всё ещё линейно |
| **sqlite-vec (vec0) в GRDB** | десятки мс, brute KNN в C | низкая (на диске) | **рекомендую** |
| Apple-native | нет готового ANN-индекса | — | только примитивы |

**Рекомендация: sqlite-vec.** Грузится через `sqlite3_auto_extension(sqlite3_vec_init)` ДО открытия
пула или в `prepareDatabase`. Лёгкая зависимость (один C-файл). KNN brute-force с SIMD; для целевых
объёмов десятки мс. Гибридные фильтры по времени/app в одном SQL.
```sql
CREATE VIRTUAL TABLE vec_embeddings USING vec0(
    ref_kind TEXT PARTITION KEY, embedding FLOAT[384]);
SELECT v.rowid, v.distance FROM vec_embeddings v
WHERE v.embedding MATCH ? AND k = 50 ORDER BY v.distance;
```
**Страховка:** протокол `VectorIndex` с `SqliteVecIndex` (default) и `AccelerateBruteForceIndex`
(fallback если расширение не соберётся). Снимает главный техриск. Нужен SQLite с разрешённой загрузкой
расширений.

### 2.2 Эмбеддинги
| Модель | dim | Качество | Вес | Прогон |
|---|---|---|---|---|
| NLEmbedding.sentenceEmbedding (текущий) | ~512 | слабое, не cross-lingual | 0 (системная) | системный |
| **multilingual-e5-small / bge-small** via MLX/CoreML | 384 | SOTA retrieval, ru+en в одном пространстве | ~120МБ | MLX/ANE |
| bge-m3 | 1024 | лучшее, тяжелее | ~2ГБ | MLX |

**Рекомендация: multilingual-e5-small (384-dim) через MLX** (тот же стек, что Whisper turbo).
Решает боль «ищу „ошибки компиляции swift“ → на экране „build failed“». Сменный протокол:
```swift
protocol EmbeddingBackend: Sendable {
    var identifier: String { get }; var dimension: Int { get }
    func embed(_ text: String) async throws -> [Float]           // L2-normalized
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}
```
Все L2-норм → косинус = dot product. Модель фиксируется в `embeddings.model`+`dim` (для
переиндексации).

### 2.3 Гибридный поиск + ранжирование
1. Lexical: `text_fts MATCH` → top-100 с `bm25(text_fts)`.
2. Semantic: эмбеддинг запроса → `vec_embeddings MATCH` → top-100 с distance.
3. **Fusion (RRF):** `score = Σ 1/(k + rank_i)`, k≈60. Не требует калибровки шкал (bm25 vs косинус в
   разных единицах).
4. Фильтры (app/window/time/source) как WHERE к финальному набору id.
5. Режимы `mode = fts | semantic | hybrid` (default hybrid).
Возвращаем: timestamp, app, window, snippet (FTS `snippet()`), media path, score, какой leg сработал.

## 3. Retention / авто-очистка
```
retentionDays: Int?; maxStorageGB: Double?; pruneIntervalMinutes: Int; storageDirectoryBookmark: Data
```
**actor RetentionManager** (таймер раз в N мин + по триггеру «диск > порог»):
1. По времени: `cutoff = now - retentionDays`.
2. По размеру: FIFO по `ts` пока не уложимся (хранить `bytes` в строках — точнее, чем `du`).
3. Каскад: `ON DELETE CASCADE` → text_blocks → триггеры чистят FTS. **vec0 — явный `DELETE`** (FK не
   цепляется к виртуальной).
4. Файлы: собрать `relative_path`, удалить HEIC/audio (вне транзакции БД).
5. Батчами (`LIMIT 500`) в отдельных транзакциях (не держать длинный writer-лок).
6. Orphan-sweep: файлы без записи — удалять.
7. После крупного прунинга: FTS `optimize` + `PRAGMA wal_checkpoint(TRUNCATE)`.
```swift
actor RetentionManager {
    func runPrune(reason: PruneReason) async throws -> PruneReport
    func enforceTimeLimit(_ days: Int) async throws -> Int
    func enforceSizeLimit(_ maxBytes: Int64) async throws -> Int
    func sweepOrphans() async throws -> Int
    func currentStorageBytes() async throws -> Int64
}
```
**Релокация:** путь как **security-scoped bookmark** (Data), не строка (иначе sandbox потеряет доступ).
`StorageManager.relocate(to:)`: валидировать → пауза записи → переместить файлы (`relative_path` не
меняется — хранятся только имена) → обновить bookmark → возобновить. БД оставить в Application Support.

## 4. Чистый REST API

### 4.1 Сервер: FlyingFox vs Hummingbird 2 vs Vapor
| | FlyingFox | Hummingbird 2 | Vapor |
|---|---|---|---|
| Транзит. зависимости | swift-nio | NIO+ServiceLifecycle | большой стек |
| Вес | лёгкий | средний | тяжёлый |
| Роутинг | примитивный closure | typed+middleware | максимальный |
| Для menubar-app | да (встроен) | да | оверкилл |

**Рекомендация: остаться на FlyingFox** (0.26.2 уже собран, минимален, async, SSE). Hummingbird 2 —
альтернатива если позже нужен typed-routing. Vapor отвергнуть. Чинить: Codable вместо строк,
middleware ошибок, порт-поиск.

### 4.2 Конвенции
- Префикс `/v1/`. Bind только `127.0.0.1`. Ответы JSON UTF-8 (кроме media/frames).
- Время = ISO-8601 + epoch ms (оба). Единый формат ошибки `{ "error": { "code", "message", "details" } }`.
- Опц. `localToken` (`Authorization: Bearer`) для мутаций.

### 4.3 Эндпоинты (ключевые схемы)
- **`GET /v1/health`** → `{ status, version, uptimeSec, capturing, mcp:{http,stdio}, port }`
- **`GET /v1/search`** params: `q`(req), `mode`(fts|semantic|hybrid), `app`, `window`, `source`,
  `from/to`, `limit`(≤200), `offset` →
  ```json
  { "query":"…","mode":"hybrid","total":37,"results":[
    {"kind":"screen","id":90213,"ts":…,"tsISO":"…","app":{"bundleId":"…","name":"Xcode"},
     "windowTitle":"…","browserUrl":null,"snippet":"…<b>build failed</b>…","score":0.84,
     "matchedBy":["fts","semantic"],"media":{"frameUrl":"/v1/frames/90213","thumbUrl":"…?thumb=1"}},
    {"kind":"audio","id":4521,"ts":…,"snippet":"…","score":0.61,"matchedBy":["semantic"],
     "media":{"audioUrl":"/v1/media/audio_….m4a"},"transcript":{"language":"ru","speaker":null}}]}
  ```
- **`GET /v1/timeline`** (скруббер) params `from`,`to`(req),`bucket`(minute|5min|hour),`app` →
  `{ from,to,bucket,"buckets":[{ts,frameCount,audioSec,topApp,representativeFrameId}] }`
- **`GET /v1/frames/{id}`** — HEIC; `?thumb=1` (ресайз CoreImage, кешировать); `?format=jpeg`. Защита:
  числовой id → resolve `relative_path` из БД (не путь из URL).
- **`GET /v1/media/{filename}`** — стриминг с HTTP Range (206). Traversal защита обязательна.
- **`GET /v1/frames/{id}/context`** — ±N сек вокруг кадра (соседние кадры, апп, фрагменты транскрипции).
- **`POST /v1/capture/toggle`** (auth) → `{ capturing, permissions:{screen,mic,accessibility} }`
- **`GET/PUT /v1/settings/storage`** (auth) — путь/retention/usage.
- **`GET /v1/stats`** — frames/audio/transcriptions/embeddings/apps/oldest/newest/dbBytes/mediaBytes/
  transcription queue.

### 4.4 DTO (Codable) — `SlishuAPIDTO.swift`, никакого `[String:Any]`/ручных строк.

### 4.5 Path traversal (укрепление)
Текущий `hasPrefix(mediaDir.path)` уязвим (`/media-evil`). Правильно:
```swift
let base = mediaDir.standardizedFileURL.resolvingSymlinksInPath()
let target = base.appendingPathComponent(filename).standardizedFileURL.resolvingSymlinksInPath()
guard Array(target.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents else { return .forbidden }
```
Плюс для `/frames/{id}` — только числовой id→lookup (traversal by design невозможен). `/media/{filename}`
валидировать regex `^[A-Za-z0-9._-]+$`.

### 4.6 Динамический порт (фикс бага)
```swift
func startServer(preferred: [UInt16]) async throws -> UInt16 {
    for port in preferred {                          // [8088, 11435, 0]
        let server = HTTPServer(address: .loopback(port: port))
        do { try await server.start()                // бросит на bind ДО self
             self.server = server
             self.activePort = await server.listeningPort; return self.activePort
        } catch let e as SocketError where e.isAddrInUse { continue }   // только EADDRINUSE
        catch { throw error }                        // прочие — наверх
    }
    throw ServerError.noAvailablePort
}
```
Дефолт **не 8080** (конфликт с дев-серверами/IPFS). Писать активный порт в
`~/Library/Application Support/Slishu/port` (для MCP-обёртки/клиентов). `SlishuHTTPServer` — actor.

## 5. MCP сервер

### 5.1 Транспорт: stdio + HTTP/SSE (оба)
1. **stdio** (главный для desktop): `Slishu --mcp` (без UI, без HTTP, по stdin/stdout — канон для Claude
   Desktop/Cursor). stdio-процесс читает БД напрямую для запросов, мутации (toggle) проксирует в
   основной инстанс через `/v1/capture/toggle` (порт из port-файла); если не запущен — внятная ошибка.
2. **HTTP/SSE** на том же порту: `GET /mcp` (SSE) + `POST /mcp` (JSON-RPC). eventsource уже в
   зависимостях.

### 5.2 Официальный SDK vs ручной JSON-RPC
**Рекомендация: официальный `modelcontextprotocol/swift-sdk`** (уже в Package.resolved). Убирает
ручную сериализацию (`try!` краш), корректный handshake/lifecycle, оба транспорта, типизированные
`Tool`/`CallTool.Result`/`Content`. Запинить на тэг/ревизию (не `branch: main`).

### 5.3 Tools (тонкие обёртки над общим сервисным слоем)
- `search_history` `{ query, mode?, app?, from?, to?, limit? }` → форматированные хиты.
- `get_timeline` `{ from, to, bucket? }` → агрегированная активность.
- `get_context_at` `{ time }` → активный апп, окно, текст экрана, фрагменты разговора ±N сек + frame ref.
- `get_status` → запись, движок, размеры, права TCC.
- `toggle_recording` `{ enable }` → проксируется в основной инстанс.
Опционально MCP resources: кадры как `slishu://frame/{id}`.

### 5.4 Безопасная сериализация
Убрать все `try!`. Ответы через типы SDK. Любой throw в handler → MCP error result (`isError:true`),
не краш.
```swift
actor SlishuMCPServer {
    init(searchService:…, timeline:…, capture:…, transcription:…)
    func runStdio() async throws
    func attachHTTP(to server: SlishuHTTPServer) async
    private func registerTools() -> [MCPToolDefinition]
}
```

## 6. Транскрипция

### 6.1 Протокол
```swift
struct TranscriptionRequest: Sendable { let audioURL: URL; let languageHint: TranscriptionLanguage; let timestamp: Date }
struct TranscriptionSegment: Sendable { let text: String; let startOffset, endOffset: TimeInterval; let language: String; let speaker: String? }
struct TranscriptionResult: Sendable { let segments: [TranscriptionSegment]; let detectedLanguage: String; let engine: String }
enum TranscriptionProgress: Sendable { case loadingModel; case processing(fraction: Double); case finished }
protocol TranscriptionBackend: Sendable {
    var identifier: String { get }; var isAvailable: Bool { get async }
    func warmUp() async throws
    func transcribe(_ req: TranscriptionRequest, progress: @Sendable (TranscriptionProgress)->Void) async throws -> TranscriptionResult
}
```
Отмена через `withTaskCancellationHandler` + `Task.checkCancellation()` между чанками.

### 6.2 Реализации
- **MLXWhisperBackend (default)** — `mlx-whisper-v3-turbo`. MLX Swift (`ml-explore/mlx-swift` +
  examples). `warmUp()` грузит веса в GPU ОДИН раз (не на каждый чанк). decode m4a→PCM 16k mono
  (`AVAudioConverter`), чанки 30с (Whisper нативно на 30с-окнах — наши чанки уже 30с), сегменты с
  таймкодами. Язык auto/ru/en.
- **SFSpeechBackend** — обёртка над текущим (нулевой вес, слабее на ru/длинном).
- **WhisperCppBackend** — `whisper.cpp` (GGUF), альтернатива MLX.
- **CloudBackend** — opt-in, помечен (нарушает «локально»).

### 6.3 Очередь/запись
```swift
actor TranscriptionService {
    private var backend: TranscriptionBackend; private var queue: [TranscriptionJob]; private var current: Task<Void,Never>?
    func setBackend(_ id: TranscriptionEngineID) async
    func enqueue(audioURL: URL, audioCaptureId: Int64, timestamp: Date)
    func cancelAll(); var status: TranscriptionStatus { get }
}
```
Поток: взять `audio_id` → `backend.transcribe` → на каждый сегмент `INSERT INTO transcriptions`
(триггер сам в `transcription_fts`) → эмбеддинг агрегата → `embeddings`+`vec_embeddings` (в той же
сервисной очереди, НЕ `Task.detached`). Backpressure: лимит очереди (50).

### 6.4 Переключение
UserDefaults: `transcriptionEngine`, `transcriptionLanguage`, `embeddingModel`. Смена движка →
`setBackend` (отменяет текущий, warmUp нового). Старые транскрипции остаются (`engine` фиксирует чем).
Смена модели эмбеддингов → опция «переиндексировать».

### 6.5 Контракт приёма от capture-слоя
```swift
struct ScreenCaptureRecord: Sendable {
    let timestamp: Date; let bundleId, appName: String; let windowTitle, browserURL: String?
    let monitorId: String; let imageData: ImagePayload; let textBlocks: [CapturedTextBlock]
    let pixelWidth, pixelHeight: Int }
struct CapturedTextBlock: Sendable { let source: TextBlock.Source; let text: String; let confidence: Double; let bbox: CGRect? }
enum ImagePayload: Sendable { case heicData(Data); case fileWritten(relativePath: String) }
struct AudioCaptureRecord: Sendable { let timestamp: Date; let relativePath: String; let durationSec: Double; let channel: AudioCapture.Channel }
actor IngestService {                              // ЕДИНСТВЕННЫЙ writer
    func ingest(_ r: ScreenCaptureRecord) async throws -> Int64
    func ingest(_ r: AudioCaptureRecord) async throws -> Int64    // ставит на транскрипцию
}
```
`IngestService`: файл (если imageData) + `screen_captures`+`text_blocks` (триггеры → FTS) + embed; для
аудио → `TranscriptionService`. Один actor = один writer (нет гонок). Дедуп/blacklist/smart-pause
остаются на capture-слое.

## 7. Сводка типов
```
StorageManager (class) · SlishuDatabase (final) · IngestService (actor) ·
EmbeddingBackend → MLXEmbeddingBackend(me5-small,default)/NLEmbeddingBackend/BGE ·
VectorIndex → SqliteVecIndex(default)/AccelerateBruteForceIndex ·
SearchService (actor) · TimelineService (actor) · CaptureController (actor) · RetentionManager (actor) ·
TranscriptionBackend → MLXWhisper(default)/SFSpeech/WhisperCpp/Cloud · TranscriptionService (actor) ·
SlishuHTTPServer (actor) · SlishuMCPServer (actor) · SlishuAPIDTO (Codable)
```

## 8. Зависимости и вес
| Зависимость | Назначение | Вес |
|---|---|---|
| GRDB 6.29 (есть) | SQLite/FTS5/pool | лёгкая |
| sqlite-vec (добавить) | вектор KNN | очень лёгкая (один C-файл) |
| FlyingFox 0.26 (есть) | REST+SSE | лёгкая (NIO транзит.) |
| MCP swift-sdk (есть, запинить) | MCP stdio+SSE | средняя |
| mlx-swift + examples (добавить) | Whisper turbo + e5 | рантайм лёгкий, веса ~1.5ГБ (не в бандле) |
| Apple frameworks | NL/Speech/AVF/Accelerate/Vision/SCK | 0 |
Net: ядро лёгкое. Тяжесть только в ML-весах (по требованию). На слабой машине дефолт может стартовать
на SFSpeech+NLEmbedding (нулевой вес).

## 9. Порядок реализации
1. Схема+миграции v1 (FTS-триггеры, PRAGMA). 2. **sqlite-vec интеграция** + VectorIndex fallback
(проверить рано — главный риск). 3. IngestService + EmbeddingBackend (NLEmbedding→MLX e5).
4. SearchService (FTS→vec→RRF)+DTO. 5. REST (фикс порта, эндпоинты, traversal). 6. TranscriptionBackend
(SFSpeech→MLXWhisper). 7. MCP (SDK, stdio+SSE). 8. RetentionManager. 9. MLX e5 + переиндексация.

## Риски
- sqlite-vec под Swift 6 toolchain — проверить загрузку рано; Accelerate fallback. - MLX Whisper:
модель в actor, не перезагружать на чанк, отмена. - Security-scoped bookmark (plain string сломается).
- Единый writer (убрать Task.detached). - MCP SDK запинить ревизию.

═══════════════════════════════════════════════════════════════════
# ПРИЛОЖЕНИЕ 4 — DESIGN: UI / права / плагины / упаковка
═══════════════════════════════════════════════════════════════════

# Slishu — UI / Permissions / Pipes / Connections / Packaging Design

> Дизайн-документ от Plan-агента (оболочка/UI/плагины/коннекторы/упаковка). Часть бандла для Pro.

## 0. Что есть сегодня
Монолит `ContentView.swift` (1531 строка), hand-rolled HStack sidebar (не NavigationSplitView), всё
состояние — разрозненные `@State` на одной гигантской view. `SlishuApp.swift` — WindowGroup + 3-кнопочный
MenuBarExtra. Backend solid: Capture/Audio/Transcription/DB/Server/MCP/SemanticSearch.

Дыры новой версии: **Pipes** = mock `[PipeItem]`, «Настроить» = `// Mock configure sheet`, нулевой
backend. **Connections** = mock, «Подключить» = toggle Bool, нет Keychain/test/config. **Permissions** =
только реактивный `-3801` детект, нет preflight/онбординга. `project.yml`: deployment 14.0, Swift 5,
нет entitlements/LSUIElement/Accessibility usage string.

## 1. App Shell

### 1.1 Структура файлов — см. PLAN.md «Целевая структура файлов».

### 1.2 SlishuApp.swift
```swift
@main struct SlishuApp: App {
    @State private var env = AppEnvironment()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("Slishu", id: "main") {                 // не WindowGroup
            RootWindow().environment(env).task { await env.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar).windowResizability(.contentMinSize).defaultSize(width:1100, height:720)
        MenuBarExtra { MenuBarContent().environment(env) }
            label: { MenuBarLabel(state: env.recording) }
        .menuBarExtraStyle(.window)                     // богатый glass-popover
        Settings { EmptyView() }
    }
}
```
- **`Window(id:)` не WindowGroup** — single-window utility; MenuBar «Открыть» → `openWindow(id:"main")`
  вместо хака `NSApp.windows.first`.
- **`MenuBarExtra(.window)`** — real glass popover: toggle, счётчики, активный порт, варнинги, выход.
- **Корень — один `@Observable AppEnvironment`** через `.environment`, читается
  `@Environment(AppEnvironment.self)`. Убираем антипаттерн (старый `TimelineTabView` брал **14
  биндингов**).

### 1.3 LSUIElement / agent mode
**Рекомендация: обычное приложение с menu-bar присутствием** (`LSUIElement = NO`), окно закрывается без
выхода (сервисы независимы от UI). Чистый TCC-UX. Опц. тумблер «Скрывать из Dock» → runtime
`NSApp.setActivationPolicy(.accessory/.regular)`. Избегаем классической ловушки agent-mode, где
backgrounded-апп не показывает screen-recording промпт.

### 1.4 Lifecycle (`AppEnvironment.bootstrap()`)
1. DB ready. 2. `PermissionsStore.refreshAll()` (preflight). 3. `ServerStore.start()` (реальный порт).
4. `RecordingStore.startIfPermittedAndEnabled()`. 5. `PipeScheduler.resume()`. 6. NSWorkspace
sleep/wake/activity observers. Teardown на `willTerminate`: stop capture (flush last audio), server.stop,
cancel pipe timers.

### 1.5 @Observable паттерн
```swift
@Observable @MainActor final class RecordingStore {
    private(set) var isCapturing = false; private(set) var hasScreenTccError = false
    private(set) var screenFrameCount = 0; private(set) var audioChunkCount = 0
    var pauseByAppEnabled = false
    func toggle() { isCapturing ? stop() : start() }
    func refreshCountsFromDB() async { … }   // GRDB ValueObservation, не Timer.publish(1s)
}
```
Заменить `Timer.publish(every:1.0)` → **GRDB `ValueObservation`** (реактивно, ноль polling).

## 2. Онбординг прав

### 2.1 `PermissionChecker` (чистые пробы)
| Право | Проба (без промпта) | Запрос | Deep-link |
|---|---|---|---|
| Screen Recording | `CGPreflightScreenCaptureAccess()` | `CGRequestScreenCaptureAccess()` (+рестарт захвата) | `…?Privacy_ScreenCapture` |
| Accessibility | `AXIsProcessTrusted()` | `AXIsProcessTrustedWithOptions([prompt:true])` | `…?Privacy_Accessibility` |
| Microphone | `AVCaptureDevice.authorizationStatus(.audio)` | `requestAccess(.audio)` | `…?Privacy_Microphone` |
| Speech (вторичное) | `SFSpeechRecognizer.authorizationStatus()` | — | — |
```swift
struct PermissionState: Sendable {
    enum Status { case granted, denied, notDetermined, needsRestart }
    var screenRecording, accessibility, microphone, speech: Status
}
```

### 2.2 Проблема `-3801` правильно
`-3801` = SCStreamError «user declined TCC». Ключевое: **после выдачи права процесс надо перезапустить**
для SCK (исторически relaunch; на macOS 15+ часто хватает `CGRequestScreenCaptureAccess` + пересоздание
`SCStream`). Статус `.needsRestart` (preflight==true, но last start вернул -3801) → кнопки
**«Перезапустить захват»** (teardown+recreate SCStream) и **«Перезапустить Slishu»** (relaunch).
Поллинг 1.5с (TCC без KVO); на grant — авто-advance + рестарт захвата для screen.

### 2.3 Flow (первый запуск)
`OnboardingFlow` при `didCompleteOnboarding==false` ИЛИ любое право denied/notDetermined. Шаги:
Welcome → Screen Recording → Accessibility («чтобы читать текст без OCR, точнее и легче для батареи») →
Microphone (опц., можно «только экран») → Done (активный порт + «начать запись»). Переиспользуемый
`PermissionRow` (общий с Settings — не разъезжаются).

### 2.4 Диагностика в Settings
Постоянная панель «Разрешения и диагностика»: те же rows + SCK live error code, last -3801 timestamp,
«Сбросить TCC» (`tccutil reset`, за confirm), «Повторить проверку».

## 3. Timeline + Time-Travel Scrubber (keystone)

### 3.1 `TimelineStore` — ось ВРЕМЯ, не индекс массива
Старый грузил всю историю в массив (HEIC каждые 2с ≈ 1.5–3ГБ/день) — не масштабируется.
```swift
@Observable @MainActor final class TimelineStore {
    var range: ClosedRange<Date>; var cursor: Date; var zoom: Zoom = .hour   // .day/.hour/.tenMin
    private(set) var lane: [FrameTick]; private(set) var current: FrameDetail?
    private(set) var isPlaying = false; var playbackRate: Double = 1.0        // 1×/2×/4×
    func loadRange(_ r: ClosedRange<Date>) async
    func seek(to t: Date) async; func step(_ dir: Step) async; func play()/pause()
}
struct FrameTick: Identifiable, Sendable { let id: Int64; let t: Date; let appId: Int64? }  // ~32 байта
struct FrameDetail: Sendable { let id: Int64; let t: Date; let imageURL: URL
    let appName, bundleId: String; let windowTitle, url: String?; let ocrText: String; let source: TextSource }
```

### 3.2 Что нужно от data/REST агентов
1. Range ticks: `GET /timeline?from&to&bucket=60` → ticks + buckets (count + topApp). In-process:
   `SELECT id, ts, app_id FROM screen_captures WHERE ts BETWEEN ? AND ? ORDER BY ts`.
2. Frame at instant: `GET /frame?at=<iso>` → nearest ≤ at + FrameDetail. In-process:
   `WHERE ts <= ? ORDER BY ts DESC LIMIT 1` + join apps + FTS text.
3. Media bytes: `GET /media/<file>` (есть) или in-process `NSImage(contentsOf:)` напрямую.
**Запрос к data:** добавить `window_title`/`browser_url` в `screen_captures` (миграция), populate в
capture-слое из `frontmostApplication` + AX.

### 3.3 ScrubberView
- **Density strip**: `Canvas`-лента по range. Бар на бакет, высота = число кадров, цвет = доминирующий
  апп (детерминированный из bundleId hash, якоря Indigo/Emerald/Space-Grey). Видно где плотно (встреча,
  кодинг-burst) vs idle.
- **Playhead**: draggable `DragGesture` → `cursor`, `seek` **debounced 60–80мс** на `userInitiated`
  (thumbnail сразу, HEIC+OCR на тик позже).
- **Zoom**: `День/Час/10мин`. **Transport**: play/pause, 1×/2×/4×, step ±1 (`⌥←/→`), «сейчас» (`⇧→`).
  Playback двигает `cursor` на медианную дельту × rate (idle-промежутки промотаются).
- **Crossfade**: `.transition(.opacity)`/`contentTransition(.interpolate)`.

### 3.4 Spotlight-поиск (унифицирован со скруббером)
`SearchStore`: `⌘F`-field, тумблер Полнотекст/Смысл(AI), фильтры app/time/source. **Клик по хиту → `cursor
= result.timestamp`** и переключение в скруббер (поиск и time-travel — одна поверхность, не два экрана).
Запрос к data: расширить `/search` параметрами `apps`/`from`/`to`/`type`.

### 3.5 Миграции (аддитивные, НЕ erase)
**Убрать `eraseDatabaseOnSchemaChange`** (опасно для history-рекордера). `v3_window_url`
(window_title,url), `v4_pipes`, `v5_connections`.

## 4. Pipes — реальный backend

### 4.1 Модель: **(a) markdown+YAML scheduled local-LLM агенты — primary**, JS только опц. escape hatch
Никита ссылается «как у screenpipe» + local LLM (Ollama/MLX). Декларативные cron-таски, дёргающие
локальный REST + local LLM — ложатся на уже построенное, ноль нового рантайма. Инспектируемо/диффабельно/
подписываемо. **JavaScriptCore (option b)** лёгок (~1–2МБ), но даёт sandboxing/security-поверхность и
тяжелее по debug — **не строить в v1**, зарезервировать `kind: script` как точку расширения.
Пайп *потребляет* Connections — чистое разделение секций.

### 4.2 Формат
Папка `~/Library/Application Support/Slishu/Pipes/<id>/`: `pipe.yaml` + `pipe.md` + опц. `icon.png`.
```yaml
id: daily-summary
name: Саммари дня
kind: prompt            # prompt | query
schedule: "0 21 * * *"  # cron
inputs:
  - source: search
    query: "*"
    range: today
    limit: 400
llm: { connection: local-llm, model: llama3.1, promptFile: pipe.md }
output: { connection: obsidian, target: "Daily/{{date}}.md", mode: append }
config:
  - { key: tone, type: enum, options: [краткий, подробный], default: краткий }
permissions: [read_history, call_llm, write_connection]
```

### 4.3 Реестр/хранение
`PipesStore` (@Observable) = папки на диске + таблица `pipes` (runtime state). Config-оверрайды per-pipe
как JSON. **Секреты НЕ здесь** — пайп ссылается на Connection (секрет в Keychain).
```sql
CREATE TABLE pipes(id TEXT PRIMARY KEY, version TEXT, enabled INTEGER, configJson TEXT,
    lastRun DATETIME, nextRun DATETIME, lastStatus TEXT, lastError TEXT, installedAt DATETIME);
CREATE TABLE pipe_runs(id INTEGER PRIMARY KEY AUTOINCREMENT, pipeId TEXT, startedAt DATETIME,
    finishedAt DATETIME, status TEXT, logText TEXT, outputRef TEXT);
```

### 4.4 Исполнение
- **PipeScheduler**: один coordinator, считает `nextRun` из cron (мини-evaluator/DispatchSourceTimer per
  pipe). Fire → `PipeRuntime.run` на background actor.
- **PipeRuntime.run**: resolve inputs (DB/REST) → context → если `kind:prompt` POST в LLM Connection
  (Ollama `/api/generate` / MLX) → output → write в output Connection → `pipe_runs` row.
- **«Запустить сейчас»** для любого пайпа. **Missed-run**: проспал cron → один catch-up на wake, не N раз.

### 4.5 Sandbox/security
Декларативные, не произвольный код. Capability-list (`permissions:` в yaml): нет `write_connection` →
никуда не пишет. Показ caps в install-sheet («будет: читать историю, вызывать local LLM, писать в
Obsidian») — явное согласие. LLM-вызовы только в user-configured Connection endpoints (дефолт local
Ollama `127.0.0.1:11434`), никогда хардкод-облако. Каждый run time-boxed + изолирован в Task; крах →
error row, не роняет capture.

### 4.6 UI
`PipesListView` (glass grid, реальный toggle/статус/nextRun, **рабочая «Настроить»**→`PipeDetailView`).
`PipeDetailView`: рендер `pipe.md`, **schema-driven форма из `config:`** (enum→Picker, string→TextField,
bool→Toggle, connection-ref→Picker совместимых Connections), редактор расписания, «Запустить сейчас»,
live-лог (`pipe_runs.logText`). `PipeInstallSheet`: из bundled examples / «Импортировать папку…» /
будущий registry URL.

### 4.7 Готовые пайпы (вместо 4 mock)
1. **Саммари дня** (prompt, 21:00): сегодняшние OCR+транскрипты → local LLM → append в Obsidian Daily.
2. **Поиск по встречам** (query+prompt): транскрипты где app∈{Zoom,Meet,Slack} → action items →
   Notion/Slack.
3. **Экспорт истории** (query, weekly): диапазон кадров+текста → Markdown/JSON через file Connection (без
   LLM — демо `kind:query`).

## 5. Connections — реальный backend

### 5.1 Таксономия/auth
| Коннектор | Тип | Auth | Egress | Test |
|---|---|---|---|---|
| Obsidian (vault) | FS | путь+bookmark | нет | пишет/удаляет `.slishu-test` |
| Local LLM (Ollama/MLX) | HTTP local | base URL | localhost | `GET /api/tags` |
| Slack | webhook | Incoming Webhook URL (Keychain) | HTTPS | POST тест |
| Notion | API | Internal Integration Token (Keychain) | HTTPS | `GET /v1/users/me` |
| File export | FS | bookmark | нет | write/delete |
**OAuth vs key:** v1 — api-key/token/webhook везде (OAuth тяжёл: redirect URI + loopback listener +
refresh). `ConnectorAuth` enum (`.none/.apiKey/.webhook/.oauth`) — OAuth позже без UI-churn.

### 5.2 Протокол
```swift
protocol Connector: Sendable {
    static var kind: ConnectorKind { get }; var auth: ConnectorAuth { get }
    func test() async throws -> ConnectionHealth        // ok/unauthorized/unreachable/error
    func write(_ payload: ConnectorPayload) async throws
    func query(_ q: ConnectorQuery) async throws -> Data
}
```
Клиенты: ObsidianConnector (FileManager+bookmark), OllamaConnector (URLSession `/api/generate`),
SlackConnector (POST webhook), NotionConnector (Bearer token), FileConnector.

### 5.3 Секреты — Keychain, НЕ UserDefaults
`KeychainStore` (`kSecClassGenericPassword`, `kSecAttrService="com.slishu.SlishuApp"`,
`account=<connectionId>`, `kSecAttrAccessibleAfterFirstUnlock` — для фоновых pipe-runs). API
`set/secret/delete`. DB `connections` хранит только НЕ-секретный конфиг.
```sql
CREATE TABLE connections(id TEXT PRIMARY KEY, kind TEXT, displayName TEXT, configJson TEXT,
    enabled INTEGER, lastTestStatus TEXT, lastTestAt DATETIME);
```

### 5.4 UI
`ConnectionsListView` (реальный health из lastTestStatus, не fake Bool). «Добавить» → kind picker →
`ConnectorConfigSheet` per kind (Obsidian: vault picker; Slack: webhook SecureField + help; Notion: token
SecureField + db id; Ollama: base-URL `127.0.0.1:11434`). Каждый sheet — **«Проверить подключение»**
(`Connector.test()`, inline result). Секреты в `SecureField` → Keychain, не эхо («•••• установлен» /
«Заменить»).

## 6. Settings
1. **Хранилище**: путь (`mediaDirectory`), «Изменить папку…» NSOpenPanel + **security-scoped bookmark**,
   размер на диске (async sum), retention (7/30/90/без + макс GB), `RetentionPruner` (hourly
   DispatchSourceTimer), «Показать в Finder» + DB path.
2. **Транскрипция**: picker MLX(default)/SFSpeech/Whisper.cpp. v1 рабочий — SFSpeech; не-реализованные
   «скоро».
3. **Сервер**: **показ реального активного порта** (`ServerStore.activePort`), base URL, copy, MCP hint,
   рестарт, preferred-port (дефолт `11435`).
4. **Приватность**: опц. **пауза по приложению** (multi-select; frontmost∈set → скип кадра, hook в
   capture перед save) — НЕ блэклист по умолчанию. + smart auto-pause тумблеры.
5. **Запуск при логине**: `SMAppService.mainApp.register()/unregister()`.
6. **О приложении**: AppIcon (Obsidian Acoustic Sphere), версия, «N кадров / M часов аудио».
`SettingsStore`: скаляры в UserDefaults (не-секрет), доступ к папкам — bookmarks, секреты — Keychain.

## 7. Упаковка

### 7.1 project.yml
- `deploymentTarget: "15.0"` (было 14.0). `SWIFT_VERSION: 6.0` + `SWIFT_STRICT_CONCURRENCY: complete`
  (было Swift 5). LSUIElement-handling + Dock-toggle. Usage strings: ScreenCapture (есть), Microphone
  (есть), **+ Speech**, Accessibility (нет формального ключа — документировать в онбординге),
  AppleEvents (если browser-URL через AppleScript). Entitlements файл + `CODE_SIGN_ENTITLEMENTS`.
  CFBundleIconName/AppIcon.

### 7.2 Sandbox: **Hardened Runtime, БЕЗ App Sandbox**
SCK full-display + Accessibility (cross-app AX) фундаментально несовместимы с App Sandbox; локальный TCP
сервер + произвольное хранилище на внешнем SSD тоже. **Hardened Runtime ON, App Sandbox OFF** (так
шипят Rewind/screenpipe-класс). Дистрибуция = Developer ID + **нотаризация** (не MAS — он форсит
sandbox и отклонит категорию).
```
Slishu.entitlements (hardened, non-sandboxed):
  com.apple.security.cs.allow-jit                     YES   (JSC позже)
  com.apple.security.cs.disable-library-validation    YES   (MLX dylibs)
  com.apple.security.device.audio-input               YES   (микрофон)
  com.apple.security.automation.apple-events          YES   (browser URL, опц.)
  # NO com.apple.security.app-sandbox
  # Screen Recording & Accessibility — TCC runtime grants, не entitlements
```

### 7.3 Signing/notarization/login
Developer ID Application, `--options runtime`, embed entitlements. Нотаризация `notarytool` +
`stapler staple`. DMG/zip. Launch at login — `SMAppService.mainApp` (без отдельного helper). AppIcon
`.appiconset` (16→1024) из `workspace/slishu_isolated_icon_*.png` (чистая сфера на белом, 1024²).

## 8. Build / sequencing
1. Shell skeleton (AppEnvironment+stores, NavigationSplitView, MenuBar, lifecycle поверх singletons).
2. Permissions (Checker+Store+онбординг+диагностика; -3801→needsRestart). 3. Timeline/scrubber
(TimelineStore + ScrubberView; DB v3 + range/frame REST). 4. **Connections до Pipes** (KeychainStore,
Connector+5 клиентов, v5, UI+test). 5. Pipes (формат, Engine/Scheduler/Runtime, v4, UI, 3 пайпа).
6. Settings retention/transcription/port/login. 7. Packaging (entitlements, Swift6/macOS15, AppIcon,
sign+notarize).
Запросы к sibling-агентам: (a) миграции v3/v4/v5 + убрать erase; (b) REST `/timeline`,`/frame`,
`q/apps/from/to/type` на `/search`; (c) capture populate `window_title`/`browser_url` + опц. per-app pause.
