import Foundation
import AVFoundation

enum AudioEngineError: LocalizedError {
    case noInputDevice
    case engineStartFailed(String)
    var errorDescription: String? {
        switch self {
        case .noInputDevice:          return "Нет входного аудио-устройства (микрофона)."
        case .engineStartFailed(let m): return "Не удалось запустить аудио-движок: \(m)"
        }
    }
}

/// Захват микрофона: AVAudioEngine + tap на input. Tap даунмиксит в моно, считает RMS и отдаёт кадры в
/// AsyncStream. Не actor (AVAudioEngine не Sendable, tap живёт на real-time потоке) — инкапсулируем,
/// наружу только Sendable AudioFrame. @unchecked Sendable: continuation thread-safe (yield/finish),
/// `running` — benign-гонка стоп/тап (removeTap гасит колбэки, yield после finish = no-op).
final class AudioCaptureEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let config: AudioConfig
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var running = false
    private var configObserver: NSObjectProtocol?

    /// Смена аудио-конфигурации (подключили/сняли AirPods, сменился default input) — движок встал,
    /// лента закрыта. Координатор перезапускает лег; без этого полдня звонков пропадало бы молча.
    var onConfigurationChange: (@Sendable () -> Void)?

    init(config: AudioConfig) { self.config = config }

    /// Старт. Возвращает поток кадров. Бросает, если нет устройства/движок не стартанул.
    func start() throws -> AsyncStream<AudioFrame> {
        guard !running else { throw AudioEngineError.engineStartFailed("already running") }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        let sr = format.sampleRate
        let ch = Int(format.channelCount)
        guard sr > 0, ch > 0 else { throw AudioEngineError.noInputDevice }

        let (stream, cont) = AsyncStream.makeStream(of: AudioFrame.self,
                                                    bufferingPolicy: .bufferingNewest(64))
        self.continuation = cont

        // Захватываем cont/ch/sr ЛОКАЛЬНО (не self.continuation): tap каждого цикла пишет в СВОЙ
        // continuation — переустановка self не перенаправит хвост в чужой stream, и нет гонки чтения
        // self.continuation с real-time потока (фикс data race на @unchecked Sendable-поле).
        input.installTap(onBus: 0, bufferSize: config.tapBufferSize, format: format) { [cont, ch, sr] buffer, _ in
            guard let chData = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var mono = [Float](repeating: 0, count: n)
            if ch <= 1 {
                mono.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: chData[0], count: n)
                }
            } else {
                for i in 0..<n {
                    var s: Float = 0
                    for c in 0..<ch { s += chData[c][i] }
                    mono[i] = s / Float(ch)
                }
            }
            var sum: Float = 0
            for v in mono { sum += v * v }
            let rms = (sum / Float(n)).squareRoot()
            cont.yield(AudioFrame(samples: mono, rms: rms, sampleRate: sr, ts: Date()))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            cont.finish()
            self.continuation = nil
            throw AudioEngineError.engineStartFailed(error.localizedDescription)
        }
        // Подключение/смена аудио-устройства: останавливаем лег корректно (flushFinal дойдёт через
        // finish) и сигналим координатору перезапустить с новым форматом устройства.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // queue: .main — stop() и start()/stop() координатора сериализуются на главном потоке
            // (без этого check-then-act на running гонялся бы с MainActor)
            guard let self, self.running else { return }
            self.stop()
            self.onConfigurationChange?()
        }
        running = true
        return stream
    }

    func stop() {
        guard running else { return }
        running = false
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil   // не держим cont прошлого цикла между stop и следующим start
    }
}
