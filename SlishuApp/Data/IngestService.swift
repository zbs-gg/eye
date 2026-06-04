import Foundation
import GRDB

/// ЕДИНСТВЕННЫЙ writer (actor). Capture/Transcription отдают сюда Sendable-записи; здесь — файл +
/// одна транзакция (upsert app, insert screen_capture, insert text_blocks → триггеры наполняют FTS).
/// Убирает Task.detached-гонки старой версии.
actor IngestService {
    private let db: SlishuDatabase
    private let storage: StorageManager

    init(db: SlishuDatabase, storage: StorageManager) {
        self.db = db
        self.storage = storage
    }

    @discardableResult
    func ingest(_ rec: ScreenCaptureRecord) async throws -> Int64 {
        // 1) Файл кадра пишем ДО транзакции (если capture отдал байты), путь — внутрь записи.
        //    let (не var) — иначе Swift 6 не даёт захват в concurrent write-closure.
        let relativePath: String?
        let bytes: Int?
        switch rec.image {
        case .heicData(let data):
            relativePath = try storage.writeFrame(data, timestamp: rec.timestamp, displayIndex: 0)
            bytes = data.count
        case .fileWritten(let path):
            relativePath = path
            bytes = nil
        case .none:
            relativePath = nil
            bytes = nil
        }

        let tsMs = Int64(rec.timestamp.timeIntervalSince1970 * 1000)
        let blocks = rec.textBlocks

        do {
            return try await db.pool.write { dbc -> Int64 in
                // upsert app
                let appId = try Self.upsertApp(dbc, bundleId: rec.bundleId, name: rec.appName)
                var cap = ScreenCaptureRow(
                    id: nil, ts: tsMs, appId: appId,
                    windowTitle: rec.windowTitle, browserUrl: rec.browserURL,
                    monitorId: rec.monitorId, relativePath: relativePath,
                    width: rec.pixelWidth, height: rec.pixelHeight,
                    bytes: bytes, axQuality: rec.axQuality.rawValue)
                try cap.insert(dbc)
                let captureId = cap.id!
                for b in blocks {
                    var tb = TextBlockRow(
                        id: nil, captureId: captureId, source: b.source.rawValue,
                        text: b.text, confidence: b.confidence,
                        bboxX: b.bbox.map { Double($0.origin.x) }, bboxY: b.bbox.map { Double($0.origin.y) },
                        bboxW: b.bbox.map { Double($0.size.width) }, bboxH: b.bbox.map { Double($0.size.height) })
                    try tb.insert(dbc)   // триггер text_blocks_ai наполнит text_fts
                }
                return captureId
            }
        } catch {
            // Транзакция упала — не оставляем orphan-файл (фикс дыры старой версии).
            if case .heicData = rec.image, let p = relativePath { storage.deleteFile(relativePath: p) }
            throw error
        }
    }

    @discardableResult
    func ingest(_ rec: AudioCaptureRecord) async throws -> Int64 {
        let tsMs = Int64(rec.timestamp.timeIntervalSince1970 * 1000)
        return try await db.pool.write { dbc -> Int64 in
            var row = AudioCaptureRow(id: nil, ts: tsMs, relativePath: rec.relativePath,
                                      durationSec: rec.durationSec, channel: rec.channel)
            try row.insert(dbc)
            return row.id!
        }
        // TODO(шаг 10): поставить на TranscriptionService
    }

    /// upsert по уникальному bundleId, возвращает id.
    private static func upsertApp(_ db: Database, bundleId: String, name: String) throws -> Int64 {
        if let existing = try AppRow.filter(Column("bundleId") == bundleId).fetchOne(db) {
            return existing.id!
        }
        var row = AppRow(id: nil, bundleId: bundleId, name: name)
        try row.insert(db)
        return row.id!
    }
}
