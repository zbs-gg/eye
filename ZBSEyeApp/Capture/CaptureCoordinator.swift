import Foundation
import AppKit
import CoreGraphics

struct CaptureDrainAcknowledgement: Sendable, Equatable {
    let hadActiveCapture: Bool
    let hadInFlightCycle: Bool
    let activeCycles: Int
}

/// Exact running-process identities that can change the privacy content filter.
/// PID keeps launch/exit ABA transitions visible even when the same bundle is
/// replaced between two snapshots.
private enum CapturePrivacyApplicationIdentity: Hashable {
    case protected(ProtectedCaptureApplicationIdentity)
    case ignored(processIdentifier: Int32, bundleIdentifier: String)
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
    private let healthController: CaptureHealthController
    private let streamEventFence: ScreenStreamEventFence
    private let screenshotPriorityGate: ScreenshotPriorityYieldGate
    private let screenshotHotkeyMonitor: ScreenshotHotkeyMonitor

    private(set) var isRunning = false
    private var sessionGate = CaptureSessionGateState(reasons: [])
    private var gateRevision: UInt64 = 0
    private var suspended: Bool { sessionGate.suspended }
    private var screenLocked: Bool { sessionGate.screenLocked }
    private var tickTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var runningApplicationsObservation: NSKeyValueObservation?
    private var cycleTask: Task<Void, Never>?
    private var cycleGeneration: UInt64 = 0
    private var contentTopologyRevision: UInt64 = 0
    private var workPolicy = LatestCaptureWorkPolicy()
    private var privacyApplicationInventory: Set<CapturePrivacyApplicationIdentity>?

    private var capability: [String: CaptureClass] = [:]
    private var capabilityCheckedAt: [String: Date] = [:]
    private var emptyStreak: [String: Int] = [:]
    private var lastContentText: [String: String] = [:]
    private var lastBrowserContentHash: [String: String] = [:]
    private var lastBrowserOCRAt: [String: Date] = [:]
    private var lastIdleCaptureAt = Date.distantPast
    private var lastProtectedSystemShell: String?

    var onFrame: (@MainActor () -> Void)?
    /// Returns false at critically low free space — the cycle skips capture (we don't fill the disk to the brim).
    var diskOK: @MainActor () -> Bool = { true }
    /// Privacy exclusions (1Password/bank): true → we don't record the app. Default — record everything.
    var isIgnoredApp: @MainActor (String) -> Bool = { _ in false }
    /// The full list of excluded ones (for SCContentFilter: cut their windows out of ANY frame, not just the focus one).
    var ignoredBundleIds: @MainActor () -> Set<String> = { [] }

    init(
        ingest: IngestService,
        browserContent: BrowserContentStore,
        config: CaptureConfig = CaptureConfig(),
        healthController: CaptureHealthController? = nil,
        resourceCoordinator: SCKResourceCoordinator,
        screenshotPriorityGate: ScreenshotPriorityYieldGate = ScreenshotPriorityYieldGate()
    ) {
        let controller = healthController
            ?? CaptureHealthController(nowMs: Self.epochMs())
        let eventFence = ScreenStreamEventFence()
        self.ingest = ingest
        self.browserContent = browserContent
        self.config = config
        self.axReader = AXReader(config: config)
        self.healthController = controller
        self.streamEventFence = eventFence
        self.screenshotPriorityGate = screenshotPriorityGate
        self.screenshotHotkeyMonitor = ScreenshotHotkeyMonitor(gate: screenshotPriorityGate)
        self.pipeline = FramePipeline(
            config: config,
            resourceCoordinator: resourceCoordinator,
            eventFence: eventFence,
            eventSink: { [weak controller] envelope in
                guard eventFence.isCurrent(envelope.fenceRevision) else { return }
                switch envelope.event {
                case .started(let generation):
                    controller?.screenStreamDidStart(
                        generation: generation,
                        nowMs: Self.epochMs()
                    )
                case .heartbeat(let stamp):
                    controller?.recordScreenStreamFrame(stamp, nowMs: Self.epochMs())
                case .failed(let generation, let reason):
                    controller?.recordScreenStreamFailure(
                        generation: generation,
                        reason: reason,
                        nowMs: Self.epochMs()
                    )
                }
            }
        )
        loadCapability()
        screenshotPriorityGate.onSuppressionOpened = { [weak self] _ in
            self?.yieldToNativeScreenshot()
        }
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
        if !initialSessionGate.isOpen {
            healthController.setSuspension(.locked, nowMs: Self.epochMs())
        }

        let wsc = NSWorkspace.shared.notificationCenter
        observers.append(wsc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trigger() }
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
            _ = note
            _ = MainActor.assumeIsolated {
                self?.reconcileRunningPrivacyApplications()
            }
        })
        observers.append(wsc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                         object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            _ = MainActor.assumeIsolated {
                self?.reconcileRunningPrivacyApplications()
            }
            Task { @MainActor in
                guard let self else { return }
                await self.axReader.forget(pid: pid)
            }
        })
        // NSWorkspace lifecycle notifications omit background and LSUIElement
        // processes. Observe the complete KVO inventory so an ignored helper or
        // authentication UI cannot appear behind a previously-built SCK filter.
        runningApplicationsObservation = NSWorkspace.shared.observe(
            \.runningApplications,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            runCaptureObservationOnMainActorSynchronously {
                self?.reconcileRunningPrivacyApplications()
            }
        }

        // A change in display configuration (connecting/disconnecting a monitor, a resolution change) —
        // the SCShareableContent cache goes stale instantly, otherwise capture breaks until an app change.
        defaultObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.revokeCaptureForStreamTopologyChange(.displayChanged)
            }
            Task { @MainActor in
                guard let self else { return }
                let drained = await self.pipeline.resetDisposableState()
                guard drained else {
                    self.healthController.recordScreenPipelineFailure(
                        nowMs: Self.epochMs()
                    )
                    return
                }
                if self.isRunning, !self.suspended { self.trigger() }
            }
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
        _ = screenshotHotkeyMonitor.start()
        if initialSessionGate.isOpen { trigger() }
    }

    func stop() {
        let cycle = stopAdmission()
        Task { [axReader, pipeline, browserContent] in
            await cycle?.value
            await axReader.reset()
            _ = await pipeline.resetDisposableState()
            await browserContent.clear()
        }
    }

    /// Called by PrivacyStore on an exact user-list mutation. The active SCK
    /// filter was built from the previous SCShareableContent inventory, so
    /// revoke admission before rebuilding it with the new exclusion set.
    func privacyExclusionsDidChange() {
        guard isRunning else { return }
        privacyApplicationInventory = currentPrivacyApplicationInventory()
        revokeCaptureForStreamTopologyChange(.contentTopologyChanged)
        refreshContentAfterTopologyChange()
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
        let screenDrained = await pipeline.resetDisposableState()
        await browserContent.clear()
        return CaptureDrainAcknowledgement(
            hadActiveCapture: wasRunning,
            hadInFlightCycle: hadInFlightCycle,
            activeCycles: screenDrained ? 0 : 1
        )
    }

    /// Executes one controller-admitted Eye-owned recovery attempt. It resets
    /// only this app's disposable screenshot state; it never changes TCC or a
    /// global macOS capture service.
    func performScreenRecovery(_ attempt: CaptureRecoveryAttempt) async {
        guard attempt.leg == .screen,
              healthController.isCurrentRecoveryAttempt(attempt),
              isRunning,
              !suspended,
              !screenLocked else {
            healthController.recoveryAttemptFailed(
                leg: .screen,
                generation: attempt.generation,
                reason: .screenStreamStopped,
                nowMs: Self.epochMs()
            )
            return
        }
        invalidateScreenPipeline(
            .recovery,
            screenLocked: false,
            nowMs: Self.epochMs()
        )
        guard await pipeline.resetDisposableState() else {
            healthController.recoveryAttemptFailed(
                leg: .screen,
                generation: attempt.generation,
                reason: .screenStreamStopped,
                nowMs: Self.epochMs()
            )
            return
        }
        guard healthController.markScreenRecoveryReady(attempt) else {
            healthController.recoveryAttemptFailed(
                leg: .screen,
                generation: attempt.generation,
                reason: .screenStreamStopped,
                nowMs: Self.epochMs()
            )
            return
        }
        trigger()
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
        runningApplicationsObservation?.invalidate()
        runningApplicationsObservation = nil
        privacyApplicationInventory = nil
        tickTimer?.invalidate(); tickTimer = nil
        screenshotHotkeyMonitor.stop()
        gateRevision &+= 1
        cycleGeneration &+= 1
        let cycle = cycleTask
        cycle?.cancel(); cycleTask = nil
        workPolicy.cancelAll()
        invalidateScreenPipeline(
            .recovery,
            screenLocked: screenLocked,
            nowMs: Self.epochMs()
        )
        Task { [pipeline] in await pipeline.discardPendingIntent() }
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
            healthController.recordScreenIntentional(.userIdle, nowMs: Self.epochMs())
            let now = Date()
            if now.timeIntervalSince(lastIdleCaptureAt) >= config.idleCaptureIntervalSec {
                lastIdleCaptureAt = now
                trigger()
            }
            return
        }
        trigger()
    }

    private func trigger() {
        guard isRunning, !suspended,
              CaptureSessionPolicy.mayCapture(screenLocked: screenLocked),
              !screenshotPriorityGate.isSuppressed() else { return }
        switch workPolicy.submit() {
        case .queued:
            return
        case .start(let intentID):
            startWork(intentID)
        }
    }

    private func startWork(_ intentID: UInt64) {
        cycleGeneration &+= 1
        let generation = cycleGeneration
        cycleTask = Task(priority: .utility) { @MainActor [weak self] in
            await self?.runCycle()
            guard let self, self.cycleGeneration == generation else { return }
            self.cycleTask = nil
            if let next = self.workPolicy.complete(intentID) {
                self.startWork(next)
            }
        }
    }

    private func yieldToNativeScreenshot() {
        workPolicy.discardWaiting()
        cycleTask?.cancel()
        Task { [pipeline] in await pipeline.discardPendingIntent() }
    }

    /// A newly launched or terminated excluded/protected process changes the
    /// contents of SCShareableContent. Revoke the current cycle synchronously
    /// so pixels from a now-private window cannot commit while the persistent
    /// stream is being rebuilt with a fresh filter.
    private func revokeCaptureForStreamTopologyChange(
        _ reason: CapturePipelineInvalidationReason
    ) {
        contentTopologyRevision &+= 1
        workPolicy.discardWaiting()
        cycleTask?.cancel()
        invalidateScreenPipeline(
            reason,
            screenLocked: screenLocked,
            nowMs: Self.epochMs()
        )
        Task { [pipeline] in await pipeline.discardPendingIntent() }
    }

    private func currentPrivacyApplicationInventory()
        -> Set<CapturePrivacyApplicationIdentity> {
        let ignored = ignoredBundleIds()
        return Set(NSWorkspace.shared.runningApplications.compactMap { application in
            let processIdentifier = Int32(application.processIdentifier)
            let bundleIdentifier = application.bundleIdentifier
            let applicationName = application.localizedName
            if CaptureSessionPolicy.isProtectedCaptureSurface(
                bundleId: bundleIdentifier,
                appName: applicationName
            ) {
                return .protected(ProtectedCaptureApplicationIdentity(
                    bundleIdentifier: bundleIdentifier,
                    applicationName: applicationName,
                    processIdentifier: processIdentifier
                ))
            }
            guard let bundleIdentifier,
                  ignored.contains(bundleIdentifier) else { return nil }
            return .ignored(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
        })
    }

    /// Returns true when a lifecycle edge changed the filter topology and the
    /// caller must abandon work admitted under the previous inventory.
    @discardableResult
    private func reconcileRunningPrivacyApplications() -> Bool {
        let next = currentPrivacyApplicationInventory()
        guard let previous = privacyApplicationInventory else {
            privacyApplicationInventory = next
            return false
        }
        guard next != previous else { return false }
        privacyApplicationInventory = next

        let previousProtected = Set(previous.compactMap { identity -> ProtectedCaptureApplicationIdentity? in
            guard case .protected(let application) = identity else { return nil }
            return application
        })
        let nextProtected = Set(next.compactMap { identity -> ProtectedCaptureApplicationIdentity? in
            guard case .protected(let application) = identity else { return nil }
            return application
        })
        if previousProtected != nextProtected {
            CaptureSessionPolicy.recordProtectedApplicationInventoryChange()
        }

        guard isRunning else { return true }
        revokeCaptureForStreamTopologyChange(.contentTopologyChanged)
        refreshContentAfterTopologyChange()
        return true
    }

    private func refreshContentAfterTopologyChange() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let drained = await self.pipeline.invalidateContent()
            guard drained else {
                self.healthController.recordScreenPipelineFailure(
                    nowMs: Self.epochMs()
                )
                return
            }
            if self.isRunning, !self.suspended { self.trigger() }
        }
    }

    private func privacyApplicationInventoryStillMatches(
        _ expected: Set<CapturePrivacyApplicationIdentity>
    ) -> Bool {
        guard currentPrivacyApplicationInventory() == expected else {
            reconcileRunningPrivacyApplications()
            return false
        }
        return true
    }

    private static func userIgnoredApplicationSnapshot(
        from inventory: Set<CapturePrivacyApplicationIdentity>
    ) -> UserIgnoredCaptureApplicationSnapshot {
        Set(inventory.compactMap { identity in
            guard case let .ignored(processIdentifier, bundleIdentifier) = identity else {
                return nil
            }
            return UserIgnoredCaptureApplicationIdentity(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
        })
    }

    // MARK: cycle

    private func runCycle() async {
        if reconcileRunningPrivacyApplications() { return }
        let expectedPrivacyApplicationInventory = privacyApplicationInventory
            ?? currentPrivacyApplicationInventory()
        let userIgnoredApplicationSnapshot = Self.userIgnoredApplicationSnapshot(
            from: expectedPrivacyApplicationInventory
        )
        let screenshotPriorityRevision = screenshotPriorityGate.revision
        let expectedContentTopologyRevision = contentTopologyRevision
        guard !screenshotPriorityGate.isSuppressed() else { return }
        // Notifications are advisory: query the current login session before
        // doing any AX or ScreenCaptureKit work so a missed lock event cannot
        // admit captured pixels even temporarily.
        guard currentSessionStillAllowsCapture() else { return }
        guard diskOK() else { return }   // disk almost full — we don't write (AppEnvironment raises the status)
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else { return }
        let appName = app.localizedName ?? bundleId
        guard !ScreenshotPriorityProcessPolicy.isNativeScreenshotProcess(
            bundleIdentifier: bundleId,
            executablePath: app.executableURL?.path
        ) else {
            healthController.recordScreenIntentional(
                .privacyExcluded,
                nowMs: Self.epochMs()
            )
            return
        }
        guard CaptureSessionPolicy.mayCapture(
            screenLocked: screenLocked,
            bundleId: bundleId,
            appName: appName
        ) else {
            if lastProtectedSystemShell != bundleId {
                Log.capture.error("capture refused for protected system shell: \(bundleId, privacy: .public)")
                lastProtectedSystemShell = bundleId
            }
            healthController.recordScreenIntentional(.privacyExcluded, nowMs: Self.epochMs())
            return
        }
        lastProtectedSystemShell = nil
        let pid = app.processIdentifier
        let windowInfo = Self.frontmostWindowInfo(pid: pid)
        var excludes = ignoredBundleIds()
        if let own = Bundle.main.bundleIdentifier { excludes.insert(own) }
        let protectedApplicationSnapshot = CaptureSessionPolicy.protectedRunningApplicationSnapshot()

        // privacy exclusion: a deliberate skip = cycle health (heartbeat), not a failure
        if isIgnoredApp(bundleId) {
            guard screenshotPriorityGate.revision == screenshotPriorityRevision,
                  !screenshotPriorityGate.isSuppressed() else { return }
            guard await reconcilePersistentStreamForIntentionalCycle(
                displayID: windowInfo.displayID,
                excludedBundleIds: excludes,
                protectedApplicationSnapshot: protectedApplicationSnapshot,
                userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot
            ) else { return }
            guard contentTopologyRevision == expectedContentTopologyRevision,
                  privacyApplicationInventoryStillMatches(
                    expectedPrivacyApplicationInventory
                  ) else { return }
            healthController.recordScreenIntentional(.privacyExcluded, nowMs: Self.epochMs())
            return
        }
        // THE MAIN FIX (Pro's diagnosis): NEVER capture our own process. On a "Record" click ZBS Eye
        // stays frontmost → AXReader would read OUR AX tree → kAXValue on our SwiftUI Slider synchronously
        // calls its @MainActor Binding.get (TimelineView) right on the axreader queue → dispatch_assert_queue → crash.
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            guard screenshotPriorityGate.revision == screenshotPriorityRevision,
                  !screenshotPriorityGate.isSuppressed() else { return }
            guard await reconcilePersistentStreamForIntentionalCycle(
                displayID: windowInfo.displayID,
                excludedBundleIds: excludes,
                protectedApplicationSnapshot: protectedApplicationSnapshot,
                userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot
            ) else { return }
            guard contentTopologyRevision == expectedContentTopologyRevision,
                  privacyApplicationInventoryStillMatches(
                    expectedPrivacyApplicationInventory
                  ) else { return }
            healthController.recordScreenIntentional(.selfAppExcluded, nowMs: Self.epochMs())
            return
        }

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
        guard currentSessionStillAllowsCapture(),
              contentTopologyRevision == expectedContentTopologyRevision,
              privacyApplicationInventoryStillMatches(
                expectedPrivacyApplicationInventory
              ),
              screenshotPriorityGate.revision == screenshotPriorityRevision,
              !screenshotPriorityGate.isSuppressed() else { return }

        // The display of the FRONTMOST window by GEOMETRY. NSScreen.main won't do here: it's the screen of OUR
        // app's key window — when ZBS Eye is in the background (always while recording), it would give the primary
        // display, not the screen of the other app's active window.
        let focusedDisplayID = windowInfo.displayID

        let frame: ProcessedFrame?
        do {
            frame = try await pipeline.process(displayID: focusedDisplayID, needsOCR: needsOCR,
                                               excludedBundleIds: excludes,
                                               protectedApplicationSnapshot: protectedApplicationSnapshot,
                                               userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot)
        } catch is CancellationError {
            return
        } catch let streamError as ScreenCaptureStreamError {
            switch streamError {
            case .superseded, .stopped, .inactiveGeneration:
                return
            case .missingPixelBuffer:
                Log.capture.error("screen_stream_missing_pixel_buffer")
                return
            }
        } catch let captureError as CaptureError {
            if captureError == .streamStartFailed
                || captureError == .streamUpdateFailed
                || captureError == .streamStopUnconfirmed {
                healthController.recordScreenPipelineFailure(
                    .screenStreamStopped,
                    nowMs: Self.epochMs()
                )
            }
            Log.capture.error("screen_stream_cycle_failed")
            return
        } catch {
            Log.capture.error("screen_stream_cycle_failed")
            return
        }
        guard let frame else { return }
        guard CaptureSessionPolicy.protectedRunningApplicationSnapshot()
                == protectedApplicationSnapshot else {
            revokeCaptureForStreamTopologyChange(.contentTopologyChanged)
            let drained = await pipeline.invalidateContent()
            if !drained {
                healthController.recordScreenPipelineFailure(nowMs: Self.epochMs())
            }
            return
        }
        // Lock/display notifications can arrive while AX/SCK work is suspended at an await.
        // Re-read both tracked state and the current shell before committing any captured bytes.
        guard currentSessionStillAllowsCapture(),
              contentTopologyRevision == expectedContentTopologyRevision,
              privacyApplicationInventoryStillMatches(
                expectedPrivacyApplicationInventory
              ),
              screenshotPriorityGate.revision == screenshotPriorityRevision,
              !screenshotPriorityGate.isSuppressed() else { return }

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

    /// An intentional content skip still depends on the shared physical stream
    /// being alive and carrying the current privacy filter. Never turn an SCK
    /// start/update/stop failure into a healthy privacy/self heartbeat.
    private func reconcilePersistentStreamForIntentionalCycle(
        displayID: CGDirectDisplayID?,
        excludedBundleIds: Set<String>,
        protectedApplicationSnapshot: ProtectedCaptureApplicationSnapshot,
        userIgnoredApplicationSnapshot: UserIgnoredCaptureApplicationSnapshot
    ) async -> Bool {
        do {
            try await pipeline.reconcilePersistentStream(
                displayID: displayID,
                excludedBundleIds: excludedBundleIds,
                protectedApplicationSnapshot: protectedApplicationSnapshot,
                userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot
            )
            return true
        } catch is CancellationError {
            return false
        } catch let captureError as CaptureError {
            switch captureError {
            case .streamStartFailed, .streamUpdateFailed, .streamStopUnconfirmed:
                healthController.recordScreenPipelineFailure(
                    .screenStreamStopped,
                    nowMs: Self.epochMs()
                )
            case .staleGeneration, .noDisplay, .encodeFailed:
                break
            }
            Log.capture.error("screen_stream_reconcile_failed")
            return false
        } catch {
            Log.capture.error("screen_stream_reconcile_failed")
            return false
        }
    }

    private static func epochMs(_ date: Date = Date()) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
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
        invalidateScreenPipeline(
            .unlock,
            screenLocked: false,
            nowMs: Self.epochMs()
        )
        // Keep admission closed while the actor invalidates its session epoch.
        guard await pipeline.invalidateSessionBoundary() else {
            healthController.recordScreenPipelineFailure(
                nowMs: Self.epochMs()
            )
            return
        }
        guard isRunning, gateRevision == expectedRevision else { return }
        guard Self.currentSessionLocked() == false else {
            suspend(for: .session)
            return
        }
        applySessionGate(gate)
        guard gate.isOpen else { return }
        trigger()
    }

    private func suspend(for reason: CaptureSuspensionReasons) {
        let wasOpen = sessionGate.isOpen
        let gate = CaptureSessionPolicy.suspendedGate(previous: sessionGate, adding: reason)
        applySessionGate(gate)
        guard wasOpen, gate.suspended else { return }
        invalidateScreenPipeline(
            .suspension,
            screenLocked: gate.screenLocked,
            nowMs: Self.epochMs()
        )
        workPolicy.discardWaiting()
        cycleTask?.cancel()
        Task { [pipeline] in _ = await pipeline.invalidateSessionBoundary() }
    }

    private func applySessionGate(_ gate: CaptureSessionGateState) {
        guard gate != sessionGate else { return }
        sessionGate = gate
        gateRevision &+= 1
        let reason: CaptureSuspensionReason?
        if gate.reasons.contains(.session) {
            reason = .locked
        } else if gate.suspended {
            reason = .sleeping
        } else {
            reason = nil
        }
        healthController.setSuspension(reason, nowMs: Self.epochMs())
    }

    /// Retire queued events before the health generation itself changes. SCK
    /// callbacks arrive on a different queue, so a `.started` already waiting
    /// for MainActor must not resurrect a stream invalidated by privacy,
    /// display, suspension, or recovery.
    private func invalidateScreenPipeline(
        _ reason: CapturePipelineInvalidationReason,
        screenLocked: Bool,
        nowMs: Int64
    ) {
        streamEventFence.invalidate()
        healthController.invalidatePipeline(
            reason,
            screenLocked: screenLocked,
            nowMs: nowMs
        )
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
