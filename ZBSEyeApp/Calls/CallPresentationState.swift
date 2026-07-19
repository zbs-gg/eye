import Foundation

enum CallPresentationKind: String, Sendable, Equatable {
    case recording
    case finalizing
    case modelRequired
    case transcribing
    case provisional
    case ready
    case degraded
    case failed
}

struct CallControlRefreshKey: Hashable {
    let phase: CallCoordinatorPhase
    let callID: Int64?
    let modelState: WhisperModelLifecycleState
    let serviceReady: Bool
}

struct CallDetailRefreshKey: Hashable {
    let callID: Int64
    let modelState: WhisperModelLifecycleState
    let speakerModelState: SpeakerDiarizationModelLifecycleState
    let retryGeneration: UInt64
}

struct CallPresentationState: Sendable, Equatable {
    let kind: CallPresentationKind
    let title: String
    let detail: String
    let canInstallModel: Bool
    let canRetry: Bool
    let isProvisional: Bool
    let isFinal: Bool

    static func resolve(
        evidence: CallEvidencePage,
        modelState: WhisperModelLifecycleState
    ) -> CallPresentationState {
        let call = evidence.call
        let finalJob = evidence.finalJob
        let preferred = evidence.preferredRevision
        let degraded = call.degradationReason != nil
            || finalJob?.state == .readyDegraded
            || !evidence.projectionGaps.isEmpty

        if call.state == .recording {
            return state(.recording, "Recording call", "Mic and system audio stay on until End Call.")
        }
        if finalJob?.state == .failed || call.state == .failed {
            return state(
                .failed,
                "Transcription needs attention",
                preferred == nil
                    ? "The recording is safe. Retry transcription when ready."
                    : "The provisional transcript is safe; the final pass failed.",
                canRetry: true,
                isProvisional: preferred?.kind == .projection
            )
        }
        if preferred?.kind == .final, call.state == .ready {
            return state(
                degraded ? .degraded : .ready,
                degraded ? "Final transcript · gaps noted" : "Final transcript ready",
                degraded
                    ? "Missing source ranges are marked instead of being guessed."
                    : "Whisper finished the complete local pass.",
                isFinal: true
            )
        }
        if modelState != .ready {
            return state(
                .modelRequired,
                "Recording saved · Whisper needed",
                "Install the optional local speech model to transcribe it.",
                canInstallModel: true,
                isProvisional: preferred?.kind == .projection
            )
        }
        if preferred?.kind == .projection {
            return state(
                .provisional,
                "Provisional transcript",
                degraded
                    ? "Bookmark text is available with explicit gaps; the final pass is running."
                    : "Bookmark text is available; the final pass is running.",
                isProvisional: true
            )
        }
        if call.state == .finalizing || finalJob?.state == .running {
            return state(.finalizing, "Finishing call", "Audio is safe; the final local pass is running.")
        }
        return state(.transcribing, "Recording saved · transcribing", "Whisper will finish locally in the background.")
    }

    private static func state(
        _ kind: CallPresentationKind,
        _ title: LocalizedStringResource,
        _ detail: LocalizedStringResource,
        canInstallModel: Bool = false,
        canRetry: Bool = false,
        isProvisional: Bool = false,
        isFinal: Bool = false
    ) -> CallPresentationState {
        CallPresentationState(
            kind: kind,
            title: String(localized: title),
            detail: String(localized: detail),
            canInstallModel: canInstallModel,
            canRetry: canRetry,
            isProvisional: isProvisional,
            isFinal: isFinal
        )
    }
}
