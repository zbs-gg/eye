import Foundation

enum AudioIngressRejectionReason: Sendable, Equatable {
    case terminated
}

enum AudioIngressYieldResult: Sendable, Equatable {
    case accepted(sequence: Int64, droppedGap: AudioIngressGap?)
    case rejected(sequence: Int64, reason: AudioIngressRejectionReason)
}

/// The only work capture callbacks do after producing mono samples: assign an
/// ingress sequence and yield into a bounded stream. The lock protects the
/// sequence/accepted-watermark snapshot; no actor hop, Task, logging, DB, or IO
/// occurs on the hardware callback.
final class AudioIngressPublisher: @unchecked Sendable {
    let stream: AsyncStream<AudioFrame>

    private let continuation: AsyncStream<AudioFrame>.Continuation
    private let source: CallAudioSource
    private let epoch: Int
    private let lock = NSLock()
    private var nextSequence: Int64 = 0
    private var latestAccepted: Int64?
    private var pendingGaps: [AudioIngressGap] = []
    private var finished = false

    init(
        source: CallAudioSource,
        epoch: Int,
        capacity: Int = 64,
        initialSequence: Int64 = 0
    ) {
        self.source = source
        self.epoch = epoch
        nextSequence = initialSequence
        pendingGaps.reserveCapacity(16)
        let pair = AsyncStream.makeStream(
            of: AudioFrame.self,
            bufferingPolicy: .bufferingNewest(max(1, capacity))
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    var latestAcceptedIngressSequence: Int64? {
        lock.withLock { latestAccepted }
    }

    var nextAttemptedIngressSequence: Int64 {
        lock.withLock { nextSequence }
    }

    func drainGaps() -> [AudioIngressGap] {
        lock.withLock {
            let result = pendingGaps
            pendingGaps.removeAll(keepingCapacity: true)
            return result
        }
    }

    @discardableResult
    func yield(
        samples: [Float],
        rms: Float,
        captureSampleRate: Double,
        sourceSampleTime: Int64?,
        normalizedHostTimeNs: Int64,
        capturedAt: Date,
        provenance: AudioFrameTimingProvenance
    ) -> AudioIngressYieldResult {
        lock.withLock {
            let sequence = nextSequence
            nextSequence += 1
            guard !finished else {
                return .rejected(sequence: sequence, reason: .terminated)
            }
            let frame = AudioFrame(
                samples: samples,
                rms: rms,
                timing: AudioFrameTiming(
                    source: source,
                    epoch: epoch,
                    ingressSequence: sequence,
                    normalizedHostTimeNs: normalizedHostTimeNs,
                    sourceSampleTime: sourceSampleTime,
                    captureSampleRate: captureSampleRate,
                    frameCount: samples.count,
                    capturedAt: capturedAt,
                    provenance: provenance
                )
            )
            switch continuation.yield(frame) {
            case .enqueued:
                latestAccepted = sequence
                return .accepted(sequence: sequence, droppedGap: nil)
            case .dropped(let evicted):
                latestAccepted = sequence
                let evictedSequence = evicted.timing.ingressSequence
                let durationNs = Int64(
                    (Double(evicted.timing.frameCount)
                        / evicted.timing.captureSampleRate * 1_000_000_000).rounded()
                )
                let startMs = Int64(
                    (evicted.timing.capturedAt.timeIntervalSince1970 * 1_000).rounded()
                )
                let endMs = max(
                    startMs + 1,
                    startMs + Int64((Double(durationNs) / 1_000_000).rounded())
                )
                let gap = AudioIngressGap(
                    source: source,
                    epoch: epoch,
                    firstIngressSequence: evictedSequence,
                    lastIngressSequence: evictedSequence,
                    reason: .consumerOverflow,
                    startHostTimeNs: evicted.timing.normalizedHostTimeNs,
                    endHostTimeNs: evicted.timing.normalizedHostTimeNs + max(1, durationNs),
                    startMs: startMs,
                    endMs: endMs
                )
                record(gap)
                return .accepted(
                    sequence: sequence,
                    droppedGap: gap
                )
            case .terminated:
                finished = true
                return .rejected(sequence: sequence, reason: .terminated)
            @unknown default:
                finished = true
                return .rejected(sequence: sequence, reason: .terminated)
            }
        }
    }

    func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            continuation.finish()
        }
    }


    private func record(_ gap: AudioIngressGap) {
        if let last = pendingGaps.last,
           last.reason == gap.reason,
           last.lastIngressSequence + 1 == gap.firstIngressSequence {
            pendingGaps[pendingGaps.count - 1] = AudioIngressGap(
                source: source,
                epoch: epoch,
                firstIngressSequence: last.firstIngressSequence,
                lastIngressSequence: gap.lastIngressSequence,
                reason: gap.reason,
                startHostTimeNs: [last.startHostTimeNs, gap.startHostTimeNs].compactMap { $0 }.min(),
                endHostTimeNs: [last.endHostTimeNs, gap.endHostTimeNs].compactMap { $0 }.max(),
                startMs: [last.startMs, gap.startMs].compactMap { $0 }.min(),
                endMs: [last.endMs, gap.endMs].compactMap { $0 }.max()
            )
            return
        }
        if pendingGaps.count < 16 {
            pendingGaps.append(gap)
            return
        }
        let first = pendingGaps.first?.firstIngressSequence ?? gap.firstIngressSequence
        let collapsed = pendingGaps + [gap]
        pendingGaps = [
            AudioIngressGap(
                source: source,
                epoch: epoch,
                firstIngressSequence: first,
                lastIngressSequence: gap.lastIngressSequence,
                reason: .telemetryOverflow,
                startHostTimeNs: collapsed.compactMap(\.startHostTimeNs).min(),
                endHostTimeNs: collapsed.compactMap(\.endHostTimeNs).max(),
                startMs: collapsed.compactMap(\.startMs).min(),
                endMs: collapsed.compactMap(\.endMs).max()
            )
        ]
    }
}

struct CallPCM16Resampler: Sendable {
    private let inputSampleRate: Double
    private let outputSampleRate: Double
    private let inputStep: Double
    private var pending: [Float] = []
    private var pendingBase: Int64 = 0
    private var nextOutputPosition: Double = 0

    init(inputSampleRate: Double, outputSampleRate: Double) {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        inputStep = inputSampleRate / outputSampleRate
    }

    mutating func append(_ samples: [Float]) -> Data {
        guard !samples.isEmpty, inputSampleRate > 0, outputSampleRate > 0 else { return Data() }
        pending.append(contentsOf: samples)
        return emit(final: false)
    }

    mutating func finish() -> Data {
        let data = emit(final: true)
        pending.removeAll(keepingCapacity: false)
        return data
    }

    private mutating func emit(final: Bool) -> Data {
        let end = Double(pendingBase + Int64(pending.count))
        var output = Data()
        while nextOutputPosition < end {
            let lowerAbsolute = Int64(floor(nextOutputPosition))
            let upperAbsolute = lowerAbsolute + 1
            if !final && upperAbsolute >= pendingBase + Int64(pending.count) { break }
            let lowerIndex = Int(lowerAbsolute - pendingBase)
            guard pending.indices.contains(lowerIndex) else { break }
            let upperIndex = min(lowerIndex + 1, pending.count - 1)
            let fraction = Float(nextOutputPosition - Double(lowerAbsolute))
            let sample = pending[lowerIndex] + (pending[upperIndex] - pending[lowerIndex]) * fraction
            var pcm = quantize(sample).littleEndian
            withUnsafeBytes(of: &pcm) { output.append(contentsOf: $0) }
            nextOutputPosition += inputStep
        }

        let keepFromAbsolute = Int64(floor(nextOutputPosition))
        let removable = min(
            pending.count,
            max(0, Int(keepFromAbsolute - pendingBase))
        )
        if removable > 0 {
            pending.removeFirst(removable)
            pendingBase += Int64(removable)
        }
        return output
    }

    private func quantize(_ sample: Float) -> Int16 {
        let clamped = min(1, max(-1, sample))
        if clamped <= -1 { return .min }
        return Int16((clamped * Float(Int16.max)).rounded())
    }
}
