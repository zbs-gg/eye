import GRDB

extension CallRepository {
    static func enqueueCallEndedAutomation(
        call: CallRow,
        callID: Int64,
        occurredAtMs: Int64,
        db: Database
    ) throws {
        try CallAutomationOutbox.enqueueIfEnabled(
            eventType: .callEnded,
            semanticIdentity: "call-ended:\(callID):\(call.mediaGeneration)",
            callID: callID,
            occurredAtMs: occurredAtMs,
            data: CallEndedAutomationData(
                state: call.state.rawValue,
                interrupted: call.interrupted,
                degraded: call.degradationReason != nil
            ),
            db: db
        )
    }

    static func enqueueTranscriptFailedAutomation(
        job: CallTranscriptJobRow,
        jobID: Int64,
        errorCode: String,
        occurredAtMs: Int64,
        db: Database
    ) throws {
        try CallAutomationOutbox.enqueueIfEnabled(
            eventType: .transcriptFailed,
            semanticIdentity: "transcript-failed:\(jobID):\(job.attempts)",
            callID: job.callId,
            occurredAtMs: occurredAtMs,
            data: CallTranscriptFailedAutomationData(
                state: CallLifecycleState.failed.rawValue,
                errorCode: errorCode,
                attempt: job.attempts
            ),
            db: db
        )
    }

    static func enqueueTranscriptReadyAutomation(
        call: CallRow,
        job: CallTranscriptJobRow,
        revisionID: Int64,
        degraded: Bool,
        occurredAtMs: Int64,
        db: Database
    ) throws {
        try CallAutomationOutbox.enqueueIfEnabled(
            eventType: .transcriptReady,
            semanticIdentity: "transcript-ready:\(revisionID)",
            callID: job.callId,
            occurredAtMs: occurredAtMs,
            data: CallTranscriptReadyAutomationData(
                state: call.state.rawValue,
                degraded: degraded,
                revisionID: revisionID
            ),
            db: db
        )
    }
}
