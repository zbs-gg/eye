import Foundation
import GRDB

extension CallRepository {
    func videoSegmentForPostprocessRecovery(
        relativePath: String
    ) async throws -> CallVideoSegmentRow? {
        try await evidenceStorage.read { db in
            try CallVideoSegmentRow.fetchOne(
                db,
                sql: """
                    SELECT * FROM call_video_segments
                    WHERE relativePath = ? AND finalized = 1
                    LIMIT 1
                    """,
                arguments: [relativePath]
            )
        }
    }

    func callIDsNeedingVideoPostprocess(limit: Int = 100) async throws -> [Int64] {
        try await evidenceStorage.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT s.callId
                    FROM call_video_segments s
                    JOIN calls c ON c.id = s.callId
                    WHERE s.finalized = 1 AND s.audioMuxed = 0 AND c.state != 'recording'
                    ORDER BY s.callId
                    LIMIT ?
                    """,
                arguments: [max(1, limit)]
            )
        }
    }

    func videoPostprocessSnapshot(callID: Int64) async throws -> CallVideoPostprocessSnapshot {
        try await evidenceStorage.read { db in
            guard let call = try CallRow.fetchOne(db, key: callID) else {
                throw CallRepositoryError.callNotFound(callID)
            }
            return CallVideoPostprocessSnapshot(
                call: call,
                audioSpans: try CallSourceSpanRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_source_spans WHERE callId = ? ORDER BY source, epoch",
                    arguments: [callID]
                ),
                audioChunks: try CallAudioChunkRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_audio_chunks WHERE callId = ? AND finalized = 1 ORDER BY source, epoch, sequence",
                    arguments: [callID]
                ),
                videoSegments: try CallVideoSegmentRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_video_segments WHERE callId = ? AND finalized = 1 AND audioMuxed = 0 ORDER BY startMs, id",
                    arguments: [callID]
                )
            )
        }
    }

    func markVideoSegmentAudioMuxed(
        id: Int64,
        mediaGeneration: Int,
        bytes: Int64,
        sha256: String
    ) async throws {
        try await evidenceStorage.write { db in
            try db.execute(
                sql: """
                    UPDATE call_video_segments
                    SET bytes = ?, sha256 = ?, audioMuxed = 1
                    WHERE id = ? AND mediaGeneration = ? AND finalized = 1
                    """,
                arguments: [bytes, sha256, id, mediaGeneration]
            )
            guard db.changesCount == 1 else {
                throw CallRepositoryError.invalidMediaMutation(id)
            }
        }
    }

    func recoverOpenVideoSpans(nowMs: Int64) async throws {
        try await evidenceStorage.write { db in
            let spans = try CallVideoSpanRow.fetchAll(
                db,
                sql: "SELECT * FROM call_video_spans WHERE endedAtMs IS NULL OR availability = 'recording'"
            )
            for var span in spans {
                guard let spanID = span.id else { continue }
                let lastEnd = try Int64.fetchOne(
                    db,
                    sql: "SELECT MAX(endMs) FROM call_video_segments WHERE videoSpanId = ? AND finalized = 1",
                    arguments: [spanID]
                ) ?? span.startedAtMs
                let end = max(lastEnd + 1, nowMs)
                span.endedAtMs = end
                span.availability = .gap
                span.gapReason = "process_crash"
                try span.update(db)
                var gap = CallVideoGapRow(
                    id: nil,
                    callId: span.callId,
                    mediaGeneration: span.mediaGeneration,
                    startMs: lastEnd,
                    endMs: end,
                    reason: "process_crash",
                    createdAtMs: nowMs
                )
                try gap.insert(db)
            }
        }
    }

    func beginVideoSpan(
        callID: Int64,
        epoch: Int,
        displayID: String,
        startedAtMs: Int64,
        width: Int,
        height: Int,
        fps: Int
    ) async throws -> CallVideoSpanRow {
        try await evidenceStorage.write { db in
            guard let call = try CallRow.fetchOne(db, key: callID),
                  call.state == .recording else {
                throw CallRepositoryError.callNotRecording(callID)
            }
            var row = CallVideoSpanRow(
                id: nil,
                callId: callID,
                mediaGeneration: call.mediaGeneration,
                epoch: epoch,
                displayId: displayID,
                startedAtMs: startedAtMs,
                endedAtMs: nil,
                width: width,
                height: height,
                fps: fps,
                codec: nil,
                availability: .recording,
                gapReason: nil
            )
            try row.insert(db)
            return row
        }
    }

    func appendVideoSegment(_ draft: CallVideoSegmentDraft) async throws -> CallVideoSegmentRow {
        try await evidenceStorage.write { db in
            var row = CallVideoSegmentRow(
                id: nil,
                callId: draft.callId,
                videoSpanId: draft.videoSpanId,
                mediaGeneration: draft.mediaGeneration,
                epoch: draft.epoch,
                sequence: draft.sequence,
                startMs: draft.startMs,
                endMs: draft.endMs,
                relativePath: draft.relativePath,
                bytes: draft.bytes,
                sha256: draft.sha256,
                width: draft.width,
                height: draft.height,
                fps: draft.fps,
                codec: draft.codec,
                finalized: true,
                audioMuxed: draft.audioMuxed
            )
            try row.insert(db)
            return row
        }
    }

    func finishVideoSpan(
        spanID: Int64,
        endedAtMs: Int64,
        codec: CallVideoCodec?,
        availability: CallVideoAvailability,
        reason: String?
    ) async throws {
        try await evidenceStorage.write { db in
            try db.execute(
                sql: """
                    UPDATE call_video_spans
                    SET endedAtMs = ?, codec = COALESCE(?, codec), availability = ?, gapReason = ?
                    WHERE id = ? AND endedAtMs IS NULL
                    """,
                arguments: [endedAtMs, codec?.rawValue, availability.rawValue, reason, spanID]
            )
        }
    }

    func recordVideoGap(
        callID: Int64,
        startMs: Int64,
        endMs: Int64,
        reason: String,
        nowMs: Int64
    ) async throws {
        guard endMs >= startMs else { return }
        try await evidenceStorage.write { db in
            guard let call = try CallRow.fetchOne(db, key: callID) else {
                throw CallRepositoryError.callNotFound(callID)
            }
            var row = CallVideoGapRow(
                id: nil,
                callId: callID,
                mediaGeneration: call.mediaGeneration,
                startMs: startMs,
                endMs: endMs,
                reason: reason,
                createdAtMs: nowMs
            )
            try row.insert(db)
        }
    }

    func setRecordingMode(callID: Int64, mode: CallRecordingMode, nowMs: Int64) async throws {
        try await evidenceStorage.write { db in
            try db.execute(
                sql: "UPDATE calls SET recordingMode = ?, updatedAtMs = ? WHERE id = ?",
                arguments: [mode.rawValue, nowMs, callID]
            )
        }
    }
}
