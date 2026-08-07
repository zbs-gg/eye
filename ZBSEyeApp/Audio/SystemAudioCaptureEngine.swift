import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Darwin

struct SystemAudioCaptureStartCancelled: Error, Sendable, Equatable {
    let teardownOutcome: SystemAudioCaptureTeardownOutcome
}

/// Captures SYSTEM audio (what plays through the speakers/headphones — the far side of calls, videos, meetings)
/// via a ScreenCaptureKit audio-only SCStream. Uses the already-granted Screen Recording permission (microphone
/// is NOT needed). Downmixes to mono + RMS → AsyncStream<AudioFrame> (the same path as the microphone).
/// @unchecked Sendable: callbacks run on sampleQueue, but the only cross-queue
/// state is the locked `frameAdmission`; lifecycle fields stay on MainActor.
final class SystemAudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let config: AudioConfig
    private let resourceCoordinator: SCKResourceCoordinator
    private let lifecycle: SystemAudioCaptureLifecycle<SCStream>
    private let frameAdmission = SystemAudioFrameAdmission<
        SCStream,
        SystemAudioIngressSink
    >()
    private let externalStopLock = NSLock()
    private var registeredStreamIDs: Set<ObjectIdentifier> = []
    private var externallyStoppedStreamIDs: Set<ObjectIdentifier> = []
    private var stream: SCStream?
    private var running = false
    private var epoch = -1
    private var nextIngressSequence: Int64 = 0
    private var lastAcceptedIngressSequence: Int64?
    private var completedGaps: [AudioIngressGap] = []
    private let sampleQueue = DispatchQueue(label: "com.zbseye.systemaudio.samples")
    private let discardScreenOutput = SystemAudioDiscardScreenOutput()
    private let discardScreenQueue = DispatchQueue(
        label: "com.zbseye.systemaudio.discard-screen",
        qos: .utility
    )

    /// The stream died mid-run (SCK error, permission revoked, display reconfiguration) — the feed is closed;
    /// the coordinator restarts the leg. Without the delegate the death was silent (the feed hung forever).
    var onStreamStopped: (@Sendable () -> Void)?

    @MainActor
    init(
        config: AudioConfig,
        resourceCoordinator: SCKResourceCoordinator
    ) {
        self.config = config
        self.resourceCoordinator = resourceCoordinator
        self.lifecycle = SystemAudioCaptureLifecycle()
        super.init()
    }

    var latestAcceptedIngressSequence: Int64? {
        frameAdmission.currentSink()?.publisher.latestAcceptedIngressSequence
            ?? lastAcceptedIngressSequence
    }

    func drainIngressGaps() -> [AudioIngressGap] {
        let result = completedGaps
            + (frameAdmission.currentSink()?.publisher.drainGaps() ?? [])
        completedGaps.removeAll(keepingCapacity: true)
        return result
    }

    @MainActor
    func start() async throws -> AsyncStream<AudioFrame> {
        guard !running else { throw AudioEngineError.engineStartFailed("already running") }
        guard let startToken = await lifecycle.beginStart() else {
            throw AudioEngineError.engineStartFailed("already starting")
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                lifecycle.failStart(token: startToken)
                throw AudioEngineError.noInputDevice
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true   // do not record ZBS Eye's own audio (echo/loop)
            // We don't need video — minimize it: tiny frame, rare tick (an audio-only stream still
            // requires a valid video part in the config).
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            epoch += 1
            let sink = SystemAudioIngressSink(
                epoch: epoch,
                initialSequence: nextIngressSequence
            )
            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            registerStream(stream)
            var startWasInvoked = false
            do {
                try await resourceCoordinator.withExclusiveAccess(
                    owner: .systemAudio,
                    operation: .start
                ) {
                    try Task.checkCancellation()
                    guard lifecycle.isStartCurrent(startToken) else {
                        throw SystemAudioCaptureStartInvalidated()
                    }
                    do {
                        try stream.addStreamOutput(
                            self,
                            type: .audio,
                            sampleHandlerQueue: sampleQueue
                        )
                        try Task.checkCancellation()
                        // SCK still has a video leg when capturesAudio is
                        // enabled. A tiny discard output keeps that leg valid
                        // without feeding pixels into the audio callback queue.
                        try stream.addStreamOutput(
                            discardScreenOutput,
                            type: .screen,
                            sampleHandlerQueue: discardScreenQueue
                        )
                        try Task.checkCancellation()
                        guard lifecycle.isStartCurrent(startToken) else {
                            throw SystemAudioCaptureStartInvalidated()
                        }
                        startWasInvoked = true
                        try await stream.startCapture()
                        try Task.checkCancellation()
                        guard lifecycle.isStartCurrent(startToken) else {
                            throw SystemAudioCaptureStartInvalidated()
                        }
                    } catch {
                        // Once startCapture() has been invoked the stream may
                        // already own live SCK resources even if its async
                        // continuation throws or cancellation wins. Keep both
                        // outputs attached until the retained stop path has
                        // physically stopped that exact stream; removing them
                        // first recreates SCK's "stream output NOT found"
                        // lifecycle ordering.
                        if !startWasInvoked {
                            removeCaptureOutputs(from: stream)
                        }
                        throw error
                    }
                }
            } catch is SystemAudioCaptureStartInvalidated {
                sink.publisher.finish()
                if startWasInvoked {
                    let teardownOutcome = await retainAndStopRejectedStart(
                        stream,
                        token: startToken
                    )
                    throw SystemAudioCaptureStartCancelled(
                        teardownOutcome: teardownOutcome
                    )
                }
                unregisterStream(stream)
                lifecycle.failStart(token: startToken)
                throw SystemAudioCaptureStartCancelled(teardownOutcome: .notNeeded)
            } catch is CancellationError {
                sink.publisher.finish()
                if startWasInvoked {
                    let teardownOutcome = await retainAndStopRejectedStart(
                        stream,
                        token: startToken
                    )
                    throw SystemAudioCaptureStartCancelled(
                        teardownOutcome: teardownOutcome
                    )
                }
                unregisterStream(stream)
                lifecycle.failStart(token: startToken)
                throw CancellationError()
            } catch {
                sink.publisher.finish()
                if startWasInvoked {
                    let teardownOutcome = await retainAndStopRejectedStart(
                        stream,
                        token: startToken
                    )
                    if !teardownOutcome.isConfirmedStopped {
                        Log.audio.error("system_audio_failed_start_teardown_unconfirmed")
                    }
                } else {
                    unregisterStream(stream)
                }
                lifecycle.failStart(token: startToken)
                throw AudioEngineError.engineStartFailed(error.localizedDescription)
            }

            // The delegate can prove a physical stop before startCapture's
            // continuation returns to MainActor. In that ordering there is no
            // published lifecycle session for the queued main callback to
            // acknowledge, so consume the synchronous marker before exposing a
            // dead stream as running.
            if consumeExternalStopMarker(for: stream) {
                removeCaptureOutputs(from: stream)
                sink.publisher.finish()
                lifecycle.failStart(token: startToken)
                throw AudioEngineError.engineStartFailed(
                    "system audio stream stopped during start"
                )
            }

            guard lifecycle.publishStarted(stream, token: startToken) else {
                // stop() won while startCapture() was suspended. SCK did create
                // the hardware session. The lifecycle adopted that exact stream
                // and retained its stop operation before publishStarted returned,
                // including across a failed teardown so restart cannot replace it.
                sink.publisher.finish()
                let teardownOutcome = await lifecycle.drain()
                throw SystemAudioCaptureStartCancelled(
                    teardownOutcome: teardownOutcome
                )
            }
            self.stream = stream
            frameAdmission.open(session: stream, sink: sink)
            running = true
            return sink.publisher.stream
        } catch {
            lifecycle.failStart(token: startToken)
            throw error
        }
    }

    /// Starts teardown synchronously and returns the task that owns the exact
    /// SCStream until ScreenCaptureKit acknowledges stopCapture().
    @MainActor
    @discardableResult
    func stop() -> Task<SystemAudioCaptureTeardownOutcome, Never>? {
        running = false
        if let sink = frameAdmission.close() {
            archive(sink)
            sink.publisher.finish()
        }
        self.stream = nil
        return lifecycle.beginStop { [self] stream in
            await stopStream(stream)
        }
    }

    /// The process must not exit, relocate, or publish a replacement session
    /// until the underlying CoreAudio/SCK resources have been released.
    @MainActor
    func stopAndDrain(
        timeout: Duration? = nil
    ) async -> SystemAudioCaptureTeardownOutcome {
        let teardown = stop()
        if let teardown, let timeout {
            return await SystemAudioTeardownDeadline.wait(
                for: teardown,
                timeout: timeout
            )
        }
        return await lifecycle.drain()
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stoppedID = ObjectIdentifier(stream)
        guard markExternalStop(streamID: stoppedID) else { return }
        // The physical stream has stopped, so both registrations can be
        // detached before lifecycle ownership is released. Removal is
        // idempotent with the normal stop path.
        removeCaptureOutputs(from: stream)
        // Field mutations happen on main only: the coordinator's stop()/start() are there too (no check-then-act race).
        // ObjectIdentifier instead of the SCStream itself — we don't drag a non-Sendable object into the main closure.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let wasRunningCurrent = self.running
                && self.stream.map(ObjectIdentifier.init) == stoppedID
            _ = self.lifecycle.acknowledgeExternalStop(
                sessionID: stoppedID
            )
            // A normal stop may still be suspended in stopCapture(). Keep its
            // marker until that operation observes the delegate-confirmed
            // physical stop; otherwise an SCK "already stopped" error would be
            // misreported as a teardown failure. Only a spontaneous stop of the
            // published running stream has no teardown waiter. Any non-current
            // marker may belong to a start/stop race and remains consumable by
            // the retained late-start teardown.
            if wasRunningCurrent {
                _ = self.consumeExternalStopMarker(streamID: stoppedID)
            }
            guard wasRunningCurrent else { return }
            self.running = false
            self.stream = nil
            if let sink = self.frameAdmission.close() {
                self.archive(sink)
                sink.publisher.finish()
            }
            self.onStreamStopped?()
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // The locked identity lookup admits only the exact current stream. A
        // late buffer from an old SCK session cannot reach a new continuation.
        guard type == .audio, sampleBuffer.isValid,
              let sink = frameAdmission.sink(for: stream),
              let payload = Self.payload(from: sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let normalizedHostTimeNs = sink.normalizedHostTimeNs(for: presentationTime)
        let callbackHostTimeNs = Int64(
            CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1_000_000_000
        )
        _ = sink.publisher.yield(
            samples: payload.samples,
            rms: payload.rms,
            captureSampleRate: payload.sampleRate,
            sourceSampleTime: presentationTime.isValid
                ? Int64(CMTimeGetSeconds(presentationTime) * payload.sampleRate)
                : nil,
            normalizedHostTimeNs: normalizedHostTimeNs,
            capturedAt: AudioHostClockWallMapper.date(
                for: normalizedHostTimeNs,
                callbackHostTimeNs: callbackHostTimeNs,
                callbackWallDate: Date()
            ),
            provenance: presentationTime.isValid ? .screenCaptureKit : .callbackFallback
        )
    }

    @MainActor
    private func stopStream(
        _ stream: SCStream
    ) async -> SystemAudioCaptureTeardownOutcome {
        await resourceCoordinator.withExclusiveAccess(
            owner: .systemAudio,
            operation: .stop
        ) {
            for attempt in 0..<2 {
                if consumeExternalStopMarker(for: stream) {
                    removeCaptureOutputs(from: stream)
                    return .stopped
                }
                do {
                    try await stream.stopCapture()
                    removeCaptureOutputs(from: stream)
                    unregisterStream(stream)
                    return .stopped
                } catch {
                    if consumeExternalStopMarker(for: stream) {
                        removeCaptureOutputs(from: stream)
                        return .stopped
                    }
                    if attempt == 0 {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            Log.audio.error("system_audio_stop_failed_after_retry")
            return .failed("system_audio_stop_failed")
        }
    }

    private func removeCaptureOutputs(from stream: SCStream) {
        try? stream.removeStreamOutput(self, type: .audio)
        try? stream.removeStreamOutput(discardScreenOutput, type: .screen)
    }

    @MainActor
    private func retainAndStopRejectedStart(
        _ stream: SCStream,
        token: SystemAudioCaptureLifecycle<SCStream>.StartToken
    ) async -> SystemAudioCaptureTeardownOutcome {
        if lifecycle.publishStarted(stream, token: token) {
            _ = lifecycle.beginStop { [self] ownedStream in
                await stopStream(ownedStream)
            }
        }
        return await lifecycle.drain()
    }

    private func consumeExternalStopMarker(for stream: SCStream) -> Bool {
        consumeExternalStopMarker(streamID: ObjectIdentifier(stream))
    }

    private func consumeExternalStopMarker(streamID: ObjectIdentifier) -> Bool {
        return externalStopLock.withLock {
            guard externallyStoppedStreamIDs.remove(streamID) != nil else { return false }
            registeredStreamIDs.remove(streamID)
            return true
        }
    }

    private func registerStream(_ stream: SCStream) {
        let streamID = ObjectIdentifier(stream)
        externalStopLock.withLock {
            registeredStreamIDs.insert(streamID)
            externallyStoppedStreamIDs.remove(streamID)
        }
    }

    private func unregisterStream(_ stream: SCStream) {
        let streamID = ObjectIdentifier(stream)
        externalStopLock.withLock {
            registeredStreamIDs.remove(streamID)
            externallyStoppedStreamIDs.remove(streamID)
        }
    }

    private func markExternalStop(streamID: ObjectIdentifier) -> Bool {
        externalStopLock.withLock {
            guard registeredStreamIDs.contains(streamID) else { return false }
            externallyStoppedStreamIDs.insert(streamID)
            return true
        }
    }

    /// CMSampleBuffer (Float32, non-interleaved — SCStream audio format) → mono frame + RMS.
    private static func payload(from sb: CMSampleBuffer) -> (samples: [Float], rms: Float, sampleRate: Double)? {
        guard let asbd = sb.formatDescription?.audioStreamBasicDescription else { return nil }
        let sr = asbd.mSampleRate
        var mono: [Float] = []
        do {
            try sb.withAudioBufferList { abl, _ in
                let channels = abl.count
                guard channels > 0, let first = abl.first else { return }
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                guard frames > 0 else { return }
                var acc = [Float](repeating: 0, count: frames)
                for buf in abl {
                    guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for i in 0..<frames { acc[i] += p[i] }
                }
                let inv = 1 / Float(channels)
                for i in 0..<frames { acc[i] *= inv }
                mono = acc
            }
        } catch { return nil }
        guard !mono.isEmpty else { return nil }
        var sum: Float = 0
        for v in mono { sum += v * v }
        let rms = (sum / Float(mono.count)).squareRoot()
        return (mono, rms, sr)
    }

    @MainActor
    private func archive(_ sink: SystemAudioIngressSink) {
        lastAcceptedIngressSequence = sink.publisher.latestAcceptedIngressSequence
            ?? lastAcceptedIngressSequence
        nextIngressSequence = sink.publisher.nextAttemptedIngressSequence
        completedGaps.append(contentsOf: sink.publisher.drainGaps())
    }
}

private struct SystemAudioCaptureStartInvalidated: Error, Sendable {}

/// SCK requires a screen output for a reliable audio stream even though Eye
/// does not consume those pixels. The 2x2 buffers are intentionally dropped.
private final class SystemAudioDiscardScreenOutput: NSObject, SCStreamOutput,
    @unchecked Sendable {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {}
}

private final class SystemAudioIngressSink: @unchecked Sendable {
    let publisher: AudioIngressPublisher
    private let lock = NSLock()
    private var bestObservedOffsetSeconds: Double?
    private var lastNormalizedNanoseconds: Int64?

    init(epoch: Int, initialSequence: Int64) {
        publisher = AudioIngressPublisher(
            source: .system,
            epoch: epoch,
            capacity: 64,
            initialSequence: initialSequence
        )
    }

    func normalizedHostTimeNs(for presentationTime: CMTime) -> Int64 {
        lock.withLock {
            let hostSeconds = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            let fallback = Int64(hostSeconds * 1_000_000_000)
            guard presentationTime.isValid else { return monotonic(fallback) }
            let presentationSeconds = CMTimeGetSeconds(presentationTime)
            guard presentationSeconds.isFinite, hostSeconds.isFinite else {
                return monotonic(fallback)
            }

            // ScreenCaptureKit normally timestamps audio directly in host-clock
            // time. Preserve it instead of baking callback-delivery latency into
            // a one-shot anchor. For relative timelines, use the minimum
            // observed delivery offset, which converges toward the clock offset
            // while rejecting scheduling spikes.
            let mappedSeconds: Double
            if abs(hostSeconds - presentationSeconds) < 60 {
                mappedSeconds = presentationSeconds
            } else {
                let observedOffset = hostSeconds - presentationSeconds
                bestObservedOffsetSeconds = min(
                    bestObservedOffsetSeconds ?? observedOffset,
                    observedOffset
                )
                mappedSeconds = presentationSeconds + (bestObservedOffsetSeconds ?? observedOffset)
            }
            return monotonic(Int64(mappedSeconds * 1_000_000_000))
        }
    }

    private func monotonic(_ candidate: Int64) -> Int64 {
        let value = max(candidate, (lastNormalizedNanoseconds ?? (candidate - 1)) + 1)
        lastNormalizedNanoseconds = value
        return value
    }
}
