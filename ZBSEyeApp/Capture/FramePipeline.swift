import Foundation
import ScreenCaptureKit
import CoreImage
import CoreVideo
import CoreGraphics
import ImageIO
import Vision
import Metal

struct OCRLine: Sendable {
    var text: String
    var confidence: Double
    var bbox: CGRect?     // normalized bbox from Vision (0..1, origin bottom-left) — for "click on what was found" / future redaction
}

/// CGImage is immutable and thread-safe — safe to run off the actor for OCR.
struct SendableCGImage: @unchecked Sendable { let image: CGImage }

/// GCD work does not inherit Swift task cancellation. The token lets queued
/// Vision work decline to start, and lets already-running synchronous Vision
/// discard its result once the screenshot-priority boundary closes.
private final class OCRCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

struct ProcessedFrame: Sendable {
    var heicData: Data
    var phash: UInt64
    var fingerprint: String
    var isDuplicate: Bool
    var width: Int
    var height: Int
    var ocr: [OCRLine]
    var displayID: UInt32   // which display we actually captured (monitorId in the DB)
}

enum CaptureError: Error, Equatable {
    case noDisplay
    case encodeFailed
    case staleGeneration
    case streamStartFailed
    case streamUpdateFailed
    case streamStopUnconfirmed
}

/// FramePipelineActor (per Pro): capture + encode + hash + OCR in ONE isolation domain. CGImage/
/// CVPixelBuffer live and die here; only a Sendable ProcessedFrame goes out. A reused
/// Metal CIContext. Perceptual-hash dedup (stores a UInt64, not the buffer).
actor FramePipeline {
    private struct ActiveStream {
        let stream: SCStream
        let generation: Int64
        var displayID: CGDirectDisplayID
        var width: Int
        var height: Int
        let excludedBundleIDs: Set<String>
        let protectedApplicationSnapshot: ProtectedCaptureApplicationSnapshot
        let userIgnoredApplicationSnapshot: UserIgnoredCaptureApplicationSnapshot
    }

    private struct StartingStream {
        let stream: SCStream
        let generation: Int64
        let controlRevision: UInt64
        let startHandshake: ScreenStreamStartHandshake
    }

    private struct StreamIdentity: Equatable {
        let stream: SCStream
        let generation: Int64
        let startHandshake: ScreenStreamStartHandshake?

        static func == (lhs: Self, rhs: Self) -> Bool {
            ObjectIdentifier(lhs.stream) == ObjectIdentifier(rhs.stream)
        }
    }

    private let config: CaptureConfig
    private let resourceCoordinator: SCKResourceCoordinator
    private let eventFence: ScreenStreamEventFence
    private let ciContext: CIContext
    private let streamOutput: ScreenCaptureStreamOutput
    private let sampleQueue = DispatchQueue(
        label: "com.zbseye.screen.samples",
        qos: .utility
    )
    private var cachedContent: SCShareableContent?
    private var cachedProtectedApplicationSnapshot: ProtectedCaptureApplicationSnapshot?
    private var cachedUserIgnoredApplicationSnapshot: UserIgnoredCaptureApplicationSnapshot?
    private var contentEpoch = CaptureContentEpoch()
    private var lastHashes: [Int: [UInt64]] = [:]   // [full, 4 quadrants] per display
    private var activeStream: ActiveStream?
    private var startingStream: StartingStream?
    private var stopOwnership = ScreenStreamStopOwnership<StreamIdentity>()
    private var stopWaiters: [CheckedContinuation<Bool, Never>] = []
    private var ensureOwnershipHeld = false
    private var ensureOwnershipWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextStreamGeneration: Int64 = 0
    private var controlRevision: UInt64 = 0

    init(
        config: CaptureConfig,
        resourceCoordinator: SCKResourceCoordinator,
        eventFence: ScreenStreamEventFence,
        eventSink: @escaping @MainActor @Sendable (ScreenStreamEventEnvelope) -> Void
    ) {
        self.config = config
        self.resourceCoordinator = resourceCoordinator
        self.eventFence = eventFence
        self.streamOutput = ScreenCaptureStreamOutput(
            livenessTimeoutSeconds: config.streamLivenessTimeoutSec,
            eventSink: eventSink
        )
        // cacheIntermediates:false — the biggest steady-RAM win: a shared CIContext otherwise piles up GPU
        // texture caches across frames (measured: ~550MB of stale IOSurface). We render each frame once and
        // don't reuse intermediates, so caching only costs memory. clearCaches() after each frame reclaims the rest.
        let opts: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "ZBSEyeFramePipeline"]
        if let dev = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: dev, options: opts)
        } else {
            self.ciContext = CIContext(options: opts)
        }
    }

    @discardableResult
    func invalidateContent() async -> Bool {
        contentEpoch.invalidate()
        cachedContent = nil
        cachedProtectedApplicationSnapshot = nil
        cachedUserIgnoredApplicationSnapshot = nil
        return await stopPersistentStream(clearHashes: false)
    }

    /// A verified login-session boundary must produce a fresh ordinary frame.
    /// Reset only here: clearing hashes on every app activation would defeat dedup.
    @discardableResult
    func invalidateSessionBoundary() async -> Bool {
        contentEpoch.invalidate()
        cachedContent = nil
        cachedProtectedApplicationSnapshot = nil
        cachedUserIgnoredApplicationSnapshot = nil
        lastHashes.removeAll(keepingCapacity: true)
        return await stopPersistentStream(clearHashes: false)
    }

    /// Rebuild only Eye-owned disposable ScreenCaptureKit/dedup state. User
    /// intent, privacy configuration, and learned AX capability live elsewhere.
    @discardableResult
    func resetDisposableState() async -> Bool {
        contentEpoch.invalidate()
        cachedContent = nil
        cachedProtectedApplicationSnapshot = nil
        cachedUserIgnoredApplicationSnapshot = nil
        lastHashes.removeAll(keepingCapacity: false)
        return await stopPersistentStream(clearHashes: false)
    }

    func discardPendingIntent() {
        streamOutput.cancelPendingFrame()
    }

    private func currentContent(
        expectedEpoch: UInt64,
        protectedApplicationSnapshot: ProtectedCaptureApplicationSnapshot,
        userIgnoredApplicationSnapshot: UserIgnoredCaptureApplicationSnapshot
    ) async throws -> SCShareableContent {
        if cachedProtectedApplicationSnapshot != protectedApplicationSnapshot
            || cachedUserIgnoredApplicationSnapshot != userIgnoredApplicationSnapshot {
            cachedContent = nil
            cachedProtectedApplicationSnapshot = nil
            cachedUserIgnoredApplicationSnapshot = nil
        }
        if let c = cachedContent {
            guard Self.contentCoversExpectedPrivacyApplications(
                c,
                protectedApplicationSnapshot: protectedApplicationSnapshot,
                userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot
            ) else {
                invalidateAfterPrivacyApplicationChange()
                _ = await stopPersistentStream(clearHashes: false)
                throw CaptureError.staleGeneration
            }
            return c
        }
        // Keep the complete application inventory. LocalAuthentication helpers
        // are often long-lived with only offscreen windows, and therefore vanish
        // from an on-screen-only inventory just before their sheet appears.
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard contentEpoch.contains(expectedEpoch) else { throw CaptureError.staleGeneration }
        guard Self.contentCoversExpectedPrivacyApplications(
            c,
            protectedApplicationSnapshot: protectedApplicationSnapshot,
            userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot
        ) else {
            invalidateAfterPrivacyApplicationChange()
            _ = await stopPersistentStream(clearHashes: false)
            throw CaptureError.staleGeneration
        }
        cachedContent = c
        cachedProtectedApplicationSnapshot = protectedApplicationSnapshot
        cachedUserIgnoredApplicationSnapshot = userIgnoredApplicationSnapshot
        return c
    }

    private static func contentCoversExpectedPrivacyApplications(
        _ content: SCShareableContent,
        protectedApplicationSnapshot: ProtectedCaptureApplicationSnapshot,
        userIgnoredApplicationSnapshot: UserIgnoredCaptureApplicationSnapshot
    ) -> Bool {
        contentCoversProtectedApplications(
            content,
            expected: protectedApplicationSnapshot
        ) && contentCoversUserIgnoredApplications(
            content,
            expected: userIgnoredApplicationSnapshot
        )
    }

    private static func contentCoversProtectedApplications(
        _ content: SCShareableContent,
        expected: ProtectedCaptureApplicationSnapshot
    ) -> Bool {
        let represented: Set<ProtectedCaptureApplicationIdentity> = Set(
            content.applications.compactMap { application -> ProtectedCaptureApplicationIdentity? in
                guard CaptureSessionPolicy.isProtectedCaptureSurface(
                    bundleId: application.bundleIdentifier,
                    appName: application.applicationName
                ) else { return nil }
                return ProtectedCaptureApplicationIdentity(
                    bundleIdentifier: application.bundleIdentifier,
                    applicationName: application.applicationName,
                    processIdentifier: Int32(application.processID)
                )
            }
        )
        return CaptureSessionPolicy.contentCoversProtectedApplications(
            expected: expected,
            represented: represented
        )
    }

    private static func contentCoversUserIgnoredApplications(
        _ content: SCShareableContent,
        expected: UserIgnoredCaptureApplicationSnapshot
    ) -> Bool {
        let represented = Set(content.applications.map {
            UserIgnoredCaptureApplicationIdentity(
                processIdentifier: Int32($0.processID),
                bundleIdentifier: $0.bundleIdentifier
            )
        })
        return CaptureSessionPolicy.contentCoversUserIgnoredApplications(
            expected: expected,
            represented: represented
        )
    }

    private func invalidateAfterPrivacyApplicationChange() {
        contentEpoch.invalidate()
        cachedContent = nil
        cachedProtectedApplicationSnapshot = nil
        cachedUserIgnoredApplicationSnapshot = nil
    }

    private func display(
        matching displayID: CGDirectDisplayID?,
        in content: SCShareableContent
    ) throws -> SCDisplay {
        guard let display = content.displays.first(where: {
            displayID == nil || $0.displayID == displayID
        }) ?? content.displays.first else { throw CaptureError.noDisplay }
        return display
    }

    private func captureFilter(
        display: SCDisplay,
        content: SCShareableContent,
        excludedBundleIDs: Set<String>
    ) -> SCContentFilter {
        let excludedApplications = content.applications.filter {
            excludedBundleIDs.contains($0.bundleIdentifier)
                || ScreenshotPriorityProcessPolicy.isNativeScreenshotApplication(
                    bundleIdentifier: $0.bundleIdentifier
                )
                || CaptureSessionPolicy.isProtectedCaptureSurface(
                    bundleId: $0.bundleIdentifier,
                    appName: $0.applicationName
                )
        }
        return SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
    }

    private func streamConfiguration(for display: SCDisplay) -> SCStreamConfiguration {
        let (width, height) = Self.cappedSize(
            display.width,
            display.height,
            maxDim: config.maxCaptureDim
        )
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(
            seconds: max(2.0, config.streamFrameIntervalSec),
            preferredTimescale: 600
        )
        configuration.queueDepth = max(1, config.streamQueueDepth)
        return configuration
    }

    /// SCK may finish an update while callbacks produced by the old filter are
    /// still queued. This fence lets every older callback finish before the
    /// output bridge is rebound to a new logical generation.
    private func drainSampleQueue() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                continuation.resume()
            }
        }
    }

    private func acquireEnsureOwnership() async {
        guard ensureOwnershipHeld else {
            ensureOwnershipHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            ensureOwnershipWaiters.append(continuation)
        }
    }

    private func releaseEnsureOwnership() {
        guard !ensureOwnershipWaiters.isEmpty else {
            ensureOwnershipHeld = false
            return
        }
        let next = ensureOwnershipWaiters.removeFirst()
        // Ownership transfers directly; the flag deliberately stays true.
        next.resume()
    }

    private func waitForInFlightStop() async -> Bool {
        guard stopOwnership.stopping != nil else { return true }
        return await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    /// Keeps one physical stream alive. Focus moving to another display updates
    /// the existing stream in place; only display/privacy/protected topology or
    /// a lifecycle boundary drains it and creates a new generation.
    private func ensurePersistentStream(
        displayID: CGDirectDisplayID?,
        excludedBundleIDs: Set<String>,
        protectedApplicationSnapshot: ProtectedCaptureApplicationSnapshot,
        userIgnoredApplicationSnapshot: UserIgnoredCaptureApplicationSnapshot
    ) async throws -> ActiveStream {
        await acquireEnsureOwnership()
        defer { releaseEnsureOwnership() }

        while true {
            try Task.checkCancellation()
            let eventRevision = eventFence.snapshot()
            try Task.checkCancellation()
            if stopOwnership.stopping != nil {
                guard await waitForInFlightStop() else {
                    throw CaptureError.streamStopUnconfirmed
                }
                // Every fact observed before a suspended stop is stale. Restart
                // from the ownership/topology gates instead of continuing toward
                // a replacement with pre-stop state.
                continue
            }
            guard startingStream == nil else { throw CaptureError.staleGeneration }
            if let failedStop = stopOwnership.failed {
                if streamOutput.didStopExternally(stream: failedStop.stream) {
                    try? failedStop.stream.removeStreamOutput(streamOutput, type: .screen)
                    guard stopOwnership.acknowledgeExternalStop(failedStop) else {
                        throw CaptureError.streamStopUnconfirmed
                    }
                } else {
                    throw CaptureError.streamStopUnconfirmed
                }
            }
            guard stopOwnership.permitsReplacement else {
                throw CaptureError.streamStopUnconfirmed
            }

            if let activeStream,
               activeStream.excludedBundleIDs != excludedBundleIDs
                || activeStream.protectedApplicationSnapshot != protectedApplicationSnapshot
                || activeStream.userIgnoredApplicationSnapshot != userIgnoredApplicationSnapshot {
                guard await stopPersistentStream(clearHashes: false) else {
                    throw CaptureError.streamStopUnconfirmed
                }
                continue
            }

            let expectedEpoch = contentEpoch.value
            let content = try await currentContent(
                expectedEpoch: expectedEpoch,
                protectedApplicationSnapshot: protectedApplicationSnapshot,
                userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot
            )
            guard contentEpoch.contains(expectedEpoch),
                  await CaptureSessionPolicy.protectedRunningApplicationSnapshot()
                    == protectedApplicationSnapshot,
                  Self.contentCoversExpectedPrivacyApplications(
                    content,
                    protectedApplicationSnapshot: protectedApplicationSnapshot,
                    userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot
                  ) else {
                invalidateAfterPrivacyApplicationChange()
                _ = await stopPersistentStream(clearHashes: false)
                throw CaptureError.staleGeneration
            }
            let selectedDisplay = try display(matching: displayID, in: content)

            if let activeStream {
                guard streamOutput.isCurrentAndPublished(
                    stream: activeStream.stream,
                    generation: activeStream.generation,
                    eventRevision: eventRevision
                ) else {
                    guard await stopPersistentStream(clearHashes: false) else {
                        throw CaptureError.streamStopUnconfirmed
                    }
                    throw CaptureError.streamStartFailed
                }
                guard activeStream.displayID != selectedDisplay.displayID else { return activeStream }
                let filter = captureFilter(
                    display: selectedDisplay,
                    content: content,
                    excludedBundleIDs: excludedBundleIDs
                )
                let configuration = streamConfiguration(for: selectedDisplay)
                let revision = controlRevision
                try Task.checkCancellation()
                var updateWasInvoked = false
                do {
                    try await resourceCoordinator.withExclusiveAccess(
                        owner: .screen,
                        operation: .update
                    ) {
                        try Task.checkCancellation()
                        updateWasInvoked = true
                        try await activeStream.stream.updateContentFilter(filter)
                        try Task.checkCancellation()
                        try await activeStream.stream.updateConfiguration(configuration)
                    }
                } catch is CancellationError {
                    if updateWasInvoked {
                        guard await stopPersistentStream(clearHashes: false) else {
                            throw CaptureError.streamStopUnconfirmed
                        }
                    }
                    throw CancellationError()
                } catch {
                    guard await stopPersistentStream(clearHashes: false) else {
                        throw CaptureError.streamStopUnconfirmed
                    }
                    throw CaptureError.streamUpdateFailed
                }
                await drainSampleQueue()
                let wasCancelled = Task.isCancelled
                guard !wasCancelled,
                      revision == controlRevision,
                      self.activeStream?.generation == activeStream.generation,
                      contentEpoch.contains(expectedEpoch),
                      Self.contentCoversExpectedPrivacyApplications(
                        content,
                        protectedApplicationSnapshot: protectedApplicationSnapshot,
                        userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot
                      ) else {
                    _ = await stopPersistentStream(clearHashes: false)
                    if wasCancelled { throw CancellationError() }
                    throw CaptureError.staleGeneration
                }
                nextStreamGeneration &+= 1
                let updated = ActiveStream(
                    stream: activeStream.stream,
                    generation: nextStreamGeneration,
                    displayID: selectedDisplay.displayID,
                    width: configuration.width,
                    height: configuration.height,
                    excludedBundleIDs: activeStream.excludedBundleIDs,
                    protectedApplicationSnapshot: activeStream.protectedApplicationSnapshot,
                    userIgnoredApplicationSnapshot: activeStream.userIgnoredApplicationSnapshot
                )
                // Same physical SCStream, new logical frame generation. Clearing
                // the retained surface prevents a post-update idle event from
                // being mislabeled with pixels from the old display.
                guard streamOutput.rebindIfCurrent(
                    stream: activeStream.stream,
                    from: activeStream.generation,
                    to: updated.generation,
                    eventRevision: eventRevision
                ) else {
                    guard await stopPersistentStream(clearHashes: false) else {
                        throw CaptureError.streamStopUnconfirmed
                    }
                    throw CaptureError.streamUpdateFailed
                }
                self.activeStream = updated
                guard streamOutput.publishIfCurrent(
                    stream: updated.stream,
                    generation: updated.generation
                ) else {
                    guard await stopPersistentStream(clearHashes: false) else {
                        throw CaptureError.streamStopUnconfirmed
                    }
                    throw CaptureError.streamUpdateFailed
                }
                return updated
            }

            let filter = captureFilter(
                display: selectedDisplay,
                content: content,
                excludedBundleIDs: excludedBundleIDs
            )
            let configuration = streamConfiguration(for: selectedDisplay)
            nextStreamGeneration &+= 1
            let generation = nextStreamGeneration
            let revision = controlRevision
            let stream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: streamOutput
            )
            do {
                try stream.addStreamOutput(
                    streamOutput,
                    type: .screen,
                    sampleHandlerQueue: sampleQueue
                )
            } catch {
                try? stream.removeStreamOutput(streamOutput, type: .screen)
                throw CaptureError.streamStartFailed
            }
            let startHandshake = ScreenStreamStartHandshake()
            streamOutput.bind(
                stream: stream,
                generation: generation,
                eventRevision: eventRevision
            )
            startingStream = StartingStream(
                stream: stream,
                generation: generation,
                controlRevision: revision,
                startHandshake: startHandshake
            )
            do {
                try Task.checkCancellation()
                try await resourceCoordinator.withExclusiveAccess(
                    owner: .screen,
                    operation: .start
                ) {
                    do {
                        try Task.checkCancellation()
                    } catch {
                        startHandshake.cancelBeforePhysicalStart()
                        throw error
                    }
                    guard startHandshake.beginPhysicalStart() else {
                        throw CancellationError()
                    }
                    try await stream.startCapture()
                }
            } catch is CancellationError {
                if startHandshake.physicalStartBegan {
                    guard await stopPersistentStream(clearHashes: false) else {
                        throw CaptureError.streamStopUnconfirmed
                    }
                } else {
                    startHandshake.cancelBeforePhysicalStart()
                    streamOutput.unbind(stream: stream)
                    try? stream.removeStreamOutput(streamOutput, type: .screen)
                    if startingStream?.generation == generation { startingStream = nil }
                }
                throw CancellationError()
            } catch {
                if startHandshake.physicalStartBegan {
                    guard await stopPersistentStream(clearHashes: false) else {
                        throw CaptureError.streamStopUnconfirmed
                    }
                } else {
                    startHandshake.cancelBeforePhysicalStart()
                    streamOutput.unbind(stream: stream)
                    try? stream.removeStreamOutput(streamOutput, type: .screen)
                    if startingStream?.generation == generation { startingStream = nil }
                }
                throw CaptureError.streamStartFailed
            }
            let wasCancelled = Task.isCancelled
            guard !wasCancelled,
                  startingStream?.generation == generation,
                  startingStream?.controlRevision == revision,
                  controlRevision == revision,
                  contentEpoch.contains(expectedEpoch),
                  Self.contentCoversExpectedPrivacyApplications(
                    content,
                    protectedApplicationSnapshot: protectedApplicationSnapshot,
                    userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot
                  ) else {
                _ = await stopPersistentStream(clearHashes: false)
                if wasCancelled { throw CancellationError() }
                throw CaptureError.staleGeneration
            }
            startingStream = nil
            let active = ActiveStream(
                stream: stream,
                generation: generation,
                displayID: selectedDisplay.displayID,
                width: configuration.width,
                height: configuration.height,
                excludedBundleIDs: excludedBundleIDs,
                protectedApplicationSnapshot: protectedApplicationSnapshot,
                userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot
            )
            activeStream = active
            guard streamOutput.publishIfCurrent(
                stream: stream,
                generation: generation
            ) else {
                guard await stopPersistentStream(clearHashes: false) else {
                    throw CaptureError.streamStopUnconfirmed
                }
                throw CaptureError.streamStartFailed
            }
            Log.capture.info("eye_screen_stream_started")
            return active
        }
    }

    func reconcilePersistentStream(
        displayID: CGDirectDisplayID?,
        excludedBundleIds: Set<String>,
        protectedApplicationSnapshot: ProtectedCaptureApplicationSnapshot,
        userIgnoredApplicationSnapshot: UserIgnoredCaptureApplicationSnapshot
    ) async throws {
        _ = try await ensurePersistentStream(
            displayID: displayID,
            excludedBundleIDs: excludedBundleIds,
            protectedApplicationSnapshot: protectedApplicationSnapshot,
            userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot
        )
    }

    /// Admission closes before stopCapture begins. A failed stop retains the
    /// exact SCStream and blocks replacement until an external-stop callback or
    /// a later retry proves the physical session is gone.
    @discardableResult
    private func stopPersistentStream(clearHashes: Bool) async -> Bool {
        controlRevision &+= 1
        streamOutput.cancelPendingFrame()
        if clearHashes { lastHashes.removeAll(keepingCapacity: false) }

        let candidate = activeStream.map {
            StreamIdentity(
                stream: $0.stream,
                generation: $0.generation,
                startHandshake: nil
            )
        } ?? startingStream.map {
            StreamIdentity(
                stream: $0.stream,
                generation: $0.generation,
                startHandshake: $0.startHandshake
            )
        }
        let admission = stopOwnership.begin(target: candidate)
        switch admission {
        case .join:
            // A second lifecycle edge joins the exact in-flight stop. Every
            // waiter receives the same confirmed/unconfirmed result.
            return await waitForInFlightStop()
        case .noResource:
            return true
        case .own(let target):
            activeStream = nil
            startingStream = nil

            // This happens before any await. A queued start either loses here
            // and can never invoke SCK, or has already crossed the physical
            // start boundary and therefore requires confirmed teardown.
            let stopDisposition = target.startHandshake?.stopDisposition()
                ?? .requiresPhysicalStop
            streamOutput.closeAdmission(stream: target.stream)
            if stopDisposition == .confirmedNotStarted {
                streamOutput.unbind(stream: target.stream)
                try? target.stream.removeStreamOutput(streamOutput, type: .screen)
                return finishStop(target, confirmed: true)
            }
            // The caller is often the capture task that Stop just cancelled.
            // An unstructured teardown task retains ownership but does not
            // inherit that cancellation, so SCK stop still runs to completion.
            let teardown = Task { await stopPhysicalStream(target) }
            return await teardown.value
        }
    }

    private func stopPhysicalStream(_ target: StreamIdentity) async -> Bool {
        if streamOutput.didStopExternally(stream: target.stream) {
            streamOutput.unbind(stream: target.stream)
            try? target.stream.removeStreamOutput(streamOutput, type: .screen)
            return finishStop(target, confirmed: true)
        }
        do {
            _ = try await resourceCoordinator.withExclusiveAccess(
                owner: .screen,
                operation: .stop
            ) {
                if streamOutput.didStopExternally(stream: target.stream) {
                    return true
                }
                try await target.stream.stopCapture()
                return false
            }
            streamOutput.unbind(stream: target.stream)
            try? target.stream.removeStreamOutput(streamOutput, type: .screen)
            return finishStop(target, confirmed: true)
        } catch {
            if streamOutput.didStopExternally(stream: target.stream) {
                streamOutput.unbind(stream: target.stream)
                try? target.stream.removeStreamOutput(streamOutput, type: .screen)
                return finishStop(target, confirmed: true)
            }
            Log.capture.error("eye_screen_stream_stop_unconfirmed")
            return finishStop(target, confirmed: false)
        }
    }

    private func finishStop(_ target: StreamIdentity, confirmed: Bool) -> Bool {
        let ownershipMatched = stopOwnership.complete(target, confirmed: confirmed)
        if !ownershipMatched {
            assertionFailure("screen stop ownership changed before completion")
        }
        let result = ownershipMatched && confirmed
        let waiters = stopWaiters
        stopWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume(returning: result) }
        return result
    }

    /// Capture + dedup + HEIC + (opt) OCR. displayID — the display of the focused window (NSScreen.main);
    /// nil/not found → the first one. Returns nil if there is no display. On a duplicate — heicData is empty,
    /// isDuplicate=true (the Coordinator decides whether to write a context-only record).
    func process(displayID: CGDirectDisplayID?, needsOCR: Bool,
                 excludedBundleIds: Set<String> = [],
                 protectedApplicationSnapshot: ProtectedCaptureApplicationSnapshot,
                 userIgnoredApplicationSnapshot: UserIgnoredCaptureApplicationSnapshot) async throws -> ProcessedFrame? {
        try Task.checkCancellation()
        let expectedEpoch = contentEpoch.value
        let active = try await ensurePersistentStream(
            displayID: displayID,
            excludedBundleIDs: excludedBundleIds,
            protectedApplicationSnapshot: protectedApplicationSnapshot,
            userIgnoredApplicationSnapshot: userIgnoredApplicationSnapshot
        )
        let rawFrame = try await streamOutput.nextFrame(generation: active.generation)
        try Task.checkCancellation()
        guard rawFrame.stamp.generation == active.generation,
              contentEpoch.contains(expectedEpoch),
              activeStream?.generation == active.generation else { return nil }

        guard await CaptureSessionPolicy.protectedRunningApplicationSnapshot()
                == protectedApplicationSnapshot else {
            _ = await invalidateContent()
            return nil
        }
        let dedupKey = Int(active.displayID)
        // Reclaim the CIContext's per-frame GPU caches on every exit path — otherwise IOSurface piles up (measured ~550MB).
        defer { ciContext.clearCaches() }

        let capW = CVPixelBufferGetWidth(rawFrame.pixelBuffer)
        let capH = CVPixelBufferGetHeight(rawFrame.pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: rawFrame.pixelBuffer)
        try Task.checkCancellation()

        // Per-tile dedup: aHash of the whole screen is blind to small changes (a new message in the corner of a 4K
        // screen flips ≤3 bits out of 64 → "duplicate"). We hash the whole frame + 4 quadrants: a local change
        // moves its own quadrant's hash a lot — the frame is no longer lost.
        let hashes = tileHashes(ciImage)
        let phash = hashes[0]
        let fingerprint = hashes.map { String($0, radix: 16) }.joined(separator: ":")
        let prev = lastHashes[dedupKey]   // per-display dedup: a monitor switch isn't a "duplicate" of the previous one
        let isDup = prev != nil && prev!.count == hashes.count &&
            zip(prev!, hashes).allSatisfy { Self.hamming($0, $1) <= config.dedupHammingThreshold }
        if isDup {
            guard contentEpoch.contains(expectedEpoch) else { return nil }
            guard await CaptureSessionPolicy.protectedRunningApplicationSnapshot()
                    == protectedApplicationSnapshot else {
                _ = await invalidateContent()
                return nil
            }
            guard contentEpoch.contains(expectedEpoch) else { return nil }
            lastHashes[dedupKey] = hashes
            return ProcessedFrame(heicData: Data(), phash: phash, fingerprint: fingerprint, isDuplicate: true,
                                  width: capW, height: capH, ocr: [],
                                  displayID: active.displayID)
        }

        try Task.checkCancellation()
        guard let heic = encodeHEIC(ciImage) else { throw CaptureError.encodeFailed }
        guard await CaptureSessionPolicy.protectedRunningApplicationSnapshot()
                == protectedApplicationSnapshot else {
            _ = await invalidateContent()
            return nil
        }
        guard contentEpoch.contains(expectedEpoch) else { return nil }

        var ocr: [OCRLine] = []
        if needsOCR, let small = downscaledForOCR(ciImage) {
            try Task.checkCancellation()
            // OCR leaves the actor executor (dedicated queue) — the actor is free for the next capture
            ocr = try await Self.runOCR(
                SendableCGImage(image: small),
                languages: config.ocrLanguages
            )
        }
        try Task.checkCancellation()
        guard contentEpoch.contains(expectedEpoch) else { return nil }
        guard await CaptureSessionPolicy.protectedRunningApplicationSnapshot()
                == protectedApplicationSnapshot else {
            _ = await invalidateContent()
            return nil
        }
        guard contentEpoch.contains(expectedEpoch) else { return nil }
        lastHashes[dedupKey] = hashes
        return ProcessedFrame(heicData: heic, phash: phash, fingerprint: fingerprint, isDuplicate: false,
                              width: capW, height: capH, ocr: ocr,
                              displayID: active.displayID)
    }

    /// Longest-side cap preserving aspect ratio (integer pixels). No upscaling — returns the input if already within.
    static func cappedSize(_ w: Int, _ h: Int, maxDim: CGFloat) -> (Int, Int) {
        let longest = CGFloat(max(w, h))
        guard longest > maxDim, longest > 0 else { return (w, h) }
        let scale = maxDim / longest
        return (max(1, Int((CGFloat(w) * scale).rounded())), max(1, Int((CGFloat(h) * scale).rounded())))
    }

    /// Downscale to ocrDownscaleMaxDim (Pro: don't OCR a full Retina frame). Rendered via Metal.
    private func downscaledForOCR(_ image: CIImage) -> CGImage? {
        let w = image.extent.width, h = image.extent.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, config.ocrDownscaleMaxDim / max(w, h))
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }

    // ── HEIC via the hardware codec ──
    private func encodeHEIC(_ image: CIImage) -> Data? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // Lossy quality (was untuned = near-lossless/fat). Frames are only viewed on the timeline; OCR already ran
        // on the live frame, so a lower quality shrinks storage with no recognition cost.
        let opts: [CIImageRepresentationOption: Any] =
            [.init(rawValue: kCGImageDestinationLossyCompressionQuality as String): config.heicQuality]
        return ciContext.heifRepresentation(of: image, format: .RGBA8, colorSpace: cs, options: opts)
    }

    /// Hashes: [whole frame, top-left, top-right, bottom-left, bottom-right].
    private func tileHashes(_ image: CIImage) -> [UInt64] {
        var out = [perceptualHash(image)]
        let e = image.extent
        guard e.width >= 64, e.height >= 64 else { return out }   // a small frame — quadrants are meaningless
        let w = e.width / 2, h = e.height / 2
        for (ox, oy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
            let rect = CGRect(x: e.minX + ox * w, y: e.minY + oy * h, width: w, height: h)
            out.append(perceptualHash(image.cropped(to: rect)))
        }
        return out
    }

    // ── perceptual hash (aHash 8×8) — stores a UInt64, not the buffer ──
    private func perceptualHash(_ image: CIImage) -> UInt64 {
        guard image.extent.width > 0, image.extent.height > 0 else { return 0 }
        let sx = 8.0 / image.extent.width
        let sy = 8.0 / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
        guard let cg = ciContext.createCGImage(scaled, from: rect),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return 0 }
        let bpr = cg.bytesPerRow
        let bpp = max(1, cg.bitsPerPixel / 8)
        var lumas = [Double](); lumas.reserveCapacity(64)
        for y in 0..<8 {
            for x in 0..<8 {
                let off = y * bpr + x * bpp
                let a = Double(ptr[off]); let b = Double(ptr[off + 1]); let c = Double(ptr[off + 2])
                lumas.append(0.299 * a + 0.587 * b + 0.114 * c)
            }
        }
        let mean = lumas.reduce(0, +) / 64
        var hash: UInt64 = 0
        for (i, l) in lumas.enumerated() where l >= mean { hash |= (UInt64(1) << UInt64(i)) }
        return hash
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    // ── Vision OCR on a dedicated queue (does NOT block the actor executor; autoreleasepool; ANE) ──
    nonisolated static func runOCR(_ img: SendableCGImage, languages: [String]) async throws -> [OCRLine] {
        let cancellation = OCRCancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    var lines: [OCRLine] = []
                    autoreleasepool {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLevel = .accurate
                        request.usesLanguageCorrection = true
                        request.recognitionLanguages = languages
                        request.automaticallyDetectsLanguage = true
                        let handler = VNImageRequestHandler(cgImage: img.image, options: [:])
                        try? handler.perform([request])
                        lines = (request.results ?? []).compactMap { obs in
                            obs.topCandidates(1).first.map {
                                OCRLine(
                                    text: $0.string,
                                    confidence: Double($0.confidence),
                                    bbox: obs.boundingBox
                                )
                            }
                        }
                    }
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(returning: lines)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
