import SwiftUI
import AppKit

/// Connections = agent access, nothing else: the local REST API and the MCP server.
/// (The processing model moved to "AI Models"; the summaries folder moved to "Automations".)
/// Everything here is copy-ready: base URL, Bearer token, curl examples, MCP config snippets —
/// paste into your agent and it can read your memory. All of it stays on 127.0.0.1.
struct ConnectionsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var revealToken = false

    var body: some View {
        Form {
            apiSection
            mcpSection
        }
        .formStyle(.grouped)
        .navigationTitle("Connections")
    }

    // MARK: — Local REST API

    /// Real values, not placeholders: the actual port the server bound and the actual Keychain token.
    private var port: Int? { env.server.activePort }
    private var portText: String { port.map(String.init) ?? "8731" }
    private var token: String { env.server.token ?? KeychainStore.apiToken() }

    private var apiSection: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                if env.server.running {
                    Label("running · port \(port ?? 0)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("not running", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                }
            }
            copyableRow(label: "Base URL", value: "http://127.0.0.1:\(portText)")
            tokenRow
            VStack(alignment: .leading, spacing: 6) {
                Text("Health check (no auth)").font(.caption).foregroundStyle(.secondary)
                CodeBlock(code: "curl http://127.0.0.1:\(portText)/health")
                Text("Search (Bearer auth)").font(.caption).foregroundStyle(.secondary)
                CodeBlock(code: "curl -H \"Authorization: Bearer \(token)\" \\\n  \"http://127.0.0.1:\(portText)/v1/search?q=meeting&limit=5\"")
            }
        } header: {
            Text("Local REST API")
        } footer: {
            Text("Agents and scripts on this Mac can read your history over HTTP. The server listens on 127.0.0.1 only; every endpoint except /health requires the Bearer token (it lives in the Keychain).")
        }
    }

    private var tokenRow: some View {
        HStack(spacing: 8) {
            Text("Bearer token")
            Spacer()
            Text(verbatim: revealToken ? token : String(repeating: "•", count: 24))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
            Button {
                revealToken.toggle()
            } label: {
                Image(systemName: revealToken ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealToken ? "Hide token" : "Reveal token")
            copyButton(token)
        }
    }

    // MARK: — MCP

    private static let mcpCommand = "\"/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye\" --mcp"

    /// The same JSON works for Claude Desktop (claude_desktop_config.json) and Cursor (~/.cursor/mcp.json).
    private static let mcpConfigJSON = """
    {
      "mcpServers": {
        "zbs-eye": {
          "command": "/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye",
          "args": ["--mcp"]
        }
      }
    }
    """

    /// Keep in sync with ZBSEyeMCPServer.toolList().
    private static let mcpTools = [
        "search_history", "get_transcript", "get_context_at", "get_timeline",
        "get_frame_image", "get_status", "get_diagnostics", "toggle_recording",
    ]

    private var mcpSection: some View {
        Section {
            Text("MCP gives AI agents (Claude Desktop, Cursor, …) tools to search and read your memory — over stdio on this Mac, no network, no token needed.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Command").font(.caption).foregroundStyle(.secondary)
                CodeBlock(code: Self.mcpCommand)
                Text("Claude Desktop — claude_desktop_config.json").font(.caption).foregroundStyle(.secondary)
                CodeBlock(code: Self.mcpConfigJSON)
                Text("Cursor — ~/.cursor/mcp.json (same JSON)").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Tools").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: Self.mcpTools.joined(separator: " · "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("MCP")
        } footer: {
            Text("The MCP server reads the same local database directly (read-only) and proxies recording control to the running app. Install the app in /Applications for the command above to match.")
        }
    }

    // MARK: — helpers

    private func copyableRow(label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer()
            Text(verbatim: value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            copyButton(value)
        }
    }

    private func copyButton(_ value: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}

/// Monospaced, selectable, copy-in-one-click code block.
private struct CodeBlock: View {
    let code: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: code)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}
