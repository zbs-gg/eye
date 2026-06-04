import Foundation
import AppKit

/// Оркестратор захвата (@MainActor — владеет observer'ами/таймером, делает только debounce+dispatch).
/// MVP-режим: event-driven по смене активного приложения + active-tick fallback. Burst-stream и
/// input-tap — позже (по плану v2). Тяжёлая работа — на акторах (AXReader/FramePipeline), main не блокируется.
@MainActor
final class CaptureCoordinator {
    private let ingest: IngestService
    private let config: CaptureConfig
    private let axReader: AXReader
    private let pipeline: FramePipeline

    private(set) var isRunning = false
    private var tickTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var cycleTask: Task<Void, Never>?
    private var pendingCycle = false
    private var lastCaptureByApp: [String: Date] = [:]

    /// Колбэк после успешной записи кадра (для UI-счётчика).
    var onFrame: (@MainActor () -> Void)?

    init(ingest: IngestService, config: CaptureConfig = CaptureConfig()) {
        self.ingest = ingest
        self.config = config
        self.axReader = AXReader(config: config)
        self.pipeline = FramePipeline(config: config)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.invalidateAndTrigger() }
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: config.activeTickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trigger() }
        }
        trigger()
    }

    func stop() {
        isRunning = false
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        activationObserver = nil
        tickTimer?.invalidate(); tickTimer = nil
        cycleTask?.cancel(); cycleTask = nil
        pendingCycle = false
    }

    private func invalidateAndTrigger() {
        Task { await pipeline.invalidateContent() }   // дисплеи могли смениться при app-switch
        trigger()
    }

    private func trigger() {
        guard isRunning else { return }
        if cycleTask != nil { pendingCycle = true; return }   // single-flight
        cycleTask = Task { @MainActor [weak self] in
            await self?.runCycle()
            guard let self else { return }
            self.cycleTask = nil
            if self.pendingCycle { self.pendingCycle = false; self.trigger() }
        }
    }

    private func runCycle() async {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? bundleId

        // rate-limit на приложение
        if let last = lastCaptureByApp[bundleId],
           Date().timeIntervalSince(last) * 1000 < Double(config.captureMinIntervalMs) { return }
        lastCaptureByApp[bundleId] = Date()

        // 1) AX (на dedicated очереди)
        let ax = await axReader.extract(pid: pid)
        let needsOCR = ax.contentChars < config.ocrMinContentChars
            && (ax.quality == .none || ax.quality == .titleOnly || ax.treeWasEmpty)

        // 2) кадр (+OCR при нужде) — в одной isolation domain
        let frame: ProcessedFrame?
        do { frame = try await pipeline.process(displayIndex: 0, needsOCR: needsOCR) }
        catch { return }   // -3801 / нет дисплея
        guard let frame, !frame.isDuplicate else { return }   // MVP: дубли пропускаем

        // 3) собрать запись
        var blocks: [CapturedTextBlock] = []
        if ax.contentChars > 0 {
            blocks.append(CapturedTextBlock(source: .ax, text: ax.contentText, confidence: 1.0))
        }
        for line in frame.ocr where !line.text.isEmpty {
            blocks.append(CapturedTextBlock(source: .ocr, text: line.text, confidence: line.confidence))
        }
        let quality: AXQuality = frame.ocr.isEmpty
            ? ax.quality
            : (ax.contentChars > 0 ? .partialUseful : .ocr)
        let tel = CaptureTelemetry(
            usefulTextChars: ax.contentChars, nodeCount: ax.nodeCount,
            treeWasEmpty: ax.treeWasEmpty, hitBudgetLimit: ax.hitBudgetLimit,
            ocrFallbackReason: needsOCR ? "ax=\(ax.quality.rawValue)" : nil,
            manualAccessibilityResult: ax.manualResult, enhancedUiResult: ax.enhancedResult)

        let record = ScreenCaptureRecord(
            timestamp: Date(), bundleId: bundleId, appName: appName,
            windowTitle: ax.windowTitle, browserURL: ax.browserURL, monitorId: "0",
            image: .heicData(frame.heicData), pixelWidth: frame.width, pixelHeight: frame.height,
            textBlocks: blocks, axQuality: quality, telemetry: tel)

        do {
            _ = try await ingest.ingest(record)
            onFrame?()
        } catch { /* logged later */ }
    }
}
