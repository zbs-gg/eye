import Foundation
import AppKit
import CoreGraphics

/// Capture orchestrator (@MainActor — owns the observers/timer, does only debounce+dispatch).
/// Event-driven on the active-app change + an active-tick fallback. Smart-pause (lock/sleep/idle),
/// per-app capability cache (GPU/canvas → OCR-only, we don't poke AX in vain). Heavy work — on actors.
@MainActor
final class CaptureCoordinator {
    private enum CaptureClass { case unknown, axViable, ocrOnly }

    /// Known GPU/canvas apps (plan: "OCR-only forever"). Everything else — learned per-app.
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
    private var screenLocked = false           // screen is locked — gates the resume-kick on screensaver.didstop
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
    /// N SCK failures in a row with a granted permission (the classic -3801: TCC requires a process restart) —
    /// surface it, otherwise "Recording" stays lit at zero frames.
    var onCaptureBroken: (@MainActor () -> Void)?
    /// Capture recovered after failures (a transient noDisplay on wake/monitor change) — clear
    /// needsRestart, otherwise a one-way ratchet blocks recording forever with a false "No permissions".
    var onCaptureRecovered: (@MainActor () -> Void)?
    /// Heartbeat: a cycle completed normally (including dedup and idle-skip) — for "capture is alive" in the UI.
    var onCycleOK: (@MainActor () -> Void)?
    /// Returns false at critically low free space — the cycle skips capture (we don't fill the disk to the brim).
    var diskOK: @MainActor () -> Bool = { true }
    /// Privacy exclusions (1Password/bank): true → we don't record the app. Default — record everything.
    var isIgnoredApp: @MainActor (String) -> Bool = { _ in false }
    /// The full list of excluded ones (for SCContentFilter: cut their windows out of ANY frame, not just the focus one).
    var ignoredBundleIds: @MainActor () -> Set<String> = { [] }

    init(ingest: IngestService, config: CaptureConfig = CaptureConfig()) {
        self.ingest = ingest
        self.config = config
        self.axReader = AXReader(config: config)
        self.pipeline = FramePipeline(config: config)
        loadCapability()
    }

    /// The capability cache persists (plan: don't re-learn after every restart). ocrOnly verdicts
    /// older than 7 days are reset — the app may have updated and started returning AX (re-probe).
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
            case "ocr": if at > cutoff { capability[bundleId] = .ocrOnly }   // expired → re-probe
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
            Task { @MainActor in self?.suspended = false; self?.invalidateAndTrigger() }   // active resume-kick: don't wait for an app-switch, recover from a possible stuck state (started-under-lock)
        })
        // DISPLAY sleep (without system sleep) — otherwise idle capture would write black frames all night,
        // and SCK errors would arm a false "restart needed".
        observers.append(wsc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = true }
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = false; self?.invalidateAndTrigger() }   // active resume-kick: don't wait for an app-switch, recover from a possible stuck state (started-under-lock)
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in await self?.axReader.forget(pid: pid) }
        })

        // A change in display configuration (connecting/disconnecting a monitor, a resolution change) —
        // the SCShareableContent cache goes stale instantly, otherwise capture breaks until an app change.
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
            // active resume-kick: don't wait for an app-switch, recover from a possible stuck state (started-under-lock)
            Task { @MainActor in self?.screenLocked = false; self?.suspended = false; self?.invalidateAndTrigger() }
        })
        distributedObservers.append(dnc.addObserver(forName: .init("com.apple.screensaver.didstart"),
                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspended = true }
        })
        distributedObservers.append(dnc.addObserver(forName: .init("com.apple.screensaver.didstop"),
                                                    object: nil, queue: .main) { [weak self] _ in
            // the screensaver ended: we lift suspend, BUT under lock we DON'T trigger capture — we wait for screenIsUnlocked
            // (otherwise we'd waste an extra cycle on the login session). On an unlocked screen the resume-kick is correct.
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
        // idle: no input longer than the threshold → a RARE mode (a frame once per idleCaptureInterval), not a full stop:
        // "record everything" includes input-free incoming — reading, video, arriving messages.
        // This is HEALTH, not a failure — we keep the heartbeat, otherwise the UI after lunch would scream "capture died".
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
        // burst trio: the immediate frame above + frames at 700ms/2s — Electron/web are often not yet drawn
        // by the first capture (plan: "an undrawn frame goes into history, and its phash suppresses the drawn one")
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
        guard diskOK() else { return }   // disk almost full — we don't write (AppEnvironment raises the status)
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return }
        // privacy exclusion: a deliberate skip = cycle health (heartbeat), not a failure
        if isIgnoredApp(bundleId) { onCycleOK?(); return }
        let pid = app.processIdentifier
        // THE MAIN FIX (Pro's diagnosis): NEVER capture our own process. On a "Record" click ZBS Eye
        // stays frontmost → AXReader would read OUR AX tree → kAXValue on our SwiftUI Slider synchronously
        // calls its @MainActor Binding.get (TimelineView) right on the axreader queue → dispatch_assert_queue → crash.
        guard pid != ProcessInfo.processInfo.processIdentifier else { onCycleOK?(); return }
        let appName = app.localizedName ?? bundleId

        // per-app capability: GPU/canvas → straight to OCR, we don't spend AX
        let cls = capability[bundleId] ?? (Self.knownOCROnly.contains(bundleId) ? .ocrOnly : .unknown)

        var ax = AXExtraction()
        var needsOCR: Bool
        if cls == .ocrOnly {
            needsOCR = true
            // we don't call full AX (the tree is empty/useless), but the window title — one cheap call:
            // otherwise Zed/Figma records were left without any windowTitle at all
            ax.windowTitle = await axReader.titleOnly(pid: pid)
        } else {
            ax = await axReader.extract(pid: pid)
            needsOCR = ax.contentChars < config.ocrMinContentChars
                && (ax.quality == .none || ax.quality == .titleOnly || ax.treeWasEmpty)
            // capability learning (persists; ocrOnly expires after 7 days → re-probe)
            if ax.contentChars >= config.usefulThreshold {
                if capability[bundleId] != .axViable { persistCapability(bundleId, .axViable) }
                emptyStreak[bundleId] = 0
            } else if ax.treeWasEmpty {
                let n = (emptyStreak[bundleId] ?? 0) + 1
                emptyStreak[bundleId] = n
                if n >= config.ocrOnlyEmptyStreak { persistCapability(bundleId, .ocrOnly) }
            }
        }
        // Pro action 3: after awaiting the AXReader actor we must be back on main. After the self-PID fix this
        // passes stably for external apps; a failure here would mean a REAL runtime mis-hop (then — repro).
        MainActor.preconditionIsolated()

        // The display of the FRONTMOST window by GEOMETRY. NSScreen.main won't do here: it's the screen of OUR
        // app's key window — when ZBS Eye is in the background (always while recording), it would give the primary
        // display, not the screen of the other app's active window.
        let focusedDisplayID = Self.displayForFrontmostWindow(pid: pid)

        let frame: ProcessedFrame?
        do {
            var excludes = ignoredBundleIds()
            if let own = Bundle.main.bundleIdentifier { excludes.insert(own) }   // Pro: the timeline doesn't record itself
            frame = try await pipeline.process(displayID: focusedDisplayID, needsOCR: needsOCR,
                                               excludedBundleIds: excludes)
            if sckFailureStreak > 0 { onCaptureRecovered?() }   // a transient failure passed — clear the ratchet
            sckFailureStreak = 0
            onCycleOK?()
        } catch {
            // -3801 after a permission grant / no display. Consecutive failures = capture effectively dead.
            sckFailureStreak += 1
            Log.capture.error("SCK capture failed (streak \(self.sckFailureStreak)): \(String(describing: error), privacy: .public)")
            if sckFailureStreak == 3 { onCaptureBroken?() }
            return
        }
        guard let frame else { return }

        if frame.isDuplicate {
            // same image — but if the AX text changed (scroll/new message), we write context-only
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

    /// The display of the topmost normal window (layer 0) of the process — by intersecting bounds with displays.
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
