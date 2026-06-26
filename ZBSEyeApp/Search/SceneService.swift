import Foundation
import GRDB
import AppKit

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

    /// Список сцен за один календарный день. `day` — любое время внутри нужного дня.
    func scenes(forDay day: Date) async throws -> [ActivityScene] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return try await scenes(from: start, to: end)
    }

    /// Список сцен в произвольном диапазоне.
    func scenes(from: Date, to: Date) async throws -> [ActivityScene] {
        let fromMs = msFromDate(from)
        let toMs = msFromDate(to)

        // Читаем сырые строки: ts, appId, windowTitle, browserUrl + имя приложения + склеенный текст.
        // Отдельный запрос для текста не делаем — кешируем per-capture только для репрезентативных кадров.
        struct RawRow: Sendable {
            let captureId: Int64
            let ts: Int64
            let appId: Int64?
            let bundleId: String?
            let appName: String?
            let windowTitle: String?
            let browserUrl: String?
        }

        let rows: [RawRow] = try await db.pool.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT c.id AS cid, c.ts AS ts, c.appId AS appId,
                       a.bundleId AS bundleId, a.name AS appName,
                       c.windowTitle AS windowTitle, c.browserUrl AS browserUrl
                FROM screen_captures c
                LEFT JOIN apps a ON a.id = c.appId
                WHERE c.ts BETWEEN ? AND ?
                ORDER BY c.ts ASC, c.id ASC
                """, arguments: [fromMs, toMs]).map { row in
                RawRow(
                    captureId: row["cid"],
                    ts: row["ts"],
                    appId: row["appId"],
                    bundleId: row["bundleId"],
                    appName: row["appName"],
                    windowTitle: row["windowTitle"],
                    browserUrl: row["browserUrl"]
                )
            }
        }

        guard !rows.isEmpty else { return [] }

        // Сегментация: новая сцена при смене appId ИЛИ разрыве > gapThreshold.
        struct SceneAccumulator {
            var rows: [RawRow]
        }
        var accumulators: [SceneAccumulator] = []
        var current = SceneAccumulator(rows: [rows[0]])

        for row in rows.dropFirst() {
            let prev = current.rows.last!
            let gapSec = Double(row.ts - prev.ts) / 1000.0
            let sameApp = row.appId == prev.appId

            if sameApp && gapSec <= gapThreshold {
                current.rows.append(row)
            } else {
                accumulators.append(current)
                current = SceneAccumulator(rows: [row])
            }
        }
        accumulators.append(current)

        // Строим Scene для каждого аккумулятора.
        var scenes: [ActivityScene] = []
        for acc in accumulators {
            guard let first = acc.rows.first, let last = acc.rows.last else { continue }
            let startDate = dateFromMs(first.ts)
            let endDate = dateFromMs(last.ts)
            let durationSec = max(1, Double(last.ts - first.ts) / 1000.0)

            // Репрезентативный кадр — середина по индексу.
            let repRow = acc.rows[acc.rows.count / 2]
            let repTitle = repRow.windowTitle ?? first.windowTitle
            let repURL = repRow.browserUrl ?? first.browserUrl

            // Саммари: эвристика без LLM — appName + windowTitle + топ-фраз из text_blocks.
            let captureIds = acc.rows.map(\.captureId)
            let summary = try await buildSummary(
                captureIds: captureIds,
                appName: first.appName,
                bundleId: first.bundleId,
                windowTitle: repTitle,
                browserURL: repURL
            )

            let sceneId = "\(first.appId.map(String.init) ?? "noapp")-\(first.ts)"
            scenes.append(ActivityScene(
                id: sceneId,
                appId: first.appId,
                bundleId: first.bundleId,
                appName: first.appName,
                repWindowTitle: repTitle,
                browserURL: repURL,
                startTs: startDate,
                endTs: endDate,
                durationSec: durationSec,
                frameCount: acc.rows.count,
                summary: summary
            ))
        }

        return scenes
    }

    /// Сцена, в которую попадает момент времени (для правой панели таймлайна).
    /// Берёт окно ±5 минут от момента, сегментирует, возвращает сцену с cursor внутри.
    func scene(containing time: Date) async throws -> ActivityScene? {
        let window: TimeInterval = 5 * 60
        let from = time.addingTimeInterval(-window)
        let to = time.addingTimeInterval(window)
        let candidates = try await scenes(from: from, to: to)
        // Выбираем сцену, внутри которой лежит time.
        return candidates.first { $0.startTs <= time && $0.endTs >= time.addingTimeInterval(-1) }
            ?? candidates.last   // fallback — ближайшая предшествующая
    }

    // MARK: - эвристическое саммари (без LLM)

    private func buildSummary(
        captureIds: [Int64],
        appName: String?,
        bundleId: String?,
        windowTitle: String?,
        browserURL: String?
    ) async throws -> String {
        // Заголовок: appName (или bundleId без префикса «com.apple.»).
        var parts: [String] = []

        let app = appName ?? bundleId.map { cleanBundleId($0) } ?? "Приложение"
        parts.append(app)

        if let url = browserURL, !url.isEmpty, let host = URL(string: url)?.host {
            parts.append(host)
        } else if let title = windowTitle, !title.isEmpty, title != app {
            parts.append(title)
        }

        // Топ-фразы из text_blocks: берём репрезентативный кадр (середина диапазона).
        // Не тянем text для всех N кадров — только один, чтобы не грузить БД.
        if captureIds.count > 0 {
            let repId = captureIds[captureIds.count / 2]
            let phrases = try await topPhrases(captureId: repId, maxPhrases: 3)
            if !phrases.isEmpty {
                parts.append("— \(phrases.joined(separator: ", "))")
            }
        }

        return parts.joined(separator: " · ")
    }

    /// Извлекаем топ-N осмысленных фраз из text_blocks одного кадра.
    /// Фильтруем мусор: меню-слова (Файл, Правка, Вид, Edit, File, View…), однобуквенные токены.
    private func topPhrases(captureId: Int64, maxPhrases: Int) async throws -> [String] {
        let raw = try await db.pool.read { dbc in
            try String.fetchOne(dbc, sql:
                "SELECT group_concat(text, ' ') FROM text_blocks WHERE captureId = ?",
                arguments: [captureId]) ?? ""
        }
        guard !raw.isEmpty else { return [] }

        let menuNoise: Set<String> = [
            "файл", "правка", "вид", "формат", "окно", "помощь", "справка", "инструменты",
            "file", "edit", "view", "format", "window", "help", "tools", "insert",
            "выбрать всё", "отменить", "копировать", "вставить",
            "undo", "redo", "copy", "paste", "select", "all",
        ]

        // Делим на токены по пробелам/переносам, фильтруем, дедуплицируем.
        let tokens = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { word in
                guard word.count >= 3 else { return false }
                return !menuNoise.contains(word.lowercased())
            }

        // Считаем частоту.
        var freq: [String: Int] = [:]
        for t in tokens { freq[t, default: 0] += 1 }

        let sorted = freq.sorted { $0.value > $1.value }.prefix(maxPhrases).map(\.key)
        return Array(sorted)
    }

    private func cleanBundleId(_ bundleId: String) -> String {
        // "com.apple.Safari" → "Safari", "com.github.atom" → "atom"
        if let last = bundleId.components(separatedBy: ".").last, last.count > 1 {
            return last.prefix(1).uppercased() + last.dropFirst()
        }
        return bundleId
    }
}
