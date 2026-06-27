import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Captures SYSTEM audio (what plays through the speakers/headphones — the far side of calls, videos, meetings)
/// via a ScreenCaptureKit audio-only SCStream. Uses the already-granted Screen Recording permission (microphone
/// is NOT needed). Downmixes to mono + RMS → AsyncStream<AudioFrame> (the same path as the microphone).
/// @unchecked Sendable: callback runs on sampleQueue; the `running` flag suppresses late callbacks from an old stream.
final class SystemAudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let config: AudioConfig
    private var stream: SCStream?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var running = false
    private let sampleQueue = DispatchQueue(label: "com.zbseye.systemaudio.samples")

    /// The stream died mid-run (SCK error, permission revoked, display reconfiguration) — the feed is closed;
    /// the coordinator restarts the leg. Without the delegate the death was silent (the feed hung forever).
    var onStreamStopped: (@Sendable () -> Void)?

    init(config: AudioConfig) {
        self.config = config
        super.init()
    }

    func start() async throws -> AsyncStream<AudioFrame> {
        guard !running else { throw AudioEngineError.engineStartFailed("already running") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw AudioEngineError.noInputDevice }

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

        let (s, cont) = AsyncStream.makeStream(of: AudioFrame.self, bufferingPolicy: .bufferingNewest(64))
        self.continuation = cont

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        do {
            try await stream.startCapture()
        } catch {
            cont.finish(); self.continuation = nil
            throw AudioEngineError.engineStartFailed(error.localizedDescription)
        }
        self.stream = stream
        running = true
        return s
    }

    func stop() {
        guard running else { return }
        running = false
        continuation?.finish()
        continuation = nil
        if let stream { Task { try? await stream.stopCapture() } }
        self.stream = nil
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
            self.continuation?.finish()
            self.continuation = nil
            self.stream = nil
            self.onStreamStopped?()
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // stream === self.stream — the frame is from EXACTLY the current stream. Otherwise a late buffer from the old,
        // not-yet-torn-down SCStream (stopCapture is async) would leak into the new cycle's continuation.
        guard running, stream === self.stream, type == .audio, sampleBuffer.isValid,
              let cont = continuation, let frame = Self.frame(from: sampleBuffer) else { return }
        cont.yield(frame)
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
