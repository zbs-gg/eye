import Foundation
import GRDB

/// Дозаполнение semantic-индекса: кадры с текстом, но без вектора в vec_screen. Источники дыр:
/// (1) миграция v3 дропнула старые 512-векторы; (2) оффлайн first-run — кадры ингестились, пока e5
/// не была скачана. Без backfill эти кадры навсегда невидимы semantic-поиску.
/// Ждёт готовности модели (а не выходит при «не готова» — иначе бы выходил ровно в сценарии, ради
/// которого существует). Страница курсором по ts (без фуллскана на каждый батч), Set имеющихся
/// векторов строится один раз и поддерживается инкрементально.
actor VectorBackfill {
    private let db: SlishuDatabase
    private let embedder: EmbeddingService
    private var running = false

    init(db: SlishuDatabase, embedder: EmbeddingService) {
        self.db = db
        self.embedder = embedder
    }

    /// Один проход до исчерпания. Повторный вызов при уже идущем — no-op.
    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }

        // 1) Дождаться модели: warmup-embed триггерит загрузку; оффлайн → ретрай раз в минуту
        //    (E5ModelProvider сам держит backoff). Без этого first-run-оффлайн выходил бы навсегда.
        while !Task.isCancelled {
            if await embedder.embed(passage: "warmup") != nil { break }
            try? await Task.sleep(for: .seconds(60))
        }
        guard !Task.isCancelled else { return }

        // 2) Снапшот: имеющиеся вектора (один раз) + верхняя граница ts. Кадры новее снапшота
        //    эмбеддит живой ingest — мы их не трогаем (нет гонки на дубль-вектор).
        guard let snapshot = try? await loadSnapshot() else { return }
        var have = snapshot.have
        var cursorTs = snapshot.maxTs + 1

        var total = 0
        var failStreak = 0
        while !Task.isCancelled {
            guard let page = try? await nextPage(before: cursorTs, limit: 300), !page.isEmpty else { break }
            cursorTs = page.last!.ts
            for item in page where !have.contains(item.id) {
                guard let text = try? await textFor(captureId: item.id), !text.isEmpty else { continue }
                guard let vec = await embedder.embed(passage: text),
                      vec.count == SlishuDatabase.embeddingDim else { continue }
                let blob = floatBlob(vec)
                do {
                    try await db.pool.write { dbc in
                        try dbc.execute(
                            sql: "INSERT INTO vec_screen(capture_id, bucket_month, embedding) VALUES (?, ?, ?)",
                            arguments: [item.id, monthBucket(dateFromMs(item.ts)), blob])
                    }
                    have.insert(item.id)
                    total += 1
                    failStreak = 0
                } catch {
                    // запись не удалась — НЕ засчитываем и не молотим вечно (диск/БД больны)
                    failStreak += 1
                    Log.app.error("backfill insert failed: \(String(describing: error), privacy: .public)")
                    if failStreak >= 10 { Log.app.error("backfill aborted: insert keeps failing"); return }
                }
            }
            try? await Task.sleep(for: .seconds(2))   // пауза между страницами — фон, не нагрузка
        }
        if total > 0 { Log.app.info("vector backfill: \(total) кадров доиндексировано") }
    }

    private struct PageItem: Sendable { let id: Int64; let ts: Int64 }
    private struct Snapshot: Sendable { let have: Set<Int64>; let maxTs: Int64 }

    private func loadSnapshot() async throws -> Snapshot {
        try await db.pool.read { dbc in
            let have = Set(try Int64.fetchAll(dbc, sql: "SELECT capture_id FROM vec_screen"))
            let maxTs = try Int64.fetchOne(dbc, sql: "SELECT COALESCE(MAX(ts), 0) FROM screen_captures") ?? 0
            return Snapshot(have: have, maxTs: maxTs)
        }
    }

    /// Страница кандидатов (кадры с текстом) строго старше cursor — O(page), не фуллскан.
    private func nextPage(before ts: Int64, limit: Int) async throws -> [PageItem] {
        try await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT c.id AS id, c.ts AS ts FROM screen_captures c
                WHERE c.ts < ? AND EXISTS (SELECT 1 FROM text_blocks tb WHERE tb.captureId = c.id)
                ORDER BY c.ts DESC LIMIT ?
                """, arguments: [ts, limit]).map { PageItem(id: $0["id"], ts: $0["ts"]) }
        }
    }

    private func textFor(captureId: Int64) async throws -> String? {
        try await db.pool.read { dbc in
            try String.fetchOne(dbc, sql:
                "SELECT group_concat(text, ' ') FROM text_blocks WHERE captureId = ?",
                arguments: [captureId])
        }
    }
}
