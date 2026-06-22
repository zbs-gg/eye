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
    private var screenLocked = false           // экран заблокирован — гейтит resume-kick screensaver.didstop
    private var tickTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var cycleTask: Task<Void, Never>?
    private var pendingCycle = false

    private var capability: [String: CaptureClass] = [:]
    private var capabilityCheckedAt: [String: Date] = [:]
    private var emptyStreak: [String: Int] = [:]
    private var lastContentText: [String: String] = [:]
    private var sckFailureStreak = 0
    private var lastIdleCaptureAt = Date.distantPast
    private var burstTask: Task<Void, Never>?

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
    /// Privacy-исключения (1Password/банк): true → приложение не записываем. Дефолт — пишем всё.
    var isIgnoredApp: @MainActor (String) -> Bool = { _ in false }
    /// Полный список исключённых (для SCContentFilter: вырезать их окна из ЛЮБОГО кадра, не только фокус).
    var ignoredBundleIds: @MainActor () -> Set<String> = { [] }

    init(ingest: IngestService, config: CaptureConfig = CaptureConfig()) {
        self.ingest = ingest
        self.config = config
        self.axReader = AXReader(config: config)
        self.pipeline = FramePipeline(config: config)
        loadCapability()
    }

    /// Capability-кэш персистится (план: не переучивать после каждого рестарта). ocrOnly-вердикты
    /// старше 7 дней сбрасываются — приложение могло обновиться и начать отдавать AX (re-probe).
    private func loadCapability() {
        let d = UserDefaults.standard
        guard let raw = d.dictionary(forKey: "zbseye.capability") as? [String: String],
              let stamps = d.dictionary(forKey: "zbseye.capabilityAt") as? [String: Double] else { return }
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        for (bundleId, cls) in raw {
            let at = Date(timeIntervalSince1970: stamps[bundleId] ?? 0)
            capabilityCheckedAt[bundleId] = at
            switch cls {
            case "ax": capability[bundleId] = .axViable
            case "ocr": if at > cutoff { capability[bundleId] = .ocrOnly }   // протух → re-probe
            default: break
            }
        }
    }

    private func persistCapability(_ bundleId: String, _ cls: CaptureClass) {
        capability[bundleId] = cls
        capabilityCheckedAt[bundleId] = Date()
        let d = UserDefaults.standard
        var raw = (d.dictionary(forKey: "zbseye.capability") as? [String: String]) ?? [:]
        var stamps = (d.dictionary(forKey: "zbseye.capabilityAt") as? [String: Double]) ?? [:]
        raw[bundleId] = cls == .axViable ? "ax" : "ocr"
        stamps[bundleId] = Date().timeIntervalSince1970
        d.set(raw, forKey: "zbseye.capability")
        d.set(stamps, forKey: "zbseye.capabilityAt")
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
            Task { @MainActor in self?.suspended = false; self?.invalidateAndTrigger() }   // активный resume-kick: не ждём app-switch, восстанавливаемся из возможного stuck (старт-под-локом)
        })
        // Сон ДИСПЛЕЯ (без сна системы) — иначе idle-захват всю ночь писал бы чёрные кадры,
        // а SCK-ошибки взводили бы ложный «нужен перезапуск».
        observers.append(wsc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = true }
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = false; self?.invalidateAndTrigger() }   // активный resume-kick: не ждём app-switch, восстанавливаемся из возможного stuck (старт-под-локом)
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in await self?.axReader.forget(pid: pid) }
        })

        // Смена конфигурации дисплеев (подключение/отключение монитора, смена разрешения) —
        // кеш SCShareableContent устаревает мгновенно, иначе захват падает до смены приложения.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.pipeline.invalidateContent() }
        })

        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"),
                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = true; self?.screenLocked = true }
        })
        distributedObservers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                    object: nil, queue: .main) { [weak self] _ in
            // активный resume-kick: не ждём app-switch, восстанавливаемся из возможного stuck (старт-под-локом)
            Task { @MainActor in self?.screenLocked = false; self?.suspended = false; self?.invalidateAndTrigger() }
        })
        distributedObservers.append(dnc.addObserver(forName: .init("com.apple.screensaver.didstart"),
                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = true }
        })
        distributedObservers.append(dnc.addObserver(forName: .init("com.apple.screensaver.didstop"),
                                                    object: nil, queue: .main) { [weak self] _ in
            // скринсейвер кончился: снимаем suspend, НО под локом НЕ триггерим захват — ждём screenIsUnlocked
            // (иначе спустим лишний цикл на login-сессию). На разлоченном экране resume-kick корректен.
            Task { @MainActor in
                self?.suspended = false
                if self?.screenLocked == false { self?.invalidateAndTrigger() }
            }
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
        burstTask?.cancel(); burstTask = nil
        pendingCycle = false
        emptyStreak.removeAll(); lastContentText.removeAll()
        Task { await axReader.reset() }
    }

    // MARK: triggers

    private func tickFired() {
        guard isRunning, !suspended else { return }
        // idle: нет ввода дольше порога → РЕДКИЙ режим (кадр раз в idleCaptureInterval), не полный стоп:
        // «записывать всё» включает входящее без ввода — чтение, видео, прилетающие сообщения.
        // Это ЗДОРОВЬЕ, не сбой — heartbeat отбиваем, иначе UI после обеда кричал бы «захват умер».
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > config.idleThresholdSec {
            onCycleOK?()
            let now = Date()
            if now.timeIntervalSince(lastIdleCaptureAt) >= config.idleCaptureIntervalSec {
                lastIdleCaptureAt = now
                trigger()
            }
            return
        }
        trigger()
    }

    private func invalidateAndTrigger() {
        guard !suspended else { return }
        Task { await pipeline.invalidateContent() }
        trigger()
        // burst trio: немедленный кадр выше + кадры на 700мс/2с — Electron/web часто ещё не дорисованы
        // к первому захвату (план: «недорисованный кадр уходит в историю, а его phash гасит дорисованный»)
        burstTask?.cancel()
        let delays = config.burstTrioDelays
        burstTask = Task { @MainActor [weak self] in
            for d in delays {
                try? await Task.sleep(for: .seconds(d))
                guard !Task.isCancelled, let self, self.isRunning, !self.suspended else { return }
                self.trigger()
            }
        }
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
        // privacy-исключение: осознанный skip = здоровье цикла (heartbeat), а не сбой
        if isIgnoredApp(bundleId) { onCycleOK?(); return }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? bundleId

        // per-app capability: GPU/canvas → сразу OCR, не тратим AX
        let cls = capability[bundleId] ?? (Self.knownOCROnly.contains(bundleId) ? .ocrOnly : .unknown)

        var ax = AXExtraction()
        var needsOCR: Bool
        if cls == .ocrOnly {
            needsOCR = true
            // полный AX не зовём (дерево пустое/бесполезное), но заголовок окна — один дешёвый вызов:
            // иначе записи Zed/Figma оставались вообще без windowTitle
            ax.windowTitle = await axReader.titleOnly(pid: pid)
        } else {
            ax = await axReader.extract(pid: pid)
            needsOCR = ax.contentChars < config.ocrMinContentChars
                && (ax.quality == .none || ax.quality == .titleOnly || ax.treeWasEmpty)
            // обучение capability (персистится; ocrOnly протухает через 7 дней → re-probe)
            if ax.contentChars >= config.usefulThreshold {
                if capability[bundleId] != .axViable { persistCapability(bundleId, .axViable) }
                emptyStreak[bundleId] = 0
            } else if ax.treeWasEmpty {
                let n = (emptyStreak[bundleId] ?? 0) + 1
                emptyStreak[bundleId] = n
                if n >= config.ocrOnlyEmptyStreak { persistCapability(bundleId, .ocrOnly) }
            }
        }

        // Дисплей FRONTMOST-окна по ГЕОМЕТРИИ. NSScreen.main здесь не годится: это экран key window
        // НАШЕГО приложения — когда ZBS Eye в фоне (всегда при записи), он давал бы primary-дисплей,
        // а не экран чужого активного окна.
        let focusedDisplayID = Self.displayForFrontmostWindow(pid: pid)

        let frame: ProcessedFrame?
        do {
            frame = try await pipeline.process(displayID: focusedDisplayID, needsOCR: needsOCR,
                                               excludedBundleIds: ignoredBundleIds())
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
                            image: .none, width: frame.width, height: frame.height,
                            monitorId: String(frame.displayID))
                lastContentText[bundleId] = ax.contentText
            }
            return
        }

        await write(bundleId: bundleId, appName: appName, ax: ax, ocr: frame.ocr,
                    image: .heicData(frame.heicData), width: frame.width, height: frame.height,
                    monitorId: String(frame.displayID))
        lastContentText[bundleId] = ax.contentText
    }

    /// Дисплей самого верхнего обычного окна (layer 0) процесса — по пересечению bounds с дисплеями.
    private static func displayForFrontmostWindow(pid: pid_t) -> CGDirectDisplayID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? Int, pid_t(owner) == pid,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict), !rect.isEmpty
            else { continue }
            var display = CGDirectDisplayID(0)
            var count: UInt32 = 0
            if CGGetDisplaysWithRect(rect, 1, &display, &count) == .success, count > 0 {
                return display
            }
        }
        return nil
    }

    private func write(bundleId: String, appName: String, ax: AXExtraction,
                       ocr: [OCRLine], image: ImagePayload, width: Int, height: Int,
                       monitorId: String) async {
        var blocks: [CapturedTextBlock] = []
        if ax.contentChars > 0 {
            blocks.append(CapturedTextBlock(source: .ax, text: ax.contentText, confidence: 1.0))
        }
        for line in ocr where !line.text.isEmpty {
            blocks.append(CapturedTextBlock(source: .ocr, text: line.text, confidence: line.confidence, bbox: line.bbox))
        }
        let quality: AXQuality = ocr.isEmpty ? ax.quality : (ax.contentChars > 0 ? .partialUseful : .ocr)
        let tel = CaptureTelemetry(
            usefulTextChars: ax.contentChars, nodeCount: ax.nodeCount,
            treeWasEmpty: ax.treeWasEmpty, hitBudgetLimit: ax.hitBudgetLimit,
            ocrFallbackReason: ocr.isEmpty ? nil : "ax=\(ax.quality.rawValue)",
            manualAccessibilityResult: ax.manualResult, enhancedUiResult: ax.enhancedResult)

        let record = ScreenCaptureRecord(
            timestamp: Date(), bundleId: bundleId, appName: appName,
            windowTitle: ax.windowTitle, browserURL: ax.browserURL, monitorId: monitorId,
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
