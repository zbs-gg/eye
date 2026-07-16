import Foundation

/// Sendable values of the audio pipeline. Non-Sendable types (AVAudioPCMBuffer/AVAudioEngine) live inside their
/// own domains; only these types cross outward.

enum AudioFrameTimingProvenance: String, Codable, Sendable, Equatable {
    case microphone
    case screenCaptureKit
    case callbackFallback
}

struct AudioFrameTiming: Codable, Sendable, Equatable {
    let source: CallAudioSource
    let epoch: Int
    let ingressSequence: Int64
    let normalizedHostTimeNs: Int64
    let sourceSampleTime: Int64?
    let captureSampleRate: Double
    let frameCount: Int
    let capturedAt: Date
    let provenance: AudioFrameTimingProvenance
}

enum AudioIngressGapReason: String, Codable, Sendable, Equatable {
    case consumerOverflow
    case sourceRestart
    case sourceUnavailable
    case telemetryOverflow
}

struct AudioIngressGap: Codable, Sendable, Equatable {
    let source: CallAudioSource
    let epoch: Int
    let firstIngressSequence: Int64
    let lastIngressSequence: Int64
    let reason: AudioIngressGapReason
}

/// One frame from an audio callback. Hardware objects never cross this boundary;
/// capture timing is explicit so a Bookmark can freeze accepted ingress rather
/// than guessing from wall-clock time.
struct AudioFrame: Sendable {
    let samples: [Float]
    let rms: Float
    let timing: AudioFrameTiming

    var sampleRate: Double { timing.captureSampleRate }
    var ts: Date { timing.capturedAt }

    init(samples: [Float], rms: Float, timing: AudioFrameTiming) {
        self.samples = samples
        self.rms = rms
        self.timing = timing
    }

    /// Compatibility for the legacy VAD path and fixtures that do not own a
    /// capture-engine ingress sequence.
    init(samples: [Float], rms: Float, sampleRate: Double, ts: Date) {
        self.init(
            samples: samples,
            rms: rms,
            timing: AudioFrameTiming(
                source: .me,
                epoch: 0,
                ingressSequence: 0,
                normalizedHostTimeNs: Int64(ts.timeIntervalSince1970 * 1_000_000_000),
                sourceSampleTime: nil,
                captureSampleRate: sampleRate,
                frameCount: samples.count,
                capturedAt: ts,
                provenance: .callbackFallback
            )
        )
    }
}

/// A completed speech segment: the file is already written and an audio_captures row inserted — ready for transcription.
struct AudioSegment: Sendable {
    let audioId: Int64
    let fileURL: URL
    let ts: Date
    let durationSec: Double
    let channel: String   // "mic" | "system" — for the transcript's speaker label (me/other party)
}

/// Result of backend transcription.
struct Transcript: Sendable {
    let text: String
    let language: String
    let engine: String
}

/// Transcription health for the UI: how many recognized/failed/dropped + the kind of the last error
/// (the key thing — distinguish "no on-device model / no permission" from transient failures).
struct TranscriptionHealth: Sendable, Equatable {
    var transcribed = 0
    var failed = 0
    var dropped = 0
    var lastErrorKind: String?   // "onDeviceUnavailable" | "notAuthorized" | "recognizerUnavailable" | nil
}

/// Sendable input for IngestService (the transcript is tied to audioId). ts — the moment of the segment
/// (for the bucket_month semantic vector).
struct TranscriptionRecord: Sendable {
    let audioId: Int64
    let ts: Date
    let text: String
    let language: String
    let engine: String
    let speaker: String?       // "me" (mic) / "other party" (system) — a cheap diarization proxy
    let startOffset: Double?
    let endOffset: Double?
    init(audioId: Int64, ts: Date, text: String, language: String, engine: String,
         speaker: String? = nil, startOffset: Double? = nil, endOffset: Double? = nil) {
        self.audioId = audioId; self.ts = ts; self.text = text; self.language = language
        self.engine = engine; self.speaker = speaker
        self.startOffset = startOffset; self.endOffset = endOffset
    }
}
