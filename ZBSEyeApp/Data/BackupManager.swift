import Foundation
import GRDB
import Compression

/// A compressed snapshot of the live DB into iCloud Drive. The live database STAYS local (fast, no corruption —
/// see project-storage-forever; you can't keep live SQLite in iCloud Drive). What goes to iCloud is a consistent
/// snapshot: GRDB online backup (page-level under WAL, WITHOUT locking the writer; vec0/FTS5 are copied as
/// ordinary pages) → LZFSE stream compression. The backup = metadata/text/search index, NOT gigabytes
/// of HEIC media (a deliberate v1 decision: media stays local).
struct BackupResult: Sendable {
    let url: URL
    let compressedBytes: Int64
    let sourceBytes: Int64
    let frames: Int
}

enum BackupError: LocalizedError {
    case iCloudUnavailable
    case insufficientSpace(needed: Int64, free: Int64)
    case verifyFailed(String)
    var errorDescription: String? {
        switch self {
        case .iCloudUnavailable: return "iCloud Drive is unavailable (not signed in or turned off)"
        case let .insufficientSpace(n, f):
            return "Not enough space: need ~\(n / 1_000_000) MB, \(f / 1_000_000) MB free"
        case let .verifyFailed(m): return "Snapshot failed verification: \(m)"
        }
    }
}

actor BackupManager {
    private let db: ZBSEyeDatabase
    private let storage: StorageManager
    private let dbURL: URL   // pin the open pool's path in init (not ZBSEyeDatabase.defaultURL() at backup
                             // time — it could point to a new root during a relocate window)

    init(db: ZBSEyeDatabase, storage: StorageManager) {
        self.db = db
        self.storage = storage
        self.dbURL = (try? ZBSEyeDatabase.defaultURL()) ?? StorageLocation.databaseURL()
    }

    // MARK: - iCloud paths (without App Sandbox we can write to CloudDocs as a normal path; the system handles sync)

    static func iCloudBase() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static func iCloudAvailable() -> Bool {
        FileManager.default.ubiquityIdentityToken != nil
            && FileManager.default.fileExists(atPath: iCloudBase().path)
    }

    static func backupsDirectory() -> URL {
        iCloudBase().appendingPathComponent("ZBS Eye/Backups", isDirectory: true)
    }

    /// Snapshots, newest first. The name zbseye-YYYYMMDD-HHmmss-SSS.sqlite.lzfse sorts
    /// lexicographically = chronologically.
    static func listBackups() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory(), includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.lastPathComponent.hasPrefix("zbseye-") && $0.lastPathComponent.hasSuffix(".sqlite.lzfse") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - creating a backup

    func makeBackup(keepN: Int) async throws -> BackupResult {
        guard Self.iCloudAvailable() else { throw BackupError.iCloudUnavailable }
        let sourceBytes = Self.fileBytes(dbURL)
        let free = storage.freeBytes()
        let needed = sourceBytes * 2            // temp .sqlite + .lzfse at the same time
        guard free > needed else { throw BackupError.insufficientSpace(needed: needed, free: free) }

        // PASSIVE checkpoint — fold WAL into main (not needed for backup consistency, but reduces size)
        try? await db.pool.writeWithoutTransaction { dbc in
            _ = try? dbc.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
        }

        // We do the heavy work right in the actor method (BackupManager is a dedicated actor, doesn't block
        // others' work). NOT Task.detached: that way cancelling the calling task (timeout on exit) properly
        // interrupts execution rather than leaving an orphaned detached task writing after the reply.
        let stamp = Self.timestamp()
        let dir = Self.backupsDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory
        let tmpSqlite = tmp.appendingPathComponent("zbseye-bak-\(stamp).sqlite")
        let tmpLzfse = tmp.appendingPathComponent("zbseye-\(stamp).sqlite.lzfse")
        defer {
            try? FileManager.default.removeItem(at: tmpSqlite)
            try? FileManager.default.removeItem(at: tmpLzfse)
        }

        // 1. online backup of the live pool → temp .sqlite (page-level; vec0/FTS5/grdb_migrations included)
        var dest: DatabaseQueue? = try DatabaseQueue(path: tmpSqlite.path)
        try db.pool.backup(to: dest!)

        // 2. verify the snapshot BEFORE compression: integrity + COUNT
        let frames = try await dest!.read { d -> Int in
            let ic = try String.fetchOne(d, sql: "PRAGMA integrity_check") ?? "?"
            guard ic == "ok" else { throw BackupError.verifyFailed("integrity_check=\(ic)") }
            return try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM screen_captures") ?? 0
        }
        dest = nil   // close the connection before reading the file for compression

        // 3. stream-compress temp .sqlite → temp .lzfse (1MB chunks, don't hold it all in RAM)
        try Self.compress(src: tmpSqlite, to: tmpLzfse)

        // 4. into iCloud via staging + atomic rename: if the process is killed (backup on exit) during
        //    the copy — only *.partial remains (won't pass the listBackups filter), not a corrupt .lzfse.
        let finalURL = dir.appendingPathComponent("zbseye-\(stamp).sqlite.lzfse")
        let staging = dir.appendingPathComponent("zbseye-\(stamp).sqlite.lzfse.partial")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: tmpLzfse, to: staging)   // cross-volume: copy, not move
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: staging, to: finalURL)   // atomic rename within the same folder

        let compressed = Self.fileBytes(finalURL)
        Self.prune(keepN: keepN)
        return BackupResult(url: finalURL, compressedBytes: compressed,
                            sourceBytes: sourceBytes, frames: frames)
    }

    // MARK: - keep-N

    static func prune(keepN: Int) {
        let fm = FileManager.default
        // clean up orphaned .partial files (a backup interrupted on exit)
        let items = (try? fm.contentsOfDirectory(at: backupsDirectory(), includingPropertiesForKeys: nil)) ?? []
        for u in items where u.lastPathComponent.hasSuffix(".lzfse.partial") { try? fm.removeItem(at: u) }
        let all = listBackups()            // newest first
        guard keepN > 0, all.count > keepN else { return }
        for url in all.dropFirst(keepN) { try? fm.removeItem(at: url) }
    }

    // MARK: - compression / decompression (LZFSE, streaming)

    static func compress(src: URL, to dst: URL) throws {
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        let filter = try OutputFilter(.compress, using: .lzfse) { (data: Data?) in
            if let data { try out.write(contentsOf: data) }
        }
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try filter.write(chunk)
        }
        try filter.finalize()
    }

    /// Decompress a snapshot (for --backup-verify and a future restore).
    static func decompress(_ src: URL, to dst: URL) throws {
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let filter = try InputFilter(.decompress, using: .lzfse) { (length: Int) -> Data? in
            try input.read(upToCount: length)
        }
        while let page = try filter.readData(ofLength: 1 << 20) {
            try out.write(contentsOf: page)
        }
    }

    /// Decompress + verify a snapshot (for --backup-verify): integrity_check + frame COUNT.
    static func verify(_ compressed: URL) throws -> (ok: Bool, frames: Int) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-verify-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try decompress(compressed, to: tmp)
        let q = try DatabaseQueue(path: tmp.path)
        return try q.read { d in
            let ic = (try String.fetchOne(d, sql: "PRAGMA integrity_check")) ?? "?"
            let frames = (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM screen_captures")) ?? 0
            return (ic == "ok", frames)
        }
    }

    // MARK: - helpers

    static func fileBytes(_ url: URL) -> Int64 {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return 0 }
        return Int64(size)
    }

    static func timestamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")   // UTC: lexicographic order of names = chronology
        df.dateFormat = "yyyyMMdd-HHmmss-SSS"        // (otherwise, on a timezone change, keep-N would delete the wrong ones)
        return df.string(from: Date())
    }
}
