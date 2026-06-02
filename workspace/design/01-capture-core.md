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
