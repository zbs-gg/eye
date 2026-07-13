import Foundation

enum MCPAccessProfile: String, Sendable, Equatable {
    case memoryReadOnly
    case advancedFull

    var cliArgument: String {
        switch self {
        case .memoryReadOnly: "--mcp"
        case .advancedFull: "--mcp-full"
        }
    }
}

/// One allowlist governs both discovery and dispatch. Hiding a tool from
/// `tools/list` alone is not an authorization boundary because a client can
/// still call a known tool name directly.
enum MCPToolPolicy {
    private static let memoryReadOnlyTools = [
        "search_history",
        "get_transcript",
        "get_context_at",
        "get_timeline",
        "get_status",
        "get_diagnostics",
    ]
    private static let advancedTools = [
        "get_frame_image",
        "toggle_recording",
    ]

    static func toolNames(for profile: MCPAccessProfile) -> [String] {
        switch profile {
        case .memoryReadOnly:
            memoryReadOnlyTools
        case .advancedFull:
            memoryReadOnlyTools + advancedTools
        }
    }

    static func allows(_ toolName: String, profile: MCPAccessProfile) -> Bool {
        toolNames(for: profile).contains(toolName)
    }
}
