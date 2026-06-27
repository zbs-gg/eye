import Foundation

/// Sendable values of the audio pipeline. Non-Sendable types (AVAudioPCMBuffer/AVAudioEngine) live inside their
/// own domains; only these types cross outward.

/// One frame from the microphone tap: mono samples (normalized float) + RMS energy for VAD.
struct AudioFrame: Sendable {
    let samples: [Float]
    let rms: Float
    let sampleRate: Double
    let ts: Date
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
