import Foundation
import GRDB
import CSqliteVec

/// Owner of the DatabasePool + migrations. Sendable (only `let pool`). Writes/reads go through the pool
/// (it's thread-safe). FTS5 external-content + triggers — WITHOUT the old version's Cartesian bug.
final class ZBSEyeDatabase: Sendable {
    enum Access: Sendable, Equatable {
        case readWrite
        case readOnly
    }

    enum OpenError: Error, Equatable {
        case readOnlyMigrationsForbidden
        case readOnlyDatabaseMissing(String)
    }

    let pool: DatabasePool

    /// Embedding dimensionality (multilingual-e5-small = 384). Fixed in the vec0 DDL.
    static let embeddingDim = 384

    /// A helper must opt into both `.readOnly` and `runMigrations: false`.
    /// Skipping migrations alone does not make SQLite read-only.
    init(
        path: String,
        runMigrations: Bool = true,
        access: Access = .readWrite
    ) throws {
        if access == .readOnly {
            guard !runMigrations else { throw OpenError.readOnlyMigrationsForbidden }
            guard FileManager.default.fileExists(atPath: path) else {
                throw OpenError.readOnlyDatabaseMissing(path)
            }
        }
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
        config.readonly = access == .readOnly
        config.prepareDatabase { db in
            if access == .readOnly {
                // Defense in depth on top of SQLITE_OPEN_READONLY. These are
                // connection-local controls and never mutate the database.
                try db.execute(sql: "PRAGMA query_only = ON")
            } else {
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                try db.execute(sql: "PRAGMA recursive_triggers = ON")  // FK cascade → DELETE on text_blocks → FTS trigger
                try db.execute(sql: "PRAGMA synchronous = NORMAL")    // WAL + NORMAL = safe+fast
            }
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
        [
            "v1", "v2_vector", "v3_vec_e5_384", "v4_vec_transcripts",
            "v5_browser_visits", "v6_embed_queue", "v7_call_envelopes",
            "v8_call_transcript_projection_gaps", "v9_call_source_gaps",
            "v10_call_preferred_vector_guard", "v11_call_automation_outbox",
            "v12_call_context_speakers",
            "v13_call_processing_ready_event",
        ]
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
        // v6: durable embedding queue. Ingest no longer embeds on the hot path (that kept the e5 model resident
        // 24/7). Instead every text-bearing frame / transcript is enqueued here (atomically with its text), and the
        // background indexer drains it — so nothing is ever stranded (a queue is the source of truth, no positional
        // "caught-up" guessing) and idle cost is O(pending), not a full-history scan. The one-time seeding of
        // pre-existing gaps is done by VectorBackfill.reconcile() in the BACKGROUND (not here) so a large
        // store-forever history can't stall the synchronous launch migration. Delete-triggers keep the queue from
        // accumulating orphan rows when a capture/transcript is pruned (retention/privacy) before it's embedded.
        m.registerMigration("v6_embed_queue") { db in
            try db.execute(sql: """
                CREATE TABLE embed_queue (
                    row_id   INTEGER NOT NULL,    -- screen_captures.id or transcriptions.id
                    kind     INTEGER NOT NULL,    -- 0 = screen frame, 1 = transcript
                    ts       INTEGER NOT NULL,    -- epoch ms (for bucket_month + newest-first ordering)
                    attempts INTEGER NOT NULL DEFAULT 0,  -- failed embed tries; a row that can't be embedded sinks
                                                          -- out of rotation (never deleted — history is precious)
                    PRIMARY KEY (row_id, kind)
                ) WITHOUT ROWID;
                """)
            try db.execute(sql: "CREATE INDEX idx_embed_queue_ts ON embed_queue(ts DESC)")
            try db.execute(sql: """
                CREATE TRIGGER embed_queue_screen_ad AFTER DELETE ON screen_captures BEGIN
                    DELETE FROM embed_queue WHERE row_id = old.id AND kind = 0;
                END;
                CREATE TRIGGER embed_queue_transcript_ad AFTER DELETE ON transcriptions BEGIN
                    DELETE FROM embed_queue WHERE row_id = old.id AND kind = 1;
                END;
                """)
        }
        // v7: first-class explicit call evidence. This is deliberately schema-only: a store-forever
        // database must open without a synchronous media or transcript backfill.
        m.registerMigration("v7_call_envelopes") { db in
            try db.execute(sql: """
                CREATE TABLE calls (
                    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
                    startIdempotencyKey   TEXT NOT NULL UNIQUE,
                    endIdempotencyKey     TEXT,
                    startTs               INTEGER NOT NULL,
                    endTs                 INTEGER,
                    state                 TEXT NOT NULL CHECK (state IN ('recording', 'finalizing', 'interrupted', 'ready', 'failed')),
                    interrupted           INTEGER NOT NULL DEFAULT 0 CHECK (interrupted IN (0, 1)),
                    degradationReason     TEXT,
                    mediaGeneration       INTEGER NOT NULL DEFAULT 0 CHECK (mediaGeneration >= 0),
                    preferredRevisionId   INTEGER REFERENCES call_transcript_revisions(id) ON DELETE SET NULL,
                    createdAtMs           INTEGER NOT NULL,
                    updatedAtMs           INTEGER NOT NULL,
                    CHECK (endTs IS NULL OR endTs >= startTs),
                    CHECK (state != 'recording' OR endTs IS NULL)
                );
                CREATE UNIQUE INDEX idx_calls_one_recording ON calls((1)) WHERE state = 'recording';
                CREATE INDEX idx_calls_start ON calls(startTs DESC);

                CREATE TABLE call_source_spans (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    callId            INTEGER NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
                    source            TEXT NOT NULL CHECK (source IN ('me', 'system')),
                    epoch             INTEGER NOT NULL CHECK (epoch >= 0),
                    sampleRate        INTEGER NOT NULL CHECK (sampleRate > 0),
                    startedAtMs       INTEGER NOT NULL,
                    endedAtMs         INTEGER,
                    startSample       INTEGER NOT NULL CHECK (startSample >= 0),
                    endSample         INTEGER,
                    startHostTimeNs   INTEGER NOT NULL CHECK (startHostTimeNs >= 0),
                    endHostTimeNs     INTEGER,
                    availability      TEXT NOT NULL CHECK (availability IN ('available', 'unavailable', 'gap')),
                    gapReason         TEXT,
                    UNIQUE(callId, source, epoch),
                    CHECK (endedAtMs IS NULL OR endedAtMs >= startedAtMs),
                    CHECK (endSample IS NULL OR endSample >= startSample),
                    CHECK (endHostTimeNs IS NULL OR endHostTimeNs >= startHostTimeNs)
                );

                CREATE TABLE call_audio_chunks (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    callId            INTEGER NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
                    sourceSpanId      INTEGER NOT NULL REFERENCES call_source_spans(id) ON DELETE CASCADE,
                    source            TEXT NOT NULL CHECK (source IN ('me', 'system')),
                    epoch             INTEGER NOT NULL CHECK (epoch >= 0),
                    sequence          INTEGER NOT NULL CHECK (sequence >= 0),
                    mediaGeneration   INTEGER NOT NULL CHECK (mediaGeneration >= 0),
                    startSample       INTEGER NOT NULL CHECK (startSample >= 0),
                    endSample         INTEGER NOT NULL CHECK (endSample >= startSample),
                    startMs           INTEGER NOT NULL,
                    endMs             INTEGER NOT NULL CHECK (endMs >= startMs),
                    relativePath      TEXT NOT NULL,
                    bytes             INTEGER NOT NULL CHECK (bytes >= 0),
                    sha256            TEXT,
                    finalized         INTEGER NOT NULL DEFAULT 0 CHECK (finalized IN (0, 1)),
                    UNIQUE(callId, source, epoch, sequence),
                    UNIQUE(relativePath)
                );
                CREATE INDEX idx_call_audio_chunks_call_time ON call_audio_chunks(callId, startMs, endMs);

                CREATE TABLE call_bookmarks (
                    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
                    callId                INTEGER NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
                    idempotencyKey        TEXT NOT NULL,
                    ordinal               INTEGER NOT NULL CHECK (ordinal > 0),
                    acceptedAtMs          INTEGER NOT NULL,
                    meIngressTarget       INTEGER,
                    systemIngressTarget   INTEGER,
                    logicalStartMs        INTEGER NOT NULL,
                    logicalEndMs          INTEGER NOT NULL,
                    contextStartMs        INTEGER NOT NULL,
                    state                 TEXT NOT NULL CHECK (state IN ('preparing', 'pending', 'deferred_capacity', 'ready', 'ready_degraded', 'failed', 'satisfied_by_final')),
                    mediaGeneration       INTEGER NOT NULL CHECK (mediaGeneration >= 0),
                    UNIQUE(callId, idempotencyKey),
                    UNIQUE(callId, ordinal),
                    CHECK (meIngressTarget IS NULL OR meIngressTarget >= 0),
                    CHECK (systemIngressTarget IS NULL OR systemIngressTarget >= 0),
                    CHECK (contextStartMs <= logicalStartMs AND logicalStartMs <= logicalEndMs),
                    CHECK (acceptedAtMs >= logicalEndMs)
                );

                CREATE TABLE call_transcript_jobs (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    identity          TEXT NOT NULL UNIQUE,
                    callId            INTEGER NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
                    bookmarkId        INTEGER REFERENCES call_bookmarks(id) ON DELETE CASCADE,
                    kind              TEXT NOT NULL CHECK (kind IN ('checkpoint', 'final')),
                    mediaGeneration   INTEGER NOT NULL CHECK (mediaGeneration >= 0),
                    state             TEXT NOT NULL CHECK (state IN ('preparing', 'deferred_capacity', 'pending', 'running', 'satisfied_by_final', 'ready', 'ready_degraded', 'failed', 'cancelled')),
                    priority          INTEGER NOT NULL,
                    logicalStartMs    INTEGER NOT NULL,
                    logicalEndMs      INTEGER NOT NULL,
                    contextStartMs    INTEGER NOT NULL,
                    meEndSample       INTEGER,
                    systemEndSample   INTEGER,
                    coverageFrozen    INTEGER NOT NULL DEFAULT 0 CHECK (coverageFrozen IN (0, 1)),
                    attempts          INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
                    errorCode         TEXT,
                    createdAtMs       INTEGER NOT NULL,
                    updatedAtMs       INTEGER NOT NULL,
                    CHECK ((kind = 'checkpoint' AND bookmarkId IS NOT NULL) OR (kind = 'final' AND bookmarkId IS NULL)),
                    CHECK (contextStartMs <= logicalStartMs AND logicalStartMs <= logicalEndMs)
                );
                CREATE UNIQUE INDEX idx_call_jobs_one_final_generation
                    ON call_transcript_jobs(callId, mediaGeneration) WHERE kind = 'final';
                CREATE INDEX idx_call_jobs_claim
                    ON call_transcript_jobs(state, priority, createdAtMs);

                CREATE TABLE call_transcript_revisions (
                    id                INTEGER PRIMARY KEY AUTOINCREMENT,
                    callId            INTEGER NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
                    jobId             INTEGER UNIQUE REFERENCES call_transcript_jobs(id) ON DELETE SET NULL,
                    projectionKey     TEXT UNIQUE,
                    kind              TEXT NOT NULL CHECK (kind IN ('interval', 'projection', 'final')),
                    mediaGeneration   INTEGER NOT NULL CHECK (mediaGeneration >= 0),
                    state             TEXT NOT NULL CHECK (state IN ('writing', 'ready', 'failed')),
                    text              TEXT NOT NULL,
                    language          TEXT NOT NULL,
                    engine            TEXT NOT NULL,
                    modelRevision     TEXT NOT NULL,
                    logicalStartMs    INTEGER NOT NULL,
                    logicalEndMs      INTEGER NOT NULL,
                    createdAtMs       INTEGER NOT NULL,
                    CHECK ((jobId IS NOT NULL) != (projectionKey IS NOT NULL)),
                    CHECK (logicalEndMs >= logicalStartMs)
                );
                CREATE INDEX idx_call_revisions_call ON call_transcript_revisions(callId, createdAtMs);

                CREATE TABLE call_transcript_segments (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    revisionId    INTEGER NOT NULL REFERENCES call_transcript_revisions(id) ON DELETE CASCADE,
                    ordinal       INTEGER NOT NULL CHECK (ordinal >= 0),
                    source        TEXT NOT NULL CHECK (source IN ('me', 'system')),
                    startMs       INTEGER NOT NULL,
                    endMs         INTEGER NOT NULL CHECK (endMs >= startMs),
                    text          TEXT NOT NULL,
                    UNIQUE(revisionId, ordinal)
                );

                CREATE TABLE call_media_mutations (
                    id                        INTEGER PRIMARY KEY AUTOINCREMENT,
                    identity                  TEXT NOT NULL UNIQUE,
                    callId                    INTEGER NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
                    kind                      TEXT NOT NULL CHECK (kind IN ('redaction', 'erase')),
                    state                     TEXT NOT NULL CHECK (state IN ('staged', 'reference_swapped', 'cleanup_pending', 'completed', 'rolled_back', 'failed')),
                    fromGeneration            INTEGER NOT NULL CHECK (fromGeneration >= 0),
                    toGeneration              INTEGER NOT NULL CHECK (toGeneration > fromGeneration),
                    oldRelativePathsJSON      TEXT NOT NULL,
                    newRelativePathsJSON      TEXT NOT NULL,
                    createdAtMs               INTEGER NOT NULL,
                    updatedAtMs               INTEGER NOT NULL,
                    errorCode                 TEXT,
                    UNIQUE(callId, toGeneration)
                );

                CREATE VIRTUAL TABLE call_transcript_fts USING fts5(
                    revision_id UNINDEXED,
                    call_id UNINDEXED,
                    text,
                    tokenize="unicode61 remove_diacritics 2"
                );
                CREATE VIRTUAL TABLE vec_call_transcripts USING vec0(
                    revision_id integer,
                    bucket_month integer partition key,
                    embedding float[384]
                );
                """)

            try db.execute(sql: """
                CREATE TRIGGER call_audio_chunks_generation_bi
                BEFORE INSERT ON call_audio_chunks BEGIN
                    SELECT CASE WHEN NEW.mediaGeneration != (
                        SELECT mediaGeneration FROM calls WHERE id = NEW.callId
                    ) THEN RAISE(ABORT, 'call audio chunk generation is stale') END;
                END;

                CREATE TRIGGER call_audio_chunks_owner_bi
                BEFORE INSERT ON call_audio_chunks BEGIN
                    SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM call_source_spans s
                        WHERE s.id = NEW.sourceSpanId
                          AND s.callId = NEW.callId
                          AND s.source = NEW.source
                          AND s.epoch = NEW.epoch
                    ) THEN RAISE(ABORT, 'call audio chunk source span mismatch') END;
                END;

                CREATE TRIGGER call_audio_chunks_identity_bu
                BEFORE UPDATE ON call_audio_chunks
                WHEN NEW.callId != OLD.callId
                  OR NEW.sourceSpanId != OLD.sourceSpanId
                  OR NEW.source != OLD.source
                  OR NEW.epoch != OLD.epoch
                  OR NEW.sequence != OLD.sequence
                  OR NEW.mediaGeneration != OLD.mediaGeneration
                  OR NEW.startSample != OLD.startSample
                  OR NEW.startMs != OLD.startMs
                  OR NEW.relativePath != OLD.relativePath BEGIN
                    SELECT RAISE(ABORT, 'call audio chunk identity is immutable');
                END;

                CREATE TRIGGER call_audio_chunks_finalized_bu
                BEFORE UPDATE ON call_audio_chunks WHEN OLD.finalized = 1 BEGIN
                    SELECT RAISE(ABORT, 'finalized call audio chunk is immutable');
                END;

                CREATE TRIGGER call_bookmarks_generation_bi
                BEFORE INSERT ON call_bookmarks BEGIN
                    SELECT CASE WHEN NEW.mediaGeneration != (
                        SELECT mediaGeneration FROM calls WHERE id = NEW.callId
                    ) THEN RAISE(ABORT, 'call bookmark generation is stale') END;
                END;

                CREATE TRIGGER call_jobs_generation_bi
                BEFORE INSERT ON call_transcript_jobs BEGIN
                    SELECT CASE WHEN NEW.mediaGeneration != (
                        SELECT mediaGeneration FROM calls WHERE id = NEW.callId
                    ) THEN RAISE(ABORT, 'call transcript job generation is stale') END;
                END;

                CREATE TRIGGER call_jobs_bookmark_owner_bi
                BEFORE INSERT ON call_transcript_jobs WHEN NEW.kind = 'checkpoint' BEGIN
                    SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM call_bookmarks b
                        WHERE b.id = NEW.bookmarkId
                          AND b.callId = NEW.callId
                          AND b.mediaGeneration = NEW.mediaGeneration
                    ) THEN RAISE(ABORT, 'call transcript job bookmark mismatch') END;
                END;

                CREATE TRIGGER call_revisions_generation_bi
                BEFORE INSERT ON call_transcript_revisions BEGIN
                    SELECT CASE WHEN NEW.mediaGeneration != (
                        SELECT mediaGeneration FROM calls WHERE id = NEW.callId
                    ) THEN RAISE(ABORT, 'call transcript revision generation is stale') END;
                END;

                CREATE TRIGGER call_revisions_job_owner_bi
                BEFORE INSERT ON call_transcript_revisions WHEN NEW.jobId IS NOT NULL BEGIN
                    SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM call_transcript_jobs j
                        WHERE j.id = NEW.jobId
                          AND j.callId = NEW.callId
                          AND j.mediaGeneration = NEW.mediaGeneration
                    ) THEN RAISE(ABORT, 'call transcript revision job mismatch') END;
                END;

                CREATE TRIGGER calls_preferred_revision_bi
                BEFORE INSERT ON calls WHEN NEW.preferredRevisionId IS NOT NULL BEGIN
                    SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM call_transcript_revisions r
                        WHERE r.id = NEW.preferredRevisionId
                          AND r.callId = NEW.id
                          AND r.mediaGeneration = NEW.mediaGeneration
                          AND r.kind IN ('projection', 'final')
                          AND r.state = 'ready'
                    ) THEN RAISE(ABORT, 'invalid preferred call transcript revision') END;
                END;

                CREATE TRIGGER calls_preferred_revision_bu
                BEFORE UPDATE OF preferredRevisionId, mediaGeneration ON calls
                WHEN NEW.preferredRevisionId IS NOT NULL BEGIN
                    SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM call_transcript_revisions r
                        WHERE r.id = NEW.preferredRevisionId
                          AND r.callId = NEW.id
                          AND r.mediaGeneration = NEW.mediaGeneration
                          AND r.kind IN ('projection', 'final')
                          AND r.state = 'ready'
                    ) THEN RAISE(ABORT, 'invalid preferred call transcript revision') END;
                END;

                CREATE TRIGGER calls_preferred_fts_au
                AFTER UPDATE OF preferredRevisionId ON calls
                WHEN OLD.preferredRevisionId IS NOT NEW.preferredRevisionId BEGIN
                    DELETE FROM call_transcript_fts WHERE revision_id = old.preferredRevisionId;
                    DELETE FROM vec_call_transcripts WHERE revision_id = old.preferredRevisionId;
                    INSERT INTO call_transcript_fts(revision_id, call_id, text)
                    SELECT id, callId, text FROM call_transcript_revisions
                    WHERE id = new.preferredRevisionId;
                END;

                CREATE TRIGGER calls_preferred_fts_ad
                AFTER DELETE ON calls BEGIN
                    DELETE FROM call_transcript_fts WHERE call_id = old.id;
                END;

                CREATE TRIGGER call_revisions_projection_ad
                AFTER DELETE ON call_transcript_revisions BEGIN
                    DELETE FROM call_transcript_fts WHERE revision_id = old.id;
                    DELETE FROM vec_call_transcripts WHERE revision_id = old.id;
                END;
                """)
        }
        // v8: provisional transcript text must not imply that missing/failed
        // Bookmark intervals were transcribed. Keep explicit gap provenance
        // beside each immutable projection without polluting searchable text.
        m.registerMigration("v8_call_transcript_projection_gaps") { db in
            try db.execute(sql: """
                CREATE TABLE call_transcript_projection_gaps (
                    revisionId     INTEGER NOT NULL REFERENCES call_transcript_revisions(id) ON DELETE CASCADE,
                    bookmarkId     INTEGER NOT NULL REFERENCES call_bookmarks(id) ON DELETE CASCADE,
                    ordinal        INTEGER NOT NULL CHECK (ordinal > 0),
                    state          TEXT NOT NULL CHECK (state IN ('preparing', 'pending', 'deferred_capacity', 'ready', 'ready_degraded', 'failed', 'satisfied_by_final')),
                    logicalStartMs INTEGER NOT NULL,
                    logicalEndMs   INTEGER NOT NULL CHECK (logicalEndMs >= logicalStartMs),
                    PRIMARY KEY (revisionId, bookmarkId)
                ) WITHOUT ROWID;
                CREATE INDEX idx_call_projection_gaps_bookmark
                    ON call_transcript_projection_gaps(bookmarkId, revisionId);
                """)
        }
        // v9: privacy redaction creates an explicit interval in the current media generation.
        // Source spans describe capture epochs and cannot represent a hole inside an epoch without
        // rewriting their immutable clock mapping, so durable gaps live beside them.
        m.registerMigration("v9_call_source_gaps") { db in
            try db.execute(sql: """
                CREATE TABLE call_source_gaps (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    callId          INTEGER NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
                    mediaGeneration INTEGER NOT NULL CHECK (mediaGeneration >= 0),
                    source          TEXT NOT NULL CHECK (source IN ('me', 'system')),
                    startMs         INTEGER NOT NULL,
                    endMs           INTEGER NOT NULL CHECK (endMs > startMs),
                    reason          TEXT NOT NULL,
                    createdAtMs     INTEGER NOT NULL,
                    UNIQUE(callId, mediaGeneration, source, startMs, endMs, reason)
                );
                CREATE INDEX idx_call_source_gaps_call_time
                    ON call_source_gaps(callId, mediaGeneration, startMs, endMs);
                CREATE TRIGGER call_source_gaps_generation_bi
                BEFORE INSERT ON call_source_gaps BEGIN
                    SELECT CASE WHEN NEW.mediaGeneration != (
                        SELECT mediaGeneration FROM calls WHERE id = NEW.callId
                    ) THEN RAISE(ABORT, 'call source gap generation is stale') END;
                END;
                """)
        }
        // v10: GRDB updates whole rows, so an unchanged preferredRevisionId can
        // still appear in an UPDATE column list. Preserve its semantic vector
        // unless the identity actually changes.
        m.registerMigration("v10_call_preferred_vector_guard") { db in
            try db.execute(sql: """
                DROP TRIGGER IF EXISTS calls_preferred_fts_au;
                CREATE TRIGGER calls_preferred_fts_au
                AFTER UPDATE OF preferredRevisionId ON calls
                WHEN OLD.preferredRevisionId IS NOT NEW.preferredRevisionId BEGIN
                    DELETE FROM call_transcript_fts WHERE revision_id = old.preferredRevisionId;
                    DELETE FROM vec_call_transcripts WHERE revision_id = old.preferredRevisionId;
                    INSERT INTO call_transcript_fts(revision_id, call_id, text)
                    SELECT id, callId, text FROM call_transcript_revisions
                    WHERE id = new.preferredRevisionId;
                END;
                """)
        }
        // v11: call lifecycle facts use a transactional outbox. Source transitions and their
        // automation hints commit together; network delivery remains entirely outside the writer.
        m.registerMigration("v11_call_automation_outbox") { db in
            try db.execute(sql: """
                CREATE TABLE call_automation_config (
                    id                      INTEGER PRIMARY KEY CHECK (id = 1),
                    enabled                 INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
                    endpointURL             TEXT,
                    endpointFingerprint     TEXT,
                    updatedAtMs             INTEGER NOT NULL DEFAULT 0,
                    CHECK (enabled = 0 OR (endpointURL IS NOT NULL AND endpointFingerprint IS NOT NULL))
                );
                INSERT INTO call_automation_config(id, enabled, updatedAtMs) VALUES (1, 0, 0);

                CREATE TABLE call_automation_outbox (
                    sequence                INTEGER PRIMARY KEY AUTOINCREMENT,
                    eventID                 TEXT NOT NULL UNIQUE,
                    semanticIdentity        TEXT NOT NULL UNIQUE,
                    callId                  INTEGER NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
                    eventType               TEXT NOT NULL CHECK (eventType IN (
                                                'call.ended',
                                                'call.transcript.ready',
                                                'call.transcript.failed'
                                            )),
                    occurredAtMs            INTEGER NOT NULL,
                    endpointFingerprint     TEXT NOT NULL,
                    payloadJSON             TEXT NOT NULL,
                    state                   TEXT NOT NULL DEFAULT 'pending' CHECK (state IN (
                                                'pending', 'sending', 'delivered', 'blocked'
                                            )),
                    attempts                INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
                    nextAttemptAtMs         INTEGER NOT NULL,
                    leaseExpiresAtMs        INTEGER,
                    httpStatus              INTEGER,
                    lastErrorCode           TEXT,
                    deliveredAtMs           INTEGER,
                    createdAtMs             INTEGER NOT NULL,
                    updatedAtMs             INTEGER NOT NULL
                );
                CREATE INDEX idx_call_automation_claim
                    ON call_automation_outbox(state, nextAttemptAtMs, sequence);
                CREATE INDEX idx_call_automation_call_sequence
                    ON call_automation_outbox(callId, sequence);
                CREATE INDEX idx_call_automation_delivered
                    ON call_automation_outbox(deliveredAtMs)
                    WHERE state = 'delivered';
                """)
        }
        // v12: one shared call context plus immutable, per-call speaker revisions.
        // This remains schema-only so large existing stores open without media work.
        m.registerMigration("v12_call_context_speakers") { db in
            try db.execute(sql: """
                ALTER TABLE calls ADD COLUMN preferredSpeakerRevisionId INTEGER
                    REFERENCES call_speaker_revisions(id) ON DELETE SET NULL;

                CREATE TABLE call_context (
                    callId                      INTEGER PRIMARY KEY REFERENCES calls(id) ON DELETE CASCADE,
                    captureOwner                TEXT NOT NULL CHECK (captureOwner IN ('manual', 'automatic', 'claimed')),
                    disposition                 TEXT NOT NULL CHECK (disposition IN ('active', 'confirmed', 'rejected')),
                    detectorFingerprintHash     TEXT,
                    sourceAppBundleID           TEXT,
                    sourceAppName               TEXT,
                    trustedOriginHost           TEXT,
                    title                       TEXT,
                    participantsJSON            TEXT NOT NULL DEFAULT '[]',
                    createdAtMs                 INTEGER NOT NULL,
                    updatedAtMs                 INTEGER NOT NULL
                ) WITHOUT ROWID;
                CREATE INDEX idx_call_context_source_app ON call_context(sourceAppBundleID, callId);

                CREATE TABLE call_speaker_revisions (
                    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
                    callId              INTEGER NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
                    mediaGeneration     INTEGER NOT NULL CHECK (mediaGeneration >= 0),
                    previousRevisionId  INTEGER REFERENCES call_speaker_revisions(id) ON DELETE SET NULL,
                    state               TEXT NOT NULL CHECK (state IN ('writing', 'ready', 'failed')),
                    engine              TEXT NOT NULL,
                    modelRevision       TEXT NOT NULL,
                    createdAtMs         INTEGER NOT NULL
                );
                CREATE INDEX idx_call_speaker_revisions_call
                    ON call_speaker_revisions(callId, mediaGeneration, createdAtMs, id);

                CREATE TABLE call_speaker_clusters (
                    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
                    revisionId          INTEGER NOT NULL REFERENCES call_speaker_revisions(id) ON DELETE CASCADE,
                    ordinal             INTEGER NOT NULL CHECK (ordinal >= 0),
                    clusterKey          TEXT NOT NULL,
                    displayName         TEXT,
                    namingProvenance    TEXT NOT NULL CHECK (namingProvenance IN ('anonymous', 'current_call', 'manual')),
                    UNIQUE(revisionId, ordinal),
                    UNIQUE(revisionId, clusterKey)
                );

                CREATE TABLE call_speaker_intervals (
                    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
                    revisionId          INTEGER NOT NULL REFERENCES call_speaker_revisions(id) ON DELETE CASCADE,
                    clusterId           INTEGER NOT NULL REFERENCES call_speaker_clusters(id) ON DELETE CASCADE,
                    ordinal             INTEGER NOT NULL CHECK (ordinal >= 0),
                    source              TEXT NOT NULL CHECK (source IN ('me', 'system')),
                    startMs             INTEGER NOT NULL,
                    endMs               INTEGER NOT NULL CHECK (endMs >= startMs),
                    UNIQUE(revisionId, ordinal)
                );
                CREATE INDEX idx_call_speaker_intervals_time
                    ON call_speaker_intervals(revisionId, startMs, endMs, ordinal);

                CREATE TRIGGER call_speaker_revisions_generation_bi
                BEFORE INSERT ON call_speaker_revisions BEGIN
                    SELECT CASE WHEN NEW.mediaGeneration != (
                        SELECT mediaGeneration FROM calls WHERE id = NEW.callId
                    ) THEN RAISE(ABORT, 'call speaker revision generation is stale') END;
                END;

                CREATE TRIGGER call_speaker_revisions_previous_bi
                BEFORE INSERT ON call_speaker_revisions WHEN NEW.previousRevisionId IS NOT NULL BEGIN
                    SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM call_speaker_revisions r
                        WHERE r.id = NEW.previousRevisionId
                          AND r.callId = NEW.callId
                          AND r.mediaGeneration = NEW.mediaGeneration
                          AND r.state = 'ready'
                    ) THEN RAISE(ABORT, 'invalid previous call speaker revision') END;
                END;

                CREATE TRIGGER call_speaker_intervals_owner_bi
                BEFORE INSERT ON call_speaker_intervals BEGIN
                    SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM call_speaker_clusters c
                        WHERE c.id = NEW.clusterId AND c.revisionId = NEW.revisionId
                    ) THEN RAISE(ABORT, 'call speaker interval cluster mismatch') END;
                END;

                CREATE TRIGGER calls_preferred_speaker_revision_bu
                BEFORE UPDATE OF preferredSpeakerRevisionId, mediaGeneration ON calls
                WHEN NEW.preferredSpeakerRevisionId IS NOT NULL BEGIN
                    SELECT CASE WHEN NOT EXISTS (
                        SELECT 1 FROM call_speaker_revisions r
                        WHERE r.id = NEW.preferredSpeakerRevisionId
                          AND r.callId = NEW.id
                          AND r.mediaGeneration = NEW.mediaGeneration
                          AND r.state = 'ready'
                    ) THEN RAISE(ABORT, 'invalid preferred call speaker revision') END;
                END;
                """)
        }
        // v13: add the post-processing readiness hint to the durable outbox.
        // SQLite cannot widen a CHECK constraint in place, so rebuild the table
        // while preserving every sequence, lease, attempt, and delivery result.
        m.registerMigration("v13_call_processing_ready_event") { db in
            try db.execute(sql: """
                ALTER TABLE call_automation_outbox RENAME TO call_automation_outbox_v12;

                CREATE TABLE call_automation_outbox (
                    sequence                INTEGER PRIMARY KEY AUTOINCREMENT,
                    eventID                 TEXT NOT NULL UNIQUE,
                    semanticIdentity        TEXT NOT NULL UNIQUE,
                    callId                  INTEGER NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
                    eventType               TEXT NOT NULL CHECK (eventType IN (
                                                'call.ended',
                                                'call.transcript.ready',
                                                'call.transcript.failed',
                                                'call.processing.ready'
                                            )),
                    occurredAtMs            INTEGER NOT NULL,
                    endpointFingerprint     TEXT NOT NULL,
                    payloadJSON             TEXT NOT NULL,
                    state                   TEXT NOT NULL DEFAULT 'pending' CHECK (state IN (
                                                'pending', 'sending', 'delivered', 'blocked'
                                            )),
                    attempts                INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
                    nextAttemptAtMs         INTEGER NOT NULL,
                    leaseExpiresAtMs        INTEGER,
                    httpStatus              INTEGER,
                    lastErrorCode           TEXT,
                    deliveredAtMs           INTEGER,
                    createdAtMs             INTEGER NOT NULL,
                    updatedAtMs             INTEGER NOT NULL
                );
                INSERT INTO call_automation_outbox(
                    sequence, eventID, semanticIdentity, callId, eventType, occurredAtMs,
                    endpointFingerprint, payloadJSON, state, attempts, nextAttemptAtMs,
                    leaseExpiresAtMs, httpStatus, lastErrorCode, deliveredAtMs, createdAtMs, updatedAtMs
                )
                SELECT
                    sequence, eventID, semanticIdentity, callId, eventType, occurredAtMs,
                    endpointFingerprint, payloadJSON, state, attempts, nextAttemptAtMs,
                    leaseExpiresAtMs, httpStatus, lastErrorCode, deliveredAtMs, createdAtMs, updatedAtMs
                FROM call_automation_outbox_v12
                ORDER BY sequence;
                DROP TABLE call_automation_outbox_v12;

                CREATE INDEX idx_call_automation_claim
                    ON call_automation_outbox(state, nextAttemptAtMs, sequence);
                CREATE INDEX idx_call_automation_call_sequence
                    ON call_automation_outbox(callId, sequence);
                CREATE INDEX idx_call_automation_delivered
                    ON call_automation_outbox(deliveredAtMs)
                    WHERE state = 'delivered';
                """)
        }
        return m
    }
}
