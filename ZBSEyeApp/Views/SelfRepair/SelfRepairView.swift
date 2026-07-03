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
    @State private var workspaceCopied = false

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
                .onChange(of: problemText) { _, _ in repairCopied = false; workspaceCopied = false }

            HStack(spacing: 10) {
                Button {
                    copyToPasteboard(buildRepairPrompt())
                    repairCopied = true; workspaceCopied = false
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

            // Quick fix vs full workspace: the button above copies a one-shot repair prompt; this one
            // bootstraps a persistent dev setup — clone + toolchain + the bundled .claude harness —
            // so the user's agent can fix this bug properly AND keep maintaining Eye afterwards.
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    copyToPasteboard(buildWorkspacePrompt())
                    workspaceCopied = true; repairCopied = false
                } label: {
                    Label(workspaceCopied ? "Copied — paste into your agent"
                                          : "Set up a dev workspace (for your agent)",
                          systemImage: workspaceCopied ? "checkmark" : "hammer")
                }
                // Single literal (not concatenation) so it stays a LocalizedStringKey → xcstrings.
                Text("Bigger job? This longer prompt has your agent clone the public source with a ready-made harness (build, diagnose, and review skills) — fix this bug properly, then keep improving Eye for you.")
                    .font(.caption).foregroundStyle(.secondary)
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

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

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

    /// The "own your recorder" bootstrap: unlike the quick repair prompt above, this sets up a
    /// persistent local workspace — clone, toolchain, green build — and points the agent at the
    /// harness that ships IN the repo (.claude skills/agents/workflows), so fixing this one bug
    /// turns into being able to maintain and extend Eye from now on.
    private func buildWorkspacePrompt() -> String {
        """
        You are my coding agent. I use ZBS Eye — a local, open-source macOS screen/audio memory \
        recorder — and I want to OWN it: set up a development workspace, reproduce and fix the \
        problem below, and keep the workspace so you can maintain and improve Eye for me from now \
        on. The full source is public: https://github.com/zbs-gg/eye

        ## What's wrong (my words)
        \(problemText.isEmpty ? "(describe the problem here)" : problemText)

        ## Diagnostics (auto-collected, on-device)
        \(diagnosticsBlock())

        ## Step 1 — set up the workspace
        1. Ask me which directory the project should live in (suggest one), and confirm before creating anything.
        2. `git clone https://github.com/zbs-gg/eye`
        3. Toolchain check: `xcode-select -p` must point at a full Xcode (not bare Command Line Tools); \
        `xcodegen` must be installed — `brew install xcodegen` if missing.
        4. `xcodegen generate` — ZBSEye.xcodeproj is generated from project.yml, it is NOT in git.
        5. Verify the build is green before changing anything:
           `xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Release -destination 'platform=macOS' build`
           (the CoreSimulator version warning is noise; look for BUILD SUCCEEDED and no `error:` lines).

        ## Step 2 — learn the harness (it ships in the repo)
        Read CLAUDE.md and AGENTS.md first — build rules, architecture map, invariants, known gotchas. \
        Then use the bundled agent harness instead of improvising:
        - `.claude/skills/eye-build` — build + common-failure playbook
        - `.claude/skills/eye-diagnose` — pull live state from my running Eye (MCP `get_diagnostics`, REST /health, logs, read-only DB)
        - `.claude/skills/eye-db-validate` — scratch-DB harness for any SQL/migration/trigger change
        - `.claude/skills/eye-review-loop` — branch → build green → self-review checklist → PR
        - `.claude/skills/eye-release` — notarized release pipeline
        - `.claude/agents/swift6-reviewer.md` — hostile Swift 6 / data-safety reviewer for your diffs
        - `.claude/workflows/eye-adversarial-review.js` — find→verify review workflow over a diff

        ## Step 3 — reproduce and fix
        Work on the problem above. Keep it local-first (zero egress) and Swift 6 strict-concurrency \
        clean — the review checklist covers both.

        ## HARD RULE — do not break my recording permissions (TCC)
        NEVER launch a Debug or differently-signed build over my installed app: macOS Screen \
        Recording permission is cdhash-strict, and a foreign signature silently kills my live \
        capture. Verify your fix headlessly instead (Release compile-check, scratch-DB SQL, MCP \
        stdio — CLAUDE.md shows how). When the fix is ready, I reinstall via a properly signed \
        build (`scripts/build-release.sh` or `scripts/build-notarized.sh`) myself.

        ## Before you finish
        Run the `eye-review-loop` skill (build gate + the full self-review checklist) before opening \
        a PR — and if the fix is worth sharing, open the PR against https://github.com/zbs-gg/eye so \
        everyone's Eye gets better.
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
