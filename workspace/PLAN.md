# Slishu — план пересборки (v2, после ревью ChatGPT 5.5 Pro)

## Context

**Что это.** Slishu — лёгкий локальный «вечная память»-рекордер для macOS: история активности на компе
(экран + accessibility-текст + аудио), индексируется и отдаётся в LAM/LLM через REST + MCP. 100%
локально, приватно. Цель — быть легче и быстрее screenpipe на Mac, нативный premium-интерфейс.

**Почему пересобираем.** Версию от Gemini переписываем с нуля: Pipes/Connections — заглушки;
приложение зависает (рекурсивный AX без таймаута); race conditions; утечки; `try!` в MCP.

**Поправленная посылка.** screenpipe тоже accessibility-first, но на Electron (VS Code/Obsidian/Slack/
Telegram/Chrome) у него AX-дерево пустое → OCR → ~147% CPU. Дифференциатор Slishu: заставить AX
работать на Electron + event-driven + нативный SwiftUI.

**Решения Никиты.** Чистая переписка · свой чистый REST + MCP · MLX Whisper turbo + сменный бэкенд ·
Pro-ревью архитектуры (сделано).

**Целевая платформа.** Swift 6 (strict concurrency `complete`), SwiftUI, deployment target macOS 15.0,
пользователь на macOS 26 Tahoe.

---

## ⚠️ Вердикт Pro (главное изменение v2)

Pro: план держится как **инженерный скелет, но НЕ как v1 production architecture**. Slishu должен
стартовать как **measured adaptive recorder** (AX-first, OCR fallback, event-driven + measured fallback,
hard per-app health), а НЕ как «победили Electron accessibility». Главная архитектурная ошибка плана v1:
**слишком рано смешивает recorder-core и automation-платформу**. Сначала железобетонное ядро
capture/search, потом Pipes.

**4 BLOCKING harness ДО любого production-кода** (иначе строим UI/Pipes поверх неизмеренного ядра):
1. **Electron AX coercion harness** — доказать на реальной машине, что флаги дают *useful* tree.
2. **SCScreenshotManager vs SCStream burst benchmark** — найти порог, где warmed-stream бьёт on-demand.
3. **sqlite-vec scale benchmark** на 100k–1M × 384 — измерить реальную латентность, решить sqlite-vec/ANN.
4. **signed/notarized empty app** + real TCC onboarding + authenticated localhost — нотаризация ломает
   skeleton в Фазе 1, не 40k строк позже.

---

## ✅ Результат harness 1a + ресёрч (2026-06-03) — ВЕРДИКТ ПО СТАВКЕ

Прогон на реальной машине (macOS 26) + 3-агентный ресёрч (`workspace/research-ax-extraction.md`):

**«AX-first побеждает на Electron» — НЕВЕРНО как абсолют. Реальная рамка: adaptive AX-first +
OCR-fallback, решается per-app в рантайме по content-quality.** Это НЕ провал — это defensible
дифференциация: screenpipe делает walk-once → преждевременный OCR → 147% CPU на Obsidian; мы — нет.

**Три класса приложений (эмпирически + архитектурно подтверждено):**
1. **AX работает** (большая доля экрана): нативные AppKit/SwiftUI (iTerm2 49k, Mail, Preview), Electron
   на DOM-редакторах CodeMirror/Monaco/ProseMirror/Lexical (Obsidian 6k, VS Code/Codex 34k), браузеры
   Chrome/Edge/Arc (с retry-walk), Safari (дерево по умолчанию), Flutter.
2. **OCR-only навсегда** (AX физически не отдаёт): GPU-рендереры (Zed/GPUI, Warp, вероятно
   Alacritty/kitty/WezTerm/Ghostty), canvas (Figma, Slack Canvas), игры, `<canvas>` внутри Electron.
3. **Per-app лотерея**: Notion=0 (custom widgets + DOM-virtualization, не пофиксить), Slack
   (virtualized), Claude desktop=67 (React без text-роли).

**Что фиксило мои «148 символов Chrome» / низкий content:** дерево строится лениво/асинхронно; timeout
200мс убивал обход до AXWebArea. v3 (timeout 50мс + budget 2с + retry 250/750/1500/3000) это чинит.
Chrome web-текст доступен через **main PID** (renderer не нужен) → AXWebArea → AXGroup → AXStaticText.AXValue.

**Загрязнение подтверждено:** на машине Никиты screenpipe/Limitless/superwhisper/krisp/Hammerspoon
глобально включают a11y → «дерево без флага». На чистой машине нужен наш флаг+retry → **это и есть наша
ценность**.

**Наша дифференциация vs screenpipe (в архитектуру):**
(1) retry-walk после флага · (2) content-quality gate (по contentChars, не flag-success/суммарному) ·
(3) **per-app capability table**: seed эвристикой editor-engine (CodeMirror/Monaco→AX; canvas/Notion→OCR),
confirmed empirically, **invalidated on app-update** · (4) resolve main vs renderer PID + walk AXWebArea ·
(5) честный OCR-tier для GPU/canvas/virtualized.

**Следствие для продукта:** Slishu = «AX где app даёт semantic editor, OCR elsewhere, decided per-app at
runtime». OCR — НЕ редкий fallback, а равноправный второй путь для целого класса (GPU/canvas/Notion).
Это меняет позиционирование (не «победили Electron»), но даёт реалистичную защитимую нишу.

---

## ✅ Результат harness 1c — sqlite-vec scale (2026-06-03)

Прогон на 384-dim (`harness/sqlite-vec-bench`, static-linked, `workspace/vec-bench.json`):

| N | plain p95 | ts-filter p95 | вставка | размер |
|---|---|---|---|---|
| 100k | **37ms** ✅ | 24ms | 94k/с | 0.16GB |
| 500k | **180ms** ❌ | 118ms | 99k/с | 0.79GB |
| 1M | **369ms** ❌ | 240ms | 96k/с | 1.58GB |

**Выводы (Pro был прав — «1M за десятки мс» overclaim):**
1. **Статическая линковка sqlite-vec в Swift работает** (v0.1.9 + sqlite 3.51.0, `-DSQLITE_CORE`,
   линк с системным libsqlite3) → **риск нотаризации закрыт**, loadable extension не нужен.
2. **Латентность линейна** (~0.37мс/1000 векторов brute-force): sqlite-vec exact годится **до
   ~100–150k** (p95<50мс). Дальше >150мс — не интерактивно.
3. **Prefilter (`ts>`/`app_id=`) ускоряет ~1.5×, но НЕ спасает** на масштабе (1M ts-filter=240мс).
   Опасение Pro «filter after KNN = death» — не подтвердилось (фильтр быстрее plain), но и не панацея.
4. **Вывод по стратегии:** одной большой vec0-таблицы недостаточно. Нужны **temporal shards**
   (помесячно): default-поиск = текущий месяц/30 дней (малый шард → 37мс), полная история — expand
   (медленнее, реже). **+ embed НЕ на каждый кадр** (только при материальном изменении текста, Pro) →
   радикально меньше векторов/месяц → шард остаётся в «быстрой» зоне.
5. **Размер критичен:** 1M=1.6GB, 3M≈4.7GB → retention default 7д/20GB обязателен (уже в плане).
6. Опции если понадобится: int8-квантизация (vec0, ~4× скорость и размер), или ANN-бэкенд
   (USearch/HNSW) при истории >1M — за `VectorIndex` протоколом (уже спроектирован сменным).

---

## Жёсткий scope v1 (что сужено по Pro)

**В v1:**
- Adaptive AX/OCR recorder с режимами (idle/active-text/burst-stream) и per-app health-телеметрией.
- DB/FTS/retention/search **без embeddings вначале** (embeddings добавляем после benchmark'а).
- Authenticated localhost REST (**все /v1 кроме /health требуют Bearer**, токен в Keychain).
- MCP **только stdio** (`Slishu --mcp`). HTTP/SSE MCP отложен.
- Один Timeline/Search UI.
- **Один Pipe**: daily summary → локальный файл / Obsidian. Никакого Slack/Notion/cloud egress.
- Connections v1: только **File export + Obsidian + Local LLM**.
- Транскрипция **ON с light-движком + VAD** (выбор Никиты — «записывать всё»): дефолт light backend
  (SFSpeech / WhisperKit small / whisper.cpp small), VAD до очереди (не транскрайбить тишину/музыку),
  unload-on-idle. MLX Whisper turbo — отдельный optional **Quality mode**, не bundled. Cloud — за флагом.

**Отложено за v1:** Slack/Notion коннекторы · HTTP/SSE MCP · MLX turbo как default · semantic vector на
миллионах (сначала benchmark + temporal shards) · multi-step pipe-маркетплейс · JS-плагины.

---

## Целевая архитектура (с правками Pro)

Принцип: **акторы Swift 6, Sendable на границах, один логический writer**. Не-Sendable
(`CVPixelBuffer`/`CMSampleBuffer`/`AXUIElement`/`VNRequest`) живут и умирают внутри одного актора.

### A. Ядро захвата — adaptive, не «event-driven победа»

- **Режимы захвата** (вместо чистого event-driven):
  - `idle`: fallback 60–120с, OCR только manual.
  - `active-text`: event-driven + fallback 5–15с, app-specific (IDE/chat/browser 5–10с, docs/static
    15–30с).
  - `burst-stream`: warmed `SCStream` 10–30с. Вход: ≥4 триггера/10с, fullscreen video, meeting-app,
    fast scroll, повторные захваты. **Это закрывает дыру «входящий контент без input-события»**
    (Slack/Telegram/CI logs/toasts/meetings) — чистый on-demand их теряет.
- **Burst trio на appActivated**: capture 0мс / 700мс / 2000мс (Electron/web AX-дерево и визуал часто
  не готовы к первому immediate кадру).
- **FramePipelineActor (ОДИН actor)** — capture + encode + hash в одной isolation domain. `SCStream`/
  `SCScreenshotManager` + `CMSampleBuffer`/`CVPixelBuffer` живут и умирают здесь; наружу только Sendable
  (`Data`/`URL`/`UInt64` phash/dims/timestamp). Переиспользуемый `CIContext(mtlDevice:)`, HEIC HW-кодек,
  perceptual-hash дедуп (`UInt64`, не буфер). **FrameEncoderActor как отдельный actor — убран** (Pro:
  граница capture→encode = мина для Swift 6 / zero-copy).
- **AXReaderActor — фасад над dedicated serial DispatchQueue/thread** (НЕ обычный actor с blocking C
  calls — иначе забьём cooperative executor). Никогда не возвращает `AXUIElement`, только `AXExtraction`
  (Sendable). **Priority extraction** (не generic traversal) под общим бюджетом 120мс:
  title 10–20мс → focused selected/value 20–30мс → focused window direct value-bearing 40–60мс →
  visible controls остаток → deep web/document scan = background enrichment, не capture-blocking.
  `AXUIElementSetMessagingTimeout` 100мс, итеративный стек, отмена по `generation`. Помнить: Swift
  cancellation НЕ прерывает blocking C-call — wall-clock budget это soft-SLA, не hard.
- **AXQuality модель** (вместо healthy/empty/ocrOnly):
  `enum AXQuality { none, titleOnly, partialUseful(chars), fullUseful(chars), timedOut(chars),
  sickPID(error) }`. Per-PID health: `healthy / slow (focused-only) / sick (skip AX 30–120с) / ocrOnly`.
- **Electron coercion — adaptive probe, не ставка** (подтверждено harness 1a + ресёрчем). Режимы
  `conservative` (AXManualAccessibility, retry 250/750/1500/3000мс, Enhanced только если empty) /
  `aggressive`. **Не перетягивать VoiceOver.** `AXManualAccessibility=attributeUnsupported` —
  бесполезный gate (Electron #37465), решать по **contentChars после retry-walk**, не по флагу. Walk
  into AXWebArea; lazy async build — первый обход пустой, re-walk обязателен.
- **Per-app capability table** (ключевая дифференциация): кэш `bundleID → {axViable, contentClass,
  lastChecked, appVersion}`. Seed эвристикой editor-engine (CodeMirror/Monaco/ProseMirror→AX;
  canvas/Notion/Slack/Claude-desktop→OCR; GPU-apps Zed/Warp→OCR), confirmed empirically на первом
  захвате, **invalidated при смене версии приложения**. Не «Electron = один bucket».
- **OCR-tier (равноправный, не редкий fallback)**: GPU-рендереры (Zed/GPUI, Warp, Alacritty/kitty/
  WezTerm/Ghostty), canvas (Figma, Slack Canvas), игры, virtualized/custom Electron (Notion, Slack,
  Claude desktop). Для них AX не пытаемся (по capability-кэшу) → сразу Vision OCR. Гейт переключения:
  AX content ≈ 0 при визуально-текстовом окне.
- **OCR fallback** (Vision, native async `RecognizeTextRequest` 15+, ru+en, ANE, downscale через Metal,
  cancellable) при: `treeWasEmpty | titleOnly | (hitBudgetLimit && usefulChars<threshold) | sickPID |
  canvas/game/remote`.
- **Telemetry на каждый capture** (доказать AX-first): `ax_quality, useful_text_chars, node_count,
  hit_budget_limit, tree_was_empty, ocr_fallback_reason, manual_accessibility_result,
  enhanced_ui_result`.
- **Smart pause** emergent (нет событий = нет захвата) + явный teardown на lock/sleep.

### B. Данные + поиск — ядро БЕЗ embeddings вначале

- **Схема GRDB v1**: `apps`, `screen_captures` (ts epoch-ms, app_id, window_title, browser_url,
  monitor_id, relative_path, w/h, bytes, **ax_quality + telemetry-поля**), `text_blocks` (source
  ax|ocr, text, confidence, bbox?), `audio_captures`, `transcriptions`. `DatabasePool`+WAL+PRAGMA.
  **FTS5 external-content** с триггерами ai/ad/au (без декартова бага). Убрать
  `eraseDatabaseOnSchemaChange`.
- **Retention с первого дня**: default **7 дней OR 20 GB** (НЕ «forever»; 30/90/forever — явный выбор
  юзера). `RetentionManager` (actor): прунинг по дням И размеру, каскад + orphan-sweep + FTS optimize +
  wal_checkpoint, батчами. Релокация через security-scoped bookmark.
- **Embeddings — ПОСЛЕ benchmark'а (Шаг 1c harness)**. `VectorIndex` протокол расширенный:
  `upsert/delete/search(query, filters, limit, candidateBudget)`, `supportsANN/supportsPreFilter/
  supportsQuantization`. Thresholds: ≤250k exact (sqlite-vec); 250k–1M только с time/app/source
  prefilter или temporal shard; >1M — ANN required OR time-windowed. **Temporal shards** (bucket_month),
  default search last 7/30 дней → expand on demand. **Static link sqlite-vec** (не loadable extension
  под Hardened Runtime). Fallback `AccelerateBruteForceIndex`. Не embed на каждый дубль-кадр — только
  при материальном изменении текста. Эмбеддинги: старт NLEmbedding (нулевой вес) → multilingual-e5-small
  via MLX как опция. Гибрид FTS+vector через RRF (k≈60) — после того как vector доказан.
- **IngestService (actor)** — единственный writer.

### C. REST + MCP — security-first

- **FlyingFox**, Codable DTO, динамический порт корректно (различать EADDRINUSE; дефолт не 8080;
  активный порт в `~/Library/Application Support/Slishu/port`). Bind только `127.0.0.1`.
- **Auth на ВСЁ кроме /health** (правка Pro — главная): `/search`, `/frames`, `/media`, `/timeline`,
  `/stats`, мутации — все требуют `Authorization: Bearer`. Токен генерится at first launch, хранится в
  **Keychain**. **Reject Host != localhost/127.0.0.1/::1**, CORS deny by default. Никаких
  unauthenticated frame/audio/media reads (это экран/тексты/аудио — основная ценность и риск).
  Path-traversal hardening (числовой id→lookup, regex на filename, resolvedSymlinks+pathComponents).
- **MCP только stdio** в v1 (`Slishu --mcp`), официальный Swift SDK (запинить ревизию), без `try!`.
  stdio получает токен через env/config. Tools: search_history, get_timeline, get_context_at,
  get_status, toggle_recording. **HTTP/SSE MCP отложен.**

### D. Транскрипция — ON с light-движком (выбор Никиты, не OFF как у Pro)

- `TranscriptionBackend` протокол (async, cancellable, progress). **v1 ON, дефолт light backend**
  (SFSpeech / whisper.cpp small / WhisperKit small). **MLX large-v3-turbo = optional Quality mode**
  (отдельный download, не bundled). Cloud — за флагом, dev only. Pro советовал OFF by default ради
  RAM/thermal — Никита хочет «записывать всё», поэтому ON, но риск гасим: light-дефолт + VAD +
  unload-on-idle + soak test (а не резидентный turbo 24/7).
- Pipeline: audio → **VAD** → coalesce → queue → транскрипт → FTS/vector. VAD до очереди (drop silence/
  music), word timestamps off unless needed, **unload model after 10–15мин idle / memory pressure**,
  queue limit by duration. Soak test 8ч обязателен (RSS plateau, no unbounded queue, sleep/wake×2,
  AirPods×2). `TranscriptionService` (actor).

### E. UI / оболочка

- App shell: `@main` `Window(id:"main")` + `MenuBarExtra(.window)`, корень `@Observable
  AppEnvironment`. Счётчики через GRDB `ValueObservation` (не Timer.publish(1s)). LSUIElement=NO +
  тумблер Dock.
- **Онбординг прав** (Шаг 1d harness): `PermissionChecker` (Screen
  `CGPreflightScreenCaptureAccess`, Accessibility `AXIsProcessTrusted`, Mic, Speech). `-3801` →
  `.needsRestart` (happy path, не edge): кнопки «Перезапустить захват»/«Перезапустить Slishu». Поллинг
  1.5с.
- **Timeline + scrubber**: `TimelineStore` ось-время (не индекс массива). Canvas density-strip, debounced
  seek 60–80мс, zoom День/Час/10мин, play/pause 1×/2×/4×, crossfade. **Spotlight унифицирован со
  скруббером** (клик по хиту → playhead). Показывать источник (AX/OCR) и ax_quality.
- **Pipes — step-based, один pipe в v1.** Schema со steps (collect→summarize→write) + `safety`
  (firstRunRequiresPreview, requirePreviewForExternalEgress, maxInputItems, maxTokensOut, timeout,
  idempotencyKey). **Prompt-injection защита**: pipe читает приватную историю → LLM → egress; first-run
  preview/dry-run обязателен, audit log, egress caps. Script-future = `runtime: script-jsc` (не сейчас).
  **v1 ship: Daily summary → local file/Obsidian.** Не Slack/Notion/cloud.
- **Connections v1**: File export, Obsidian (vault bookmark), Local LLM (Ollama/MLX localhost). Секреты
  в **Keychain**. `Connector.test()`. Slack/Notion — отложены.
- **Settings**: хранилище (путь+bookmark, размер, retention 7/20GB default), транскрипция (OFF default,
  light/MLX), сервер (реальный порт), приватность (опц. пауза по приложению — не блэклист), запуск при
  логине (`SMAppService`), about.
- **Упаковка**: **Hardened Runtime БЕЗ App Sandbox**. **Минимальные entitlements** (правка Pro):
  `allow-jit NO`, `disable-library-validation NO` (пока signed MLX не докажет необходимость),
  `automation.apple-events NO` (пока AppleScript-URL не shipped), `device.audio-input YES` только если
  mic включён. Developer ID + нотаризация **в Фазе 1**.

---

## Pre-code порядок (по Pro) — заменяет старые фазы

**Шаг 0 — Pro-ревью.** ✅ Сделано (`workspace/pro-review-response.md`).

**Шаг 1 — 4 BLOCKING harness** (отдельные мелкие программы/скрипты, НЕ приложение):
- **1a. Electron AX smoke harness** — JSON-матрица per app/version (manualSetError, enhancedSetError,
  firstNonEmptyMs, firstUsefulTextMs, nodeCount, textCharCount, webAreaFound, urlFound,
  cpuDeltaTargetApp, quality). Apps: VS Code/Slack/Obsidian/Telegram/Chrome/Arc/Edge/Brave × режимы ×
  macOS 15/26 × VoiceOver off/on × window-manager off/on. **Решает, держится ли продуктовая ставка.**
- **1b. SCScreenshotManager vs SCStream burst benchmark** — cold/warm p50/p95, energy 10мин, dropped
  captures под burst → точный порог burst-stream.
- **1c. sqlite-vec scale benchmark** 100k–1M × 384 (static-linked), с prefilter и без, concurrent
  ingest+search → решение sqlite-vec/ANN/temporal-shard.
- **1d. signed/notarized empty app** + TCC onboarding + authenticated localhost (codesign --verify
  --strict, spctl, notarytool, stapler в CI).

**Шаг 2 — ядро (после harness'ов, с учётом их цифр):**
2. signed/notarized skeleton + TCC onboarding (из 1d).
3. **FramePipelineActor** (capture+encode+hash в одной isolation domain).
4. DB/FTS/retention/search **без embeddings**.
5. **Authenticated localhost REST** для search/frame/media.
6. AX/OCR capture loop с **telemetry** (режимы + AXQuality + per-PID health).
7. **VectorIndex benchmark** (из 1c) → sqlite-vec/ANN решение → embeddings + hybrid.
8. Один Timeline/Search UI.
9. Один Pipe: daily summary → local file/Obsidian (step-based + preview).
10. Только потом audio/transcription (light default, MLX опц., VAD, soak test).

После каждой фазы: `xcodebuild` зелёный + `post-commit-verifier` на нетривиальных коммитах. Бранч не main.

---

## Verification (end-to-end)
- **Harness 1a**: на реальной машине Никиты (macOS 26, его VS Code/Obsidian/Slack/Telegram/Chrome) —
  получить JSON-матрицу AX-quality. Критерий продолжения: на большинстве его Electron-аппов quality ≥
  partialUseful с приемлемым cpuDeltaTargetApp. Иначе — пересмотреть продуктовую ставку.
- **Harness 1b/1c**: цифры порога burst-stream и латентности vector → фиксируются в плане.
- **Harness 1d**: `spctl -a -vvv -t exec Slishu.app` проходит; localhost без токена → 401.
- **Захват не виснет**: Obsidian/VS Code/Slack в фокусе → текст из AX (`text_blocks.source='ax'`), CPU
  idle ≈ 0, Electron — единицы %, не 147%. Instruments: нет роста RSS за час.
- **Права**: онбординг; отозвать Screen Recording → `.needsRestart` + рабочий рестарт.
- **REST security**: `curl /v1/search` без Bearer → 401; с чужим Host → reject.
- **Поиск**: ru-запрос по en-контенту через semantic (после Шага 7); FTS точные строки.
- **Timeline**: скруббер плавно, кадр+текст+app/url, play идёт по времени.
- **Pipe**: «Запустить сейчас» daily summary → preview → запись в Obsidian; audit log.
- **Прунинг**: лимит 7д/20GB → каскадное удаление + orphan-sweep.
- **Транскрипция** (если включена): soak 8ч, RSS plateau.

---

## Главные риски (обновлено)
1. **Electron AX ставка не доказана** — harness 1a первым; claim «adaptive», не «победа».
2. **AX wall-clock = soft-SLA** (blocking C-call); priority extraction + dedicated thread + messaging
   timeout; partial хуже OCR — gate по AXQuality.
3. **Vector overclaim на 1–3M** — thresholds + temporal shards + retention default; static-link sqlite-vec.
4. **Swift 6 граница capture→encode** — один FramePipelineActor; `@unchecked Sendable` только в
   NonSendableBridges.swift.
5. **MLX 24/7 memory/thermal** — не default; VAD; unload on idle; soak test.
6. **Localhost read API = privacy breach** — auth на всё кроме /health; Host-check; Keychain token.
7. **Prompt injection через Pipes** — один pipe, local-only egress, first-run preview, audit, caps.
8. **Hardened-runtime/нотаризация** — минимальные entitlements; нотаризация в Фазе 1.
9. **Recorder-core vs automation смешение** — сначала ядро, Pipes последними.

---

## Артефакты
- `workspace/PLAN.md` (этот файл, v2) · `workspace/pro-review-response.md` (ответ Pro) ·
  `workspace/pro-bundle.md` + `pro-prompt.txt` (бандл) · `workspace/design/01..03.md` (исходные дизайны
  — частично переопределены правками Pro выше).

## Заметка
- Сохранить project-memory о Slishu (видение, развилки, вердикт Pro, v1-scope).
