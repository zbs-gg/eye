import Foundation

struct TimelineSceneLoadKey: Equatable {
    let frameID: Int64?
    let sceneStoreReady: Bool
}

struct TimelineSceneCardPresentation {
    let bundleId: String?
    let jumpToStart: Date?
    let durationSec: Double
    let frameCount: Int
    let summary: String

    init(scene: ActivityScene) {
        bundleId = scene.bundleId
        jumpToStart = scene.startTs
        durationSec = scene.durationSec
        frameCount = scene.frameCount
        summary = scene.summary
    }

    init(frame: FrameDetail) {
        bundleId = frame.bundleId
        jumpToStart = nil
        durationSec = 0
        frameCount = 1

        let app = Self.nonEmpty(frame.appName) ?? Self.nonEmpty(frame.bundleId) ?? "Captured moment"
        if let window = Self.nonEmpty(frame.windowTitle), window != app {
            summary = "\(app) · \(window)"
        } else {
            summary = app
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Keeps asynchronous Scene lookup aligned with the exact frame currently visible.
/// A stable one-moment fallback is always available while grouping is unavailable or in flight.
struct TimelineSceneDetailState {
    private var frameID: Int64?
    private var loadedScene: ActivityScene?

    /// Returns false when an already loaded Scene safely covers this frame.
    mutating func beginLoading(for frame: FrameDetail) -> Bool {
        frameID = frame.id
        if let loadedScene, Self.matches(loadedScene, frame: frame) {
            return false
        }
        loadedScene = nil
        return true
    }

    mutating func clear() {
        frameID = nil
        loadedScene = nil
    }

    mutating func finishLoading(_ scene: ActivityScene?, forFrameID completedFrameID: Int64) {
        guard frameID == completedFrameID else { return }
        loadedScene = scene
    }

    func card(for frame: FrameDetail) -> TimelineSceneCardPresentation {
        if frameID == frame.id,
           let loadedScene,
           Self.matches(loadedScene, frame: frame) {
            return TimelineSceneCardPresentation(scene: loadedScene)
        }
        return TimelineSceneCardPresentation(frame: frame)
    }

    private static func matches(_ scene: ActivityScene, frame: FrameDetail) -> Bool {
        scene.captureIds.contains(frame.id)
            && (scene.startTs...scene.endTs).contains(frame.ts)
    }
}
