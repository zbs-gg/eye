import Foundation

/// One continuous activity scene in a single app.
/// Sendable because it crosses SceneService, SceneStore, and SwiftUI boundaries.
struct ActivityScene: Sendable, Identifiable {
    let id: String
    /// Exact database rows belonging to this Scene. Equal-time A/B/A captures
    /// can form separate sessions even when both A rows share an app identity.
    let captureIds: Set<Int64>
    let appId: Int64?
    let bundleId: String?
    let appName: String?
    let repWindowTitle: String?
    let browserURL: String?
    let startTs: Date
    let endTs: Date
    let durationSec: Double
    let frameCount: Int
    let summary: String
    let isSystem: Bool
    /// Existing image closest to the middle of this scene. The path remains
    /// relative to Eye's media root so storage relocation keeps working.
    let representativeCaptureID: Int64?
    let representativeVisualPath: String?

    init(
        id: String,
        captureIds: Set<Int64>,
        appId: Int64?,
        bundleId: String?,
        appName: String?,
        repWindowTitle: String?,
        browserURL: String?,
        startTs: Date,
        endTs: Date,
        durationSec: Double,
        frameCount: Int,
        summary: String,
        isSystem: Bool,
        representativeCaptureID: Int64? = nil,
        representativeVisualPath: String? = nil
    ) {
        self.id = id
        self.captureIds = captureIds
        self.appId = appId
        self.bundleId = bundleId
        self.appName = appName
        self.repWindowTitle = repWindowTitle
        self.browserURL = browserURL
        self.startTs = startTs
        self.endTs = endTs
        self.durationSec = durationSec
        self.frameCount = frameCount
        self.summary = summary
        self.isSystem = isSystem
        self.representativeCaptureID = representativeCaptureID
        self.representativeVisualPath = representativeVisualPath
    }
}
