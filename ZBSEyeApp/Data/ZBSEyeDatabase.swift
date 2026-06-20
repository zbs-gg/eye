import Foundation
import GRDB
import CSqliteVec

/// Владелец DatabasePool + миграции. Sendable (только `let pool`). Пишут/читают через pool
/// (он thread-safe). FTS5 external-content + триггеры — БЕЗ декартова бага старой версии.
final class ZBSEyeDatabase: Sendable {
    let pool: DatabasePool

    /// Размерность эмбеддингов (multilingual-e5-small = 384). Фиксирована в vec0 DDL.
    static let embeddingDim = 384

    /// `runMigrations: false` — для read-only потребителей (MCP-процесс), чтобы не брать exclusive
    /// write-lock на grdb_migrations и не контендить с пишущим GUI-инстансом. Схемой владеет GUI.
    init(path: String, runMigrations: Bool = true) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA recursive_triggers = ON")  // FK-каскад → DELETE на text_blocks → FTS-триггер
            try db.execute(sql: "PRAGMA synchronous = NORMAL")    // WAL + NORMAL = безопасно+быстро
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            try db.execute(sql: "PRAGMA mmap_size = 268435456")   // 256 MB
            // Регистрируем sqlite-vec (static, без loadable-extension) на каждом соединении пула.
            // rc проверяем — иначе ошибка всплыла бы позже как «no such module: vec0».
            if let conn = db.sqliteConnection {
                var err: UnsafeMutablePointer<CChar>?
                let rc = sqlite3_vec_init(conn, &err, nil)
                if rc != SQLITE_OK {
                    let msg = err.map { String(cString: $0) } ?? "unknown"
                    if err != nil { sqlite3_free(err) }
                    throw DatabaseError(message: "sqlite-vec init failed: \(msg)")
                }
            }
        }
        pool = try DatabasePool(path: path, configuration: config)
        if runMigrations { try Self.migrator.migrate(pool) }
    }

    /// Стандартное расположение БД — через единый StorageLocation (учитывает relocate). Медиа — отдельно.
    static func defaultURL() throws -> URL {
        StorageLocation.databaseURL()
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        // НЕ erase on schema change — это history-рекордер, данные пользователя ценны.

        m.registerMigration("v1") { db in
            try db.create(table: "apps") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bundleId", .text).notNull().unique()
                t.column("name", .text).notNull()
            }
            try db.create(table: "screen_captures") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .integer).notNull().indexed()
                t.column("appId", .integer).references("apps", onDelete: .setNull)
                t.column("windowTitle", .text)
                t.column("browserUrl", .text)
                t.column("monitorId", .text).notNull()
                t.column("relativePath", .text)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("bytes", .integer)
                t.column("axQuality", .text)
                // телеметрия (план v2 — доказывать AX-first)
                t.column("usefulTextChars", .integer)
                t.column("nodeCount", .integer)
                t.column("treeWasEmpty", .boolean)
                t.column("hitBudgetLimit", .boolean)
                t.column("ocrFallbackReason", .text)
                t.column("manualAccessibilityResult", .text)
                t.column("enhancedUiResult", .text)
            }
            try db.create(indexOn: "screen_captures", columns: ["appId", "ts"])

            try db.create(table: "text_blocks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("captureId", .integer).notNull()
                    .references("screen_captures", onDelete: .cascade).indexed()
                t.column("source", .text).notNull()
                t.column("text", .text).notNull()
                t.column("confidence", .double).notNull().defaults(to: 1.0)
                t.column("bboxX", .double); t.column("bboxY", .double)
                t.column("bboxW", .double); t.column("bboxH", .double)
            }
            try db.create(table: "audio_captures") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .integer).notNull().indexed()
                t.column("relativePath", .text).notNull()
                t.column("durationSec", .double).notNull()
                t.column("channel", .text).notNull().defaults(to: "mic")
                t.column("bytes", .integer)
            }
            try db.create(table: "transcriptions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("audioId", .integer).notNull()
                    .references("audio_captures", onDelete: .cascade).indexed()
                t.column("text", .text).notNull()
                t.column("language", .text).notNull()
                t.column("speaker", .text)
                t.column("startOffset", .double); t.column("endOffset", .double)
                t.column("engine", .text).notNull()
            }

            // FTS5 external-content: индекс без дублирования текста. Связь rowid→id строго 1:1.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE text_fts USING fts5(
                    text, content='text_blocks', content_rowid='id',
                    tokenize="unicode61 remove_diacritics 2");
                """)
            try db.execute(sql: """
                CREATE TRIGGER text_blocks_ai AFTER INSERT ON text_blocks BEGIN
                    INSERT INTO text_fts(rowid, text) VALUES (new.id, new.text);
                END;
                CREATE TRIGGER text_blocks_ad AFTER DELETE ON text_blocks BEGIN
                    INSERT INTO text_fts(text_fts, rowid, text) VALUES('delete', old.id, old.text);
                END;
                CREATE TRIGGER text_blocks_au AFTER UPDATE ON text_blocks BEGIN
                    INSERT INTO text_fts(text_fts, rowid, text) VALUES('delete', old.id, old.text);
                    INSERT INTO text_fts(rowid, text) VALUES (new.id, new.text);
                END;
                """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcription_fts USING fts5(
                    text, content='transcriptions', content_rowid='id',
                    tokenize="unicode61 remove_diacritics 2");
                """)
            try db.execute(sql: """
                CREATE TRIGGER transcriptions_ai AFTER INSERT ON transcriptions BEGIN
                    INSERT INTO transcription_fts(rowid, text) VALUES (new.id, new.text);
                END;
                CREATE TRIGGER transcriptions_ad AFTER DELETE ON transcriptions BEGIN
                    INSERT INTO transcription_fts(transcription_fts, rowid, text) VALUES('delete', old.id, old.text);
                END;
                CREATE TRIGGER transcriptions_au AFTER UPDATE ON transcriptions BEGIN
                    INSERT INTO transcription_fts(transcription_fts, rowid, text) VALUES('delete', old.id, old.text);
                    INSERT INTO transcription_fts(rowid, text) VALUES (new.id, new.text);
                END;
                """)
        }

        // v2: vec0-таблица для семантического поиска (legacy 512-dim, NLEmbedding).
        m.registerMigration("v2_vector") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE vec_screen USING vec0(
                    capture_id integer, bucket_month integer partition key, embedding float[512]
                );
                """)
        }
        // v3: переход на multilingual-e5 (384-dim, cross-lingual). Пересоздаём vec0 — старые 512-векторы
        // дропаются (новые ingest переиндексируются под e5; VectorBackfill доиндексирует).
        // bucket_month = temporal sharding.
        m.registerMigration("v3_vec_e5_384") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS vec_screen")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE vec_screen USING vec0(
                    capture_id integer, bucket_month integer partition key, embedding float[\(embeddingDim)]
                );
                """)
        }
        // v4: semantic для аудио-транскриптов — ключевое обещание «ru-запрос находит en-звонок»
        // работало только для экрана (транскрипты были FTS-only).
        m.registerMigration("v4_vec_transcripts") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE vec_transcripts USING vec0(
                    transcription_id integer, bucket_month integer partition key, embedding float[\(embeddingDim)]
                );
                """)
        }
        return m
    }
}
