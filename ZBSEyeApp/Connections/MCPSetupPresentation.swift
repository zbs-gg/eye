import Foundation

enum MCPSetupPresentationError: Error, Equatable {
    case invalidExecutableURL
}

struct MCPSetupPresentation: Sendable, Equatable {
    let installedPath: String
    let codexCommand: String
    let claudeJSON: String
    let accessSummary: String
    let statusLabel: String
    let restartInstruction: String

    init(executableURL: URL, profile: MCPAccessProfile) throws {
        guard executableURL.isFileURL,
              !executableURL.path.isEmpty,
              !executableURL.path.contains("\0"),
              !executableURL.absoluteString.localizedCaseInsensitiveContains("%00") else {
            throw MCPSetupPresentationError.invalidExecutableURL
        }

        installedPath = executableURL.path
        codexCommand = [
            "codex mcp add zbs-eye --",
            Self.shellQuote(executableURL.path),
            profile.cliArgument,
        ].joined(separator: " ")
        claudeJSON = try Self.makeClaudeJSON(
            executablePath: executableURL.path,
            argument: profile.cliArgument
        )
        switch profile {
        case .memoryReadOnly:
            accessSummary = "Reads local Timeline text, transcripts, and status. It cannot receive screenshot images or control recording."
        case .advancedFull:
            accessSummary = "Also allows screenshot image access and recording control. Use only with an agent you trust."
        }
        statusLabel = "Ready to connect"
        restartInstruction = "Restart Codex or Claude after adding this connection or updating ZBS Eye."
    }

    private struct ClaudeServer: Encodable {
        let command: String
        let args: [String]
    }

    private struct ClaudeConfiguration: Encodable {
        let mcpServers: [String: ClaudeServer]
    }

    private static func makeClaudeJSON(
        executablePath: String,
        argument: String
    ) throws -> String {
        let configuration = ClaudeConfiguration(
            mcpServers: [
                "zbs-eye": ClaudeServer(
                    command: executablePath,
                    args: [argument]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(configuration), as: UTF8.self)
    }

    /// POSIX single-quote escaping. The path remains one literal argv value even
    /// when it contains spaces, quotes, semicolons, or command-substitution text.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
