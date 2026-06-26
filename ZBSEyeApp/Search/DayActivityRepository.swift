import Foundation
import GRDB

/// Лёгкая строка кадра для агрегации активности дня (без текста). Sendable — ходит из actor наружу.
struct CaptureLite: Sendable {
    let id: Int64
    let ts: Int64
    let appId: Int64?
    let appName: String?
    let bundleId: String?
    let windowTitle: String?
    let browserUrl: String?
}

/// Одна сессия активности: подряд идущие кадры одной группы (app или app+window) с допуском на паузу.
/// Держит сами кадры (не только id) — потребитель берёт first/last/rep по месту.
struct ActivitySession: Sendable {
    let captures: [CaptureLite]            // непустой, ts ASC
    var first: CaptureLite { captures[0] }
    var last: CaptureLite { captures[captures.count - 1] }
    var rep: CaptureLite { captures[captures.count / 2] }   // репрезентативный — середина по индексу
    var count: Int { captures.count }
    var startMs: Int64 { first.ts }
    var endMs: Int64 { last.ts }
    var durationMs: Int64 { last.ts - first.ts }
    var appId: Int64? { first.appId }
    var captureIds: [Int64] { captures.map(\.id) }
}

/// Как группировать кадры в сессии.
enum SessionGrouping: Sendable {
    case appOnly        // сцена = одно приложение (Scenes; окно может меняться внутри)
    case appAndWindow   // сессия = приложение + окно (DailySummary, Cartographer)
}

/// Общий слой агрегации активности дня: ОДИН скан кадров + чистые функции сегментации / активного
/// времени / переключений контекста + батч-текст. Дедуп логики, которая была размазана по
/// SceneService / CartographerService / DailySummaryService (ревью Pro #9). Actor: только read, не writer.
actor DayActivityRepository {
    private let db: ZBSEyeDatabase
    init(db: ZBSEyeDatabase) { self.db = db }

    // MARK: — выборка (БД)

    /// Один скан кадров диапазона (ts ASC). Лёгкие поля — без текста.
    func captures(fromMs: Int64, toMs: Int64) async throws -> [CaptureLite] {
        try await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT c.id AS id, c.ts AS ts, c.appId AS appId,
                       a.name AS appName, a.bundleId AS bundleId,
                       c.windowTitle AS windowTitle, c.browserUrl AS browserUrl
                FROM screen_captures c LEFT JOIN apps a ON a.id = c.appId
                WHERE c.ts BETWEEN ? AND ? ORDER BY c.ts ASC, c.id ASC
                """, arguments: [fromMs, toMs]).map {
                CaptureLite(id: $0["id"], ts: $0["ts"], appId: $0["appId"],
                            appName: $0["appName"], bundleId: $0["bundleId"],
                            windowTitle: $0["windowTitle"], browserUrl: $0["browserUrl"])
            }
        }
    }

    /// Кадры за один календарный день (`day` — любое время внутри).
    func captures(forDay day: Date) async throws -> [CaptureLite] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return try await captures(fromMs: msFromDate(start), toMs: msFromDate(end) - 1)
    }

    /// Текст кадров одним запросом (`group_concat` per capture) — без N+1.
    func batchText(captureIds: [Int64]) async throws -> [Int64: String] {
        let ids = Array(Set(captureIds))
        guard !ids.isEmpty else { return [:] }
        return try await db.pool.read { dbc -> [Int64: String] in
            let ph = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(dbc, sql: """
                SELECT captureId, group_concat(text, ' ') AS txt
                FROM text_blocks WHERE captureId IN (\(ph)) GROUP BY captureId
                """, arguments: StatementArguments(ids))
            var out: [Int64: String] = [:]
            for r in rows { out[r["captureId"]] = r["txt"] ?? "" }
            return out
        }
    }

    // MARK: — чистые функции (без БД, тестируемы независимо)

    /// Сегментация кадров в сессии. Новая сессия при смене группы ИЛИ разрыве > gapMs.
    static func sessions(_ caps: [CaptureLite], grouping: SessionGrouping, gapMs: Int64) -> [ActivitySession] {
        guard !caps.isEmpty else { return [] }
        func sameGroup(_ a: CaptureLite, _ b: CaptureLite) -> Bool {
            switch grouping {
            case .appOnly:      return a.appId == b.appId
            case .appAndWindow: return a.appId == b.appId && a.windowTitle == b.windowTitle
            }
        }
        var sessions: [ActivitySession] = []
        var bucket: [CaptureLite] = [caps[0]]
        for cap in caps.dropFirst() {
            let head = bucket[0]
            let last = bucket[bucket.count - 1]
            if sameGroup(cap, head) && (cap.ts - last.ts) <= gapMs {
                bucket.append(cap)
            } else {
                sessions.append(ActivitySession(captures: bucket))
                bucket = [cap]
            }
        }
        sessions.append(ActivitySession(captures: bucket))
        return sessions
    }

    /// Активное время по приложениям (ms): дельта от предыдущего кадра отдаём предыдущему приложению,
    /// cap на простой (дельта > activeGapCapMs = idle, засчитываем максимум cap). Число кадров ≠ время
    /// (интервал захвата плавает: active≈3с, idle≈60с, bursts/dedup).
    static func appActiveMs(_ caps: [CaptureLite], activeGapCapMs: Int64) -> [Int64: Int64] {
        var dur: [Int64: Int64] = [:]
        var prev: CaptureLite? = nil
        for cap in caps {
            if let p = prev, let appId = p.appId {
                dur[appId, default: 0] += min(cap.ts - p.ts, activeGapCapMs)
            }
            prev = cap
        }
        return dur
    }

    /// Смены контекста за день: соседние кадры с разным appId/windowTitle.
    static func contextSwitches(_ caps: [CaptureLite]) -> Int {
        var switches = 0, hasPrev = false
        var prevApp: Int64? = nil, prevWin: String? = nil
        for cap in caps {
            if hasPrev && (cap.appId != prevApp || cap.windowTitle != prevWin) { switches += 1 }
            prevApp = cap.appId; prevWin = cap.windowTitle; hasPrev = true
        }
        return switches
    }
}
