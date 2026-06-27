import Foundation
import GRDB

/// History export (anti-lock-in: "take your memory with you"): Markdown per day (screen sessions +
/// transcripts) + optionally media files. Reuses DailySummaryService's collect-grouping.
actor ExportService {
    private let db: ZBSEyeDatabase
    private let summary: DailySummaryService
    private let mediaDirectory: URL

    struct Report: Sendable {
        var days = 0
        var mediaFiles = 0
        var mediaErrors = 0
        var path: String = ""
    }

    init(db: ZBSEyeDatabase, summary: DailySummaryService, mediaDirectory: URL) {
        self.db = db
        self.summary = summary
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
            try Int64.fetchOne(dbc, sql: """
                SELECT MIN(t) FROM (
                    SELECT MIN(ts) AS t FROM screen_captures
                    UNION ALL SELECT MIN(ts) FROM audio_captures
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
                let name = DailySummaryService.ymd(day)
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
        return report
    }

    /// Markdown for a day: screen sessions (as in daily-summary, no LLM) + transcripts with speakers.
    private func markdownForDay(_ day: Date) async throws -> String? {
        let collected: CollectedDay
        do { collected = try await summary.collect(day: day, safety: .default) }
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

    /// Copy a day's media into a subfolder (heic frames + m4a segments).
    private func copyMedia(day: Date, next: Date, into folder: URL) async throws -> (copied: Int, errors: Int) {
        let startMs = msFromDate(day), endMs = msFromDate(next) - 1
        let paths: [String] = try await db.pool.read { dbc in
            let frames = try String.fetchAll(dbc, sql: """
                SELECT relativePath FROM screen_captures
                WHERE ts BETWEEN ? AND ? AND relativePath IS NOT NULL
                """, arguments: [startMs, endMs])
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
}
