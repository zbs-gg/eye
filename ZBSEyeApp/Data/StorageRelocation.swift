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
        case .sameLocation: return "Это уже текущая папка данных"
        case let .destinationOccupied(p): return "В выбранной папке уже есть данные ZBS Eye (\(p)) — выбери другую"
        case let .insufficientSpace(n, f):
            return "Недостаточно места: нужно ~\(n / 1_000_000) МБ, свободно \(f / 1_000_000) МБ"
        case let .verifyFailed(m): return "Перенос не подтверждён: \(m). Данные на старом месте целы."
        }
    }
}

/// Перенос «вечной памяти» (БД + media) в другую папку. БД — GRDB online backup (консистентный
/// снапшот живого пула под WAL; vec0/FTS5 как страницы). media — COPY (НЕ move: старое место цело до
/// подтверждения). Verify (integrity + COUNT-parity + media count) ДО переключения. Вызывающий ПОТОМ
/// делает StorageLocation.setRoot + relaunch (репоинт через рестарт — единственный способ перецепить и
/// вспомогательные процессы --mcp/--backup-now, которые читают путь независимо).
actor StorageRelocator {
    /// chosen — папка, выбранная пользователем; данные лягут в chosen/ZBS Eye. Захват ДОЛЖЕН быть на
    /// паузе (recording.pauseForMaintenance) до вызова, иначе пара граничных кадров осядет в старом root.
    func migrate(sourcePool: DatabasePool, sourceDBURL: URL, sourceMedia: URL, chosen: URL,
                 progress: @Sendable @escaping (Double, String) -> Void) async throws -> RelocationReport {
        let newRoot = chosen.appendingPathComponent("ZBS Eye", isDirectory: true)
        let currentRoot = StorageLocation.dataRoot().standardizedFileURL
        guard newRoot.standardizedFileURL.path != currentRoot.path else { throw RelocationError.sameLocation }

        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let destDB = newRoot.appendingPathComponent("zbseye.sqlite")
            let destMedia = newRoot.appendingPathComponent("media", isDirectory: true)
            // Занятый dest (напр. возврат в legacy, где осталась устаревшая копия) — НЕ клобберим и НЕ
            // блокируем: отодвигаем в сторону ZBS Eye.replaced-<ts> (без потерь, юзер удалит сам).
            if fm.fileExists(atPath: destDB.path) {
                let aside = newRoot.deletingLastPathComponent()
                    .appendingPathComponent("ZBS Eye.replaced-\(BackupManager.timestamp())", isDirectory: true)
                try fm.moveItem(at: newRoot, to: aside)
            }

            // pre-flight: место на ЦЕЛЕВОМ томе
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
                // 1. БД: online backup живого пула → dest .sqlite
                progress(0.05, "Копирую базу…")
                var dest: DatabaseQueue? = try DatabaseQueue(path: destDB.path)
                try sourcePool.backup(to: dest!)

                // 2. verify ДО переключения: integrity dest + COUNT-parity src↔dst (захват на паузе → src статичен)
                progress(0.45, "Проверяю базу…")
                let srcCounts = try sourcePool.read { try Self.counts($0) }
                let destCounts = try dest!.read { db -> [String: Int] in
                    let ic = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "?"
                    guard ic == "ok" else { throw RelocationError.verifyFailed("integrity_check=\(ic)") }
                    return try Self.counts(db)
                }
                dest = nil   // закрыть соединение dest перед дальнейшим
                guard srcCounts == destCounts else {
                    throw RelocationError.verifyFailed("счётчики не совпали (src \(srcCounts), dst \(destCounts))")
                }

                // 3. media — COPY (старое место цело)
                progress(0.55, "Копирую медиа (\(mediaFiles.count))…")
                for (i, f) in mediaFiles.enumerated() {
                    let to = destMedia.appendingPathComponent(f.lastPathComponent)
                    try? fm.removeItem(at: to)
                    try fm.copyItem(at: f, to: to)
                    if i % 300 == 0 {
                        progress(0.55 + 0.4 * Double(i) / Double(max(1, mediaFiles.count)), "Копирую медиа…")
                    }
                }
                // 4. media parity
                let destCount = ((try? fm.contentsOfDirectory(at: destMedia, includingPropertiesForKeys: nil)) ?? []).count
                guard destCount >= mediaFiles.count else {
                    throw RelocationError.verifyFailed("медиа: скопировано \(destCount) из \(mediaFiles.count)")
                }

                progress(1.0, "Готово")
                return RelocationReport(newDataRoot: newRoot, dbBytes: srcDBBytes, mediaFilesCopied: mediaFiles.count)
            } catch {
                try? fm.removeItem(at: newRoot)   // откат: источник нетронут
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
