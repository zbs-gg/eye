import Foundation
import GRDB

/// Retention defaults. ZBS Eye = "forever memory": by default we delete NOTHING (0 = forever). The user
/// can enable a limit by days/size in Settings. The old default of 7d/20GB SILENTLY trimmed history —
/// for "forever memory" that contradicts the essence of the product (and it ate the import of prior history live).
enum RetentionPolicy: Sendable {
    static let defaultDays = 0                  // 0 = forever
    static let defaultMaxBytes: Int64 = 0       // 0 = no limit
}

struct PruneReport: Sendable {
    var framesDeleted = 0
    var audioDeleted = 0
    var orphansDeleted = 0
}

/// Pruning by days AND size (default 7d/20GB). The cascade cleans text_blocks → triggers clean FTS.
/// Size is computed from the DB (`SUM(bytes)`), not by walking the FS (HIGH fix from review). The orphan sweep
/// respects the grace window so it doesn't delete a frame that IngestService wrote but hasn't committed yet (race fix).
actor RetentionManager {
    private let db: ZBSEyeDatabase
    private let storage: StorageManager

    /// Files younger than this window are treated as possibly in-flight and aren't touched by the orphan sweep.
    private let orphanGraceSeconds: TimeInterval = 60

    init(db: ZBSEyeDatabase, storage: StorageManager) {
        self.db = db
        self.storage = storage
    }

    func prune(retentionDays: Int?, maxBytes: Int64?) async throws -> PruneReport {
        var report = PruneReport()
        // FOOTGUN GUARD: days/maxBytes ≤ 0 = "forever" (NOT "delete everything older than 0 days" / "shrink to 0 bytes").
        // Without this, the default-forever accidentally arriving as 0 would wipe the entire history.
        if let days = retentionDays, days > 0 {
            let cutoff = Int64(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970 * 1000)
            report.framesDeleted += try await deleteFramesOlderThan(cutoff)
            report.audioDeleted += try await deleteAudioOlderThan(cutoff)
        }
        if let maxBytes, maxBytes > 0 {
            let (f, a) = try await enforceSizeLimit(maxBytes)
            report.framesDeleted += f
            report.audioDeleted += a
        }
        report.orphansDeleted = try await sweepOrphans()
        try? await sweepVectorOrphans()   // vec0 has no FK: insurance against orphans (races, old bugs)
        try await checkpoint()
        return report
    }

    /// vec-table orphans (the base row was deleted, the vector remained). Cheap with a PK subquery; once per prune.
    private func sweepVectorOrphans() async throws {
        try await db.pool.write { db in
            try db.execute(sql: "DELETE FROM vec_screen WHERE capture_id NOT IN (SELECT id FROM screen_captures)")
            try db.execute(sql: "DELETE FROM vec_transcripts WHERE transcription_id NOT IN (SELECT id FROM transcriptions)")
        }
    }

    // ── MEDIA size from the DB (SUM bytes). The index file is DELIBERATELY left out of the enforce loop:
    //    a sqlite file doesn't shrink on DELETE (only VACUUM) — include it in the threshold and, when the index
    //    exceeds the limit, the loop would silently wipe the whole history. The UI honestly labels it "media limit". ──
    private func dbBytes() async throws -> Int64 {
        try await db.pool.read { db in
            let f = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM screen_captures") ?? 0
            let a = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM audio_captures") ?? 0
            return f + a
        }
    }

    // ── deletion by time (exit on number of rows deleted, not on paths — dedup-nil-paths fix) ──
    private func deleteFramesOlderThan(_ cutoffMs: Int64) async throws -> Int {
        var deleted = 0
        while true {
            let (count, paths): (Int, [String]) = try await db.pool.write { db in
                let rows = try ScreenCaptureRow
                    .filter(Column("ts") < cutoffMs).order(Column("ts")).limit(500).fetchAll(db)
                if rows.isEmpty { return (0, []) }
                let ids = rows.compactMap(\.id)
                try ScreenCaptureRow.filter(ids.contains(Column("id"))).deleteAll(db)  // cascade → FTS
                try Self.deleteVectors(db, captureIds: ids)                              // vec0 (no FK cascade)
                return (rows.count, rows.compactMap(\.relativePath))
            }
            if count == 0 { break }
            for p in paths { storage.deleteFile(relativePath: p) }
            deleted += count
        }
        return deleted
    }

    /// vec0 doesn't support FK cascade — clean explicitly by capture_id.
    private static func deleteVectors(_ db: Database, captureIds: [Int64]) throws {
        guard !captureIds.isEmpty else { return }
        let list = captureIds.map(String.init).joined(separator: ",")
        try db.execute(sql: "DELETE FROM vec_screen WHERE capture_id IN (\(list))")
    }

    /// Analog for audio: map audioId → transcription_id BEFORE the cascade delete of transcriptions
    /// (otherwise vec_transcripts accumulates orphans — vec0 has no FK).
    private static func deleteTranscriptVectors(_ db: Database, audioIds: [Int64]) throws {
        guard !audioIds.isEmpty else { return }
        let list = audioIds.map(String.init).joined(separator: ",")
        let tids = try Int64.fetchAll(db, sql: "SELECT id FROM transcriptions WHERE audioId IN (\(list))")
        guard !tids.isEmpty else { return }
        let tlist = tids.map(String.init).joined(separator: ",")
        try db.execute(sql: "DELETE FROM vec_transcripts WHERE transcription_id IN (\(tlist))")
    }

    private func deleteAudioOlderThan(_ cutoffMs: Int64) async throws -> Int {
        var deleted = 0
        while true {
            let (count, paths): (Int, [String]) = try await db.pool.write { db in
                let rows = try AudioCaptureRow
                    .filter(Column("ts") < cutoffMs).order(Column("ts")).limit(500).fetchAll(db)
                if rows.isEmpty { return (0, []) }
                let ids = rows.compactMap(\.id)
                try Self.deleteTranscriptVectors(db, audioIds: ids)   // before the cascade (mapping needed)
                try AudioCaptureRow.filter(ids.contains(Column("id"))).deleteAll(db)
                return (rows.count, rows.map(\.relativePath))
            }
            if count == 0 { break }
            for p in paths { storage.deleteFile(relativePath: p) }
            deleted += count
        }
        return deleted
    }

    // ── size: delete the oldest frames, then audio, while SUM(bytes) > the limit ──
    private func enforceSizeLimit(_ maxBytes: Int64) async throws -> (frames: Int, audio: Int) {
        var frames = 0, audio = 0
        while try await dbBytes() > maxBytes {
            if try await deleteOldestFrameBatch(into: &frames) { continue }
            if try await deleteOldestAudioBatch(into: &audio) { continue }
            break   // nothing to delete — don't loop forever
        }
        return (frames, audio)
    }

    /// Emergency freeing of DISK SPACE (low-disk recording pause): deletes the oldest until free space is
    /// below target. Difference from prune(): someone else may have filled the disk — a 7d/20GB policy
    /// would then delete nothing, and the recording pause would never self-heal. If there's no ZBS Eye data
    /// left and space is still low — the disk is occupied by others (returns how much was deleted; the caller shows status).
    func pruneUntilFree(targetFreeBytes: Int64) async throws -> PruneReport {
        var report = PruneReport()
        while storage.freeBytes() < targetFreeBytes {
            if try await deleteOldestFrameBatch(into: &report.framesDeleted) { continue }
            if try await deleteOldestAudioBatch(into: &report.audioDeleted) { continue }
            break   // no ZBS Eye data left — beyond here isn't our zone
        }
        try await checkpoint()   // return space to the OS: FTS optimize + WAL truncate
        return report
    }

    /// Deleting a PERIOD (privacy: "accidentally recorded a password/conversation — erase forever").
    /// The cascade cleans text_blocks/transcriptions → FTS triggers; vec tables — explicitly (vec0 has no FK).
    /// toMs = Int64.max + fromMs = 0 → "delete everything".
    func deleteRange(fromMs: Int64, toMs: Int64) async throws -> PruneReport {
        var report = PruneReport()
        while true {
            let (c, paths): (Int, [String]) = try await db.pool.write { db in
                let rows = try ScreenCaptureRow
                    .filter(Column("ts") >= fromMs && Column("ts") <= toMs)
                    .order(Column("ts")).limit(500).fetchAll(db)
                if rows.isEmpty { return (0, []) }
                let ids = rows.compactMap(\.id)
                try ScreenCaptureRow.filter(ids.contains(Column("id"))).deleteAll(db)
                try Self.deleteVectors(db, captureIds: ids)
                return (rows.count, rows.compactMap(\.relativePath))
            }
            if c == 0 { break }
            for p in paths { storage.deleteFile(relativePath: p) }
            report.framesDeleted += c
        }
        while true {
            let (c, paths): (Int, [String]) = try await db.pool.write { db in
                let rows = try AudioCaptureRow
                    .filter(Column("ts") >= fromMs && Column("ts") <= toMs)
                    .order(Column("ts")).limit(500).fetchAll(db)
                if rows.isEmpty { return (0, []) }
                let ids = rows.compactMap(\.id)
                try Self.deleteTranscriptVectors(db, audioIds: ids)
                try AudioCaptureRow.filter(ids.contains(Column("id"))).deleteAll(db)
                return (rows.count, rows.map(\.relativePath))
            }
            if c == 0 { break }
            for p in paths { storage.deleteFile(relativePath: p) }
            report.audioDeleted += c
        }
        try? await checkpoint()   // best-effort: a checkpoint error must not mask a successful deletion
        // Full deletion → VACUUM: otherwise sqlite reuses pages, the file doesn't shrink, and the user
        // sees "I deleted everything but it's still almost as full" — undermining trust in the privacy feature.
        if fromMs == 0 && toMs == Int64.max {
            try? await db.pool.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM")
            }
        }
        return report
    }

    /// Oldest batch of frames (500): true = something was deleted.
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

    /// Oldest batch of audio (500): true = something was deleted.
    private func deleteOldestAudioBatch(into counter: inout Int) async throws -> Bool {
        let (ac, ap): (Int, [String]) = try await db.pool.write { db in
            let rows = try AudioCaptureRow.order(Column("ts")).limit(500).fetchAll(db)
            if rows.isEmpty { return (0, []) }
            let ids = rows.compactMap(\.id)
            try Self.deleteTranscriptVectors(db, audioIds: ids)   // before the cascade (mapping needed)
            try AudioCaptureRow.filter(ids.contains(Column("id"))).deleteAll(db)
            return (rows.count, rows.map(\.relativePath))
        }
        guard ac > 0 else { return false }
        for p in ap { storage.deleteFile(relativePath: p) }
        counter += ac
        return true
    }

    // ── orphan sweep with a grace window (fix for the race with in-flight ingest) ──
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
            // a too-fresh file may be a frame from in-flight ingest (written, not yet committed) — don't touch it
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
        }
        // WAL truncate MUST run OUTSIDE a transaction (inside write{} it's a silent no-op). busy under
        // concurrent writes — no problem: the next prune will retry.
        try? await db.pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
}
