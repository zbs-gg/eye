import Foundation

/// One continuous activity scene in a single app.
/// Sendable because it crosses SceneService, SceneStore, and SwiftUI boundaries.
struct ActivityScene: Sendable, Identifiable {
    let id: String
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
