import Foundation
import AppKit
import CoreGraphics

/// Оркестратор захвата (@MainActor — владеет observer'ами/таймером, делает только debounce+dispatch).
/// Event-driven по смене активного приложения + active-tick fallback. Smart-pause (lock/sleep/idle),
/// per-app capability cache (GPU/canvas → OCR-only, не дёргаем AX впустую). Тяжёлая работа — на акторах.
@MainActor
final class CaptureCoordinator {
    private enum CaptureClass { case unknown, axViable, ocrOnly }

    /// Известные GPU/canvas-приложения (план: «OCR-only навсегда»). Остальное — обучается per-app.
    private static let knownOCROnly: Set<String> = [
        "dev.zed.Zed", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "net.kovidgoyal.kitty", "com.mitchellh.ghostty", "com.github.wez.wezterm",
        "io.alacritty", "org.alacritty", "com.figma.Desktop",
    ]

    private let ingest: IngestService
    private let config: CaptureConfig
    private let axReader: AXReader
    private let pipeline: FramePipeline

    private(set) var isRunning = false
    private var suspended = false              // lock/sleep
    private var tickTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var cycleTask: Task<Void, Never>?
    private var pendingCycle = false

    private var capability: [String: CaptureClass] = [:]
    private var emptyStreak: [String: Int] = [:]
    private var lastContentText: [String: String] = [:]
    private var sckFailureStreak = 0

    var onFrame: (@MainActor () -> Void)?
    /// N SCK-отказов подряд при выданном праве (классика -3801: TCC требует перезапуск процесса) —
    /// поднять наверх, иначе горит «Запись идёт» при нуле кадров.
    var onCaptureBroken: (@MainActor () -> Void)?
    /// Захват восстановился после отказов (транзиентный noDisplay при wake/смене мониторов) — снять
    /// needsRestart, иначе односторонний ratchet навсегда блокирует запись ложным «Нет прав».
    var onCaptureRecovered: (@MainActor () -> Void)?
    /// Heartbeat: цикл прошёл штатно (включая дедуп и idle-skip) — для «захват жив» в UI.
    var onCycleOK: (@MainActor () -> Void)?
    /// Возвращает false при критично малом свободном месте — цикл пропускает захват (диск не добиваем).
    var diskOK: @MainActor () -> Bool = { true }

    init(ingest: IngestService, config: CaptureConfig = CaptureConfig()) {
        self.ingest = ingest
        self.config = config
        self.axReader = AXReader(config: config)
        self.pipeline = FramePipeline(config: config)
    }

    // MARK: lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        suspended = false

        let wsc = NSWorkspace.shared.notificationCenter
        observers.append(wsc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.invalidateAndTrigger() }
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.willSleepNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = true }
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.didWakeNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = false }
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in await self?.axReader.forget(pid: pid) }
        })

        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"),
                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = true }
        })
        distributedObservers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = false }
        })

        tickTimer = Timer.scheduledTimer(withTimeInterval: config.activeTickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickFired() }
        }
        trigger()
    }

    func stop() {
        isRunning = false
        let wsc = NSWorkspace.shared.notificationCenter
        observers.forEach { wsc.removeObserver($0) }
        observers.removeAll()
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.forEach { dnc.removeObserver($0) }
        distributedObservers.removeAll()
        tickTimer?.invalidate(); tickTimer = nil
        cycleTask?.cancel(); cycleTask = nil
        pendingCycle = false
        emptyStreak.removeAll(); lastContentText.removeAll()
        Task { await axReader.reset() }
    }

    // MARK: triggers

    private func tickFired() {
        guard isRunning, !suspended else { return }
        // idle: нет ввода дольше порога → не захватываем по тику (smart-pause). Это ЗДОРОВЬЕ, не сбой —
        // heartbeat отбиваем, иначе UI после обеда кричал бы «захват умер».
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > config.idleThresholdSec { onCycleOK?(); return }
        trigger()
    }

    private func invalidateAndTrigger() {
        guard !suspended else { return }
        Task { await pipeline.invalidateContent() }
        trigger()
    }

    private func trigger() {
        guard isRunning, !suspended else { return }
        if cycleTask != nil { pendingCycle = true; return }   // single-flight
        cycleTask = Task { @MainActor [weak self] in
            await self?.runCycle()
            guard let self else { return }
            self.cycleTask = nil
            if self.pendingCycle { self.pendingCycle = false; self.trigger() }
        }
    }

    // MARK: cycle

    private func runCycle() async {
        guard diskOK() else { return }   // диск почти полон — не пишем (статус поднимает AppEnvironment)
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? bundleId

        // per-app capability: GPU/canvas → сразу OCR, не тратим AX
        let cls = capability[bundleId] ?? (Self.knownOCROnly.contains(bundleId) ? .ocrOnly : .unknown)

        var ax = AXExtraction()
        var needsOCR: Bool
        if cls == .ocrOnly {
            needsOCR = true
        } else {
            ax = await axReader.extract(pid: pid)
            needsOCR = ax.contentChars < config.ocrMinContentChars
                && (ax.quality == .none || ax.quality == .titleOnly || ax.treeWasEmpty)
            // обучение capability
            if ax.contentChars >= config.usefulThreshold {
                capability[bundleId] = .axViable
                emptyStreak[bundleId] = 0
            } else if ax.treeWasEmpty {
                let n = (emptyStreak[bundleId] ?? 0) + 1
                emptyStreak[bundleId] = n
                if n >= config.ocrOnlyEmptyStreak { capability[bundleId] = .ocrOnly }
            }
        }

        let frame: ProcessedFrame?
        do {
            frame = try await pipeline.process(displayIndex: 0, needsOCR: needsOCR)
            if sckFailureStreak > 0 { onCaptureRecovered?() }   // транзиентный сбой прошёл — снять ratchet
            sckFailureStreak = 0
            onCycleOK?()
        } catch {
            // -3801 после выдачи права / нет дисплея. Подряд идущие отказы = захват фактически мёртв.
            sckFailureStreak += 1
            Log.capture.error("SCK capture failed (streak \(self.sckFailureStreak)): \(String(describing: error), privacy: .public)")
            if sckFailureStreak == 3 { onCaptureBroken?() }
            return
        }
        guard let frame else { return }

        if frame.isDuplicate {
            // картинка та же — но если AX-текст изменился (скролл/новое сообщение), пишем context-only
            if ax.contentChars > 0, ax.contentText != (lastContentText[bundleId] ?? "") {
                await write(bundleId: bundleId, appName: appName, ax: ax, ocr: [],
                            image: .none, width: frame.width, height: frame.height)
                lastContentText[bundleId] = ax.contentText
            }
            return
        }

        await write(bundleId: bundleId, appName: appName, ax: ax, ocr: frame.ocr,
                    image: .heicData(frame.heicData), width: frame.width, height: frame.height)
        lastContentText[bundleId] = ax.contentText
    }

    private func write(bundleId: String, appName: String, ax: AXExtraction,
                       ocr: [OCRLine], image: ImagePayload, width: Int, height: Int) async {
        var blocks: [CapturedTextBlock] = []
        if ax.contentChars > 0 {
            blocks.append(CapturedTextBlock(source: .ax, text: ax.contentText, confidence: 1.0))
        }
        for line in ocr where !line.text.isEmpty {
            blocks.append(CapturedTextBlock(source: .ocr, text: line.text, confidence: line.confidence))
        }
        let quality: AXQuality = ocr.isEmpty ? ax.quality : (ax.contentChars > 0 ? .partialUseful : .ocr)
        let tel = CaptureTelemetry(
            usefulTextChars: ax.contentChars, nodeCount: ax.nodeCount,
            treeWasEmpty: ax.treeWasEmpty, hitBudgetLimit: ax.hitBudgetLimit,
            ocrFallbackReason: ocr.isEmpty ? nil : "ax=\(ax.quality.rawValue)",
            manualAccessibilityResult: ax.manualResult, enhancedUiResult: ax.enhancedResult)

        let record = ScreenCaptureRecord(
            timestamp: Date(), bundleId: bundleId, appName: appName,
            windowTitle: ax.windowTitle, browserURL: ax.browserURL, monitorId: "0",
            image: image, pixelWidth: width, pixelHeight: height,
            textBlocks: blocks, axQuality: quality, telemetry: tel)
        do {
            _ = try await ingest.ingest(record)
            onFrame?()
        } catch {
            Log.ingest.error("frame ingest failed: \(String(describing: error), privacy: .public)")
        }
    }
}
