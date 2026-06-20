import Foundation
import GRDB

/// Импорт прежней истории (~/.screenpipe/db.sqlite): забрать накопленную память без потерь, не
/// привязывая себя к чужому продукту. Переносится ТЕКСТ + метаданные (кадры: app/окно/URL/AX/OCR-текст;
/// аудио: транскрипты со спикером). Медиа НЕ копируется (50k+ jpg/чанки остаются на месте,
/// наша «вечная память» — про поиск и контекст). Векторы доиндексирует VectorBackfill фоном.
/// Идемпотентен: курсоры по id персистятся — повторный запуск продолжает, не дублирует.
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

    /// Прогресс — колбэк (frames, audio) каждые ~500 строк.
    func run(sourcePath: String = HistoryImporter.defaultSourcePath,
             progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Report {
        guard !running else { return Report() }
        running = true
        defer { running = false }

        // Источник строго read-only (чужая БД, может быть открыта своим приложением).
        var cfg = Configuration()
        cfg.readonly = true
        let source = try DatabaseQueue(path: sourcePath, configuration: cfg)

        var report = Report()
        let (frames, fSkip) = try await importFrames(source: source, progress: progress)
        let (audio, aSkip) = try await importAudio(source: source, framesDone: frames, progress: progress)
        report.frames = frames
        report.audio = audio
        report.skipped = fSkip + aSkip
        Log.app.info("импорт истории: +\(report.frames) кадров, +\(report.audio) аудио, пропущено(битый ts/пусто) \(report.skipped)")
        return report
    }

    // MARK: кадры

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
            skipped += rawCount - page.count   // строки с непарсируемым ts (observability, не потеря: курсор по raw id)
            // даже если все строки страницы отфильтровались (битый ts) — курсор двигаем по сырому id
            let rawMaxId: Int64? = try await source.read { [cursor] dbc in
                try Int64.fetchOne(dbc, sql: "SELECT MAX(id) FROM (SELECT id FROM frames WHERE id > ? ORDER BY id LIMIT 500)",
                                   arguments: [cursor])
            }
            guard let nextCursor = rawMaxId else { break }

            try await db.pool.write { dbc in
                for f in page {
                    let appId = try Self.upsertApp(dbc, name: f.app)
                    // Идемпотентность: повторный прогон (после reset курсора / частичной потери от
                    // retention) не должен дублировать уже импортированное. Ключ — (ts, appId, sp).
                    // ИЗВЕСТНОЕ ОГРАНИЧЕНИЕ: ключ без device_name схлопывает кадры одного приложения с
                    // одинаковым ts на РАЗНЫХ мониторах (~0.15% в реальной исходной БД). Корректный
                    // фикс — source_id колонка; делается в storage-rework (нельзя менять ключ сейчас:
                    // сломает идемпотентность против уже импортированных monitorId='sp' строк).
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

    // MARK: аудио

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
            skipped += rawCount - page.count   // битый ts / пустой транскрипт
            let rawMaxId: Int64? = try await source.read { [cursor] dbc in
                try Int64.fetchOne(dbc, sql: "SELECT MAX(id) FROM (SELECT id FROM audio_transcriptions WHERE id > ? ORDER BY id LIMIT 500)",
                                   arguments: [cursor])
            }
            guard let nextCursor = rawMaxId else { break }

            try await db.pool.write { dbc in
                for a in page {
                    // Идемпотентность: не дублировать при повторном прогоне. Ключ — (ts, channel,
                    // text): в источнике несколько РАЗНЫХ реплик легитимно делят один ts, поэтому
                    // только (ts,channel) их ошибочно схлопывает — нужен ещё текст транскрипта.
                    if try Int.fetchOne(dbc, sql: """
                        SELECT 1 FROM audio_captures ac JOIN transcriptions t ON t.audioId = ac.id
                        WHERE ac.ts = ? AND ac.channel = ? AND ac.relativePath = 'imported'
                              AND t.text = ? LIMIT 1
                        """,
                        arguments: [a.tsMs, a.isInput ? "mic" : "system", a.text]) != nil { continue }
                    var row = AudioCaptureRow(id: nil, ts: a.tsMs,
                                              relativePath: "imported",   // медиа не переносим
                                              durationSec: a.dur,
                                              channel: a.isInput ? "mic" : "system", bytes: nil)
                    try row.insert(dbc)
                    var tr = TranscriptionRow(id: nil, audioId: row.id!, text: a.text,
                                              language: "auto",
                                              speaker: a.isInput ? "я" : "собеседник",
                                              startOffset: 0, endOffset: a.dur,
                                              engine: "imported/(a.engine)")
                    try tr.insert(dbc)
                }
            }
            total += page.count
            cursor = nextCursor
            UserDefaults.standard.set(String(cursor), forKey: cursorKey)
            progress?(framesDone, total)   // кадры уже импортированы — не обнуляем счётчик в UI
            await Task.yield()
        }
        return (total, skipped)
    }

    // MARK: helpers

    /// Их timestamp — ISO8601 с МИКРОсекундами («2026-06-06T15:43:21.233864+00:00») либо без.
    /// Форматтеры локальные (не static): DateFormatter не Sendable; цена на страницу из 500 строк — мизер.
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

    /// Их app_name без bundleId — синтезируем стабильный уникальный ключ.
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
