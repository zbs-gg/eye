import SwiftUI
import AppKit

/// Self-repair: because the source is public and you have your own agent, a broken thing isn't a dead
/// end. Describe the problem → Eye collects on-device diagnostics and either copies a ready-to-run
/// repair prompt for your coding agent (read the source, reproduce, fix) or opens a pre-filled GitHub
/// issue. Reachable from a main-window toolbar button, the menu bar, and Settings. Nothing egresses.
struct SelfRepairView: View {
    @Environment(AppEnvironment.self) private var env
    /// When shown as a sheet, this dismisses it. nil when embedded (Settings).
    var onClose: (() -> Void)? = nil

    @State private var problemText = ""
    @State private var repairCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Something not working?", systemImage: "wrench.and.screwdriver")
                    .font(.title3.bold())
                Spacer()
                if let onClose { Button("Close") { onClose() } }
            }
            Text("ZBS Eye is open to read and yours to fix. Describe what's wrong — Eye collects the "
                 + "diagnostics and hands your own AI agent a ready-to-run repair prompt (it reads the "
                 + "source and fixes it). If that doesn't do it, file a GitHub issue with one click. "
                 + "Nothing leaves your machine.")
                .font(.callout).foregroundStyle(.secondary)

            TextField("What went wrong? (e.g. audio doesn't record during calls)",
                      text: $problemText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                .onChange(of: problemText) { _, _ in repairCopied = false }

            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(buildRepairPrompt(), forType: .string)
                    repairCopied = true
                } label: {
                    Label(repairCopied ? "Copied — paste into your agent" : "Ask your agent to fix it",
                          systemImage: repairCopied ? "checkmark" : "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                Button { openGitHubIssue() } label: {
                    Label("Open a GitHub issue", systemImage: "ladybug")
                }
                Spacer()
            }

            DisclosureGroup("What gets shared (nothing leaves the machine on its own)") {
                Text(diagnosticsBlock())
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
        }
        .padding(onClose == nil ? 0 : 24)
        .frame(minWidth: onClose == nil ? 0 : 460, alignment: .leading)
    }

    // MARK: — prompt / diagnostics (shared with the MCP get_diagnostics tool's intent)

    private func buildRepairPrompt() -> String {
        """
        You are my coding agent. Something isn't working in ZBS Eye — a local macOS app I run. The full \
        source is public: https://github.com/zbs-gg/eye . Please read the repo, reproduce, and fix it.

        ## What's wrong (my words)
        \(problemText.isEmpty ? "(describe the problem here)" : problemText)

        ## Diagnostics (auto-collected, on-device)
        \(diagnosticsBlock())

        ## Do this
        1. Open github.com/zbs-gg/eye — read README.md, AGENTS.md, BUILD.md (written for agents).
        2. Reproduce and fix the issue above. Keep it local-first (no cloud/egress), Swift 6 strict concurrency.
        3. Rebuild: `bash scripts/build-notarized.sh` (or `scripts/build-release.sh` for a self-signed dev build).
        4. If you can't fix it, open a GitHub issue at github.com/zbs-gg/eye/issues/new with this whole message.

        (Tip: connect ZBS Eye's MCP server — `ZBS Eye --mcp` — and call `get_diagnostics` for live state.)
        """
    }

    private func diagnosticsBlock() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let p = env.permissions.snapshot
        let rec = env.recording
        return """
        - App: ZBS Eye \(v) · \(ProcessInfo.processInfo.operatingSystemVersionString)
        - Permissions: screen=\(p.screenRecording) accessibility=\(p.accessibility) mic=\(p.microphone) speech=\(p.speech)
        - Recording: capturing=\(rec.isCapturing) blocked=\(rec.blockedReason ?? "—") degraded=\(rec.degradedReason ?? "—")
        - Audio mode: \(env.audioSettings.audioMode.rawValue) · frames this session: \(rec.screenFrameCount)
        """
    }

    private func openGitHubIssue() {
        let title = problemText.isEmpty ? "Bug report" : String(problemText.prefix(70))
        let body = "## What's wrong\n\(problemText)\n\n## Diagnostics\n\(diagnosticsBlock())"
        var comps = URLComponents(string: "https://github.com/zbs-gg/eye/issues/new")!
        comps.queryItems = [.init(name: "title", value: title), .init(name: "body", value: body)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}
