import Foundation

/// One scene — continuous activity in a single app with no gap > `gapThreshold`.
/// Sendable: it crosses actor boundaries (SceneService → SceneStore → SwiftUI).
struct ActivityScene: Sendable, Identifiable {
    let id: String             // "appId-startTs" — a stable key for ForEach
    let appId: Int64?
    let bundleId: String?
    let appName: String?
    let repWindowTitle: String?
    let browserURL: String?
    let startTs: Date
    let endTs: Date
    let durationSec: Double
    let frameCount: Int
    let summary: String        // 1–2 lines of a meaningful description (heuristic, no LLM)
}

/// Segments `screen_captures` into scenes on the fly (no schema migration). Fetching/segmentation/batch text
/// are delegated to the shared DayActivityRepository — here it's only the domain assembly of a scene + a heuristic summary.
/// Actor: db-read only (via repo), not a writer.
actor SceneService {
    private let repo: DayActivityRepository

    /// A gap with no frames > the threshold = a scene boundary. 3 minutes (180 s) per the spec.
    private let gapMs: Int64 = 180 * 1000

    init(repo: DayActivityRepository) { self.repo = repo }

    /// List of scenes for a single calendar day. `day` — any time within the desired day.
    func scenes(forDay day: Date) async throws -> [ActivityScene] {
        let caps = try await repo.captures(forDay: day)
        return try await build(from: caps)
    }

    /// List of scenes within an arbitrary range.
    func scenes(from: Date, to: Date) async throws -> [ActivityScene] {
        let caps = try await repo.captures(fromMs: msFromDate(from), toMs: msFromDate(to))
        return try await build(from: caps)
    }

    /// The scene that a moment in time falls into (for the timeline's right panel).
    /// Widened window (±90 min) + EXACT containment: we return a scene only if its range actually
    /// covers `time`. A cursor in a "gap" (no activity) → nil (the UI shows RAW). No fallback to "nearest"
    /// (Pro review #4 — a frame from another scene must not stand in for the current one).
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

    // MARK: - assembly

    /// Segments frames into scenes (app-only) and builds an ActivityScene. The text for the summary is fetched in
    /// ONE batch query over the representative frames of all scenes (no N+1, Pro review #7).
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

    // MARK: - heuristic summary (no LLM, no DB)

    private static func buildSummary(appName: String?, bundleId: String?, windowTitle: String?,
                                     browserURL: String?, repText: String) -> String {
        var parts: [String] = []
        let app = appName ?? bundleId.map { cleanBundleId($0) } ?? "App"
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

    /// Top-N meaningful phrases from the concatenated frame text. We filter out menu noise and short tokens.
    private static func topPhrases(from raw: String, maxPhrases: Int) -> [String] {
        guard !raw.isEmpty else { return [] }
        let menuNoise: Set<String> = [
            "file", "edit", "view", "format", "window", "help", "guide", "tools",
            "insert",
            "select all", "undo", "copy", "paste",
            "redo", "select", "all",
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
