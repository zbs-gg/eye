import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

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
        AsyncStream<AudioFrame>.Continuation
    >()
    private var stream: SCStream?
    private var running = false
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

            let (s, cont) = AsyncStream.makeStream(
                of: AudioFrame.self,
                bufferingPolicy: .bufferingNewest(64)
            )
            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            do {
                try await stream.startCapture()
            } catch {
                cont.finish()
                lifecycle.failStart(token: startToken)
                throw AudioEngineError.engineStartFailed(error.localizedDescription)
            }

            guard lifecycle.publishStarted(stream, token: startToken) else {
                // stop() won while startCapture() was suspended. SCK did create
                // the hardware session. The lifecycle adopted that exact stream
                // and retained its stop operation before publishStarted returned,
                // including across a failed teardown so restart cannot replace it.
                cont.finish()
                let teardownOutcome = await lifecycle.drain()
                throw SystemAudioCaptureStartCancelled(
                    teardownOutcome: teardownOutcome
                )
            }
            self.stream = stream
            frameAdmission.open(session: stream, sink: cont)
            running = true
            return s
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
        frameAdmission.close()?.finish()
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
            self.frameAdmission.close()?.finish()
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
              let cont = frameAdmission.sink(for: stream),
              let frame = Self.frame(from: sampleBuffer) else { return }
        cont.yield(frame)
    }

    @MainActor
    private static func stopStream(
        _ stream: SCStream
    ) async -> SystemAudioCaptureTeardownOutcome {
        var lastError = "unknown ScreenCaptureKit error"
        for attempt in 0..<2 {
            do {
                try await stream.stopCapture()
                return .stopped
            } catch {
                lastError = error.localizedDescription
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        Log.audio.error("system audio stop failed after retry: \(lastError, privacy: .public)")
        return .failed(lastError)
    }

    /// CMSampleBuffer (Float32, non-interleaved — SCStream audio format) → mono frame + RMS.
    private static func frame(from sb: CMSampleBuffer) -> AudioFrame? {
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
        return AudioFrame(samples: mono, rms: rms, sampleRate: sr, ts: Date())
    }
}
