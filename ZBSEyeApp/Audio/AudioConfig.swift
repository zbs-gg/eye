import Foundation

/// Audio capture and transcription parameters (DI, testable). Slice 1: mic only, on-device SFSpeech.
/// System audio, 16k downsample, multi-locale auto-detect, MLX Quality mode — follow-up.
struct AudioConfig: Sendable {
    var tapBufferSize: UInt32 = 4096        // ~85ms at 48k — VAD frame granularity
    var vadEnergyThreshold: Float = 0.012   // RMS over normalized floats; below this — silence/background
    var minSpeechSec: Double = 0.4          // shorter — not a segment (clicks/noise)
    var silenceHangoverSec: Double = 0.7    // this much silence in a row → close the segment
    var maxSegmentSec: Double = 28          // segment length cap (on-device speech prefers short ones)
    var maxQueuedSegments = 240             // backpressure: on overflow we drop new ones
    var idleUnloadSeconds: Double = 900     // 15 min idle → unload the recognizer (RAM)
    var localeIdentifiers = ["ru-RU", "en-US"] // try both, take the one with the best confidence (auto-detect)
    var minTranscriptConfidence: Float = 0.3 // below this (when confidence is actually >0) → noise, don't pollute FTS
    var targetSampleRate: Double = 16_000   // downsample m4a to 16k (speech, ×3 lighter; SFSpeech is 16k anyway)
    var transcribeTimeoutSec: Double = 60   // cap on recognizing a single locale (a stuck on-device engine)
}
