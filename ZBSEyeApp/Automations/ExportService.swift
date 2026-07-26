import CryptoKit
import Foundation
import GRDB

enum CallExportError: Error, Sendable, Equatable {
    case callNotFound
    case callStillRecording
    case invalidEvidence
}

enum CallExportSourceAvailability: String, Codable, Sendable, Equatable {
    case available
    case availableWithGaps = "available_with_gaps"
    case unavailable
}

enum CallExportTranscriptStatus: String, Codable, Sendable, Equatable {
    case none
    case provisional
    case final
}

struct CallExportEnvelope: Codable, Sendable, Equatable {
    let identifier: String
    let startMs: Int64
    let endMs: Int64
    let state: CallLifecycleState
    let interrupted: Bool
    let degradationReason: String?
    let mediaGeneration: Int
}

struct CallExportContext: Codable, Sendable, Equatable {
    let captureOwner: CallCaptureOwner
    let disposition: CallCaptureDisposition
    let title: String?
    let participants: [String]
    let sourceApp: String?
}

struct CallExportSpeakerInterval: Codable, Sendable, Equatable {
    let source: CallAudioSource
    let startMs: Int64
    let endMs: Int64
}

struct CallExportSpeaker: Codable, Sendable, Equatable {
    let clusterKey: String
    let label: String
    let namingProvenance: CallSpeakerNamingProvenance
    let intervals: [CallExportSpeakerInterval]
}

struct CallExportSpeakerRevision: Codable, Sendable, Equatable {
    let identifier: String
    let state: CallSpeakerRevisionState
    let engine: String
    let modelRevision: String
    let speakers: [CallExportSpeaker]
    let speakersTruncated: Bool
    let intervalsTruncated: Bool
}

struct CallExportSourceSpan: Codable, Sendable, Equatable {
    let epoch: Int
    let sampleRate: Int
    let startMs: Int64
    let endMs: Int64?
    let availability: CallSourceAvailability
    let gapReason: String?
}

struct CallExportGap: Codable, Sendable, Equatable {
    let startMs: Int64
    let endMs: Int64
    let reason: String
}

struct CallExportSource: Codable, Sendable, Equatable {
    let source: CallAudioSource
    let availability: CallExportSourceAvailability
    let spans: [CallExportSourceSpan]
    let gaps: [CallExportGap]
}

struct CallExportBookmark: Codable, Sendable, Equatable {
    let ordinal: Int
    let acceptedAtMs: Int64
    let logicalStartMs: Int64
    let logicalEndMs: Int64
    let state: CallBookmarkState
}

struct CallExportTranscriptSegment: Codable, Sendable, Equatable {
    let ordinal: Int
    let source: CallAudioSource
    let startMs: Int64
    let endMs: Int64
    let text: String
}

struct CallExportTranscriptGap: Codable, Sendable, Equatable {
    let bookmarkOrdinal: Int
    let state: CallBookmarkState
    let logicalStartMs: Int64
    let logicalEndMs: Int64
}

struct CallExportTranscript: Codable, Sendable, Equatable {
    let status: CallExportTranscriptStatus
    let language: String?
    let engine: String?
    let modelRevision: String?
    let segments: [CallExportTranscriptSegment]
    let gaps: [CallExportTranscriptGap]
}

struct CallExportAudioReference: Codable, Sendable, Equatable {
    let source: CallAudioSource
    let startMs: Int64
    let endMs: Int64
    let sampleRate: Int
    let bytes: Int64
    let sha256: String
    let file: String
}

struct CallExportManifest: Codable, Sendable, Equatable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let call: CallExportEnvelope
    let context: CallExportContext?
    let sources: [CallExportSource]
    let bookmarks: [CallExportBookmark]
    let transcript: CallExportTranscript
    let preferredSpeakerRevision: CallExportSpeakerRevision?
    let audio: [CallExportAudioReference]
}

struct CallExportReport: Sendable, Equatable {
    let path: String
    let audioFiles: Int
}

/// History export (anti-lock-in: "take your memory with you"): Markdown per day (screen sessions +
/// transcripts) + optionally media files. Reuses DailySummaryService's collect-grouping.
actor ExportService {
    typealias DayCollector = @Sendable (Date) async throws -> CollectedDay

    private static let maximumExportedSpeakers = 128
    private static let maximumExportedSpeakerIntervals = 5_000

    private let db: ZBSEyeDatabase
    private let collectDay: DayCollector?
    private let mediaDirectory: URL

    struct Report: Sendable {
        var days = 0
        var mediaFiles = 0
        var mediaErrors = 0
        var calls = 0
        var path: String = ""
    }

    init(
        db: ZBSEyeDatabase,
        mediaDirectory: URL,
        collectDay: DayCollector? = nil
    ) {
        self.db = db
        self.collectDay = collectDay
        self.mediaDirectory = mediaDirectory
    }

    /// Export a range of days into a folder. includeMedia — copy heic/m4a (can be many gigabytes).
    func export(from: Date, to: Date, into destination: URL, includeMedia: Bool) async throws -> Report {
        var report = Report()
        let cal = Calendar.current
        let exportRoot = destination.appendingPathComponent("ZBS Eye Export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        report.path = exportRoot.path

        // Clamp to the start of data: "all history" from epoch-0 would spin ~20,000 empty iterations from 1970.
        let oldestMs: Int64? = try await db.pool.read { dbc in
            let protectedIDs = try SystemAppFilter.protectedAppIDs(in: dbc)
            let visible = SystemAppFilter.visibleCapturePredicate(
                .c,
                protectedAppIDs: protectedIDs
            )
            return try Int64.fetchOne(dbc, sql: """
                SELECT MIN(t) FROM (
                    SELECT MIN(c.ts) AS t FROM screen_captures c WHERE \(visible)
                    UNION ALL SELECT MIN(ts) FROM audio_captures
                    UNION ALL SELECT MIN(startTs) FROM calls
                ) WHERE t IS NOT NULL
                """)
        }
        guard let oldestMs else { return report }   // no data at all
        let effectiveFrom = max(from, dateFromMs(oldestMs))

        var day = cal.startOfDay(for: effectiveFrom)
        let endDay = cal.startOfDay(for: to)
        while day <= endDay && !Task.isCancelled {
            let next = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            if let md = try await markdownForDay(day) {
                let name = Self.ymd(day)
                try Data(md.utf8).write(to: exportRoot.appendingPathComponent("\(name).md"), options: .atomic)
                report.days += 1
                if includeMedia {
                    let (copied, errors) = try await copyMedia(day: day, next: next,
                                                               into: exportRoot.appendingPathComponent(name, isDirectory: true))
                    report.mediaFiles += copied
                    report.mediaErrors += errors
                }
            }
            day = next
        }
        let callIDs = try await db.pool.read { dbc in
            try Int64.fetchAll(
                dbc,
                sql: """
                    SELECT id FROM calls
                    WHERE state != ? AND startTs <= ? AND COALESCE(endTs, startTs) >= ?
                    ORDER BY startTs, id
                    """,
                arguments: [CallLifecycleState.recording.rawValue, msFromDate(to), msFromDate(effectiveFrom)]
            )
        }
        if !callIDs.isEmpty {
            let callsRoot = exportRoot.appendingPathComponent("calls", isDirectory: true)
            for callID in callIDs where !Task.isCancelled {
                let callReport = try await exportCall(
                    id: callID,
                    into: callsRoot,
                    includeAudio: includeMedia
                )
                report.calls += 1
                report.mediaFiles += callReport.audioFiles
            }
        }
        return report
    }

    /// Exports one finished Call Envelope as a replace-safe local bundle. The JSON
    /// contains only stable public fields and paths relative to that bundle.
    func exportCall(
        id callID: Int64,
        into destination: URL,
        includeAudio: Bool
    ) async throws -> CallExportReport {
        let snapshot = try await callSnapshot(id: callID)
        guard snapshot.call.state != .recording else {
            throw CallExportError.callStillRecording
        }
        guard let callID = snapshot.call.id else { throw CallExportError.callNotFound }
        let name = "call-\(callID)-\(snapshot.call.startTs)"
        let bundle = destination.appendingPathComponent(name, isDirectory: true)
        let staging = destination.appendingPathComponent(".\(name)-\(UUID().uuidString).tmp", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        let audio = includeAudio
            ? try copyCallAudio(snapshot: snapshot, into: staging)
            : []
        let manifest = makeManifest(snapshot: snapshot, audio: audio)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(
            to: staging.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        guard try await currentGeneration(callID: callID) == snapshot.call.mediaGeneration else {
            throw CallExportError.invalidEvidence
        }
        if fileManager.fileExists(atPath: bundle.path) {
            _ = try fileManager.replaceItemAt(bundle, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: bundle)
        }
        guard try await currentGeneration(callID: callID) == snapshot.call.mediaGeneration else {
            try? fileManager.removeItem(at: bundle)
            throw CallExportError.invalidEvidence
        }
        return CallExportReport(path: bundle.path, audioFiles: audio.count)
    }

    /// Markdown for a day: screen sessions (as in daily-summary, no LLM) + transcripts with speakers.
    private func markdownForDay(_ day: Date) async throws -> String? {
        guard let collectDay else { return nil }
        let collected: CollectedDay
        do { collected = try await collectDay(day) }
        catch let e as AutomationError {
            if case .noData = e { return nil }   // empty day — no file; anything else is a real error
            throw e
        }

        let tf = DateFormatter(); tf.locale = Locale(identifier: "ru_RU"); tf.dateFormat = "HH:mm"
        let dayF = DateFormatter(); dayF.locale = Locale(identifier: "ru_RU"); dayF.dateFormat = "EEEE, d MMMM yyyy"

        var md = "# \(dayF.string(from: collected.day))\n\n"
        md += "_ZBS Eye export · \(collected.totalCaptures) frames, \(collected.totalSlices) sessions_\n\n"
        md += "## Activity\n\n"
        for s in collected.slices {
            md += "### \(tf.string(from: s.start))–\(tf.string(from: s.end)) · \(s.app)"
            if let w = s.window, !w.isEmpty { md += " — \(w)" }
            md += "\n"
            if let u = s.url, !u.isEmpty { md += "<\(u)>\n" }
            if !s.sample.isEmpty { md += "\n> \(s.sample)\n" }
            md += "\n"
        }

        // transcripts for the day (with speakers)
        let cal = Calendar.current
        let startMs = msFromDate(cal.startOfDay(for: day))
        let endMs = startMs + 86_400_000 - 1
        struct T { let ts: Int64; let speaker: String?; let text: String }
        let transcripts: [T] = try await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT a.ts AS ts, t.speaker AS speaker, t.text AS text
                FROM transcriptions t JOIN audio_captures a ON a.id = t.audioId
                WHERE a.ts BETWEEN ? AND ? ORDER BY a.ts
                """, arguments: [startMs, endMs]).map {
                T(ts: $0["ts"], speaker: $0["speaker"], text: $0["text"])
            }
        }
        if !transcripts.isEmpty {
            md += "## Conversations\n\n"
            for t in transcripts {
                let who = t.speaker ?? "—"
                md += "**\(tf.string(from: dateFromMs(t.ts))) · \(who):** \(t.text)\n\n"
            }
        }
        return md
    }

    private struct CallExportSnapshot: Sendable {
        let call: CallRow
        let context: CallContextRow?
        let spans: [CallSourceSpanRow]
        let gaps: [CallSourceGapRow]
        let bookmarks: [CallBookmarkRow]
        let revision: CallTranscriptRevisionRow?
        let transcriptGaps: [CallTranscriptProjectionGapRow]
        let segments: [CallTranscriptSegmentRow]
        let chunks: [CallAudioChunkRow]
        let speakerRevision: CallSpeakerRevisionRow?
        let speakerClusters: [CallSpeakerClusterRow]
        let speakerIntervals: [CallSpeakerIntervalRow]
    }

    private func callSnapshot(id callID: Int64) async throws -> CallExportSnapshot {
        try await db.pool.read { dbc in
            guard let call = try CallRow.fetchOne(dbc, key: callID) else {
                throw CallExportError.callNotFound
            }
            let context = try CallContextRow.fetchOne(dbc, key: callID)
            let spans = try CallSourceSpanRow.fetchAll(
                dbc,
                sql: "SELECT * FROM call_source_spans WHERE callId = ? ORDER BY source, epoch, id",
                arguments: [callID]
            )
            let gaps = try CallSourceGapRow.fetchAll(
                dbc,
                sql: """
                    SELECT * FROM call_source_gaps
                    WHERE callId = ? AND mediaGeneration = ?
                    ORDER BY source, startMs, endMs, id
                    """,
                arguments: [callID, call.mediaGeneration]
            )
            let bookmarks = try CallBookmarkRow.fetchAll(
                dbc,
                sql: """
                    SELECT * FROM call_bookmarks
                    WHERE callId = ? AND mediaGeneration = ? ORDER BY ordinal, id
                    """,
                arguments: [callID, call.mediaGeneration]
            )
            let revision = try call.preferredRevisionId.flatMap { revisionID in
                try CallTranscriptRevisionRow.fetchOne(
                    dbc,
                    sql: """
                        SELECT * FROM call_transcript_revisions
                        WHERE id = ? AND callId = ? AND mediaGeneration = ? AND state = ?
                        """,
                    arguments: [
                        revisionID,
                        callID,
                        call.mediaGeneration,
                        CallTranscriptRevisionState.ready.rawValue,
                    ]
                )
            }
            let transcriptGaps: [CallTranscriptProjectionGapRow]
            let segments: [CallTranscriptSegmentRow]
            if let revisionID = revision?.id {
                transcriptGaps = try CallTranscriptProjectionGapRow.fetchAll(
                    dbc,
                    sql: """
                        SELECT * FROM call_transcript_projection_gaps
                        WHERE revisionId = ? ORDER BY ordinal, bookmarkId
                        """,
                    arguments: [revisionID]
                )
                segments = try CallTranscriptSegmentRow.fetchAll(
                    dbc,
                    sql: """
                        SELECT * FROM call_transcript_segments
                        WHERE revisionId = ? ORDER BY ordinal, id
                        """,
                    arguments: [revisionID]
                )
            } else {
                transcriptGaps = []
                segments = []
            }
            let chunks = try CallAudioChunkRow.fetchAll(
                dbc,
                sql: """
                    SELECT * FROM call_audio_chunks
                    WHERE callId = ? AND mediaGeneration = ? AND finalized = 1
                    ORDER BY source, startMs, epoch, sequence, id
                    """,
                arguments: [callID, call.mediaGeneration]
            )
            let speakerRevision = try call.preferredSpeakerRevisionId.flatMap { revisionID in
                try CallSpeakerRevisionRow.fetchOne(
                    dbc,
                    sql: """
                        SELECT * FROM call_speaker_revisions
                        WHERE id = ? AND callId = ? AND mediaGeneration = ? AND state = ?
                        """,
                    arguments: [
                        revisionID,
                        callID,
                        call.mediaGeneration,
                        CallSpeakerRevisionState.ready.rawValue,
                    ]
                )
            }
            let speakerClusters: [CallSpeakerClusterRow]
            let speakerIntervals: [CallSpeakerIntervalRow]
            if let speakerRevisionID = speakerRevision?.id {
                speakerClusters = try CallSpeakerClusterRow.fetchAll(
                    dbc,
                    sql: """
                        SELECT * FROM call_speaker_clusters
                        WHERE revisionId = ? ORDER BY ordinal, id LIMIT ?
                        """,
                    arguments: [speakerRevisionID, Self.maximumExportedSpeakers + 1]
                )
                speakerIntervals = try CallSpeakerIntervalRow.fetchAll(
                    dbc,
                    sql: """
                        SELECT * FROM call_speaker_intervals
                        WHERE revisionId = ? ORDER BY ordinal, id LIMIT ?
                        """,
                    arguments: [speakerRevisionID, Self.maximumExportedSpeakerIntervals + 1]
                )
            } else {
                speakerClusters = []
                speakerIntervals = []
            }
            return CallExportSnapshot(
                call: call,
                context: context,
                spans: spans,
                gaps: gaps,
                bookmarks: bookmarks,
                revision: revision,
                transcriptGaps: transcriptGaps,
                segments: segments,
                chunks: chunks,
                speakerRevision: speakerRevision,
                speakerClusters: speakerClusters,
                speakerIntervals: speakerIntervals
            )
        }
    }

    private func currentGeneration(callID: Int64) async throws -> Int? {
        try await db.pool.read { dbc in
            try Int.fetchOne(
                dbc,
                sql: "SELECT mediaGeneration FROM calls WHERE id = ? AND state != ?",
                arguments: [callID, CallLifecycleState.recording.rawValue]
            )
        }
    }

    private func makeManifest(
        snapshot: CallExportSnapshot,
        audio: [CallExportAudioReference]
    ) -> CallExportManifest {
        let callEnd = snapshot.call.endTs ?? snapshot.call.updatedAtMs
        let sources = [CallAudioSource.me, .system].map { source in
            let spans = snapshot.spans.filter { $0.source == source }
            var gaps = snapshot.gaps
                .filter { $0.source == source }
                .map { CallExportGap(startMs: $0.startMs, endMs: $0.endMs, reason: $0.reason) }
            gaps.append(contentsOf: spans.compactMap { span in
                guard span.availability == .gap || span.gapReason != nil else { return nil }
                return CallExportGap(
                    startMs: span.startedAtMs,
                    endMs: span.endedAtMs ?? callEnd,
                    reason: span.gapReason ?? "capture_gap"
                )
            })
            gaps.sort {
                ($0.startMs, $0.endMs, $0.reason) < ($1.startMs, $1.endMs, $1.reason)
            }
            let hasAvailable = spans.contains { $0.availability == .available }
            let availability: CallExportSourceAvailability
            if hasAvailable, !gaps.isEmpty {
                availability = .availableWithGaps
            } else if hasAvailable {
                availability = .available
            } else {
                availability = .unavailable
            }
            return CallExportSource(
                source: source,
                availability: availability,
                spans: spans.map {
                    CallExportSourceSpan(
                        epoch: $0.epoch,
                        sampleRate: $0.sampleRate,
                        startMs: $0.startedAtMs,
                        endMs: $0.endedAtMs,
                        availability: $0.availability,
                        gapReason: $0.gapReason
                    )
                },
                gaps: gaps
            )
        }
        let transcriptStatus: CallExportTranscriptStatus
        switch snapshot.revision?.kind {
        case .projection: transcriptStatus = .provisional
        case .final: transcriptStatus = .final
        case .interval, .none: transcriptStatus = .none
        }
        let context = snapshot.context.map {
            CallExportContext(
                captureOwner: $0.captureOwner,
                disposition: $0.disposition,
                title: $0.title,
                participants: Self.decodeParticipants($0.participantsJSON),
                sourceApp: $0.sourceAppName
            )
        }
        let preferredSpeakerRevision = Self.speakerProjection(snapshot: snapshot)
        return CallExportManifest(
            formatVersion: CallExportManifest.currentFormatVersion,
            call: CallExportEnvelope(
                identifier: "call-\(snapshot.call.id ?? 0)",
                startMs: snapshot.call.startTs,
                endMs: callEnd,
                state: snapshot.call.state,
                interrupted: snapshot.call.interrupted,
                degradationReason: snapshot.call.degradationReason,
                mediaGeneration: snapshot.call.mediaGeneration
            ),
            context: context,
            sources: sources,
            bookmarks: snapshot.bookmarks.map {
                CallExportBookmark(
                    ordinal: $0.ordinal,
                    acceptedAtMs: $0.acceptedAtMs,
                    logicalStartMs: $0.logicalStartMs,
                    logicalEndMs: $0.logicalEndMs,
                    state: $0.state
                )
            },
            transcript: CallExportTranscript(
                status: transcriptStatus,
                language: snapshot.revision?.language,
                engine: snapshot.revision?.engine,
                modelRevision: snapshot.revision?.modelRevision,
                segments: snapshot.segments.map {
                    CallExportTranscriptSegment(
                        ordinal: $0.ordinal,
                        source: $0.source,
                        startMs: $0.startMs,
                        endMs: $0.endMs,
                        text: $0.text
                    )
                },
                gaps: snapshot.transcriptGaps.map {
                    CallExportTranscriptGap(
                        bookmarkOrdinal: $0.ordinal,
                        state: $0.state,
                        logicalStartMs: $0.logicalStartMs,
                        logicalEndMs: $0.logicalEndMs
                    )
                }
            ),
            preferredSpeakerRevision: preferredSpeakerRevision,
            audio: audio
        )
    }

    private static func speakerProjection(
        snapshot: CallExportSnapshot
    ) -> CallExportSpeakerRevision? {
        guard let revision = snapshot.speakerRevision,
              let revisionID = revision.id,
              revision.state == .ready,
              revision.callId == snapshot.call.id,
              revision.mediaGeneration == snapshot.call.mediaGeneration else {
            return nil
        }
        let clusters = Array(snapshot.speakerClusters.prefix(maximumExportedSpeakers))
        let intervals = Array(snapshot.speakerIntervals.prefix(maximumExportedSpeakerIntervals))
        let intervalsByCluster = Dictionary(grouping: intervals, by: \.clusterId)
        return CallExportSpeakerRevision(
            identifier: "speaker-revision-\(revisionID)",
            state: revision.state,
            engine: revision.engine,
            modelRevision: revision.modelRevision,
            speakers: clusters.compactMap { cluster in
                guard let clusterID = cluster.id else { return nil }
                return CallExportSpeaker(
                    clusterKey: cluster.clusterKey,
                    label: cluster.displayName ?? "Speaker \(cluster.ordinal + 1)",
                    namingProvenance: cluster.namingProvenance,
                    intervals: (intervalsByCluster[clusterID] ?? []).map {
                        CallExportSpeakerInterval(
                            source: $0.source,
                            startMs: $0.startMs,
                            endMs: $0.endMs
                        )
                    }
                )
            },
            speakersTruncated: snapshot.speakerClusters.count > maximumExportedSpeakers,
            intervalsTruncated: snapshot.speakerIntervals.count > maximumExportedSpeakerIntervals
        )
    }

    private static func decodeParticipants(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return names.lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(12)
            .map { String($0.prefix(80)) }
    }

    private func copyCallAudio(
        snapshot: CallExportSnapshot,
        into bundle: URL
    ) throws -> [CallExportAudioReference] {
        guard !snapshot.chunks.isEmpty else { return [] }
        let secureRoot = try SecureCallSpoolRoot(root: mediaDirectory)
        let spans = Dictionary(
            uniqueKeysWithValues: snapshot.spans.compactMap { span in span.id.map { ($0, span) } }
        )
        var result: [CallExportAudioReference] = []
        for chunk in snapshot.chunks {
            guard chunk.bytes >= 0,
                  chunk.bytes <= Int64(Int.max),
                  let span = spans[chunk.sourceSpanId] else {
                throw CallExportError.invalidEvidence
            }
            let data = try secureRoot.readRange(
                relativePath: chunk.relativePath,
                offset: 0,
                byteCount: Int(chunk.bytes)
            )
            guard data.count == Int(chunk.bytes) else { throw CallExportError.invalidEvidence }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let expected = chunk.sha256, !expected.isEmpty, expected != digest {
                throw CallExportError.invalidEvidence
            }
            let relative = String(
                format: "audio/%@/epoch-%04d-seq-%06d-%lld-%lld.pcm",
                chunk.source.rawValue,
                chunk.epoch,
                chunk.sequence,
                chunk.startSample,
                chunk.endSample
            )
            let destination = bundle.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            result.append(
                CallExportAudioReference(
                    source: chunk.source,
                    startMs: chunk.startMs,
                    endMs: chunk.endMs,
                    sampleRate: span.sampleRate,
                    bytes: chunk.bytes,
                    sha256: digest,
                    file: relative
                )
            )
        }
        return result
    }

    /// Copy a day's media into a subfolder (heic frames + m4a segments).
    private func copyMedia(day: Date, next: Date, into folder: URL) async throws -> (copied: Int, errors: Int) {
        let startMs = msFromDate(day), endMs = msFromDate(next) - 1
        let paths: [String] = try await db.pool.read { dbc in
            let frameRows = try Row.fetchAll(dbc, sql: """
                SELECT c.relativePath AS relativePath, a.bundleId AS bundleId, a.name AS appName
                FROM screen_captures c LEFT JOIN apps a ON a.id = c.appId
                WHERE c.ts BETWEEN ? AND ? AND c.relativePath IS NOT NULL
                """, arguments: [startMs, endMs])
            let frames: [String] = frameRows.compactMap { row in
                guard !SystemAppFilter.isProtectedCaptureSurface(
                    bundleId: row["bundleId"],
                    appName: row["appName"]
                ) else { return nil }
                return row["relativePath"]
            }
            let audio = try String.fetchAll(dbc, sql:
                "SELECT relativePath FROM audio_captures WHERE ts BETWEEN ? AND ?",
                arguments: [startMs, endMs])
            return frames + audio
        }
        guard !paths.isEmpty else { return (0, 0) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var copied = 0
        var errors = 0
        for rel in paths where !Task.isCancelled {
            let src = mediaDirectory.appendingPathComponent(rel)
            let dst = folder.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: dst.path) { copied += 1; continue }  // re-export
            do { try FileManager.default.copyItem(at: src, to: dst); copied += 1 }
            catch { errors += 1 }
        }
        return (copied, errors)
    }

    private static func ymd(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
