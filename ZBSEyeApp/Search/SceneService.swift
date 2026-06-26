import Foundation
import GRDB

/// Одна сцена — непрерывная активность в одном приложении без разрыва > `gapThreshold`.
/// Sendable: пересекает актор-границы (SceneService → SceneStore → SwiftUI).
struct ActivityScene: Sendable, Identifiable {
    let id: String             // "appId-startTs" — стабильный ключ для ForEach
    let appId: Int64?
    let bundleId: String?
    let appName: String?
    let repWindowTitle: String?
    let browserURL: String?
    let startTs: Date
    let endTs: Date
    let durationSec: Double
    let frameCount: Int
    let summary: String        // 1–2 строки осмысленного описания (эвристика без LLM)
}

/// Сегментирует `screen_captures` в сцены на лету (без миграции схемы).
/// Actor: только db-read, не writer — безопасно использовать параллельно с IngestService.
actor SceneService {
    private let db: ZBSEyeDatabase

    /// Разрыв без кадров > порога = граница сцены. 3 минуты (180 с) по заданию.
    private let gapThreshold: TimeInterval = 180

    init(db: ZBSEyeDatabase) { self.db = db }

    /// Сырая строка кадра для сегментации.
    private struct RawRow: Sendable {
        let captureId: Int64
        let ts: Int64
        let appId: Int64?
        let bundleId: String?
        let appName: String?
        let windowTitle: String?
        let browserUrl: String?
    }

    /// Список сцен за один календарный день. `day` — любое время внутри нужного дня.
    func scenes(forDay day: Date) async throws -> [ActivityScene] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return try await scenes(from: start, to: end)
    }

    /// Список сцен в произвольном диапазоне. Текст для саммари тянется ОДНИМ батч-запросом по
    /// репрезентативным кадрам всех сцен (а не отдельным запросом на каждую сцену — ревью Pro #7).
    func scenes(from: Date, to: Date) async throws -> [ActivityScene] {
        let fromMs = msFromDate(from)
        let toMs = msFromDate(to)

        let rows = try await fetchRows(fromMs: fromMs, toMs: toMs)
        guard !rows.isEmpty else { return [] }

        let segments = Self.segment(rows, gapThreshold: gapThreshold)
        // Репрезентативный кадр каждой сцены — середина по индексу. Текст к ним — одним запросом.
        let repIds = segments.map { $0[$0.count / 2].captureId }
        let textByCapture = try await batchRepText(captureIds: repIds)

        return segments.map { seg in
            let repId = seg[seg.count / 2].captureId
            return Self.buildScene(seg, repText: textByCapture[repId] ?? "")
        }
    }

    /// Сцена, в которую попадает момент времени (для правой панели таймлайна).
    /// Расширенное окно (±90 мин) + ТОЧНОЕ содержание: возвращаем сцену, только если её диапазон
    /// реально накрывает `time`. Если курсор в «дыре» (нет активности) — nil (UI покажет RAW).
    /// Без fallback-«ближайшей» (ревью Pro #4 — кадр чужой сцены не должен подменять текущий).
    func scene(containing time: Date) async throws -> ActivityScene? {
        let window: TimeInterval = 90 * 60
        let timeMs = msFromDate(time)
        let rows = try await fetchRows(fromMs: msFromDate(time.addingTimeInterval(-window)),
                                       toMs: msFromDate(time.addingTimeInterval(window)))
        guard !rows.isEmpty else { return nil }

        let segments = Self.segment(rows, gapThreshold: gapThreshold)
        // Точное содержание: первый кадр сцены ≤ time ≤ последний. В дыре между сценами — ни одна
        // не накрывает → nil.
        guard let seg = segments.first(where: { ($0.first?.ts ?? .max) <= timeMs
                                                 && ($0.last?.ts ?? .min) >= timeMs }) else { return nil }
        let repId = seg[seg.count / 2].captureId
        let textByCapture = try await batchRepText(captureIds: [repId])
        return Self.buildScene(seg, repText: textByCapture[repId] ?? "")
    }

    // MARK: - выборка

    private func fetchRows(fromMs: Int64, toMs: Int64) async throws -> [RawRow] {
        try await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT c.id AS cid, c.ts AS ts, c.appId AS appId,
                       a.bundleId AS bundleId, a.name AS appName,
                       c.windowTitle AS windowTitle, c.browserUrl AS browserUrl
                FROM screen_captures c
                LEFT JOIN apps a ON a.id = c.appId
                WHERE c.ts BETWEEN ? AND ?
                ORDER BY c.ts ASC, c.id ASC
                """, arguments: [fromMs, toMs]).map { row in
                RawRow(captureId: row["cid"], ts: row["ts"], appId: row["appId"],
                       bundleId: row["bundleId"], appName: row["appName"],
                       windowTitle: row["windowTitle"], browserUrl: row["browserUrl"])
            }
        }
    }

    /// Текст репрезентативных кадров — ОДНИМ запросом `WHERE captureId IN (…)` (без N+1).
    private func batchRepText(captureIds: [Int64]) async throws -> [Int64: String] {
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

    // MARK: - сегментация (чистая, без БД)

    /// Новая сцена при смене appId ИЛИ разрыве > gapThreshold.
    private static func segment(_ rows: [RawRow], gapThreshold: TimeInterval) -> [[RawRow]] {
        guard !rows.isEmpty else { return [] }
        var segments: [[RawRow]] = []
        var current: [RawRow] = [rows[0]]
        for row in rows.dropFirst() {
            let prev = current.last!
            let gapSec = Double(row.ts - prev.ts) / 1000.0
            if row.appId == prev.appId && gapSec <= gapThreshold {
                current.append(row)
            } else {
                segments.append(current)
                current = [row]
            }
        }
        segments.append(current)
        return segments
    }

    private static func buildScene(_ seg: [RawRow], repText: String) -> ActivityScene {
        let first = seg.first!, last = seg.last!
        let repRow = seg[seg.count / 2]
        let repTitle = repRow.windowTitle ?? first.windowTitle
        let repURL = repRow.browserUrl ?? first.browserUrl
        let summary = buildSummary(appName: first.appName, bundleId: first.bundleId,
                                   windowTitle: repTitle, browserURL: repURL, repText: repText)
        let sceneId = "\(first.appId.map(String.init) ?? "noapp")-\(first.ts)"
        return ActivityScene(
            id: sceneId, appId: first.appId, bundleId: first.bundleId, appName: first.appName,
            repWindowTitle: repTitle, browserURL: repURL,
            startTs: dateFromMs(first.ts), endTs: dateFromMs(last.ts),
            durationSec: max(1, Double(last.ts - first.ts) / 1000.0),
            frameCount: seg.count, summary: summary)
    }

    // MARK: - эвристическое саммари (без LLM, без БД)

    private static func buildSummary(appName: String?, bundleId: String?, windowTitle: String?,
                                     browserURL: String?, repText: String) -> String {
        var parts: [String] = []
        let app = appName ?? bundleId.map { cleanBundleId($0) } ?? "Приложение"
        parts.append(app)

        if let url = browserURL, !url.isEmpty, let host = URL(string: url)?.host {
            parts.append(host)
        } else if let title = windowTitle, !title.isEmpty, title != app {
            parts.append(title)
        }

        let phrases = topPhrases(from: repText, maxPhrases: 3)
        if !phrases.isEmpty { parts.append("— \(phrases.joined(separator: ", "))") }

        return parts.joined(separator: " · ")
    }

    /// Топ-N осмысленных фраз из склеенного текста кадра. Фильтруем меню-шум и короткие токены.
    private static func topPhrases(from raw: String, maxPhrases: Int) -> [String] {
        guard !raw.isEmpty else { return [] }
        let menuNoise: Set<String> = [
            "файл", "правка", "вид", "формат", "окно", "помощь", "справка", "инструменты",
            "file", "edit", "view", "format", "window", "help", "tools", "insert",
            "выбрать всё", "отменить", "копировать", "вставить",
            "undo", "redo", "copy", "paste", "select", "all",
        ]
        let tokens = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 3 && !menuNoise.contains($0.lowercased()) }
        var freq: [String: Int] = [:]
        for t in tokens { freq[t, default: 0] += 1 }
        return Array(freq.sorted { $0.value > $1.value }.prefix(maxPhrases).map(\.key))
    }

    private static func cleanBundleId(_ bundleId: String) -> String {
        if let last = bundleId.components(separatedBy: ".").last, last.count > 1 {
            return last.prefix(1).uppercased() + last.dropFirst()
        }
        return bundleId
    }
}
