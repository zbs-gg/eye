import Foundation

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

/// Сегментирует `screen_captures` в сцены на лету (без миграции схемы). Выборку/сегментацию/батч-текст
/// делегирует общему DayActivityRepository — здесь только доменная сборка сцены + эвристическое саммари.
/// Actor: только db-read (через repo), не writer.
actor SceneService {
    private let repo: DayActivityRepository

    /// Разрыв без кадров > порога = граница сцены. 3 минуты (180 с) по заданию.
    private let gapMs: Int64 = 180 * 1000

    init(repo: DayActivityRepository) { self.repo = repo }

    /// Список сцен за один календарный день. `day` — любое время внутри нужного дня.
    func scenes(forDay day: Date) async throws -> [ActivityScene] {
        let caps = try await repo.captures(forDay: day)
        return try await build(from: caps)
    }

    /// Список сцен в произвольном диапазоне.
    func scenes(from: Date, to: Date) async throws -> [ActivityScene] {
        let caps = try await repo.captures(fromMs: msFromDate(from), toMs: msFromDate(to))
        return try await build(from: caps)
    }

    /// Сцена, в которую попадает момент времени (для правой панели таймлайна).
    /// Расширенное окно (±90 мин) + ТОЧНОЕ содержание: возвращаем сцену, только если её диапазон реально
    /// накрывает `time`. Курсор в «дыре» (нет активности) → nil (UI покажет RAW). Без fallback-«ближайшей»
    /// (ревью Pro #4 — кадр чужой сцены не должен подменять текущий).
    func scene(containing time: Date) async throws -> ActivityScene? {
        let window: TimeInterval = 90 * 60
        let timeMs = msFromDate(time)
        let caps = try await repo.captures(fromMs: msFromDate(time.addingTimeInterval(-window)),
                                           toMs: msFromDate(time.addingTimeInterval(window)))
        guard !caps.isEmpty else { return nil }
        let sessions = DayActivityRepository.sessions(caps, grouping: .appOnly, gapMs: gapMs)
        guard let seg = sessions.first(where: { $0.startMs <= timeMs && $0.endMs >= timeMs }) else { return nil }
        let text = try await repo.batchText(captureIds: [seg.rep.id])
        return Self.buildScene(seg, repText: text[seg.rep.id] ?? "")
    }

    // MARK: - сборка

    /// Сегментирует кадры в сцены (app-only) и строит ActivityScene. Текст для саммари — ОДНИМ батч-
    /// запросом по репрезентативным кадрам всех сцен (без N+1, ревью Pro #7).
    private func build(from caps: [CaptureLite]) async throws -> [ActivityScene] {
        guard !caps.isEmpty else { return [] }
        let sessions = DayActivityRepository.sessions(caps, grouping: .appOnly, gapMs: gapMs)
        let repIds = sessions.map { $0.rep.id }
        let textByCapture = try await repo.batchText(captureIds: repIds)
        return sessions.map { Self.buildScene($0, repText: textByCapture[$0.rep.id] ?? "") }
    }

    private static func buildScene(_ seg: ActivitySession, repText: String) -> ActivityScene {
        let first = seg.first, rep = seg.rep
        let repTitle = rep.windowTitle ?? first.windowTitle
        let repURL = rep.browserUrl ?? first.browserUrl
        let summary = buildSummary(appName: first.appName, bundleId: first.bundleId,
                                   windowTitle: repTitle, browserURL: repURL, repText: repText)
        let sceneId = "\(first.appId.map(String.init) ?? "noapp")-\(first.ts)"
        return ActivityScene(
            id: sceneId, appId: first.appId, bundleId: first.bundleId, appName: first.appName,
            repWindowTitle: repTitle, browserURL: repURL,
            startTs: dateFromMs(seg.startMs), endTs: dateFromMs(seg.endMs),
            durationSec: max(1, Double(seg.durationMs) / 1000.0),
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
