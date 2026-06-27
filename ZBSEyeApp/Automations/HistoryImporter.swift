import Foundation
import GRDB

/// Import prior history (~/.screenpipe/db.sqlite): take the accumulated memory without loss, without
/// tying ourselves to someone else's product. We move TEXT + metadata (frames: app/window/URL/AX/OCR text;
/// audio: transcripts with speaker). Media is NOT copied (50k+ jpg/chunks stay in place,
/// our "forever memory" is about search and context). Vectors are back-indexed by VectorBackfill in the background.
/// Idempotent: id cursors persist — a re-run continues without duplicating.
actor HistoryImporter {
    private let db: ZBSEyeDatabase
    private var running = false

    struct Report: Sendable {
        var frames = 0
        var audio = 0
        var skipped = 0
    }

    static var defaultSourcePath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".screenpipe/db.sqlite").path
    }
    static var sourceExists: Bool { FileManager.default.fileExists(atPath: defaultSourcePath) }

    init(db: ZBSEyeDatabase) { self.db = db }

    /// Progress — callback (frames, audio) every ~500 rows.
    func run(sourcePath: String = HistoryImporter.defaultSourcePath,
             progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Report {
        guard !running else { return Report() }
        running = true
        defer { running = false }

        // Source strictly read-only (someone else's DB, may be open in its own app).
        var cfg = Configuration()
        cfg.readonly = true
        let source = try DatabaseQueue(path: sourcePath, configuration: cfg)

        var report = Report()
        let (frames, fSkip) = try await importFrames(source: source, progress: progress)
        let (audio, aSkip) = try await importAudio(source: source, framesDone: frames, progress: progress)
        report.frames = frames
        report.audio = audio
        report.skipped = fSkip + aSkip
        Log.app.info("history import: +\(report.frames) frames, +\(report.audio) audio, skipped(bad ts/empty) \(report.skipped)")
        return report
    }

    // MARK: frames

    private struct SPFrame: Sendable {
        let id: Int64; let tsMs: Int64
        let app: String; let window: String?; let url: String?
        let text: String?; let source: String
    }

    private func importFrames(source: DatabaseQueue,
                              progress: (@Sendable (Int, Int) -> Void)?) async throws -> (imported: Int, skipped: Int) {
        let cursorKey = "zbseye.import.sp.frameCursor"
        var cursor = Int64(UserDefaults.standard.string(forKey: cursorKey) ?? "") ?? 0
        var total = 0
        var skipped = 0
        while !Task.isCancelled {
            let (page, rawCount): ([SPFrame], Int) = try await source.read { [cursor] dbc in
                let rows = try Row.fetchAll(dbc, sql: """
                    SELECT f.id AS id, f.timestamp AS ts, f.app_name AS app, f.window_name AS win,
                           f.browser_url AS url, f.accessibility_text AS ax, f.full_text AS full,
                           f.text_source AS src,
                           (SELECT o.text FROM ocr_text o WHERE o.frame_id = f.id LIMIT 1) AS ocr
                    FROM frames f WHERE f.id > ? ORDER BY f.id LIMIT 500
                    """, arguments: [cursor])
                let mapped: [SPFrame] = rows.compactMap { row in
                    guard let tsMs = Self.parseTimestamp(row["ts"]) else { return nil }
                    let ax: String? = row["ax"]
                    let full: String? = row["full"]
                    let ocr: String? = row["ocr"]
                    let text = [ax, full, ocr].compactMap { $0 }.first { !$0.isEmpty }
                    let isAX = (ax?.isEmpty == false) || (row["src"] as String?) == "accessibility"
                    return SPFrame(id: row["id"], tsMs: tsMs,
                                   app: (row["app"] as String?) ?? "imported",
                                   window: row["win"], url: row["url"],
                                   text: text, source: isAX ? "ax" : "ocr")
                }
                return (mapped, rows.count)
            }
            skipped += rawCount - page.count   // rows with an unparseable ts (observability, not loss: cursor by raw id)
            // even if every row of the page got filtered out (bad ts) — advance the cursor by the raw id
            let rawMaxId: Int64? = try await source.read { [cursor] dbc in
                try Int64.fetchOne(dbc, sql: "SELECT MAX(id) FROM (SELECT id FROM frames WHERE id > ? ORDER BY id LIMIT 500)",
                                   arguments: [cursor])
            }
            guard let nextCursor = rawMaxId else { break }

            try await db.pool.write { dbc in
                for f in page {
                    let appId = try Self.upsertApp(dbc, name: f.app)
                    // Idempotency: a re-run (after a cursor reset / partial loss from
                    // retention) must not duplicate what was already imported. Key — (ts, appId, sp).
                    // KNOWN LIMITATION: a key without device_name collapses frames of the same app with
                    // the same ts on DIFFERENT monitors (~0.15% in the real source DB). The correct
                    // fix is a source_id column; done in the storage rework (can't change the key now:
                    // it would break idempotency against already-imported monitorId='sp' rows).
                    if try Int.fetchOne(dbc, sql:
                        "SELECT 1 FROM screen_captures WHERE ts = ? AND appId = ? AND monitorId = 'sp' LIMIT 1",
                        arguments: [f.tsMs, appId]) != nil { continue }
                    var cap = ScreenCaptureRow(
                        id: nil, ts: f.tsMs, appId: appId,
                        windowTitle: f.window, browserUrl: f.url,
                        monitorId: "sp", relativePath: nil,
                        width: nil, height: nil, bytes: nil,
                        axQuality: f.source == "ax" ? "fullUseful" : "ocr",
                        usefulTextChars: f.text?.count, nodeCount: nil,
                        treeWasEmpty: nil, hitBudgetLimit: nil,
                        ocrFallbackReason: "imported",
                        manualAccessibilityResult: nil, enhancedUiResult: nil)
                    try cap.insert(dbc)
                    if let text = f.text, !text.isEmpty {
                        var tb = TextBlockRow(id: nil, captureId: cap.id!, source: f.source,
                                              text: String(text.prefix(20_000)), confidence: 1.0,
                                              bboxX: nil, bboxY: nil, bboxW: nil, bboxH: nil)
                        try tb.insert(dbc)
                    }
                }
            }
            total += page.count
            cursor = nextCursor
            UserDefaults.standard.set(String(cursor), forKey: cursorKey)
            progress?(total, 0)
            await Task.yield()
        }
        return (total, skipped)
    }

    // MARK: audio

    private func importAudio(source: DatabaseQueue, framesDone: Int,
                             progress: (@Sendable (Int, Int) -> Void)?) async throws -> (imported: Int, skipped: Int) {
        struct SPAudio: Sendable {
            let id: Int64; let tsMs: Int64; let text: String
            let isInput: Bool; let dur: Double; let engine: String
        }
        let cursorKey = "zbseye.import.sp.audioCursor"
        var cursor = Int64(UserDefaults.standard.string(forKey: cursorKey) ?? "") ?? 0
        var total = 0
        var skipped = 0
        while !Task.isCancelled {
            let (page, rawCount): ([SPAudio], Int) = try await source.read { [cursor] dbc in
                let rows = try Row.fetchAll(dbc, sql: """
                    SELECT id, timestamp AS ts, transcription, is_input_device AS inp,
                           start_time, end_time, transcription_engine AS engine
                    FROM audio_transcriptions WHERE id > ? ORDER BY id LIMIT 500
                    """, arguments: [cursor])
                let mapped: [SPAudio] = rows.compactMap { row in
                    guard let tsMs = Self.parseTimestamp(row["ts"]),
                          let text = row["transcription"] as String?, !text.isEmpty else { return nil }
                    let start: Double? = row["start_time"]
                    let end: Double? = row["end_time"]
                    return SPAudio(id: row["id"], tsMs: tsMs, text: text,
                                   isInput: (row["inp"] as Bool?) ?? true,
                                   dur: max(0, (end ?? 0) - (start ?? 0)),
                                   engine: (row["engine"] as String?) ?? "imported")
                }
                return (mapped, rows.count)
            }
            skipped += rawCount - page.count   // bad ts / empty transcript
            let rawMaxId: Int64? = try await source.read { [cursor] dbc in
                try Int64.fetchOne(dbc, sql: "SELECT MAX(id) FROM (SELECT id FROM audio_transcriptions WHERE id > ? ORDER BY id LIMIT 500)",
                                   arguments: [cursor])
            }
            guard let nextCursor = rawMaxId else { break }

            try await db.pool.write { dbc in
                for a in page {
                    // Idempotency: don't duplicate on a re-run. Key — (ts, channel,
                    // text): in the source several DIFFERENT utterances legitimately share one ts, so
                    // (ts,channel) alone would wrongly collapse them — the transcript text is also needed.
                    if try Int.fetchOne(dbc, sql: """
                        SELECT 1 FROM audio_captures ac JOIN transcriptions t ON t.audioId = ac.id
                        WHERE ac.ts = ? AND ac.channel = ? AND ac.relativePath = 'imported'
                              AND t.text = ? LIMIT 1
                        """,
                        arguments: [a.tsMs, a.isInput ? "mic" : "system", a.text]) != nil { continue }
                    var row = AudioCaptureRow(id: nil, ts: a.tsMs,
                                              relativePath: "imported",   // we don't move media
                                              durationSec: a.dur,
                                              channel: a.isInput ? "mic" : "system", bytes: nil)
                    try row.insert(dbc)
                    var tr = TranscriptionRow(id: nil, audioId: row.id!, text: a.text,
                                              language: "auto",
                                              speaker: a.isInput ? "me" : "other",
                                              startOffset: 0, endOffset: a.dur,
                                              engine: "imported/(a.engine)")
                    try tr.insert(dbc)
                }
            }
            total += page.count
            cursor = nextCursor
            UserDefaults.standard.set(String(cursor), forKey: cursorKey)
            progress?(framesDone, total)   // frames already imported — don't reset the counter in the UI
            await Task.yield()
        }
        return (total, skipped)
    }

    // MARK: helpers

    /// Their timestamp — ISO8601 with MICROseconds ("2026-06-06T15:43:21.233864+00:00") or without.
    /// Formatters are local (not static): DateFormatter isn't Sendable; the cost per 500-row page is negligible.
    static func parseTimestamp(_ raw: String?) -> Int64? {
        guard let raw else { return nil }
        let micro = DateFormatter()
        micro.locale = Locale(identifier: "en_US_POSIX")
        micro.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        if let d = micro.date(from: raw) { return msFromDate(d) }
        if let d = ISO8601DateFormatter().date(from: raw) { return msFromDate(d) }
        let fr = ISO8601DateFormatter()
        fr.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fr.date(from: raw) { return msFromDate(d) }
        return nil
    }

    /// Their app_name has no bundleId — we synthesize a stable unique key.
    private static func upsertApp(_ db: Database, name: String) throws -> Int64 {
        let bundleId = "imported." + name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
        if let existing = try AppRow.filter(Column("bundleId") == bundleId).fetchOne(db) {
            return existing.id!
        }
        var row = AppRow(id: nil, bundleId: bundleId, name: name)
        try row.insert(db)
        return row.id!
    }
}
