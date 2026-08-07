import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

enum ScreenCaptureStreamError: Error, Sendable, Equatable {
    case inactiveGeneration
    case superseded
    case stopped
    case missingPixelBuffer
}

enum ScreenStreamEvent: Sendable, Equatable {
    case started(Int64)
    case heartbeat(ScreenStreamFrameStamp)
    case failed(Int64, CaptureHealthReason)
}

struct ScreenStreamEventEnvelope: Sendable, Equatable {
    let fenceRevision: UInt64
    let event: ScreenStreamEvent
}

/// One long-lived MainActor consumer preserves event order. Producers may run
/// on SCK's sample queue, delegate queue, watchdog queue, or the pipeline actor;
/// they only append to this channel while holding the output-state lock.
private final class ScreenStreamEventDelivery: @unchecked Sendable {
    private let continuation: AsyncStream<ScreenStreamEventEnvelope>.Continuation
    private let consumer: Task<Void, Never>

    init(sink: @escaping @MainActor @Sendable (ScreenStreamEventEnvelope) -> Void) {
        var capturedContinuation: AsyncStream<ScreenStreamEventEnvelope>.Continuation?
        let stream = AsyncStream<ScreenStreamEventEnvelope> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation!
        self.consumer = Task { @MainActor in
            for await event in stream {
                sink(event)
            }
        }
    }

    func enqueue(_ event: ScreenStreamEvent, fenceRevision: UInt64) {
        continuation.yield(
            ScreenStreamEventEnvelope(
                fenceRevision: fenceRevision,
                event: event
            )
        )
    }

    deinit {
        continuation.finish()
        consumer.cancel()
    }
}

/// Explicit bridge from ScreenCaptureKit's callback queue into the
/// FramePipeline actor. The retained CVPixelBuffer never reaches any other
/// consumer; only that actor hashes, encodes and OCRs it.
struct ScreenStreamPixelFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let stamp: ScreenStreamFrameStamp
}

/// ScreenCaptureKit invokes this object on a utility queue. All callback state
/// is behind one lock, and the only pending work is one latest continuation.
/// A second intent supersedes the older waiter instead of queuing more work.
final class ScreenCaptureStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable {
    private struct Waiter {
        let intent: ScreenStreamIntent
        let continuation: CheckedContinuation<ScreenStreamPixelFrame, Error>
    }

    private let lock = NSLock()
    private let livenessTimeoutNs: UInt64
    private let eventDelivery: ScreenStreamEventDelivery
    private var streamID: ObjectIdentifier?
    private var boundGeneration: Int64?
    private var admissionOpen = false
    private var publication = ScreenStreamPublicationPolicy()
    private var policy = ScreenStreamFreshnessPolicy()
    private var liveness = ScreenStreamLivenessPolicy()
    private var missingPixels = ScreenStreamMissingPixelPolicy()
    private var waiter: Waiter?
    private var latestPixelBuffer: CVPixelBuffer?
    private var watchdog: DispatchSourceTimer?
    private var externallyStoppedStreamID: ObjectIdentifier?

    init(
        livenessTimeoutSeconds: Double,
        eventSink: @escaping @MainActor @Sendable (ScreenStreamEventEnvelope) -> Void
    ) {
        livenessTimeoutNs = UInt64(max(0, livenessTimeoutSeconds) * 1_000_000_000)
        self.eventDelivery = ScreenStreamEventDelivery(sink: eventSink)
        self.liveness = ScreenStreamLivenessPolicy(
            timeoutMs: Int64(max(0, livenessTimeoutSeconds) * 1_000)
        )
        super.init()
    }

    func bind(stream: SCStream, generation: Int64, eventRevision: UInt64) {
        let oldWaiter: Waiter?
        lock.lock()
        oldWaiter = waiter
        waiter = nil
        latestPixelBuffer = nil
        streamID = ObjectIdentifier(stream)
        boundGeneration = generation
        admissionOpen = true
        externallyStoppedStreamID = nil
        publication.bind(generation: generation, eventRevision: eventRevision)
        missingPixels.reset()
        policy.beginGeneration(generation)
        liveness.stopped()
        watchdog?.cancel()
        watchdog = nil
        lock.unlock()
        oldWaiter?.continuation.resume(throwing: ScreenCaptureStreamError.superseded)
    }

    /// Changes only the logical generation of the same physical stream. The
    /// current binding check and the mutation happen under one lock, so a
    /// delegate stop can win before the rebind or observe the new generation,
    /// but can never be erased by a later unconditional bind.
    func rebindIfCurrent(
        stream: SCStream,
        from oldGeneration: Int64,
        to newGeneration: Int64,
        eventRevision: UInt64
    ) -> Bool {
        let oldWaiter: Waiter?
        lock.lock()
        guard streamID == ObjectIdentifier(stream),
              boundGeneration == oldGeneration,
              admissionOpen,
              publication.rebindIfPublished(
                  from: oldGeneration,
                  to: newGeneration,
                  eventRevision: eventRevision
              ) else {
            lock.unlock()
            return false
        }
        oldWaiter = waiter
        waiter = nil
        latestPixelBuffer = nil
        boundGeneration = newGeneration
        missingPixels.reset()
        policy.beginGeneration(newGeneration)
        liveness.stopped()
        watchdog?.cancel()
        watchdog = nil
        lock.unlock()
        oldWaiter?.continuation.resume(throwing: ScreenCaptureStreamError.superseded)
        return true
    }

    /// Linear publication boundary. The ordered start event is enqueued while
    /// the same lock excludes delegate-stop, so it always precedes any failure
    /// event for this generation.
    func publishIfCurrent(
        stream: SCStream,
        generation: Int64
    ) -> Bool {
        lock.lock()
        guard streamID == ObjectIdentifier(stream),
              boundGeneration == generation,
              admissionOpen,
              let eventRevision = publication.publishIfPending(
                  generation: generation
              ) else {
            lock.unlock()
            return false
        }
        liveness.started(generation: generation, nowMs: Self.uptimeMs())
        installWatchdogLocked(generation: generation)
        eventDelivery.enqueue(
            .started(generation),
            fenceRevision: eventRevision
        )
        lock.unlock()
        return true
    }

    func isCurrentAndPublished(
        stream: SCStream,
        generation: Int64,
        eventRevision: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return streamID == ObjectIdentifier(stream)
            && boundGeneration == generation
            && admissionOpen
            && publication.isPublished(
                generation: generation,
                eventRevision: eventRevision
            )
    }

    func unbind(stream: SCStream) {
        let stoppedWaiter: Waiter?
        lock.lock()
        guard streamID == ObjectIdentifier(stream) else {
            lock.unlock()
            return
        }
        streamID = nil
        boundGeneration = nil
        admissionOpen = false
        publication.end()
        policy.endGeneration()
        liveness.stopped()
        watchdog?.cancel()
        watchdog = nil
        latestPixelBuffer = nil
        missingPixels.reset()
        stoppedWaiter = waiter
        waiter = nil
        lock.unlock()
        stoppedWaiter?.continuation.resume(throwing: ScreenCaptureStreamError.stopped)
    }

    /// Reject pixels immediately but retain the physical stream identity until
    /// stopCapture or the delegate proves teardown. This closes the stop-error
    /// race without allowing a late callback to fulfill work.
    func closeAdmission(stream: SCStream) {
        let stoppedWaiter: Waiter?
        lock.lock()
        guard streamID == ObjectIdentifier(stream) else {
            lock.unlock()
            return
        }
        admissionOpen = false
        publication.end()
        policy.endGeneration()
        liveness.stopped()
        watchdog?.cancel()
        watchdog = nil
        latestPixelBuffer = nil
        missingPixels.reset()
        stoppedWaiter = waiter
        waiter = nil
        lock.unlock()
        stoppedWaiter?.continuation.resume(throwing: ScreenCaptureStreamError.stopped)
    }

    func nextFrame(generation: Int64) async throws -> ScreenStreamPixelFrame {
        try await withCheckedThrowingContinuation { continuation in
            let superseded: Waiter?
            lock.lock()
            guard streamID != nil,
                  admissionOpen,
                  policy.generation == generation,
                  publication.isPublished(generation: generation) else {
                lock.unlock()
                continuation.resume(throwing: ScreenCaptureStreamError.inactiveGeneration)
                return
            }
            let intent = policy.requestFrame()
            superseded = waiter
            waiter = Waiter(intent: intent, continuation: continuation)
            missingPixels.reset()
            lock.unlock()
            superseded?.continuation.resume(throwing: ScreenCaptureStreamError.superseded)
        }
    }

    func cancelPendingFrame() {
        let cancelled: Waiter?
        lock.lock()
        cancelled = waiter
        if let intent = waiter?.intent { policy.cancelIntent(intent) }
        waiter = nil
        missingPixels.reset()
        lock.unlock()
        cancelled?.continuation.resume(throwing: CancellationError())
    }

    func didStopExternally(stream: SCStream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return externallyStoppedStreamID == ObjectIdentifier(stream)
    }

    // MARK: SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid,
              let metadata = Self.metadata(from: sampleBuffer) else { return }

        let resume: (Waiter, ScreenStreamPixelFrame)?
        let missingPixelWaiter: Waiter?
        let stamp: ScreenStreamFrameStamp
        lock.lock()
        guard streamID == ObjectIdentifier(stream), admissionOpen else {
            lock.unlock()
            return
        }
        stamp = ScreenStreamFrameStamp(
            generation: policy.generation,
            status: metadata.status,
            displayTime: metadata.displayTime
        )
        let samplePixelBuffer = sampleBuffer.imageBuffer
        switch metadata.status {
        case .complete:
            // A complete event promises its own current surface. Clear the
            // retained surface when it is malformed so a later idle callback
            // cannot resurrect pixels from before the missing update.
            latestPixelBuffer = samplePixelBuffer
        case .idle:
            if let samplePixelBuffer { latestPixelBuffer = samplePixelBuffer }
        case .nonProgress:
            break
        }
        // An idle event may intentionally omit its IOSurface and reuse the
        // last usable surface. A complete event promises a current surface;
        // substituting retained pixels there would silently record stale data.
        let availablePixelBuffer: CVPixelBuffer? = switch metadata.status {
        case .complete: samplePixelBuffer
        case .idle: samplePixelBuffer ?? latestPixelBuffer
        case .nonProgress: nil
        }
        let observation = policy.observe(
            stamp,
            canFulfillIntent: availablePixelBuffer != nil
        )
        var heartbeatRevision = observation != .rejected
            ? publication.publishedEventRevision(generation: stamp.generation)
            : nil
        if heartbeatRevision != nil {
            _ = liveness.observed(stamp, nowMs: Self.uptimeMs())
        }
        let missingPixelDecision = missingPixels.observe(
            acceptedProgress: observation != .rejected,
            hasUsablePixel: availablePixelBuffer != nil,
            hasWaiter: waiter != nil
        )
        if case .fulfilled(let intent) = observation,
           let current = waiter,
           current.intent == intent,
           let buffer = availablePixelBuffer {
            waiter = nil
            resume = (current, ScreenStreamPixelFrame(pixelBuffer: buffer, stamp: stamp))
            missingPixelWaiter = nil
        } else if missingPixelDecision == .failWaiter,
                  let current = waiter {
            policy.cancelIntent(current.intent)
            waiter = nil
            missingPixelWaiter = current
            if let failure = publication.failureEvent(
                boundGeneration: boundGeneration
            ) {
                eventDelivery.enqueue(
                    .failed(failure.generation, .screenStreamStopped),
                    fenceRevision: failure.eventRevision
                )
            }
            admissionOpen = false
            publication.end()
            policy.endGeneration()
            liveness.stopped()
            watchdog?.cancel()
            watchdog = nil
            latestPixelBuffer = nil
            heartbeatRevision = nil
            resume = nil
        } else {
            resume = nil
            missingPixelWaiter = nil
        }
        if let heartbeatRevision {
            eventDelivery.enqueue(
                .heartbeat(stamp),
                fenceRevision: heartbeatRevision
            )
        }
        lock.unlock()

        if let resume {
            resume.0.continuation.resume(returning: resume.1)
        } else {
            missingPixelWaiter?.continuation.resume(
                throwing: ScreenCaptureStreamError.missingPixelBuffer
            )
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let failure: (generation: Int64, eventRevision: UInt64)?
        let stoppedWaiter: Waiter?
        lock.lock()
        guard streamID == ObjectIdentifier(stream) else {
            lock.unlock()
            return
        }
        failure = admissionOpen
            ? publication.failureEvent(boundGeneration: boundGeneration)
            : nil
        externallyStoppedStreamID = ObjectIdentifier(stream)
        streamID = nil
        boundGeneration = nil
        admissionOpen = false
        publication.end()
        policy.endGeneration()
        liveness.stopped()
        watchdog?.cancel()
        watchdog = nil
        latestPixelBuffer = nil
        missingPixels.reset()
        stoppedWaiter = waiter
        waiter = nil
        if let failure {
            eventDelivery.enqueue(
                .failed(failure.generation, .screenStreamStopped),
                fenceRevision: failure.eventRevision
            )
        }
        lock.unlock()

        stoppedWaiter?.continuation.resume(throwing: ScreenCaptureStreamError.stopped)
    }

    private func installWatchdogLocked(generation: Int64) {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .utility)
        )
        let intervalNs = max(UInt64(250_000_000), min(livenessTimeoutNs / 4, 1_000_000_000))
        timer.schedule(
            deadline: .now() + .nanoseconds(Int(intervalNs)),
            repeating: .nanoseconds(Int(intervalNs)),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            self?.watchdogFired(generation: generation)
        }
        watchdog = timer
        timer.resume()
    }

    private func watchdogFired(generation: Int64) {
        let eventRevision: UInt64?
        lock.lock()
        eventRevision = publication.isPublished(generation: generation)
            && liveness.generation == generation
            && liveness.shouldReportStall(nowMs: Self.uptimeMs())
            ? publication.publishedEventRevision(generation: generation)
            : nil
        if let eventRevision {
            eventDelivery.enqueue(
                .failed(generation, .screenStreamStalled),
                fenceRevision: eventRevision
            )
        }
        lock.unlock()
    }

    private static func metadata(
        from sampleBuffer: CMSampleBuffer
    ) -> (status: ScreenStreamFrameStatus, displayTime: UInt64)? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachment = attachments.first,
        let rawStatus = (attachment[.status] as? NSNumber)?.intValue,
        let status = SCFrameStatus(rawValue: rawStatus),
        let displayTime = (attachment[.displayTime] as? NSNumber)?.uint64Value else {
            return nil
        }
        let mapped: ScreenStreamFrameStatus = switch status {
        case .complete: .complete
        case .idle: .idle
        default: .nonProgress
        }
        return (mapped, displayTime)
    }

    private static func uptimeMs() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
