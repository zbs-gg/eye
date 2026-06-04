import Foundation
import GRDB

struct PruneReport: Sendable {
    var framesDeleted = 0
    var audioDeleted = 0
    var orphansDeleted = 0
}

/// Прунинг по дням И размеру (default 7д/20GB — НЕ «forever», по Pro). Каскад чистит text_blocks →
/// триггеры чистят FTS. Файлы удаляются по relativePath. Батчами, чтобы не держать длинный writer-лок.
actor RetentionManager {
    private let db: SlishuDatabase
    private let storage: StorageManager

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
        if let maxBytes, storage.totalBytes() > maxBytes {
            report.framesDeleted += try await enforceSizeLimit(maxBytes)
        }
        report.orphansDeleted = try await sweepOrphans()
        try await checkpoint()
        return report
    }

    private func deleteFramesOlderThan(_ cutoffMs: Int64) async throws -> Int {
        var deleted = 0
        while true {
            // батч из 500 старейших файлов кадров до cutoff
            let paths: [String] = try await db.pool.write { db in
                let rows = try ScreenCaptureRow
                    .filter(Column("ts") < cutoffMs)
                    .order(Column("ts"))
                    .limit(500)
                    .fetchAll(db)
                if rows.isEmpty { return [] }
                let ids = rows.compactMap(\.id)
                try ScreenCaptureRow.filter(ids.contains(Column("id"))).deleteAll(db)  // каскад → text_blocks → FTS
                return rows.compactMap(\.relativePath)
            }
            if paths.isEmpty { break }
            for p in paths { storage.deleteFile(relativePath: p) }
            deleted += paths.count
        }
        return deleted
    }

    private func deleteAudioOlderThan(_ cutoffMs: Int64) async throws -> Int {
        var deleted = 0
        while true {
            let paths: [String] = try await db.pool.write { db in
                let rows = try AudioCaptureRow
                    .filter(Column("ts") < cutoffMs).order(Column("ts")).limit(500).fetchAll(db)
                if rows.isEmpty { return [] }
                let ids = rows.compactMap(\.id)
                try AudioCaptureRow.filter(ids.contains(Column("id"))).deleteAll(db)
                return rows.map(\.relativePath)
            }
            if paths.isEmpty { break }
            for p in paths { storage.deleteFile(relativePath: p) }
            deleted += paths.count
        }
        return deleted
    }

    /// FIFO по ts, пока размер media-папки не уложится в лимит.
    private func enforceSizeLimit(_ maxBytes: Int64) async throws -> Int {
        var deleted = 0
        while storage.totalBytes() > maxBytes {
            let paths: [String] = try await db.pool.write { db in
                let rows = try ScreenCaptureRow.order(Column("ts")).limit(500).fetchAll(db)
                if rows.isEmpty { return [] }
                let ids = rows.compactMap(\.id)
                try ScreenCaptureRow.filter(ids.contains(Column("id"))).deleteAll(db)
                return rows.compactMap(\.relativePath)
            }
            if paths.isEmpty { break }
            for p in paths { storage.deleteFile(relativePath: p) }
            deleted += paths.count
        }
        return deleted
    }

    /// Файлы в media без записи в БД (защита от рассинхрона при крашах).
    private func sweepOrphans() async throws -> Int {
        let known: Set<String> = try await db.pool.read { db in
            let s = try String.fetchAll(db, sql: "SELECT relativePath FROM screen_captures WHERE relativePath IS NOT NULL")
            let a = try String.fetchAll(db, sql: "SELECT relativePath FROM audio_captures")
            return Set(s).union(a)
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: storage.mediaDirectory, includingPropertiesForKeys: nil)) ?? []
        var deleted = 0
        for url in files {
            let name = url.lastPathComponent
            if !known.contains(name) && (name.hasSuffix(".heic") || name.hasSuffix(".m4a")) {
                try? FileManager.default.removeItem(at: url); deleted += 1
            }
        }
        return deleted
    }

    private func checkpoint() async throws {
        try await db.pool.write { db in
            try db.execute(sql: "INSERT INTO text_fts(text_fts) VALUES('optimize')")
            _ = try? db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}
