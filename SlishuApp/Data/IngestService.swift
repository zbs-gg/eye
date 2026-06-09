import Foundation
import GRDB

/// Writer для capture-данных (actor). Capture/Transcription отдают сюда Sendable-записи; здесь — файл +
/// одна транзакция (upsert app, insert screen_capture, insert text_blocks → триггеры наполняют FTS).
/// Убирает Task.detached-гонки старой версии.
/// NB: записи в БД сериализует GRDB DatabasePool через RetentionManager И IngestService (не один объект-
/// writer, а один сериализованный writer-канал пула). Координация с retention — через grace-window в
/// sweepOrphans (см. RetentionManager), чтобы orphan-sweep не удалил in-flight кадр.
actor IngestService {
    private let db: SlishuDatabase
    private let storage: StorageManager
    private let embedder: EmbeddingService

    init(db: SlishuDatabase, storage: StorageManager, embedder: EmbeddingService) {
        self.db = db
        self.storage = storage
        self.embedder = embedder
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

        // эмбеддинг — ДО транзакции (async). Embed только если есть текст (не дёргаем actor на пустом).
        let fullText = blocks.map(\.text).joined(separator: " ")
        let embedding: [Float]? = fullText.isEmpty ? nil : await embedder.embed(fullText)
        let bucket = monthBucket(rec.timestamp)

        do {
            return try await db.pool.write { dbc -> Int64 in
                // upsert app
                let appId = try Self.upsertApp(dbc, bundleId: rec.bundleId, name: rec.appName)
                let tel = rec.telemetry
                var cap = ScreenCaptureRow(
                    id: nil, ts: tsMs, appId: appId,
                    windowTitle: rec.windowTitle, browserUrl: rec.browserURL,
                    monitorId: rec.monitorId, relativePath: relativePath,
                    width: rec.pixelWidth, height: rec.pixelHeight,
                    bytes: bytes, axQuality: rec.axQuality.rawValue,
                    usefulTextChars: tel.usefulTextChars, nodeCount: tel.nodeCount,
                    treeWasEmpty: tel.treeWasEmpty, hitBudgetLimit: tel.hitBudgetLimit,
                    ocrFallbackReason: tel.ocrFallbackReason,
                    manualAccessibilityResult: tel.manualAccessibilityResult,
                    enhancedUiResult: tel.enhancedUiResult)
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
                // семантический вектор в vec0 (temporal-партиция по месяцу).
                // Защита: пишем только при совпадении размерности (иначе vec0 бросит и откатит ВЕСЬ
                // ingest — кадр потеряется; лучше тихо пропустить semantic, FTS останется).
                if let embedding, embedding.count == SlishuDatabase.embeddingDim {
                    try dbc.execute(sql: "INSERT INTO vec_screen(capture_id, bucket_month, embedding) VALUES (?, ?, ?)",
                                    arguments: [captureId, bucket, floatBlob(embedding)])
                }
                return captureId
            }
        } catch {
            // Транзакция упала — чистим файл, записанный ЭТИМ слоем (.heicData). Файлы .fileWritten
            // принадлежат capture-слою — их при сбое подберёт sweepOrphans (после grace-window).
            if case .heicData = rec.image, let p = relativePath { storage.deleteFile(relativePath: p) }
            throw error
        }
    }

    @discardableResult
    func ingest(_ rec: AudioCaptureRecord) async throws -> Int64 {
        let tsMs = Int64(rec.timestamp.timeIntervalSince1970 * 1000)
        let bytes = rec.bytes ?? storage.fileSize(relativePath: rec.relativePath)
        return try await db.pool.write { dbc -> Int64 in
            var row = AudioCaptureRow(id: nil, ts: tsMs, relativePath: rec.relativePath,
                                      durationSec: rec.durationSec, channel: rec.channel, bytes: bytes)
            try row.insert(dbc)
            return row.id!
        }
    }

    /// Транскрипт сегмента → transcriptions (триггер transcriptions_ai наполнит transcription_fts).
    /// Эмбеддинг речи в vec0 — follow-up (vec_screen сейчас только для кадров; для аудио нужна своя
    /// vec-таблица или общий индекс с kind-полем). Пока аудио ищется через FTS.
    @discardableResult
    func ingest(_ rec: TranscriptionRecord) async throws -> Int64 {
        try await db.pool.write { dbc -> Int64 in
            var row = TranscriptionRow(
                id: nil, audioId: rec.audioId, text: rec.text, language: rec.language,
                speaker: nil, startOffset: rec.startOffset, endOffset: rec.endOffset, engine: rec.engine)
            try row.insert(dbc)
            return row.id!
        }
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
