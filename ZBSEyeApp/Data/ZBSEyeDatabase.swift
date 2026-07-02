import Foundation
import GRDB
import CSqliteVec

/// Owner of the DatabasePool + migrations. Sendable (only `let pool`). Writes/reads go through the pool
/// (it's thread-safe). FTS5 external-content + triggers — WITHOUT the old version's Cartesian bug.
final class ZBSEyeDatabase: Sendable {
    let pool: DatabasePool

    /// Embedding dimensionality (multilingual-e5-small = 384). Fixed in the vec0 DDL.
    static let embeddingDim = 384

    /// `runMigrations: false` — for read-only consumers (the MCP process), to avoid taking an exclusive
    /// write-lock on grdb_migrations and contending with the writing GUI instance. The GUI owns the schema.
    init(path: String, runMigrations: Bool = true) throws {
        // mmap+WAL are especially prone to DB corruption on EXTERNAL/network volumes (our relocate to SSD!) — SQLite
        // docs warn about this directly, screenpipe disabled mmap as its top corruption fix. "Forever memory" =
        // integrity > speed. On internal APFS we keep a moderate mmap; on external/unknown — 0.
        // We query the volume by the PARENT folder: the DB file itself isn't created yet on the first launch
        // (DatabasePool creates it below) → resourceValues on a nonexistent path would return nil → mmap=0
        // for the entire first session even on an internal disk. The data-root folder is already created by StorageManager.
        let isInternal = (try? URL(fileURLWithPath: path).deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) ?? false
        let mmapBytes = isInternal ? 134_217_728 : 0   // 128 MB internal, 0 on external/unknown
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA recursive_triggers = ON")  // FK cascade → DELETE on text_blocks → FTS trigger
            try db.execute(sql: "PRAGMA synchronous = NORMAL")    // WAL + NORMAL = safe+fast
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            try db.execute(sql: "PRAGMA mmap_size = \(mmapBytes)")   // 0 on an external volume — anti-corruption
            // Register sqlite-vec (static, no loadable extension) on every pool connection.
            // We check rc — otherwise the error would surface later as "no such module: vec0".
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
        if runMigrations {
            try Self.migrator.migrate(pool)
            Self.warnIfNewerSchema(pool)
        }
    }

    /// Defensive downgrade guard: if the DB carries migration identifiers this binary doesn't know, it
    /// was written by a NEWER ZBS Eye. We never erase (the history is precious) — just log, so a
    /// downgrade is visible instead of silently mis-reading a future schema.
    private static let knownMigrations: Set<String> =
        ["v1", "v2_vector", "v3_vec_e5_384", "v4_vec_transcripts", "v5_browser_visits"]
    private static func warnIfNewerSchema(_ pool: DatabasePool) {
        let applied = (try? pool.read { db in
            try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
        }) ?? []
        let unknown = applied.filter { !knownMigrations.contains($0) }
        if !unknown.isEmpty {
            Log.app.error("DB created by a newer ZBS Eye (unknown migrations: \(unknown.joined(separator: ", "))) — running without schema changes.")
        }
    }

    /// Standard DB location — via the single StorageLocation (accounts for relocate). Media is separate.
    static func defaultURL() throws -> URL {
        StorageLocation.databaseURL()
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        // NOT erase on schema change — this is a history recorder, the user's data is valuable.

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
                // telemetry (v2 plan — to prove AX-first)
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

            // FTS5 external-content: index without duplicating text. The rowid→id relation is strictly 1:1.
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

        // v2: vec0 table for semantic search (legacy 512-dim, NLEmbedding).
        m.registerMigration("v2_vector") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE vec_screen USING vec0(
                    capture_id integer, bucket_month integer partition key, embedding float[512]
                );
                """)
        }
        // v3: switch to multilingual-e5 (384-dim, cross-lingual). Recreate vec0 — the old 512-vectors
        // are dropped (new ingests are reindexed for e5; VectorBackfill back-indexes the rest).
        // bucket_month = temporal sharding.
        m.registerMigration("v3_vec_e5_384") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS vec_screen")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE vec_screen USING vec0(
                    capture_id integer, bucket_month integer partition key, embedding float[\(embeddingDim)]
                );
                """)
        }
        // v4: semantic for audio transcripts — the key promise "a ru query finds an en call"
        // worked only for the screen (transcripts were FTS-only).
        m.registerMigration("v4_vec_transcripts") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE vec_transcripts USING vec0(
                    transcription_id integer, bucket_month integer partition key, embedding float[\(embeddingDim)]
                );
                """)
        }
        // v5: real browser history (imported from each browser's own local DB). Dia/Arc don't expose the
        // URL via AX, so screen_captures.browserUrl is empty for them — this pulls the actual URLs + visit
        // times straight from the browser. On-device only; FTS on title+url so you can recall a site you
        // opened even without a screen frame.
        m.registerMigration("v5_browser_visits") { db in
            try db.create(table: "browser_visits") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .integer).notNull().indexed()     // visit time, epoch ms
                t.column("url", .text).notNull()
                t.column("host", .text)
                t.column("title", .text)
                t.column("browser", .text).notNull()             // bundle id of the source browser
                t.column("visitCount", .integer)
            }
            // one row per (browser, url, ts) — a re-import can't duplicate a visit
            try db.execute(sql: "CREATE UNIQUE INDEX idx_browser_visits_uniq ON browser_visits(browser, ts, url)")
            try db.create(indexOn: "browser_visits", columns: ["host", "ts"])
            try db.execute(sql: """
                CREATE VIRTUAL TABLE browser_visits_fts USING fts5(
                    title, url, content='browser_visits', content_rowid='id',
                    tokenize="unicode61 remove_diacritics 2");
                """)
            try db.execute(sql: """
                CREATE TRIGGER browser_visits_ai AFTER INSERT ON browser_visits BEGIN
                    INSERT INTO browser_visits_fts(rowid, title, url) VALUES (new.id, new.title, new.url);
                END;
                CREATE TRIGGER browser_visits_ad AFTER DELETE ON browser_visits BEGIN
                    INSERT INTO browser_visits_fts(browser_visits_fts, rowid, title, url) VALUES('delete', old.id, old.title, old.url);
                END;
                """)
        }
        return m
    }
}
