import Foundation
import Darwin   // kill(2)/SIGKILL — enforce the request timeout by killing a runaway CLI subprocess

/// The "use your own Claude Code" provider: instead of pasting an API key, ZBS Eye runs the user's
/// already-authenticated `claude` CLI locally as a subprocess (`claude -p --output-format json`).
///
/// Two responsibilities live here so LLMClient stays focused on HTTP:
///  • `ClaudeCodeLocator` — resolve & cache the absolute path to the `claude` binary. A GUI app does NOT
///    inherit the login-shell PATH, so we probe well-known install locations first, then fall back to a
///    login shell's `command -v`. It also checks (once, via `claude --help`) whether the installed CLI
///    accepts `--append-system-prompt`, so we can degrade to prepending the system text if it doesn't.
///  • `ClaudeCodeRunner` — spawn the process off the main actor, feed the prompt on stdin (never argv, so
///    no arg-length limit and nothing leaks into the process table), read stdout to completion, and
///    enforce a hard timeout by SIGKILLing the child. The prompt and the answer are NEVER logged.
///
/// The subprocess egresses to Anthropic via the user's Claude Code login — so the provider still sits
/// behind the same cloud-consent gate as OpenRouter/Anthropic/OpenAI (see AIProvider.isCloud).
enum ClaudeCodeCLI {
    /// Well-known absolute locations to probe before falling back to a login shell.
    static func candidatePaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            home + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
    }
}

/// Resolves & caches the `claude` binary path process-wide. An `actor`, so the (blocking) discovery
/// runs off the main actor and is serialized — no duplicate shell-outs across concurrent probes.
actor ClaudeCodeLocator {
    static let shared = ClaudeCodeLocator()

    private var cachedPath: String?
    private var cachedSupportsAppendSystem: Bool?

    /// Absolute path to `claude`, or nil if it isn't installed / on PATH. Cached after the first success;
    /// a miss is not cached, so a later `resolve()` re-checks (the user may install the CLI while open).
    func resolve() async -> String? {
        if let cachedPath { return cachedPath }
        guard let p = Self.discover() else { return nil }
        cachedPath = p
        return p
    }

    /// Drop the caches so the next `resolve()` re-discovers (e.g. the user just installed the CLI).
    func refresh() async {
        cachedPath = nil
        cachedSupportsAppendSystem = nil
    }

    /// Whether the installed CLI accepts `--append-system-prompt` (verified once against `claude --help`).
    /// Falls back to `false` (⇒ caller prepends the system text) if the CLI is missing or help is unreadable.
    func supportsAppendSystemPrompt() async -> Bool {
        if let cachedSupportsAppendSystem { return cachedSupportsAppendSystem }
        guard let path = await resolve() else { return false }
        let ok = Self.helpMentionsAppendSystemPrompt(path)
        cachedSupportsAppendSystem = ok
        return ok
    }

    // MARK: discovery (synchronous; runs on the actor's executor, off the main actor)

    private static func discover() -> String? {
        let fm = FileManager.default
        for c in ClaudeCodeCLI.candidatePaths() where fm.isExecutableFile(atPath: c) { return c }
        // Fallback: a login shell sources the user's profile → the full PATH a GUI app never inherits.
        return loginShellLookup()
    }

    private static func loginShellLookup() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (!path.isEmpty && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }

    private static func helpMentionsAppendSystemPrompt(_ path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--help"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        do { try proc.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.contains("--append-system-prompt")
    }
}

/// Spawns the `claude` CLI, feeds the prompt on stdin, returns raw stdout — with a hard timeout.
enum ClaudeCodeRunner {

    /// A tiny thread-safe box carrying the child's PID out to the timeout task, so it can SIGKILL a
    /// runaway process without sharing the non-Sendable `Process` across concurrency domains.
    private final class PIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: Int32?
        private var finished = false
        func set(_ p: Int32) { lock.lock(); pid = p; lock.unlock() }
        func markFinished() { lock.lock(); finished = true; lock.unlock() }
        func killIfRunning() {
            lock.lock(); defer { lock.unlock() }
            if !finished, let pid { kill(pid, SIGKILL) }
        }
    }

    /// Run `claude` with `args`, writing `stdin` to the child, and return its stdout `Data`.
    /// Throws `AutomationError.llm` on spawn failure, a non-zero exit (stderr snippet), or timeout.
    static func run(path: String, args: [String], stdin: String, timeout: TimeInterval) async throws -> Data {
        let box = PIDBox()
        let safeTimeout = max(1, timeout)
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let proc = Process()
                        proc.executableURL = URL(fileURLWithPath: path)
                        proc.arguments = args
                        // Keep the parent environment (HOME etc.) so the CLI finds its own credentials.
                        proc.environment = ProcessInfo.processInfo.environment
                        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
                        proc.standardInput = inPipe
                        proc.standardOutput = outPipe
                        proc.standardError = errPipe
                        do {
                            try proc.run()
                        } catch {
                            cont.resume(throwing: AutomationError.llm("couldn't start Claude Code"))
                            return
                        }
                        box.set(proc.processIdentifier)
                        // Prompt → stdin (never argv): no arg-length limit, nothing in the process table.
                        let wh = inPipe.fileHandleForWriting
                        wh.write(Data(stdin.utf8))
                        try? wh.close()
                        // Read stdout/stderr fully BEFORE waitUntilExit — avoids a full-pipe deadlock.
                        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        proc.waitUntilExit()
                        box.markFinished()
                        let status = proc.terminationStatus
                        guard status == 0 else {
                            let msg = String(data: errData, encoding: .utf8)?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            cont.resume(throwing: AutomationError.llm(
                                msg.isEmpty ? "Claude Code exited with status \(status)"
                                            : "Claude Code: \(String(msg.prefix(200)))"))
                            return
                        }
                        cont.resume(returning: outData)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(safeTimeout * 1_000_000_000))
                box.killIfRunning()   // SIGKILL → the reader hits EOF and the worker task unwinds
                throw AutomationError.llm("Claude Code timed out")
            }
            defer { group.cancelAll() }
            do {
                let result = try await group.next()!
                return result
            } catch {
                box.killIfRunning()   // never leave an orphaned CLI behind if the group threw
                throw error
            }
        }
    }
}
