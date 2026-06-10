import Foundation
import GRDB
import Compression

/// Сжатый снапшот живой БД в iCloud Drive. Живая база ОСТАЁТСЯ локальной (быстро, без corruption —
/// см. project-storage-forever; живую SQLite в iCloud Drive нельзя). В iCloud уезжает консистентный
/// снапшот: GRDB online backup (page-level под WAL, БЕЗ блокировки writer'а; vec0/FTS5 копируются как
/// обычные страницы) → стрим-сжатие LZFSE. Бэкап = метаданные/текст/индекс поиска, НЕ гигабайты
/// HEIC-медиа (осознанное v1-решение: медиа остаётся локально).
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
        case .iCloudUnavailable: return "iCloud Drive недоступен (не залогинен или выключен)"
        case let .insufficientSpace(n, f):
            return "Недостаточно места: нужно ~\(n / 1_000_000) МБ, свободно \(f / 1_000_000) МБ"
        case let .verifyFailed(m): return "Снапшот не прошёл проверку: \(m)"
        }
    }
}

actor BackupManager {
    private let db: SlishuDatabase
    private let storage: StorageManager
    private let dbURL: URL   // фиксируем путь открытого пула в init (не SlishuDatabase.defaultURL() в момент
                             // бэкапа — он мог бы указать на новый root в окне relocate)

    init(db: SlishuDatabase, storage: StorageManager) {
        self.db = db
        self.storage = storage
        self.dbURL = (try? SlishuDatabase.defaultURL()) ?? StorageLocation.databaseURL()
    }

    // MARK: - iCloud-пути (без App Sandbox можно писать в CloudDocs как обычный путь; синк делает система)

    static func iCloudBase() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static func iCloudAvailable() -> Bool {
        FileManager.default.ubiquityIdentityToken != nil
            && FileManager.default.fileExists(atPath: iCloudBase().path)
    }

    static func backupsDirectory() -> URL {
        iCloudBase().appendingPathComponent("Slishu/Backups", isDirectory: true)
    }

    /// Снапшоты, новейшие первыми. Имя slishu-YYYYMMDD-HHmmss-SSS.sqlite.lzfse сортируется
    /// лексикографически = хронологически.
    static func listBackups() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory(), includingPropertiesForKeys: nil)) ?? []
        return items
            .filter { $0.lastPathComponent.hasPrefix("slishu-") && $0.lastPathComponent.hasSuffix(".sqlite.lzfse") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: - создание бэкапа

    func makeBackup(keepN: Int) async throws -> BackupResult {
        guard Self.iCloudAvailable() else { throw BackupError.iCloudUnavailable }
        let sourceBytes = Self.fileBytes(dbURL)
        let free = storage.freeBytes()
        let needed = sourceBytes * 2            // temp .sqlite + .lzfse одновременно
        guard free > needed else { throw BackupError.insufficientSpace(needed: needed, free: free) }

        // PASSIVE checkpoint — свести WAL в main (не нужен для консистентности backup, но уменьшает объём)
        try? await db.pool.writeWithoutTransaction { dbc in
            _ = try? dbc.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
        }

        // Тяжёлую работу выполняем прямо в актор-методе (BackupManager — выделенный актор, не блокирует
        // чужую работу). НЕ Task.detached: тогда отмена вызывающей задачи (таймаут на выходе) корректно
        // прерывает выполнение, а не оставляет осиротевший detached-таск дописывать после reply.
        let stamp = Self.timestamp()
        let dir = Self.backupsDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory
        let tmpSqlite = tmp.appendingPathComponent("slishu-bak-\(stamp).sqlite")
        let tmpLzfse = tmp.appendingPathComponent("slishu-\(stamp).sqlite.lzfse")
        defer {
            try? FileManager.default.removeItem(at: tmpSqlite)
            try? FileManager.default.removeItem(at: tmpLzfse)
        }

        // 1. online backup живого пула → temp .sqlite (page-level; vec0/FTS5/grdb_migrations включены)
        var dest: DatabaseQueue? = try DatabaseQueue(path: tmpSqlite.path)
        try db.pool.backup(to: dest!)

        // 2. verify снапшота ДО сжатия: integrity + COUNT
        let frames = try await dest!.read { d -> Int in
            let ic = try String.fetchOne(d, sql: "PRAGMA integrity_check") ?? "?"
            guard ic == "ok" else { throw BackupError.verifyFailed("integrity_check=\(ic)") }
            return try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM screen_captures") ?? 0
        }
        dest = nil   // закрыть соединение перед чтением файла на сжатие

        // 3. стрим-сжатие temp .sqlite → temp .lzfse (чанки 1MB, не держим всё в RAM)
        try Self.compress(src: tmpSqlite, to: tmpLzfse)

        // 4. в iCloud через staging + атомарный rename: если процесс убьют (бэкап на выходе) во время
        //    копии — останется лишь *.partial (не пройдёт фильтр listBackups), а не битый .lzfse.
        let finalURL = dir.appendingPathComponent("slishu-\(stamp).sqlite.lzfse")
        let staging = dir.appendingPathComponent("slishu-\(stamp).sqlite.lzfse.partial")
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: tmpLzfse, to: staging)   // кросс-томовый: copy, не move
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: staging, to: finalURL)   // атомарный rename в той же папке

        let compressed = Self.fileBytes(finalURL)
        Self.prune(keepN: keepN)
        return BackupResult(url: finalURL, compressedBytes: compressed,
                            sourceBytes: sourceBytes, frames: frames)
    }

    // MARK: - keep-N

    static func prune(keepN: Int) {
        let fm = FileManager.default
        // подчистить осиротевшие .partial (прерванный бэкап на выходе)
        let items = (try? fm.contentsOfDirectory(at: backupsDirectory(), includingPropertiesForKeys: nil)) ?? []
        for u in items where u.lastPathComponent.hasSuffix(".lzfse.partial") { try? fm.removeItem(at: u) }
        let all = listBackups()            // новейшие первыми
        guard keepN > 0, all.count > keepN else { return }
        for url in all.dropFirst(keepN) { try? fm.removeItem(at: url) }
    }

    // MARK: - сжатие / распаковка (LZFSE, стримово)

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

    /// Распаковка снапшота (для --backup-verify и будущего restore).
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

    /// Распаковать + проверить снапшот (для --backup-verify): integrity_check + COUNT кадров.
    static func verify(_ compressed: URL) throws -> (ok: Bool, frames: Int) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("slishu-verify-\(UUID().uuidString).sqlite")
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
        df.timeZone = TimeZone(identifier: "UTC")   // UTC: лексикографический порядок имён = хронология
        df.dateFormat = "yyyyMMdd-HHmmss-SSS"        // (иначе при смене часового пояса keep-N удалит не те)
        return df.string(from: Date())
    }
}
