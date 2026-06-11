import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Захват СИСТЕМНОГО звука (то, что играет в колонках/наушниках — другая сторона звонков, видео, встречи)
/// через ScreenCaptureKit audio-only SCStream. Использует уже выданное право Screen Recording (микрофон
/// НЕ нужен). Даунмикс в моно + RMS → AsyncStream<AudioFrame> (тот же путь, что и микрофон).
/// @unchecked Sendable: callback на sampleQueue; `running`-флаг гасит запоздавшие колбэки старого стрима.
final class SystemAudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let config: AudioConfig
    private var stream: SCStream?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var running = false
    private let sampleQueue = DispatchQueue(label: "com.slishu.systemaudio.samples")

    /// Стрим умер mid-run (ошибка SCK, отзыв права, перестройка дисплеев) — лента закрыта;
    /// координатор перезапускает лег. Без делегата смерть была молчаливой (лента висела навсегда).
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
        cfg.excludesCurrentProcessAudio = true   // не записывать собственный звук ZBS Eye (эхо/петля)
        // Видео нам не нужно — минимизируем: крошечный кадр, редкий тик (audio-only стрим всё равно
        // требует валидной video-части в конфиге).
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
        // Мутации полей — только на main: stop()/start() координатора тоже там (без гонки check-then-act).
        // ObjectIdentifier вместо самого SCStream — non-Sendable объект не тащим в main-замыкание.
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
        // stream === self.stream — кадр от ИМЕННО текущего стрима. Иначе запоздавший буфер старого,
        // ещё не снесённого SCStream (stopCapture async) уехал бы в continuation нового цикла.
        guard running, stream === self.stream, type == .audio, sampleBuffer.isValid,
              let cont = continuation, let frame = Self.frame(from: sampleBuffer) else { return }
        cont.yield(frame)
    }

    /// CMSampleBuffer (Float32, non-interleaved — формат SCStream audio) → моно-кадр + RMS.
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
