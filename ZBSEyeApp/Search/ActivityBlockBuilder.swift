import Foundation

/// One activity BLOCK — a stretch of the day the user was plausibly doing one thing: consecutive
/// user scenes separated by < `ActivityBlockBuilder.mergeGapMs`. Built on top of already-filtered
/// scenes, so system shells (loginwindow etc.) never appear inside — they became gaps upstream.
/// Sendable: crosses SceneStore → SwiftUI.
struct ActivityBlock: Sendable, Identifiable {
    /// Per-app aggregate inside a block: display name + active seconds (desc by seconds).
    struct AppShare: Sendable, Identifiable {
        let name: String
        let bundleId: String?
        let seconds: Double
        var id: String { name }
    }

    let id: String                   // "block-<startMs>" — stable key for ForEach
    let startTs: Date
    let endTs: Date
    let scenes: [ActivityScene]      // underlying app sessions, ts ASC (non-empty)
    let topApps: [AppShare]          // by active-time share, desc
    let heuristicLabel: String       // dominant app + dominant topic — always available, no LLM

    var durationSec: Double { scenes.reduce(0) { $0 + $1.durationSec } }
    var frameCount: Int { scenes.reduce(0) { $0 + $1.frameCount } }
    /// "Xcode, Chrome, Finder" — for the collapsed block header.
    var topAppsLine: String { topApps.prefix(3).map(\.name).joined(separator: ", ") }

    /// The longest visual scene from the dominant app best represents the
    /// block. If that app has no retained image, use the longest visual scene
    /// in the block rather than showing an unrelated future frame.
    var representativeVisualScene: ActivityScene? {
        let visualScenes = scenes.filter { scene in
            guard let path = scene.representativeVisualPath else { return false }
            return !path.isEmpty && path != "imported"
        }
        guard !visualScenes.isEmpty else { return nil }
        if let dominant = topApps.first {
            let fromDominantApp = visualScenes.filter {
                ($0.appName ?? $0.bundleId ?? "App") == dominant.name
            }
            if let scene = Self.longestScene(fromDominantApp) { return scene }
        }
        return Self.longestScene(visualScenes)
    }

    var representativeVisualPath: String? {
        representativeVisualScene?.representativeVisualPath
    }

    private static func longestScene(_ candidates: [ActivityScene]) -> ActivityScene? {
        candidates.sorted { lhs, rhs in
            if lhs.durationSec != rhs.durationSec { return lhs.durationSec > rhs.durationSec }
            if lhs.startTs != rhs.startTs { return lhs.startTs < rhs.startTs }
            return lhs.id < rhs.id
        }.first
    }
}

/// Pure scenes → blocks assembly (no DB, independently testable). Reuses the existing labeling
/// infrastructure: browser host attribution (`hostFromURL`) and title cleanup (`cleanPageTitle`)
/// from DayActivityRepository — the same rules Daily Insights / usage stats already follow.
enum ActivityBlockBuilder {
    /// Consecutive scenes closer than this merge into one block. The single tuning point:
    /// 15 min ≈ "still the same stretch of work" (a coffee break doesn't split the block).
    static let mergeGapMs: Int64 = 15 * 60 * 1000

    /// Merge consecutive non-system scenes into blocks. Input is assumed ts ASC (SceneService order).
    static func blocks(from scenes: [ActivityScene]) -> [ActivityBlock] {
        let user = scenes.filter { !$0.isSystem }   // defensive: blocks never contain system shells
        guard !user.isEmpty else { return [] }
        var out: [ActivityBlock] = []
        var bucket: [ActivityScene] = [user[0]]
        for scene in user.dropFirst() {
            let gapMs = msFromDate(scene.startTs) - msFromDate(bucket[bucket.count - 1].endTs)
            if gapMs < mergeGapMs {
                bucket.append(scene)
            } else {
                out.append(build(bucket))
                bucket = [scene]
            }
        }
        out.append(build(bucket))
        return out
    }

    // MARK: - assembly

    private static func build(_ scenes: [ActivityScene]) -> ActivityBlock {
        let start = scenes[0].startTs
        let end = scenes.map(\.endTs).max() ?? scenes[scenes.count - 1].endTs
        let topApps = appShares(scenes)
        return ActivityBlock(
            id: "block-\(msFromDate(start))",
            startTs: start, endTs: end,
            scenes: scenes, topApps: topApps,
            heuristicLabel: heuristicLabel(scenes: scenes, topApps: topApps))
    }

    /// Active seconds per app (scene durations already exclude long gaps), desc by time.
    private static func appShares(_ scenes: [ActivityScene]) -> [ActivityBlock.AppShare] {
        var seconds: [String: Double] = [:]
        var bundleIds: [String: String] = [:]
        for s in scenes {
            let name = s.appName ?? s.bundleId ?? "App"
            seconds[name, default: 0] += s.durationSec
            if let bid = s.bundleId, bundleIds[name] == nil { bundleIds[name] = bid }
        }
        return seconds.sorted { $0.value > $1.value }.map {
            ActivityBlock.AppShare(name: $0.key, bundleId: bundleIds[$0.key], seconds: $0.value)
        }
    }

    /// "Xcode · ZBSEye" — dominant app + dominant topic. Topic comes from the dominant app's longest
    /// scene: browser host when there's a URL, cleaned window/tab title otherwise (same attribution
    /// rules as the rest of the app).
    private static func heuristicLabel(scenes: [ActivityScene], topApps: [ActivityBlock.AppShare]) -> String {
        guard let dominant = topApps.first else { return "Activity" }
        let dominantScenes = scenes.filter { ($0.appName ?? $0.bundleId ?? "App") == dominant.name }
        let longest = dominantScenes.max { $0.durationSec < $1.durationSec }
        if let t = longest.flatMap(topic(of:)) { return "\(dominant.name) · \(t)" }
        return dominant.name
    }

    /// Dominant topic of a scene: URL host > cleaned window title. nil when neither says anything.
    static func topic(of scene: ActivityScene) -> String? {
        if let url = scene.browserURL, let host = DayActivityRepository.hostFromURL(url) { return host }
        if let title = scene.repWindowTitle, !title.isEmpty, title != scene.appName {
            let clean = DayActivityRepository.cleanPageTitle(title)
            if !clean.isEmpty { return clean }
        }
        return nil
    }
}
