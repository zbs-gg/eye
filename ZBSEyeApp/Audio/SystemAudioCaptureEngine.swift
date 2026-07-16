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
    private let lifecycle: SystemAudioCaptureLifecycle<SCStream>
    private let frameAdmission = SystemAudioFrameAdmission<
        SCStream,
        SystemAudioIngressSink
    >()
    private var stream: SCStream?
    private var running = false
    private var epoch = -1
    private var nextIngressSequence: Int64 = 0
    private var lastAcceptedIngressSequence: Int64?
    private var completedGaps: [AudioIngressGap] = []
    private let sampleQueue = DispatchQueue(label: "com.zbseye.systemaudio.samples")

    /// The stream died mid-run (SCK error, permission revoked, display reconfiguration) — the feed is closed;
    /// the coordinator restarts the leg. Without the delegate the death was silent (the feed hung forever).
    var onStreamStopped: (@Sendable () -> Void)?

    @MainActor
    init(config: AudioConfig) {
        self.config = config
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
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            do {
                try await stream.startCapture()
            } catch {
                sink.publisher.finish()
                lifecycle.failStart(token: startToken)
                throw AudioEngineError.engineStartFailed(error.localizedDescription)
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
        return lifecycle.beginStop { stream in
            await Self.stopStream(stream)
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
        // Field mutations happen on main only: the coordinator's stop()/start() are there too (no check-then-act race).
        // ObjectIdentifier instead of the SCStream itself — we don't drag a non-Sendable object into the main closure.
        let stoppedID = ObjectIdentifier(stream)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running,
                  self.stream.map(ObjectIdentifier.init) == stoppedID else { return }
            self.running = false
            self.stream = nil
            if let sink = self.frameAdmission.close() {
                self.archive(sink)
                sink.publisher.finish()
            }
            _ = self.lifecycle.acknowledgeExternalStop(sessionID: stoppedID)
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
        _ = sink.publisher.yield(
            samples: payload.samples,
            rms: payload.rms,
            captureSampleRate: payload.sampleRate,
            sourceSampleTime: presentationTime.isValid
                ? Int64(CMTimeGetSeconds(presentationTime) * payload.sampleRate)
                : nil,
            normalizedHostTimeNs: sink.normalizedHostTimeNs(for: presentationTime),
            capturedAt: Date(),
            provenance: presentationTime.isValid ? .screenCaptureKit : .callbackFallback
        )
    }

    @MainActor
    private static func stopStream(
        _ stream: SCStream
    ) async -> SystemAudioCaptureTeardownOutcome {
        for attempt in 0..<2 {
            do {
                try await stream.stopCapture()
                return .stopped
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        Log.audio.error("system_audio_stop_failed_after_retry")
        return .failed("system_audio_stop_failed")
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
