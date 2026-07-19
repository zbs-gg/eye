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

    /// Enqueues once both authoritative local projections refer to the current
    /// media generation. The semantic identity makes retries and either
    /// completion order (transcript first or speakers first) idempotent.
    static func enqueueProcessingReadyAutomationIfComplete(
        callID: Int64,
        occurredAtMs: Int64,
        db: Database
    ) throws {
        guard let call = try CallRow.fetchOne(db, key: callID),
              call.state == .ready,
              let transcriptRevisionID = call.preferredRevisionId,
              let speakerRevisionID = call.preferredSpeakerRevisionId,
              let transcript = try CallTranscriptRevisionRow.fetchOne(db, key: transcriptRevisionID),
              transcript.callId == callID,
              transcript.mediaGeneration == call.mediaGeneration,
              transcript.kind == .final,
              transcript.state == .ready,
              let speakers = try CallSpeakerRevisionRow.fetchOne(db, key: speakerRevisionID),
              speakers.callId == callID,
              speakers.mediaGeneration == call.mediaGeneration,
              speakers.state == .ready else { return }

        try CallAutomationOutbox.enqueueIfEnabled(
            eventType: .processingReady,
            semanticIdentity: "processing-ready:\(callID):\(call.mediaGeneration):\(transcriptRevisionID):\(speakerRevisionID)",
            callID: callID,
            occurredAtMs: occurredAtMs,
            data: CallProcessingReadyAutomationData(
                state: call.state.rawValue,
                transcriptRevisionID: transcriptRevisionID,
                speakerRevisionID: speakerRevisionID
            ),
            db: db
        )
    }
}
