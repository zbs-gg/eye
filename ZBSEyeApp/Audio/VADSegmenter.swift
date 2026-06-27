import Foundation

/// Pure VAD/segmenter (no I/O — tested in isolation). Based on frame energy it decides whether to keep
/// accumulating samples into the current segment and when to close it. Silence BEFORE speech begins is
/// dropped (we don't write empty segments); the energy threshold cuts out music/background; prolonged
/// silence closes the segment.
struct VADSegmenter: Sendable {
    /// What the consumer should do with the current frame:
    /// - ignore: silence before speech — do NOT accumulate the frame;
    /// - append: accumulate the frame into the segment;
    /// - flush: accumulate the frame and CLOSE the segment (enough speech gathered → send to transcription);
    /// - discard: close and THROW AWAY the accumulated audio (the speech turned out too short).
    enum Action: Equatable { case ignore, append, flush, discard }

    var energyThreshold: Float
    var minSpeechSec: Double
    var silenceHangoverSec: Double
    var maxSegmentSec: Double

    private var inSpeech = false
    private var speechSec = 0.0     // total "voiced" seconds in the segment
    private var silenceSec = 0.0    // consecutive silence since the last voiced frame
    private var segSec = 0.0        // full length of the segment

    init(config: AudioConfig) {
        energyThreshold = config.vadEnergyThreshold
        minSpeechSec = config.minSpeechSec
        silenceHangoverSec = config.silenceHangoverSec
        maxSegmentSec = config.maxSegmentSec
    }

    mutating func feed(rms: Float, frameSec: Double) -> Action {
        let voiced = rms >= energyThreshold
        if !inSpeech {
            guard voiced else { return .ignore }
            inSpeech = true; speechSec = frameSec; silenceSec = 0; segSec = frameSec
            return .append
        }
        segSec += frameSec
        if voiced { speechSec += frameSec; silenceSec = 0 } else { silenceSec += frameSec }

        if silenceSec >= silenceHangoverSec {
            let enough = speechSec >= minSpeechSec
            reset()
            return enough ? .flush : .discard
        }
        if segSec >= maxSegmentSec { reset(); return .flush }
        return .append
    }

    /// Force-close the current segment (on recording stop). Returns true if there was something to emit.
    mutating func finishPending() -> Bool {
        let had = inSpeech && speechSec >= minSpeechSec
        reset()
        return had
    }

    private mutating func reset() { inSpeech = false; speechSec = 0; silenceSec = 0; segSec = 0 }
}
