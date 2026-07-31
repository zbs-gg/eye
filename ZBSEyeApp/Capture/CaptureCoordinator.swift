import Foundation
import AppKit
import CoreGraphics

struct CaptureDrainAcknowledgement: Sendable, Equatable {
    let hadActiveCapture: Bool
    let hadInFlightCycle: Bool
    let activeCycles: Int
}

/// Capture orchestrator (@MainActor — owns the observers/timer, does only debounce+dispatch).
/// Event-driven on the active-app change + an active-tick fallback. Smart-pause (lock/sleep/idle),
/// per-app capability cache (GPU/canvas → OCR-only, we don't poke AX in vain). Heavy work — on actors.
@MainActor
final class CaptureCoordinator {
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
    private let browserContent: BrowserContentStore

    private(set) var isRunning = false
    private var sessionGate = CaptureSessionGateState(reasons: [])
    private var gateRevision: UInt64 = 0
    private var suspended: Bool { sessionGate.suspended }
    private var screenLocked: Bool { sessionGate.screenLocked }
    private var tickTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var cycleTask: Task<Void, Never>?
    private var pendingCycle = false

    private var capability: [String: CaptureClass] = [:]
    private var capabilityCheckedAt: [String: Date] = [:]
    private var emptyStreak: [String: Int] = [:]
    private var lastContentText: [String: String] = [:]
    private var lastBrowserContentHash: [String: String] = [:]
    private var lastBrowserOCRAt: [String: Date] = [:]
    private var sckFailureStreak = 0
    private var lastIdleCaptureAt = Date.distantPast
    private var burstTask: Task<Void, Never>?
    private var lastProtectedSystemShell: String?

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

    init(
        ingest: IngestService,
        browserContent: BrowserContentStore,
        config: CaptureConfig = CaptureConfig()
    ) {
        self.ingest = ingest
        self.browserContent = browserContent
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
            case "ocr":
                if at > cutoff, !BrowserCapturePolicy.isChromiumBrowser(bundleId) {
                    capability[bundleId] = .ocrOnly
                }
            default: break
            }
        }
    }

    private func persistCapability(_ bundleId: String, _ cls: CaptureClass) {
        if cls == .ocrOnly, BrowserCapturePolicy.isChromiumBrowser(bundleId) { return }
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
        // Notifications only describe transitions and can be missed when ZBS Eye
        // launches under lock. Seed from the current session, failing closed when
        // the query is unavailable; the active tick reconciles it again later.
        let initialSessionGate = CaptureSessionPolicy.startupGate(
            sessionLockedNow: Self.currentSessionLocked()
        )
        applySessionGate(initialSessionGate)

        let wsc = NSWorkspace.shared.notificationCenter
        observers.append(wsc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.invalidateAndTrigger() }
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.willSleepNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            // Closing edges must revoke admission before this main-queue
            // notification callback returns. Deferring suspension to an
            // unstructured Task can let an already queued capture continuation
            // commit a post-boundary frame with the old open gate.
            MainActor.assumeIsolated { self?.suspend(for: .systemSleep) }
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.didWakeNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.resumeIfSessionUnlocked(clearing: .systemSleep) }
        })
        // DISPLAY sleep (without system sleep) — otherwise idle capture would write black frames all night,
        // and SCK errors would arm a false "restart needed".
        observers.append(wsc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend(for: .displaySleep) }
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.resumeIfSessionUnlocked(clearing: .displaySleep) }
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let bundleID = app.bundleIdentifier
            let appName = app.localizedName
            // The observer is explicitly delivered on OperationQueue.main. Bump
            // the MainActor epoch synchronously before this callback returns;
            // deferring the bump into an unstructured Task could let an already
            // queued frame continuation commit with the pre-launch revision.
            let protectedLifecycleChanged = MainActor.assumeIsolated {
                CaptureSessionPolicy.recordProtectedApplicationLifecycle(
                    bundleId: bundleID,
                    appName: appName
                )
            }
            guard protectedLifecycleChanged else { return }
            Task { @MainActor in
                guard let self else { return }
                await self.pipeline.invalidateContent()
            }
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier
            let appName = app.localizedName
            // Same main-queue/MainActor invariant as the launch observer: the
            // lifecycle revision changes before any queued capture continuation.
            let protectedLifecycleChanged = MainActor.assumeIsolated {
                CaptureSessionPolicy.recordProtectedApplicationLifecycle(
                    bundleId: bundleID,
                    appName: appName
                )
            }
            Task { @MainActor in
                guard let self else { return }
                if protectedLifecycleChanged { await self.pipeline.invalidateContent() }
                await self.axReader.forget(pid: pid)
            }
        })

        // A change in display configuration (connecting/disconnecting a monitor, a resolution change) —
        // the SCShareableContent cache goes stale instantly, otherwise capture breaks until an app change.
        defaultObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.pipeline.invalidateContent() }
        })

        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(dnc.addObserver(forName: .init("com.apple.screenIsLocked"),
                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend(for: .session) }
        })
        distributedObservers.append(dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"),
                                                    object: nil, queue: .main) { [weak self] _ in
            // Confirm the notification against CGSession: delivery can be delayed
            // or out of order around display sleep and fast user switching.
            Task { @MainActor in await self?.resumeIfSessionUnlocked(clearing: .session) }
        })
        distributedObservers.append(dnc.addObserver(forName: .init("com.apple.screensaver.didstart"),
                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend(for: .screenSaver) }
        })
        distributedObservers.append(dnc.addObserver(forName: .init("com.apple.screensaver.didstop"),
                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.resumeIfSessionUnlocked(clearing: .screenSaver) }
        })

        tickTimer = Timer.scheduledTimer(withTimeInterval: config.activeTickSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tickFired() }
        }
        if initialSessionGate.isOpen { trigger() }
    }

    func stop() {
        let cycle = stopAdmission()
        Task { [axReader, browserContent] in
            await cycle?.value
            await axReader.reset()
            await browserContent.clear()
        }
    }

    /// Maintenance barrier: returns only after the single-flight capture cycle
    /// has finished its final IngestService write. Cancellation closes future
    /// admission; awaiting the Task handles actor calls that were already past
    /// their cancellation point.
    func stopAndDrain() async -> CaptureDrainAcknowledgement {
        let wasRunning = isRunning
        let cycle = stopAdmission()
        let hadInFlightCycle = cycle != nil
        await cycle?.value
        await axReader.reset()
        await pipeline.invalidateContent()
        await browserContent.clear()
        return CaptureDrainAcknowledgement(
            hadActiveCapture: wasRunning,
            hadInFlightCycle: hadInFlightCycle,
            activeCycles: 0
        )
    }

    private func stopAdmission() -> Task<Void, Never>? {
        isRunning = false
        let wsc = NSWorkspace.shared.notificationCenter
        observers.forEach { wsc.removeObserver($0) }
        observers.removeAll()
        let nc = NotificationCenter.default
        defaultObservers.forEach { nc.removeObserver($0) }
        defaultObservers.removeAll()
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.forEach { dnc.removeObserver($0) }
        distributedObservers.removeAll()
        tickTimer?.invalidate(); tickTimer = nil
        gateRevision &+= 1
        let cycle = cycleTask
        cycle?.cancel(); cycleTask = nil
        burstTask?.cancel(); burstTask = nil
        pendingCycle = false
        emptyStreak.removeAll()
        lastContentText.removeAll()
        lastBrowserContentHash.removeAll()
        lastBrowserOCRAt.removeAll()
        lastProtectedSystemShell = nil
        return cycle
    }

    // MARK: triggers

    private func tickFired() async {
        guard isRunning else { return }
        guard let gate = CaptureSessionPolicy.periodicGate(
            previous: sessionGate,
            sessionLockedNow: Self.currentSessionLocked()
        ) else { return }
        if !sessionGate.isOpen, gate.isOpen {
            // A valid current unlock is authoritative even when the distributed
            // unlock event was missed. Resume immediately instead of waiting for
            // another app switch or another timer interval.
            await openGateAfterSessionBoundary(gate)
            return
        }
        applySessionGate(gate)
        guard gate.isOpen else { return }
        guard CaptureSessionPolicy.mayCapture(screenLocked: screenLocked) else { return }
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

    private func invalidateAndTrigger() async {
        guard !suspended,
              CaptureSessionPolicy.mayCapture(screenLocked: screenLocked) else { return }
        await pipeline.invalidateContent()
        // Actor invalidation suspends. Re-check the current login session before
        // admitting a capture so a concurrent lock cannot race the resume kick.
        guard isRunning, !suspended, currentSessionStillAllowsCapture() else { return }
        triggerAndArmBurst()
    }

    private func triggerAndArmBurst() {
        guard isRunning, !suspended, currentSessionStillAllowsCapture() else { return }
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
        guard isRunning, !suspended,
              CaptureSessionPolicy.mayCapture(screenLocked: screenLocked) else { return }
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
        // Notifications are advisory: query the current login session before
        // doing any AX or ScreenCaptureKit work so a missed lock event cannot
        // admit captured pixels even temporarily.
        guard currentSessionStillAllowsCapture() else { return }
        guard diskOK() else { return }   // disk almost full — we don't write (AppEnvironment raises the status)
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return }
        let appName = app.localizedName ?? bundleId
        guard CaptureSessionPolicy.mayCapture(
            screenLocked: screenLocked,
            bundleId: bundleId,
            appName: appName
        ) else {
            if lastProtectedSystemShell != bundleId {
                Log.capture.error("capture refused for protected system shell: \(bundleId, privacy: .public)")
                lastProtectedSystemShell = bundleId
            }
            onCycleOK?()
            return
        }
        lastProtectedSystemShell = nil
        // privacy exclusion: a deliberate skip = cycle health (heartbeat), not a failure
        if isIgnoredApp(bundleId) { onCycleOK?(); return }
        let pid = app.processIdentifier
        // THE MAIN FIX (Pro's diagnosis): NEVER capture our own process. On a "Record" click ZBS Eye
        // stays frontmost → AXReader would read OUR AX tree → kAXValue on our SwiftUI Slider synchronously
        // calls its @MainActor Binding.get (TimelineView) right on the axreader queue → dispatch_assert_queue → crash.
        guard pid != ProcessInfo.processInfo.processIdentifier else { onCycleOK?(); return }

        let windowInfo = Self.frontmostWindowInfo(pid: pid)
        var browser = await browserContent.match(
            bundleID: bundleId,
            windowTitle: windowInfo.title,
            browserURL: nil
        )

        // Fresh rendered DOM wins before AX. Chromium never inherits a stale
        // persisted OCR-only verdict from a previous version.
        let learned = capability[bundleId]
            ?? (Self.knownOCROnly.contains(bundleId) ? .ocrOnly : .unknown)
        let cls = BrowserCapturePolicy.effectiveClass(bundleID: bundleId, learned: learned)

        var ax = AXExtraction()
        var needsOCR: Bool
        if let browser {
            ax.windowTitle = browser.title
            ax.browserURL = browser.url
            needsOCR = throttledBrowserOCR(bundleID: bundleId, requested: browser.requiresOCR)
        } else if cls == .ocrOnly {
            needsOCR = true
            // we don't call full AX (the tree is empty/useless), but the window title — one cheap call:
            // otherwise Zed/Figma records were left without any windowTitle at all
            ax.windowTitle = await axReader.titleOnly(pid: pid)
        } else {
            ax = await axReader.extract(pid: pid)
            // Some Chromium builds hide CGWindowName but expose a title or URL
            // through the bounded AX read. Correlate once more before deciding
            // whether OCR is needed; DOM still wins as the text source.
            browser = await browserContent.match(
                bundleID: bundleId,
                windowTitle: ax.windowTitle,
                browserURL: ax.browserURL
            )
            if let browser {
                ax.windowTitle = browser.title
                ax.browserURL = browser.url
                needsOCR = throttledBrowserOCR(bundleID: bundleId, requested: browser.requiresOCR)
            } else {
                let decision = BrowserCapturePolicy.afterAccessibility(
                    bundleID: bundleId,
                    extraction: ax,
                    previousEmptyStreak: emptyStreak[bundleId] ?? 0,
                    config: config
                )
                emptyStreak[bundleId] = decision.emptyStreak
                if let learnedClass = decision.learnedClass,
                   capability[bundleId] != learnedClass {
                    persistCapability(bundleId, learnedClass)
                }
                needsOCR = BrowserCapturePolicy.isChromiumBrowser(bundleId)
                    ? throttledBrowserOCR(bundleID: bundleId, requested: decision.needsOCR)
                    : decision.needsOCR
            }
        }
        // Pro action 3: after awaiting the AXReader actor we must be back on main. After the self-PID fix this
        // passes stably for external apps; a failure here would mean a REAL runtime mis-hop (then — repro).
        MainActor.preconditionIsolated()
        // AX extraction suspends. Re-attest before asking ScreenCaptureKit for
        // pixels in case the session locked while AXReader was running.
        guard currentSessionStillAllowsCapture() else { return }

        // The display of the FRONTMOST window by GEOMETRY. NSScreen.main won't do here: it's the screen of OUR
        // app's key window — when ZBS Eye is in the background (always while recording), it would give the primary
        // display, not the screen of the other app's active window.
        let focusedDisplayID = windowInfo.displayID
        let protectedApplicationSnapshot = CaptureSessionPolicy.protectedRunningApplicationSnapshot()

        let frame: ProcessedFrame?
        do {
            var excludes = ignoredBundleIds()
            if let own = Bundle.main.bundleIdentifier { excludes.insert(own) }   // Pro: the timeline doesn't record itself
            frame = try await pipeline.process(displayID: focusedDisplayID, needsOCR: needsOCR,
                                               excludedBundleIds: excludes,
                                               protectedApplicationSnapshot: protectedApplicationSnapshot)
            if sckFailureStreak > 0 { onCaptureRecovered?() }   // a transient failure passed — clear the ratchet
            sckFailureStreak = 0
            onCycleOK?()
        } catch {
            // -3801 after a permission grant / no display. Consecutive failures = capture effectively dead.
            sckFailureStreak += 1
            Log.capture.error("screen_capture_failed streak=\(self.sckFailureStreak)")
            if sckFailureStreak == 3 { onCaptureBroken?() }
            return
        }
        guard let frame else { return }
        guard CaptureSessionPolicy.protectedRunningApplicationSnapshot()
                == protectedApplicationSnapshot else {
            await pipeline.invalidateContent()
            return
        }
        // Lock/display notifications can arrive while AX/SCK work is suspended at an await.
        // Re-read both tracked state and the current shell before committing any captured bytes.
        guard currentSessionStillAllowsCapture() else { return }

        if frame.isDuplicate {
            // Same pixels may still carry a new SPA/iframe document.
            let contentText = browser?.text ?? ax.contentText
            let textChanged = !contentText.isEmpty
                && contentText != (lastContentText[bundleId] ?? "")
            let browserIdentityChanged = browser.map {
                $0.contentHash != lastBrowserContentHash[bundleId]
            } ?? false
            if textChanged || browserIdentityChanged {
                await write(bundleId: bundleId, appName: appName, ax: ax, browser: browser, ocr: [],
                            image: .none, width: frame.width, height: frame.height,
                            monitorId: String(frame.displayID))
                lastContentText[bundleId] = contentText
                lastBrowserContentHash[bundleId] = browser?.contentHash
            }
            return
        }

        await write(bundleId: bundleId, appName: appName, ax: ax, browser: browser, ocr: frame.ocr,
                    image: .heicData(frame.heicData), width: frame.width, height: frame.height,
                    monitorId: String(frame.displayID))
        lastContentText[bundleId] = browser?.text ?? ax.contentText
        lastBrowserContentHash[bundleId] = browser?.contentHash
    }

    private func resumeIfSessionUnlocked(clearing reason: CaptureSuspensionReasons) async {
        let previousGate = sessionGate
        let gate = CaptureSessionPolicy.resumeSignalGate(
            previous: previousGate,
            clearing: reason,
            sessionLockedNow: Self.currentSessionLocked()
        )
        if !previousGate.isOpen, gate.isOpen {
            await openGateAfterSessionBoundary(gate)
            return
        }
        applySessionGate(gate)
    }

    private func openGateAfterSessionBoundary(_ gate: CaptureSessionGateState) async {
        let expectedRevision = gateRevision
        // Keep admission closed while the actor invalidates its session epoch.
        await pipeline.invalidateSessionBoundary()
        guard isRunning, gateRevision == expectedRevision else { return }
        guard Self.currentSessionLocked() == false else {
            suspend(for: .session)
            return
        }
        applySessionGate(gate)
        guard gate.isOpen else { return }
        triggerAndArmBurst()
    }

    private func suspend(for reason: CaptureSuspensionReasons) {
        applySessionGate(
            CaptureSessionPolicy.suspendedGate(previous: sessionGate, adding: reason)
        )
    }

    private func applySessionGate(_ gate: CaptureSessionGateState) {
        guard gate != sessionGate else { return }
        sessionGate = gate
        gateRevision &+= 1
    }

    private func currentSessionStillAllowsCapture() -> Bool {
        guard sessionGate.isOpen else { return false }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return false }
        return CaptureSessionPolicy.mayCapture(
            screenLocked: screenLocked,
            sessionLockedNow: Self.currentSessionLocked(),
            bundleId: bundleId,
            appName: app.localizedName ?? bundleId
        )
    }

    private static func currentSessionLocked() -> Bool? {
        let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any]
        return CaptureSessionPolicy.sessionLockState(from: sessionInfo)
    }

    /// The display of the topmost normal window (layer 0) of the process — by intersecting bounds with displays.
    private struct FrontmostWindowInfo {
        let displayID: CGDirectDisplayID?
        let title: String?
    }

    private static func frontmostWindowInfo(pid: pid_t) -> FrontmostWindowInfo {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return FrontmostWindowInfo(displayID: nil, title: nil)
        }
        for w in list {
            guard let owner = w[kCGWindowOwnerPID as String] as? Int, pid_t(owner) == pid,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict), !rect.isEmpty
            else { continue }
            var display = CGDirectDisplayID(0)
            var count: UInt32 = 0
            if CGGetDisplaysWithRect(rect, 1, &display, &count) == .success, count > 0 {
                return FrontmostWindowInfo(
                    displayID: display,
                    title: w[kCGWindowName as String] as? String
                )
            }
        }
        return FrontmostWindowInfo(displayID: nil, title: nil)
    }

    private func write(bundleId: String, appName: String, ax: AXExtraction,
                       browser: BrowserPageContent?, ocr: [OCRLine],
                       image: ImagePayload, width: Int, height: Int,
                       monitorId: String) async {
        var blocks: [CapturedTextBlock] = []
        if let browser, !browser.text.isEmpty {
            blocks.append(CapturedTextBlock(source: .browserDOM, text: browser.text, confidence: 1.0))
        }
        if browser == nil, ax.contentChars > 0 {
            blocks.append(CapturedTextBlock(source: .ax, text: ax.contentText, confidence: 1.0))
        }
        for line in ocr where !line.text.isEmpty {
            blocks.append(CapturedTextBlock(source: .ocr, text: line.text, confidence: line.confidence, bbox: line.bbox))
        }
        let quality: AXQuality
        if !ocr.isEmpty {
            quality = ax.contentChars > 0 || browser?.text.isEmpty == false ? .partialUseful : .ocr
        } else if browser?.text.isEmpty == false {
            quality = .fullUseful
        } else {
            quality = ax.quality
        }
        let tel = CaptureTelemetry(
            usefulTextChars: browser?.text.count ?? ax.contentChars, nodeCount: ax.nodeCount,
            treeWasEmpty: ax.treeWasEmpty, hitBudgetLimit: ax.hitBudgetLimit,
            ocrFallbackReason: ocr.isEmpty
                ? nil
                : (browser?.requiresOCR == true ? "browser=pixelOnly" : "ax=\(ax.quality.rawValue)"),
            manualAccessibilityResult: ax.manualResult, enhancedUiResult: ax.enhancedResult)

        let record = ScreenCaptureRecord(
            timestamp: Date(), bundleId: bundleId, appName: appName,
            windowTitle: browser?.title ?? ax.windowTitle,
            browserURL: browser?.url ?? ax.browserURL,
            monitorId: monitorId,
            image: image, pixelWidth: width, pixelHeight: height,
            textBlocks: blocks, axQuality: quality, telemetry: tel)
        do {
            _ = try await ingest.ingest(record)
            onFrame?()
        } catch {
            Log.ingest.error("screen_frame_ingest_failed")
        }
    }

    private func throttledBrowserOCR(bundleID: String, requested: Bool) -> Bool {
        guard requested else { return false }
        let now = Date()
        if !BrowserCapturePolicy.allowsBrowserOCR(
            lastAt: lastBrowserOCRAt[bundleID],
            now: now,
            interval: config.browserOCRIntervalSec
        ) {
            return false
        }
        lastBrowserOCRAt[bundleID] = now
        return true
    }
}
