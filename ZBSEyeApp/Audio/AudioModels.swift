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
    let startHostTimeNs: Int64?
    let endHostTimeNs: Int64?
    let startMs: Int64?
    let endMs: Int64?

    init(
        source: CallAudioSource,
        epoch: Int,
        firstIngressSequence: Int64,
        lastIngressSequence: Int64,
        reason: AudioIngressGapReason,
        startHostTimeNs: Int64? = nil,
        endHostTimeNs: Int64? = nil,
        startMs: Int64? = nil,
        endMs: Int64? = nil
    ) {
        self.source = source
        self.epoch = epoch
        self.firstIngressSequence = firstIngressSequence
        self.lastIngressSequence = lastIngressSequence
        self.reason = reason
        self.startHostTimeNs = startHostTimeNs
        self.endHostTimeNs = endHostTimeNs
        self.startMs = startMs
        self.endMs = endMs
    }
}

enum AudioHostClockWallMapper {
    static func date(
        for normalizedHostTimeNs: Int64,
        callbackHostTimeNs: Int64,
        callbackWallDate: Date
    ) -> Date {
        callbackWallDate.addingTimeInterval(
            Double(normalizedHostTimeNs - callbackHostTimeNs) / 1_000_000_000
        )
    }
}

struct BoundedAudioIngressGaps: Sendable {
    private(set) var intervals: [AudioIngressGap] = []
    private(set) var hadAnyGap = false
    private let capacity: Int

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
        intervals.reserveCapacity(self.capacity)
    }

    mutating func record(_ gap: AudioIngressGap) {
        hadAnyGap = true
        if let last = intervals.last,
           last.source == gap.source,
           last.epoch == gap.epoch,
           last.reason == gap.reason,
           gap.firstIngressSequence <= last.lastIngressSequence + 1 {
            intervals[intervals.count - 1] = AudioIngressGap(
                source: gap.source,
                epoch: gap.epoch,
                firstIngressSequence: min(last.firstIngressSequence, gap.firstIngressSequence),
                lastIngressSequence: max(last.lastIngressSequence, gap.lastIngressSequence),
                reason: gap.reason,
                startHostTimeNs: [last.startHostTimeNs, gap.startHostTimeNs].compactMap { $0 }.min(),
                endHostTimeNs: [last.endHostTimeNs, gap.endHostTimeNs].compactMap { $0 }.max(),
                startMs: [last.startMs, gap.startMs].compactMap { $0 }.min(),
                endMs: [last.endMs, gap.endMs].compactMap { $0 }.max()
            )
            return
        }
        intervals.append(gap)
        if intervals.count > capacity {
            intervals.removeFirst(intervals.count - capacity)
        }
    }

    func covers(source: CallAudioSource, sequence: Int64) -> Bool {
        intervals.contains {
            $0.source == source
                && $0.firstIngressSequence <= sequence
                && $0.lastIngressSequence >= sequence
        }
    }

    mutating func prune(source: CallAudioSource, through sequence: Int64) {
        intervals.removeAll {
            $0.source == source && $0.lastIngressSequence <= sequence
        }
    }
}

typealias CallAudioFrameSink = @Sendable (AudioFrame) async -> Bool

enum CallAudioFrameRoute: Sendable, Equatable {
    /// No explicit Call owns the physical leg, so the ordinary Timeline pipeline may consume it.
    case background
    /// The current explicit Call sink owns this frame.
    case explicitCall
    /// A hard privacy/lifecycle edge closed the Call synchronously. The frame is intentionally
    /// consumed without reaching either the old Call spool or the background Timeline pipeline.
    case dropAtBoundary
}

/// A synchronous MainActor latch in front of the asynchronous Call spool. Closing it does not
/// detach or reopen a sink: only the final live lifecycle check may admit the exact lease returned
/// for a newly prepared sink. That prevents unlock/resume or an ABA-stale start from resurrecting
/// an old Call whose teardown is still suspended in detector or persistence work.
struct CallAudioFrameAdmissionLatch: Sendable, Equatable {
    private enum Phase: Sendable, Equatable {
        case detached
        case prepared(CallAudioFrameAdmissionLease)
        case open(CallAudioFrameAdmissionLease)
        case sealed(CallAudioFrameAdmissionLease)
    }

    private var phase = Phase.detached
    private var nextGeneration: UInt64 = 0

    var permitsCallFrames: Bool {
        if case .open = phase { return true }
        return false
    }

    /// Replacing the sink creates a new ABA-safe identity but never admits frames by itself. The
    /// final live lifecycle check must explicitly admit this exact lease.
    mutating func installSink(present: Bool) -> CallAudioFrameAdmissionLease? {
        guard present else {
            phase = .detached
            return nil
        }
        nextGeneration &+= 1
        let lease = CallAudioFrameAdmissionLease(generation: nextGeneration)
        phase = .prepared(lease)
        return lease
    }

    @discardableResult
    mutating func admit(_ lease: CallAudioFrameAdmissionLease) -> Bool {
        guard case let .prepared(prepared) = phase, prepared == lease else { return false }
        phase = .open(lease)
        return true
    }

    func isOpen(for lease: CallAudioFrameAdmissionLease) -> Bool {
        guard case let .open(open) = phase else { return false }
        return open == lease
    }

    mutating func close() {
        switch phase {
        case .detached, .sealed:
            return
        case let .prepared(lease), let .open(lease):
            phase = .sealed(lease)
        }
    }

    func route(hasCallSink: Bool) -> CallAudioFrameRoute {
        guard hasCallSink else { return .background }
        return permitsCallFrames ? .explicitCall : .dropAtBoundary
    }
}

struct CallAudioFrameAdmissionLease: Sendable, Equatable {
    fileprivate let generation: UInt64
}

/// Issued by CallRecordingStore before its first asynchronous start operation. Every hard closing
/// edge advances `lifecycleGeneration`, so a close-and-reopen that happens before sink installation
/// still invalidates the in-flight start. `unscoped` exists only for lower-level coordinator tests;
/// AppEnvironment deliberately rejects it.
struct CallAudioStartAdmissionLease: Sendable, Equatable {
    let startGeneration: UInt64
    let lifecycleGeneration: UInt64
    let isScoped: Bool

    static let unscoped = CallAudioStartAdmissionLease(
        startGeneration: 0,
        lifecycleGeneration: 0,
        isScoped: false
    )
}

struct AudioIngressTargets: Sendable, Equatable {
    let me: Int64?
    let system: Int64?
}

struct CallAudioFrameBoundary: Sendable, Equatable {
    let targets: AudioIngressTargets

    func contains(source: CallAudioSource, ingressSequence: Int64) -> Bool {
        let maximum: Int64?
        switch source {
        case .me: maximum = targets.me
        case .system: maximum = targets.system
        }
        guard let maximum else { return false }
        return ingressSequence <= maximum
    }
}

enum CallAudioFrameRouter {
    /// Returns whether the frame is owned by the Call path and therefore must not fall through to
    /// the ordinary Timeline pipeline. Once admission is sealed, a pre-boundary frame may still be
    /// offered to the Call sink so an already accepted frame can drain. A closed sink is still a
    /// consumed Call frame: returning its rejection would leak the frame into Timeline after the
    /// hard lifecycle/privacy boundary.
    static func route(
        _ frame: AudioFrame,
        admission: CallAudioFrameRoute,
        sealedBoundary: CallAudioFrameBoundary?,
        sink: CallAudioFrameSink?
    ) async -> Bool {
        switch admission {
        case .background:
            return false
        case .dropAtBoundary:
            guard let sink,
                  sealedBoundary?.contains(
                    source: frame.timing.source,
                    ingressSequence: frame.timing.ingressSequence
                  ) == true
            else { return true }
            _ = await sink(frame)
            return true
        case .explicitCall:
            guard let sink else { return false }
            return await sink(frame)
        }
    }
}

enum CallAudioFinalizationTargetPolicy {
    /// Once a hard boundary is sealed, physical engines may keep accepting frames until teardown.
    /// Finalization must wait only for the frozen boundary, never for those intentionally dropped
    /// post-boundary sequences.
    static func targets(
        hasCallSink: Bool,
        sealedBoundary: CallAudioFrameBoundary?,
        liveTargets: AudioIngressTargets
    ) -> AudioIngressTargets {
        if hasCallSink, let sealedBoundary { return sealedBoundary.targets }
        return liveTargets
    }
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
