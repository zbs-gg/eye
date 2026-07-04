import Foundation
import Darwin   // kill(2)/SIGKILL + POSIX read(2)/errno — enforce timeouts and drain pipes without blocking

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
/// Concurrency discipline: EVERY blocking `Process`/`waitUntilExit()` here runs on a dedicated
/// DispatchQueue — NEVER on Swift's cooperative pool (a slow login profile like nvm/conda would otherwise
/// stall an actor thread) — and each spawn is time-bounded so a wedged child can't hang the caller.
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

/// A tiny thread-safe box carrying a child's PID out to a timeout task, so it can SIGKILL a runaway
/// process without sharing the non-Sendable `Process` across concurrency domains. Shared by the locator
/// probes and the main runner.
private final class ProcessPIDBox: @unchecked Sendable {
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

/// A lock-guarded `Data` box so stdout and stderr can be drained on parallel queues: a `FileHandle` isn't
/// Sendable, so only the resulting `Data` crosses back (after a `DispatchGroup` join).
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Read a file descriptor to EOF with raw POSIX reads. An fd (`Int32`) is Sendable — a `FileHandle` is not
/// — so this is what lets stdout and stderr be drained on parallel queues under strict concurrency.
private func drainFD(_ fd: Int32) -> Data {
    var out = Data()
    let cap = 64 * 1024
    var buf = [UInt8](repeating: 0, count: cap)
    while true {
        let n = read(fd, &buf, cap)
        if n > 0 {
            out.append(contentsOf: buf[0..<n])
        } else if n == -1 && errno == EINTR {
            continue                       // interrupted syscall — retry, don't lose the tail
        } else {
            break                          // 0 = EOF; any other <0 = error → stop
        }
    }
    return out
}

/// Resolves & caches the `claude` binary path process-wide. An `actor`, so the state is serialized — but
/// the actual blocking discovery (a login shell, a `--help` probe) is dispatched OFF the cooperative pool.
actor ClaudeCodeLocator {
    static let shared = ClaudeCodeLocator()

    private var cachedPath: String?
    private var cachedSupportsAppendSystem: Bool?

    /// Absolute path to `claude`, or nil if it isn't installed / on PATH. Cached after the first success;
    /// a miss is not cached, so a later `resolve()` re-checks (the user may install the CLI while open).
    func resolve() async -> String? {
        if let cachedPath { return cachedPath }
        // Fast path: stat well-known absolute locations (cheap, non-blocking). No Process spawned here.
        let fm = FileManager.default
        for c in ClaudeCodeCLI.candidatePaths() where fm.isExecutableFile(atPath: c) {
            cachedPath = c
            return c
        }
        // Fallback needs a login shell — a BLOCKING Process. Run it off the cooperative pool, time-bounded.
        guard let p = await Self.loginShellLookup() else { return nil }
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
        let ok = await Self.helpMentionsAppendSystemPrompt(path)
        cachedSupportsAppendSystem = ok
        return ok
    }

    // MARK: discovery (every blocking Process runs OFF the cooperative pool, each time-bounded)

    private static func loginShellLookup() async -> String? {
        guard let data = await runProbe(executable: "/bin/zsh",
                                        arguments: ["-lc", "command -v claude"]) else { return nil }
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (!path.isEmpty && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }

    private static func helpMentionsAppendSystemPrompt(_ path: String) async -> Bool {
        guard let data = await runProbe(executable: path, arguments: ["--help"]) else { return false }
        return (String(data: data, encoding: .utf8) ?? "").contains("--append-system-prompt")
    }

    /// Spawn a short-lived probe on a DEDICATED global queue (NEVER the cooperative pool), capture stdout,
    /// discard stderr (login-profile noise), and enforce a hard timeout via SIGKILL. Returns nil on spawn
    /// failure or timeout — a wedged login profile can hang the child, but none of our threads.
    private static func runProbe(executable: String, arguments: [String],
                                 timeout: TimeInterval = 5) async -> Data? {
        let box = ProcessPIDBox()
        return await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let proc = Process()
                        proc.executableURL = URL(fileURLWithPath: executable)
                        proc.arguments = arguments
                        // Keep the parent environment (HOME etc.) so the CLI/shell resolve as expected.
                        proc.environment = ProcessInfo.processInfo.environment
                        let out = Pipe()
                        proc.standardOutput = out
                        proc.standardError = FileHandle.nullDevice   // drop profile/stderr noise
                        proc.standardInput = FileHandle.nullDevice   // never let the child block on stdin
                        do { try proc.run() } catch { cont.resume(returning: nil); return }
                        box.set(proc.processIdentifier)
                        let data = out.fileHandleForReading.readDataToEndOfFile()
                        proc.waitUntilExit()
                        box.markFinished()
                        cont.resume(returning: data)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeout) * 1_000_000_000))
                box.killIfRunning()   // SIGKILL → the reader hits EOF and the worker resumes with what it has
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            box.killIfRunning()       // whichever task lost the race, make sure no child is left running
            return first
        }
    }
}

/// Spawns the `claude` CLI, feeds the prompt on stdin, returns raw stdout — with a hard timeout.
enum ClaudeCodeRunner {

    /// Run `claude` with `args`, writing `stdin` to the child, and return its stdout `Data`.
    /// Throws `AutomationError.llm` on spawn failure, a non-zero exit (stderr snippet), or timeout.
    static func run(path: String, args: [String], stdin: String, timeout: TimeInterval) async throws -> Data {
        let box = ProcessPIDBox()
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
                        // Drain stdout AND stderr CONCURRENTLY. Reading them in sequence deadlocks a child
                        // that fills the (~64KB) stderr pipe while still writing stdout: it blocks on the
                        // stderr write, never closes stdout, and our stdout read then waits forever (until
                        // the timeout SIGKILL). Read the raw fds on parallel queues (an fd is Sendable; a
                        // FileHandle is not), then join before reaping the process.
                        let outFD = outPipe.fileHandleForReading.fileDescriptor
                        let errFD = errPipe.fileHandleForReading.fileDescriptor
                        let errBox = DataBox()
                        let drain = DispatchGroup()
                        drain.enter()
                        DispatchQueue.global(qos: .userInitiated).async {
                            errBox.set(drainFD(errFD))
                            drain.leave()
                        }
                        let outData = drainFD(outFD)
                        drain.wait()
                        let errData = errBox.get()
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
                box.killIfRunning()   // SIGKILL → the readers hit EOF and the worker task unwinds
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
