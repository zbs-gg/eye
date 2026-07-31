import Foundation

enum SettingsRoute: String, CaseIterable, Identifiable, Sendable {
    case permissions
    case ai
    case dataStorage
    case browserCapture
    case mcpTools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .permissions: String(localized: "Permissions")
        case .ai: String(localized: "AI")
        case .dataStorage: String(localized: "Data Storage")
        case .browserCapture: String(localized: "Browser Capture")
        case .mcpTools: String(localized: "MCP & AI Tools")
        }
    }

    var systemImage: String {
        switch self {
        case .permissions: "hand.raised"
        case .ai: "sparkles"
        case .dataStorage: "internaldrive"
        case .browserCapture: "globe.badge.chevron.backward"
        case .mcpTools: "point.3.connected.trianglepath.dotted"
        }
    }
}
