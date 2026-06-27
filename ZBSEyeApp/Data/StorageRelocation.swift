import Foundation
import GRDB
import AppKit

struct RelocationReport: Sendable {
    let newDataRoot: URL
    let dbBytes: Int64
    let mediaFilesCopied: Int
}

enum RelocationError: LocalizedError {
    case sameLocation
    case destinationOccupied(String)
    case insufficientSpace(needed: Int64, free: Int64)
    case verifyFailed(String)
    var errorDescription: String? {
        switch self {
        case .sameLocation: return "This is already the current data folder"
        case let .destinationOccupied(p): return "The selected folder already contains ZBS Eye data (\(p)) — pick another one"
        case let .insufficientSpace(n, f):
            return "Not enough space: need ~\(n / 1_000_000) MB, \(f / 1_000_000) MB free"
        case let .verifyFailed(m): return "Move not confirmed: \(m). The data at the old location is intact."
        }
    }
}

/// Moves "forever memory" (DB + media) to another folder. DB — GRDB online backup (a consistent
/// snapshot of the live pool under WAL; vec0/FTS5 as pages). media — COPY (NOT move: the old location stays intact until
/// confirmation). Verify (integrity + COUNT-parity + media count) BEFORE switching over. The caller THEN
/// does StorageLocation.setRoot + relaunch (repointing via restart is the only way to re-attach the
/// helper processes --mcp/--backup-now too, which read the path independently).
actor StorageRelocator {
    /// chosen — the folder picked by the user; data lands in chosen/ZBS Eye. Capture MUST be
    /// paused (recording.pauseForMaintenance) before the call, otherwise a couple of boundary frames settle into the old root.
    func migrate(sourcePool: DatabasePool, sourceDBURL: URL, sourceMedia: URL, chosen: URL,
                 progress: @Sendable @escaping (Double, String) -> Void) async throws -> RelocationReport {
        let newRoot = chosen.appendingPathComponent("ZBS Eye", isDirectory: true)
        let currentRoot = StorageLocation.dataRoot().standardizedFileURL
        guard newRoot.standardizedFileURL.path != currentRoot.path else { throw RelocationError.sameLocation }

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let destDB = newRoot.appendingPathComponent("zbseye.sqlite")
            let destMedia = newRoot.appendingPathComponent("media", isDirectory: true)
            // An occupied dest (e.g. moving back to legacy, where a stale copy remained) — we do NOT clobber and do NOT
            // block: we move it aside to ZBS Eye.replaced-<ts> (no data loss, the user deletes it themselves).
            if fm.fileExists(atPath: destDB.path) {
                let aside = newRoot.deletingLastPathComponent()
                    .appendingPathComponent("ZBS Eye.replaced-\(BackupManager.timestamp())", isDirectory: true)
                try fm.moveItem(at: newRoot, to: aside)
            }

            // pre-flight: space on the TARGET volume
            let srcDBBytes = BackupManager.fileBytes(sourceDBURL)
            let mediaFiles = (try? fm.contentsOfDirectory(at: sourceMedia,
                                                          includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let mediaBytes = mediaFiles.reduce(Int64(0)) { $0 + BackupManager.fileBytes($1) }
            let needed = srcDBBytes + mediaBytes + (256 << 20)
            let freeOpt = try? chosen.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
            let free = freeOpt.map { Int64($0) } ?? Int64.max
            guard free > needed else { throw RelocationError.insufficientSpace(needed: needed, free: free) }

            try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
            try fm.createDirectory(at: destMedia, withIntermediateDirectories: true)

            do {
                // 1. DB: online backup of the live pool → dest .sqlite
                progress(0.05, "Copying the database…")
                var dest: DatabaseQueue? = try DatabaseQueue(path: destDB.path)
                try sourcePool.backup(to: dest!)

                // 2. verify BEFORE switching: integrity of dest + COUNT-parity src↔dst (capture paused → src is static)
                progress(0.45, "Verifying the database…")
                let srcCounts = try sourcePool.read { try Self.counts($0) }
                let destCounts = try dest!.read { db -> [String: Int] in
                    let ic = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "?"
                    guard ic == "ok" else { throw RelocationError.verifyFailed("integrity_check=\(ic)") }
                    return try Self.counts(db)
                }
                dest = nil   // close the dest connection before proceeding
                guard srcCounts == destCounts else {
                    throw RelocationError.verifyFailed("counts did not match (src \(srcCounts), dst \(destCounts))")
                }

                // 3. media — COPY (the old location stays intact)
                progress(0.55, "Copying media (\(mediaFiles.count))…")
                for (i, f) in mediaFiles.enumerated() {
                    let to = destMedia.appendingPathComponent(f.lastPathComponent)
                    try? fm.removeItem(at: to)
                    try fm.copyItem(at: f, to: to)
                    if i % 300 == 0 {
                        progress(0.55 + 0.4 * Double(i) / Double(max(1, mediaFiles.count)), "Copying media…")
                    }
                }
                // 4. media parity
                let destCount = ((try? fm.contentsOfDirectory(at: destMedia, includingPropertiesForKeys: nil)) ?? []).count
                guard destCount >= mediaFiles.count else {
                    throw RelocationError.verifyFailed("media: copied \(destCount) of \(mediaFiles.count)")
                }

                progress(1.0, "Done")
                return RelocationReport(newDataRoot: newRoot, dbBytes: srcDBBytes, mediaFilesCopied: mediaFiles.count)
            } catch {
                try? fm.removeItem(at: newRoot)   // rollback: source untouched
                throw error
            }
        }.value
    }

    private static func counts(_ db: Database) throws -> [String: Int] {
        var c: [String: Int] = [:]
        for t in ["screen_captures", "text_blocks", "audio_captures", "transcriptions", "apps"] {
            c[t] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)") ?? -1
        }
        return c
    }
}
