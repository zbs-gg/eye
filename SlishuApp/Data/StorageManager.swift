import Foundation

/// Расположение медиа (HEIC/m4a). Пути в БД — относительные (`relativePath`), резолвятся против
/// текущего mediaDirectory. Релокация через security-scoped bookmark — Фаза 2 (шаг 11); пока default.
final class StorageManager: Sendable {
    let mediaDirectory: URL

    init() throws {
        self.mediaDirectory = StorageLocation.mediaDirectory()   // учитывает relocate
    }

    func url(forRelative relativePath: String) -> URL {
        mediaDirectory.appendingPathComponent(relativePath)
    }

    /// Пишет данные кадра, возвращает относительный путь.
    func writeFrame(_ data: Data, timestamp: Date, displayIndex: Int) throws -> String {
        let name = "screen_\(Int64(timestamp.timeIntervalSince1970 * 1000))_\(displayIndex).heic"
        try data.write(to: url(forRelative: name), options: .atomic)
        return name
    }

    func deleteFile(relativePath: String) {
        try? FileManager.default.removeItem(at: url(forRelative: relativePath))
    }

    func fileSize(relativePath: String) -> Int? {
        try? url(forRelative: relativePath).resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    /// Свободно на томе с медиа (для disk-guard: не добивать диск записью 24/7).
    func freeBytes() -> Int64 {
        let vals = try? mediaDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(vals?.volumeAvailableCapacityForImportantUsage ?? .max)
    }

    func totalBytes() -> Int64 {
        guard let en = FileManager.default.enumerator(at: mediaDirectory,
                  includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
