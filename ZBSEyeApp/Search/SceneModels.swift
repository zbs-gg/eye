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
}
