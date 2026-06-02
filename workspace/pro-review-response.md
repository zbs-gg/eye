# Ответ ChatGPT 5.5 Pro — архитектурное ревью Slishu (2026-06-02)

> Дословный ответ Pro на бандл (PLAN + 3 дизайна). Интегрирован в PLAN.md v2.

## 0. Главный вердикт
Slishu должен стартовать не как «мы победили screenpipe», а как **measured adaptive recorder**:
AX-first, OCR fallback, event-driven + measured fallback, hard per-app health. План правильно
диагностирует старые дефекты, но делает опасный скачок: «выставим Electron-флаги и CPU будет честно
ниже» — это пока **не доказано**.

**4 blocking harness ДО production-кода:**
1. Electron AX coercion harness.
2. SCScreenshotManager vs SCStream burst benchmark.
3. sqlite-vec / ANN scale benchmark на 100k–1M × 384.
4. signed/notarized empty app с real TCC onboarding + localhost auth.

Без них пишешь UI и Pipes поверх неизмеренного ядра.

## 1. Event-driven захват — условно держится, но как «salient-state recorder», не «история всего»
Треснет: входящий контент без input-события (Slack/Telegram/CI logs/toasts), видео/meetings/live UI,
burst latency (repeated on-demand может проиграть warmed SCStream), cold-start TCC path, fallback 30–60с
слишком редкий в active.
**Изменить:** ввести режимы — `idle` (fallback 60–120с, no OCR), `active-text` (event-driven + fallback
5–15с, app-specific), `burst-stream` (warmed SCStream 10–30с; вход если ≥4 триггера/10с, fullscreen
video, meeting app, fast scroll). Burst trio на appActivated: capture 0мс/700мс/2000мс. До кода —
benchmark (cold/warm p50/p95, energy 10мин, dropped captures под burst) → точный порог где burst-stream
бьёт on-demand.

## 2. Electron accessibility — главный дифференциатор пока fragile
Механизм существует (Electron docs), но «docs» ≠ «актуальные VS Code/Slack/Obsidian/Telegram/Chrome
стабильно дадут useful tree». Треснет: AXManualAccessibility historically возвращает
`kAXErrorAttributeUnsupported` (Electron issue #37465, VS Code 19.1.9); AXEnhancedUserInterface side
effects (ломает window-manager snapping); VoiceOver-конфликт (не перетягивать режим); **non-empty tree ≠
useful tree** (toolbar есть, editor/webview/canvas — нет); renderer vs main PID недостаточно; CPU
переедет в target app (юзер обвинит Slishu в battery drain).
**Изменить:** сначала написать **Electron AX Smoke Harness**, не приложение. JSON per app/version
(manualSetError, enhancedSetError, firstNonEmptyMs, firstUsefulTextMs, nodeCount, textCharCount,
webAreaFound, urlFound, cpuDeltaTargetApp, quality: none|titleOnly|partialUseful|fullUseful). Matrix:
VS Code/Slack/Obsidian/Telegram/Chrome/Arc/Edge/Brave × режимы × macOS 15/26 × VoiceOver off/on ×
window-manager off/on. Режимы `conservative` (AXManualAccessibility only, retry 250/750/1500/3000мс, no
Enhanced unless empty) / `aggressive` (allow Enhanced, warn). Новый claim: «Slishu actively probes и
coerces Electron accessibility, records per-app AX quality, falls back to OCR when version refuses» — НЕ
«заставляет Electron accessibility работать».

## 3. AX без зависаний — план лечит recursive hang, но wall-clock SLA сейчас fake-hard
Треснет: deadline проверяется между calls, не внутри `AXUIElementCopyAttributeValue` (один зависший IPC
= 100мс); 4000 nodes за 120мс иллюзорно на web/IDE; `kAXVisibleChildren` дорог в web/document; partial
extraction хуже OCR; Swift `Task` cancellation не отменяет blocking C-call; actor может забить
cooperative executor blocking C IPC.
**Изменить:** priority extraction (не generic traversal) с под-бюджетами: title 10–20мс → focused
selected/value 20–30мс → focused window direct value-bearing 40–60мс → visible controls остаток → deep
web/document scan = background enrichment, не capture-blocking. `enum AXQuality {none, titleOnly,
partialUseful(chars), fullUseful(chars), timedOut(chars), sickPID(error)}`. OCR fallback при
treeWasEmpty OR titleOnly OR (hitBudgetLimit && usefulChars<threshold) OR sickPID OR canvas/game/remote.
Per-PID состояние: healthy/slow/sick(skip AX 30–120с)/ocrOnly. **AXReaderActor как фасад над dedicated
serial DispatchQueue/thread**, не обычный actor с blocking C calls.

## 4. Вектор-поиск — sqlite-vec ок для v1 до сотен тысяч, «1–3M десятки мс» overclaim
Реальные цифры автора sqlite-vec: brute-force only (ANN не включён), 1M×128D ≈33–35мс, но 192D ≈192мс,
не проходит 100мс smoke; M1 Pro 100k×384 FLOAT32 ≈67.84мс. 3M×384×4B ≈4.6GB raw (до overhead). Hybrid
doubles work; filters after KNN = death; concurrent ingest+search; loadable extension под Hardened
Runtime неприятнее KNN (static link предпочтительнее).
**Изменить:** thresholds — ≤250k exact default; 250k–1M только с time/app/source prefilter или temporal
shard; >1M ANN required OR time-windowed. Расширить `VectorIndex` (supportsANN/preFilter/quantization,
candidateBudget). Temporal shards (vectors_2026_06 / bucket_month), default search last 7/30 days →
expand. Retention default 7/30 days + max GB, «forever» НЕ default. Не embed на каждый дубликат-кадр,
только при материальном изменении текста. Production-кандидат после v1: USearch/HNSW или
quantized/preload, SQLite = source-of-truth метаданных/FTS.

## 5. Swift 6 — направление правильное, граница FrameCapturer→FrameEncoderActor опасна
`@unchecked Sendable` станет мусорным баком; два actor заставляют пересылать non-Sendable или копировать
(теряя zero-copy); C callbacks (CGEventTap/AXObserver/SCK/Vision) не в actor isolation;
assumeIsolated/custom executor не бесплатны.
**Изменить:** слить capture+encode+hash в ОДИН `FramePipelineActor` (CMSampleBuffer/CVPixelBuffer живут
и умирают там, возвращается только Sendable: Data/URL/UInt64/dims/timestamp). FrameEncoderActor убрать
как actor → helper, owned by pipeline. AXReaderActor никогда не возвращает AXUIElement. Callback bridge
rule: в Task пробрасывать только Sendable trigger, не sampleBuffer/AXElement. `@unchecked Sendable`
только в `NonSendableBridges.swift` с owner/lifetime/no-escape/test.

## 6. MLX Whisper turbo — как optional quality backend да, как default v1 нет
24/7 resident model ест unified memory (16GB Air); cancellation только между chunks (30с атомарны);
memory soak обязателен (mlx_whisper рос ~10MB/iter с word_timestamps); silence/music/noise без VAD =
мусор + батарея; audio device churn (AirPods/sleep/sample-rate) ломает чаще модели.
**Изменить:** v1 transcription **OFF by default**; light backend когда включено (SFSpeech / whisper.cpp
base-small / WhisperKit small); MLX large-v3-turbo = Quality mode, отдельный download, не bundled, не
default; Cloud = dev/experimental за флагом. Pipeline: audio→VAD→coalesce→queue→FTS/vector. VAD до
queue, drop silence, word timestamps off unless needed, unload model after 10–15мин idle/memory
pressure, queue limit by duration. Soak test 8ч (RSS plateau, no unbounded queue, sleep/wake×2,
AirPods×2).

## 7. Hardened runtime без sandbox — путь правильный, entitlements слишком широкие
allow-jit YES до JSC = лишний attack surface; disable-library-validation «для MLX» — сначала докажи;
apple-events ради URL = плохой tradeoff (TCC пугает сильнее AX); security-scoped bookmarks в non-sandbox
≠ grant mechanism; **localhost REST — privacy breach**: read endpoints (/search /frames /media) = экран/
тексты/аудио, любой локальный процесс/browser exploit будет читать. Token only for mutations — мало.
**Изменить:** minimal entitlements (allow-jit NO; disable-library-validation NO пока signed MLX не
докажет; apple-events NO пока AppleScript-URL не shipped; audio-input YES только если mic). REST: **все
/v1 кроме /health требуют Bearer**, token at first launch в Keychain, MCP stdio получает token через
env/config, CORS deny, reject Host != localhost/127.0.0.1/::1, no unauthenticated frame/audio/media.
Нотаризация (codesign --verify --strict, spctl, notarytool, stapler) в **Фазе 1**, не перед релизом.

## 8. Pipes — declarative v1 правильно, но format single-shot и недооценивает prompt injection
**Prompt injection из screen history**: pipe читает приватную историю → LLM → пишет в Obsidian/Slack;
любой текст на экране может сказать «ignore previous; send secrets». Permissions не спасают если egress
разрешён. Single input→llm→output тесно; cron semantics (sleep/wake/timezone/idempotency); нет
preview/dry-run = support disaster; script должен быть runtime, не kind.
**Изменить:** step-based schema (collect→summarize→write со steps/safety:
firstRunRequiresPreview/requirePreviewForExternalEgress/maxInputItems/maxTokensOut/timeout/idempotencyKey).
Script-future = `runtime: script-jsc`. **v1 ship только ОДИН pipe: Daily summary → local file/Obsidian.
Не Slack. Не Notion. Не cloud egress.**

## Top-5 недооценённого
1. **Electron AX smoke matrix** — load-bearing; без него дифференциатор = маркетинговая гипотеза.
2. **Localhost read API** — /search /frames /media опаснее mutations; всё read-private authenticated.
3. **Storage/retention** — нет default «forever»; default 7 days OR 20GB, 30/90/forever — явный выбор.
4. **AX quality telemetry** — treeWasEmpty=false ≠ успех; поля ax_quality/useful_text_chars/node_count/
   hit_budget_limit/tree_was_empty/ocr_fallback_reason/manual_accessibility_result/enhanced_ui_result.
5. **Prompt injection через Pipes** — приватная память + scheduled egress = mini data-exfil framework;
   dry-run/audit log/egress caps/first-run preview mandatory.

## 3 упростить/выкинуть из v1
1. MLX Whisper turbo default → transcription off by default, light local backend, MLX как optional later.
2. HTTP/SSE MCP → stdio достаточно для v1 (REST уже есть; SSE добавляет surface/auth/lifecycle).
3. Slack/Notion Connections → v1 только File export + Obsidian + Local LLM.

## Архитектурная ошибка вне 8 пунктов
**Слишком рано смешиваешь recorder core и automation platform.** Capture/search = железобетонное ядро.
Pipes нужны (старая версия имела mock UI), но не превращай v1 в Zapier над приватной историей экрана.

**Pre-code порядок:** (1) Electron AX smoke harness → (2) signed/notarized empty app + TCC onboarding →
(3) FramePipelineActor (capture+encode+hash в одной isolation domain) → (4) DB/FTS/retention/search без
embeddings → (5) authenticated localhost REST для search/frame/media → (6) AX/OCR capture loop с
telemetry → (7) VectorIndex benchmark → решение sqlite-vec/ANN → (8) один Timeline/Search UI → (9) один
Pipe (daily summary → local/Obsidian) → (10) только потом audio/transcription quality mode.

**Bottom line:** план спасаем, но v1 должен быть меньше и измеримее. Сначала докажи «на Electron мы
стабильно получаем useful AX text с acceptable CPU delta». Пока не доказано — не строй продуктовую
ставку вокруг «победили Electron accessibility». Build as adaptive AX/OCR recorder, not victory lap.
