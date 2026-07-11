import Foundation
import GRDB
import AppKit

struct RelocationReport: Sendable {
    let newDataRoot: URL
    let dbBytes: Int64
    let mediaFilesCopied: Int
    let modelFilesCopied: Int
    let modelBytesCopied: Int64
}

/// Moves "forever memory" (DB + media + managed generative assets) to another folder. DB — GRDB online backup (a consistent
/// snapshot of the live pool under WAL; vec0/FTS5 as pages). media — COPY (NOT move: the old location stays intact until
/// confirmation). Verify (integrity + COUNT-parity + media count) BEFORE switching over. The caller THEN
/// does StorageLocation.setRoot + relaunch (repointing via restart is the only way to re-attach the
/// helper processes --mcp/--backup-now too, which read the path independently).
actor StorageRelocator {
    /// chosen — the folder picked by the user; data lands in chosen/ZBS Eye. Capture MUST be
    /// paused (recording.pauseForMaintenance) before the call, otherwise a couple of boundary frames settle into the old root.
    func migrate(sourcePool: DatabasePool, sourceDBURL: URL, sourceMedia: URL, chosen: URL,
                 progress: @Sendable @escaping (Double, String) -> Void) async throws -> RelocationReport {
        let currentRoot = StorageLocation.dataRoot().resolvingSymlinksInPath().standardizedFileURL
        let newRoot = try StorageRelocationPolicy.destinationRoot(
            currentRoot: currentRoot,
            chosenParent: chosen
        )

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let destDB = newRoot.appendingPathComponent("zbseye.sqlite")
            let destMedia = newRoot.appendingPathComponent("media", isDirectory: true)
            let sourceModels = StorageLocation.builtInModelRoot(under: currentRoot)
            let destModels = StorageLocation.builtInModelRoot(under: newRoot)
            // pre-flight: space on the TARGET volume
            let srcDBBytes = BackupManager.fileBytes(sourceDBURL)
            guard let mediaInventory = try RelocatableAssetTree
                .inventoryIfPresent(at: sourceMedia) else {
                throw RelocationError.verifyFailed("the source media directory is missing")
            }
            let mediaBytes = mediaInventory.totalBytes
            let modelInventory = try RelocatableAssetTree.inventoryIfPresent(at: sourceModels)
            let modelBytes = modelInventory?.totalBytes ?? 0
            let needed = try StorageRelocationPolicy.requiredFreeBytes(
                databaseBytes: srcDBBytes,
                mediaBytes: mediaBytes,
                modelBytes: modelBytes
            )
            let destinationParent = newRoot.deletingLastPathComponent()
            let capacity = try? destinationParent.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            let available = capacity?.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
                ?? capacity?.volumeAvailableCapacity.map { Int64($0) }
            try StorageRelocationPolicy.requireCapacity(
                requiredBytes: needed,
                availableBytes: available
            )

            // Every destination mutation lives in one rollback boundary. An
            // occupied root is kept aside on success and restored verbatim if
            // any create/copy/verification step fails.
            let replacementRoot = newRoot.deletingLastPathComponent()
                .appendingPathComponent(
                    "ZBS Eye.replaced-\(BackupManager.timestamp())-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
            return try StorageRelocationDestinationTransaction.run(
                destinationRoot: newRoot,
                replacementRoot: replacementRoot,
                fileManager: fm
            ) {
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
                progress(0.55, "Copying media (\(mediaInventory.files.count))…")
                let copiedMedia = try RelocatableAssetTree.copyIfPresent(
                    from: sourceMedia,
                    to: destMedia
                )
                // 4. media parity. Compare against the pre-flight inventory as
                // well as copy-time parity so a source mutation cannot be
                // silently accepted between sizing and the DB snapshot.
                guard copiedMedia == mediaInventory else {
                    throw RelocationError.verifyFailed(
                        "media inventory changed during relocation"
                    )
                }

                // 5. managed model assets — the download/runtime managers are
                // drained by the caller, so staging + journal + installed LKG
                // form one immutable tree for this copy. Exact relative-path,
                // byte-count, and SHA-256 parity is checked before the flip.
                progress(0.88, "Copying local AI model…")
                let copiedModels = try RelocatableAssetTree.copyIfPresent(
                    from: sourceModels,
                    to: destModels
                )

                progress(1.0, "Done")
                return RelocationReport(
                    newDataRoot: newRoot,
                    dbBytes: srcDBBytes,
                    mediaFilesCopied: mediaInventory.files.count,
                    modelFilesCopied: copiedModels?.files.count ?? 0,
                    modelBytesCopied: copiedModels?.totalBytes ?? 0
                )
            }
        }.value
    }

    private static func counts(_ db: Database) throws -> [String: Int] {
        var c: [String: Int] = [:]
        for t in [
            "screen_captures", "text_blocks", "audio_captures", "transcriptions",
            "apps", "browser_visits", "embed_queue",
        ] {
            c[t] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)") ?? -1
        }
        return c
    }
}
