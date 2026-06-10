import Foundation
import GRDB

/// Дефолты retention (план v2 — НЕ «forever»). Пользователь может расширить в Settings.
enum RetentionPolicy: Sendable {
    static let defaultDays = 7
    static let defaultMaxBytes: Int64 = 20 * 1024 * 1024 * 1024   // 20 GB
}

struct PruneReport: Sendable {
    var framesDeleted = 0
    var audioDeleted = 0
    var orphansDeleted = 0
}

/// Прунинг по дням И размеру (default 7д/20GB). Каскад чистит text_blocks → триггеры чистят FTS.
/// Размер считается из БД (`SUM(bytes)`), а не обходом FS (фикс HIGH из ревью). Orphan-sweep уважает
/// grace-window, чтобы не удалить кадр, который IngestService записал, но ещё не закоммитил (фикс race).
actor RetentionManager {
    private let db: SlishuDatabase
    private let storage: StorageManager

    /// Файлы моложе этого окна считаются возможно in-flight и не трогаются orphan-sweep'ом.
    private let orphanGraceSeconds: TimeInterval = 60

    init(db: SlishuDatabase, storage: StorageManager) {
        self.db = db
        self.storage = storage
    }

    func prune(retentionDays: Int?, maxBytes: Int64?) async throws -> PruneReport {
        var report = PruneReport()
        if let days = retentionDays {
            let cutoff = Int64(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 * 1000)
            report.framesDeleted += try await deleteFramesOlderThan(cutoff)
            report.audioDeleted += try await deleteAudioOlderThan(cutoff)
        }
        if let maxBytes {
            let (f, a) = try await enforceSizeLimit(maxBytes)
            report.framesDeleted += f
            report.audioDeleted += a
        }
        report.orphansDeleted = try await sweepOrphans()
        try await checkpoint()
        return report
    }

    // ── размер из БД, не из FS ──
    private func dbBytes() async throws -> Int64 {
        try await db.pool.read { db in
            let f = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM screen_captures") ?? 0
            let a = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM audio_captures") ?? 0
            return f + a
        }
    }

    // ── удаление по времени (выход по числу удалённых строк, не по paths — фикс dedup-nil-paths) ──
    private func deleteFramesOlderThan(_ cutoffMs: Int64) async throws -> Int {
        var deleted = 0
        while true {
            let (count, paths): (Int, [String]) = try await db.pool.write { db in
                let rows = try ScreenCaptureRow
                    .filter(Column("ts") < cutoffMs).order(Column("ts")).limit(500).fetchAll(db)
                if rows.isEmpty { return (0, []) }
                let ids = rows.compactMap(\.id)
                try ScreenCaptureRow.filter(ids.contains(Column("id"))).deleteAll(db)  // каскад → FTS
                try Self.deleteVectors(db, captureIds: ids)                              // vec0 (нет FK-каскада)
                return (rows.count, rows.compactMap(\.relativePath))
            }
            if count == 0 { break }
            for p in paths { storage.deleteFile(relativePath: p) }
            deleted += count
        }
        return deleted
    }

    /// vec0 не поддерживает FK-каскад — чистим явно по capture_id.
    private static func deleteVectors(_ db: Database, captureIds: [Int64]) throws {
        guard !captureIds.isEmpty else { return }
        let list = captureIds.map(String.init).joined(separator: ",")
        try db.execute(sql: "DELETE FROM vec_screen WHERE capture_id IN (\(list))")
    }

    private func deleteAudioOlderThan(_ cutoffMs: Int64) async throws -> Int {
        var deleted = 0
        while true {
            let (count, paths): (Int, [String]) = try await db.pool.write { db in
                let rows = try AudioCaptureRow
                    .filter(Column("ts") < cutoffMs).order(Column("ts")).limit(500).fetchAll(db)
                if rows.isEmpty { return (0, []) }
                let ids = rows.compactMap(\.id)
                try AudioCaptureRow.filter(ids.contains(Column("id"))).deleteAll(db)
                return (rows.count, rows.map(\.relativePath))
            }
            if count == 0 { break }
            for p in paths { storage.deleteFile(relativePath: p) }
            deleted += count
        }
        return deleted
    }

    // ── размер: удаляем старейшие кадры, затем аудио, пока SUM(bytes) > лимита ──
    private func enforceSizeLimit(_ maxBytes: Int64) async throws -> (frames: Int, audio: Int) {
        var frames = 0, audio = 0
        while try await dbBytes() > maxBytes {
            if try await deleteOldestFrameBatch(into: &frames) { continue }
            if try await deleteOldestAudioBatch(into: &audio) { continue }
            break   // нечего удалять — не зацикливаемся
        }
        return (frames, audio)
    }

    /// Экстренное освобождение МЕСТА НА ДИСКЕ (low-disk пауза записи): удаляет старейшее, пока свободно
    /// меньше target. Отличие от prune(): диск мог забить кто-то другой — политика 7д/20GB при этом
    /// ничего бы не удалила, и пауза записи никогда бы не самоизлечилась. Если данных Slishu больше нет,
    /// а места всё ещё мало — диск занят не нами (вернёт сколько удалено; вызывающий покажет статус).
    func pruneUntilFree(targetFreeBytes: Int64) async throws -> PruneReport {
        var report = PruneReport()
        while storage.freeBytes() < targetFreeBytes {
            if try await deleteOldestFrameBatch(into: &report.framesDeleted) { continue }
            if try await deleteOldestAudioBatch(into: &report.audioDeleted) { continue }
            break   // данных Slishu не осталось — дальше не наша зона
        }
        try await checkpoint()   // вернуть место ОС: FTS optimize + WAL truncate
        return report
    }

    /// Старейший батч кадров (500): true = что-то удалили.
    private func deleteOldestFrameBatch(into counter: inout Int) async throws -> Bool {
        let (fc, fp): (Int, [String]) = try await db.pool.write { db in
            let rows = try ScreenCaptureRow.order(Column("ts")).limit(500).fetchAll(db)
            if rows.isEmpty { return (0, []) }
            let ids = rows.compactMap(\.id)
            try ScreenCaptureRow.filter(ids.contains(Column("id"))).deleteAll(db)
            try Self.deleteVectors(db, captureIds: ids)
            return (rows.count, rows.compactMap(\.relativePath))
        }
        guard fc > 0 else { return false }
        for p in fp { storage.deleteFile(relativePath: p) }
        counter += fc
        return true
    }

    /// Старейший батч аудио (500): true = что-то удалили.
    private func deleteOldestAudioBatch(into counter: inout Int) async throws -> Bool {
        let (ac, ap): (Int, [String]) = try await db.pool.write { db in
            let rows = try AudioCaptureRow.order(Column("ts")).limit(500).fetchAll(db)
            if rows.isEmpty { return (0, []) }
            let ids = rows.compactMap(\.id)
            try AudioCaptureRow.filter(ids.contains(Column("id"))).deleteAll(db)
            return (rows.count, rows.map(\.relativePath))
        }
        guard ac > 0 else { return false }
        for p in ap { storage.deleteFile(relativePath: p) }
        counter += ac
        return true
    }

    // ── orphan-sweep с grace-window (фикс race с in-flight ingest) ──
    private func sweepOrphans() async throws -> Int {
        let known: Set<String> = try await db.pool.read { db in
            let s = try String.fetchAll(db, sql: "SELECT relativePath FROM screen_captures WHERE relativePath IS NOT NULL")
            let a = try String.fetchAll(db, sql: "SELECT relativePath FROM audio_captures")
            return Set(s).union(a)
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: storage.mediaDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let graceCutoff = Date().addingTimeInterval(-orphanGraceSeconds)
        var deleted = 0
        for url in files {
            let name = url.lastPathComponent
            guard name.hasSuffix(".heic") || name.hasSuffix(".m4a") else { continue }
            if known.contains(name) { continue }
            // слишком свежий файл может быть кадром in-flight ingest (записан, ещё не закоммичен) — не трогаем
            let mdate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mdate > graceCutoff { continue }
            try? FileManager.default.removeItem(at: url)
            deleted += 1
        }
        return deleted
    }

    private func checkpoint() async throws {
        try await db.pool.write { db in
            try db.execute(sql: "INSERT INTO text_fts(text_fts) VALUES('optimize')")
            try db.execute(sql: "INSERT INTO transcription_fts(transcription_fts) VALUES('optimize')")
            _ = try? db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}
