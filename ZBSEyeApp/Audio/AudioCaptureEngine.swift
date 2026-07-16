import Foundation
import AVFoundation
import Darwin

enum AudioEngineError: LocalizedError {
    case noInputDevice
    case engineStartFailed(String)
    var errorDescription: String? {
        switch self {
        case .noInputDevice:          return "No audio input device (microphone)."
        case .engineStartFailed(let m): return "Failed to start the audio engine: \(m)"
        }
    }
}

/// Microphone capture: AVAudioEngine + a tap on the input. The tap downmixes to mono, computes RMS and yields frames into
/// an AsyncStream. Not an actor (AVAudioEngine isn't Sendable, the tap lives on a real-time thread) — we encapsulate it,
/// only the Sendable AudioFrame crosses the boundary. @unchecked Sendable: the continuation is thread-safe (yield/finish),
/// `running` — a benign stop/tap race (removeTap silences callbacks, a yield after finish is a no-op).
final class AudioCaptureEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let config: AudioConfig
    private var publisher: AudioIngressPublisher?
    private var running = false
    private var configObserver: NSObjectProtocol?
    private var epoch = -1
    private var nextIngressSequence: Int64 = 0
    private var lastAcceptedIngressSequence: Int64?
    private var completedGaps: [AudioIngressGap] = []

    /// Audio configuration change (AirPods plugged/unplugged, default input switched) — the engine stopped,
    /// the stream closed. The coordinator restarts the leg; without this, half a day of calls would vanish silently.
    var onConfigurationChange: (@Sendable () -> Void)?

    init(config: AudioConfig) { self.config = config }

    var latestAcceptedIngressSequence: Int64? {
        publisher?.latestAcceptedIngressSequence ?? lastAcceptedIngressSequence
    }

    func drainIngressGaps() -> [AudioIngressGap] {
        let result = completedGaps + (publisher?.drainGaps() ?? [])
        completedGaps.removeAll(keepingCapacity: true)
        return result
    }

    /// Start. Returns the frame stream. Throws if there's no device / the engine didn't start.
    func start() throws -> AsyncStream<AudioFrame> {
        guard !running else { throw AudioEngineError.engineStartFailed("already running") }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        let sr = format.sampleRate
        let ch = Int(format.channelCount)
        guard sr > 0, ch > 0 else { throw AudioEngineError.noInputDevice }

        epoch += 1
        let publisher = AudioIngressPublisher(
            source: .me,
            epoch: epoch,
            capacity: 64,
            initialSequence: nextIngressSequence
        )
        self.publisher = publisher

        // We capture cont/ch/sr LOCALLY (not self.continuation): each cycle's tap writes into ITS OWN
        // continuation — re-installing self won't redirect the tail into a foreign stream, and there's no race reading
        // self.continuation from the real-time thread (fixes a data race on the @unchecked Sendable field).
        input.installTap(onBus: 0, bufferSize: config.tapBufferSize, format: format) { [publisher, ch, sr] buffer, time in
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
            let hostTimeNs: Int64
            if time.isHostTimeValid {
                hostTimeNs = Int64(AVAudioTime.seconds(forHostTime: time.hostTime) * 1_000_000_000)
            } else {
                hostTimeNs = Int64(AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1_000_000_000)
            }
            let callbackHostTimeNs = Int64(
                AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1_000_000_000
            )
            let capturedAt = AudioHostClockWallMapper.date(
                for: hostTimeNs,
                callbackHostTimeNs: callbackHostTimeNs,
                callbackWallDate: Date()
            )
            _ = publisher.yield(
                samples: mono,
                rms: rms,
                captureSampleRate: sr,
                sourceSampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
                normalizedHostTimeNs: hostTimeNs,
                capturedAt: capturedAt,
                provenance: time.isHostTimeValid ? .microphone : .callbackFallback
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            archive(publisher)
            publisher.finish()
            self.publisher = nil
            throw AudioEngineError.engineStartFailed(error.localizedDescription)
        }
        // Audio device connected/changed: we stop the leg cleanly (flushFinal arrives via
        // finish) and signal the coordinator to restart with the new device format.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // queue: .main — the coordinator's stop() and start()/stop() are serialized on the main thread
            // (without this, the check-then-act on running would race with MainActor)
            guard let self, self.running else { return }
            self.stop()
            self.onConfigurationChange?()
        }
        running = true
        return publisher.stream
    }

    func stop() {
        guard running else { return }
        running = false
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let publisher {
            archive(publisher)
            publisher.finish()
        }
        publisher = nil   // don't hold the previous cycle's publisher between stop and the next start
    }

    private func archive(_ publisher: AudioIngressPublisher) {
        lastAcceptedIngressSequence = publisher.latestAcceptedIngressSequence
            ?? lastAcceptedIngressSequence
        nextIngressSequence = publisher.nextAttemptedIngressSequence
        completedGaps.append(contentsOf: publisher.drainGaps())
    }
}
