import Foundation
import GRDB

/// Запросы для time-travel скруббера: границы истории, тики кадров, плотность по бакетам, кадр в момент.
actor TimelineService {
    private let db: ZBSEyeDatabase
    init(db: ZBSEyeDatabase) { self.db = db }

    /// Границы истории по ОБОИМ источникам (экран + аудио): живое аудио при статичном экране тоже
    /// двигает хвост таймлайна (иначе запись звонка не появлялась на strip до нового кадра).
    func bounds() async throws -> TimeBounds {
        try await db.pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT MIN(t) AS lo, MAX(t) AS hi FROM (
                    SELECT MIN(ts) AS t FROM screen_captures
                    UNION ALL SELECT MAX(ts) FROM screen_captures
                    UNION ALL SELECT MIN(ts) FROM audio_captures
                    UNION ALL SELECT MAX(ts) FROM audio_captures
                ) WHERE t IS NOT NULL
                """)
            let lo: Int64? = row?["lo"]
            let hi: Int64? = row?["hi"]
            return TimeBounds(oldest: lo.map(dateFromMs), newest: hi.map(dateFromMs))
        }
    }

    /// Плотность активности по бакетам (для density-strip). bucketMs — ширина бакета.
    func density(from: Date, to: Date, bucketMs: Int64) async throws -> [DensityBucket] {
        let f = msFromDate(from), t = msFromDate(to)
        let b = max(1000, bucketMs)
        return try await db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT (ts / ?) * ? AS bucket, COUNT(*) AS c
                FROM screen_captures WHERE ts BETWEEN ? AND ?
                GROUP BY bucket ORDER BY bucket
                """, arguments: [b, b, f, t]).map {
                DensityBucket(ts: dateFromMs($0["bucket"]), count: $0["c"])
            }
        }
    }

    /// Ближайший кадр ≤ времени + его агрегированный текст и контекст.
    func frameAt(_ time: Date) async throws -> FrameDetail? {
        try await fetchFrame(where: "c.ts <= ? ORDER BY c.ts DESC, c.id DESC", args: [msFromDate(time)])
    }

    /// Строго следующий кадр — для шага вперёд и плеера. Тай-брейк (ts,id): кадры с равным ts
    /// (мультимонитор) не схлопываются — плеер посетит каждый. afterId nil → строгий ts-переход.
    func nextFrame(after time: Date, afterId: Int64? = nil) async throws -> FrameDetail? {
        let t = msFromDate(time)
        if let id = afterId {
            return try await fetchFrame(
                where: "(c.ts > ? OR (c.ts = ? AND c.id > ?)) ORDER BY c.ts ASC, c.id ASC",
                args: [t, t, id])
        }
        return try await fetchFrame(where: "c.ts > ? ORDER BY c.ts ASC, c.id ASC", args: [t])
    }

    /// Строго предыдущий кадр — для шага назад (зеркальный тай-брейк).
    func prevFrame(before time: Date, beforeId: Int64? = nil) async throws -> FrameDetail? {
        let t = msFromDate(time)
        if let id = beforeId {
            return try await fetchFrame(
                where: "(c.ts < ? OR (c.ts = ? AND c.id < ?)) ORDER BY c.ts DESC, c.id DESC",
                args: [t, t, id])
        }
        return try await fetchFrame(where: "c.ts < ? ORDER BY c.ts DESC, c.id DESC", args: [t])
    }

    func frameDetail(id: Int64) async throws -> FrameDetail? {
        try await fetchFrame(where: "c.id = ?", args: [id])
    }

    /// Плотность АУДИО-активности (вторая дорожка density-strip): где в истории есть речь.
    func audioDensity(from: Date, to: Date, bucketMs: Int64) async throws -> [DensityBucket] {
        let f = msFromDate(from), t = msFromDate(to)
        let b = max(1000, bucketMs)
        return try await db.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT (ts / ?) * ? AS bucket, COUNT(*) AS c
                FROM audio_captures WHERE ts BETWEEN ? AND ?
                GROUP BY bucket ORDER BY bucket
                """, arguments: [b, b, f, t]).map {
                DensityBucket(ts: dateFromMs($0["bucket"]), count: $0["c"])
            }
        }
    }

    /// Аудио-сегмент + его транскрипт (для панели прослушивания в таймлайне).
    func audioDetail(id: Int64) async throws -> AudioDetail? {
        try await db.pool.read { db in
            guard let row = try Row.fetchOne(db, sql:
                "SELECT id, ts, durationSec, channel, relativePath FROM audio_captures WHERE id = ?",
                arguments: [id]) else { return nil }
            let tr = try Row.fetchOne(db, sql:
                "SELECT text, language, speaker FROM transcriptions WHERE audioId = ? ORDER BY id DESC LIMIT 1",
                arguments: [id])
            return AudioDetail(
                id: row["id"], ts: dateFromMs(row["ts"]), durationSec: row["durationSec"],
                channel: row["channel"], relativePath: row["relativePath"],
                transcript: tr?["text"], language: tr?["language"], speaker: tr?["speaker"])
        }
    }

    // Общий маппинг: один кадр по предикату + его склеенный текст. clause включает ORDER/LIMIT не нужен —
    // LIMIT 1 добавляем здесь; ORDER задаётся в clause до LIMIT. clause — compile-time константы выше.
    private func fetchFrame(where clause: String, args: [Int64]) async throws -> FrameDetail? {
        try await db.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT c.id AS id, c.ts AS ts, c.relativePath AS relativePath, c.windowTitle AS windowTitle,
                       c.browserUrl AS browserUrl, c.axQuality AS axQuality, a.bundleId AS bundleId, a.name AS appName
                FROM screen_captures c LEFT JOIN apps a ON a.id = c.appId
                WHERE \(clause) LIMIT 1
                """, arguments: StatementArguments(args)) else { return nil }
            let id: Int64 = row["id"]
            let text = try String.fetchOne(db, sql:
                "SELECT group_concat(text, '\n') FROM text_blocks WHERE captureId = ?", arguments: [id]) ?? ""
            let sources = try String.fetchAll(db, sql:
                "SELECT DISTINCT source FROM text_blocks WHERE captureId = ?", arguments: [id])
            return FrameDetail(
                id: id, ts: dateFromMs(row["ts"]), relativePath: row["relativePath"],
                bundleId: row["bundleId"], appName: row["appName"],
                windowTitle: row["windowTitle"], browserURL: row["browserUrl"],
                text: text, axQuality: row["axQuality"], sources: sources)
        }
    }
}
