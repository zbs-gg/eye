import CryptoKit
import Darwin
import Foundation
import MachO
import Security

enum ClaudeCodeAdapterError: Error, Sendable, Equatable {
    case executableUnavailable
    case executableRejected
    case notAuthenticated
    case unapprovedAPIProvider
    case authorizationChanged
    case invalidSelection
    case forbiddenEvent
    case malformedOutput
    case outputTooLarge
    case processFailed
    case timedOut
    case cancelled
}

struct ClaudeCodeExecutableIdentity: Sendable, Equatable {
    let canonicalURL: URL
    let fileIdentity: ClaudeCodeFileIdentity
    let version: String
    let sha256: String
    let signingIdentifier: String
    let teamIdentifier: String
    let ownerUserID: UInt32
    let currentUserID: UInt32
    let permissions: UInt16
    let isRegularFile: Bool
    let isArm64MachO: Bool
}

struct ClaudeCodeFileIdentity: Sendable, Equatable {
    let deviceID: UInt64
    let fileID: UInt64
    let byteCount: Int64
    let mode: UInt16
    let ownerUserID: UInt32
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

enum ClaudeCodeSecurityPolicy {
    static let allowedVersion = "2.1.220"
    static let allowedSHA256 = "8addc857f3fe64d5a0368af9ee50321b50afb4a6918ba3ef018ab84f5dbbe081"
    static let signingIdentifier = "com.anthropic.claude-code"
    static let teamIdentifier = "Q6L2SF6YDW"
    static let maximumInputBytes = 2 * 1_024 * 1_024
    static let maximumOutputBytes = 2 * 1_024 * 1_024
    static let maximumErrorBytes = 64 * 1_024

    static func validate(_ identity: ClaudeCodeExecutableIdentity) throws {
        guard identity.version == allowedVersion,
              identity.sha256.lowercased() == allowedSHA256,
              identity.signingIdentifier == signingIdentifier,
              identity.teamIdentifier == teamIdentifier,
              identity.ownerUserID == identity.currentUserID,
              identity.isRegularFile,
              identity.isArm64MachO,
              identity.permissions & 0o022 == 0,
              identity.permissions & 0o100 != 0
        else { throw ClaudeCodeAdapterError.executableRejected }
    }
}

protocol ClaudeCodeExecutableVerifying: Sendable {
    func revalidate(_ trustedIdentity: ClaudeCodeExecutableIdentity) async throws
}

protocol ClaudeCodeExecutableInspecting: ClaudeCodeExecutableVerifying {
    func inspect() async throws -> ClaudeCodeExecutableIdentity
}

extension ClaudeCodeExecutableInspecting {
    func revalidate(_ trustedIdentity: ClaudeCodeExecutableIdentity) async throws {
        let currentIdentity = try await inspect()
        try ClaudeCodeSecurityPolicy.validate(currentIdentity)
        guard currentIdentity == trustedIdentity else {
            throw ClaudeCodeAdapterError.executableRejected
        }
    }
}

struct SystemClaudeCodeExecutableInspector: ClaudeCodeExecutableInspecting {
    private let candidates: [URL]

    init(candidates: [URL]? = nil) {
        if let candidates {
            self.candidates = candidates
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.candidates = [
                home.appendingPathComponent(".local/bin/claude"),
                URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                URL(fileURLWithPath: "/usr/local/bin/claude"),
            ]
        }
    }

    func inspect() async throws -> ClaudeCodeExecutableIdentity {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let candidate = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
                throw ClaudeCodeAdapterError.executableUnavailable
            }
            let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
            let before = try Self.currentFileIdentity(at: canonical)
            guard before.mode & UInt16(S_IFMT) == UInt16(S_IFREG) else {
                throw ClaudeCodeAdapterError.executableRejected
            }
            let signature = try Self.signingIdentity(of: canonical)
            let version = Self.releaseVersion(at: canonical)
            let sha256 = try Self.sha256(of: canonical)
            let isArm64MachO = try Self.isArm64MachO(canonical)
            let after = try Self.currentFileIdentity(at: canonical)
            guard after == before else {
                throw ClaudeCodeAdapterError.executableRejected
            }
            return ClaudeCodeExecutableIdentity(
                canonicalURL: canonical,
                fileIdentity: before,
                version: version,
                sha256: sha256,
                signingIdentifier: signature.identifier,
                teamIdentifier: signature.teamIdentifier,
                ownerUserID: before.ownerUserID,
                currentUserID: getuid(),
                permissions: before.mode & 0o7777,
                isRegularFile: true,
                isArm64MachO: isArm64MachO
            )
        }.value
    }

    static func currentFileIdentity(at url: URL) throws -> ClaudeCodeFileIdentity {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw ClaudeCodeAdapterError.executableRejected
        }
        return ClaudeCodeFileIdentity(
            deviceID: UInt64(bitPattern: Int64(metadata.st_dev)),
            fileID: UInt64(metadata.st_ino),
            byteCount: metadata.st_size,
            mode: UInt16(metadata.st_mode),
            ownerUserID: metadata.st_uid,
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            changedSeconds: Int64(metadata.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    /// The official standalone installer uses a version-named executable
    /// (`.../versions/2.1.220`); packaged layouts may use
    /// `.../2.1.220/claude`. Identity/hash/signature checks still pin the exact
    /// artifact after this layout-only extraction.
    static func releaseVersion(at canonicalURL: URL) -> String {
        canonicalURL.lastPathComponent == "claude"
            ? canonicalURL.deletingLastPathComponent().lastPathComponent
            : canonicalURL.lastPathComponent
    }

    private static func signingIdentity(of url: URL) throws -> (identifier: String, teamIdentifier: String) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { throw ClaudeCodeAdapterError.executableRejected }

        let requirementText = "anchor apple generic and identifier \"\(ClaudeCodeSecurityPolicy.signingIdentifier)\" and certificate leaf[subject.OU] = \"\(ClaudeCodeSecurityPolicy.teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        else { throw ClaudeCodeAdapterError.executableRejected }

        var rawInfo: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInfo) == errSecSuccess,
              let info = rawInfo as? [CFString: Any],
              let identifier = info[kSecCodeInfoIdentifier] as? String,
              let teamIdentifier = info[kSecCodeInfoTeamIdentifier] as? String
        else { throw ClaudeCodeAdapterError.executableRejected }
        return (identifier, teamIdentifier)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isArm64MachO(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: MemoryLayout<mach_header_64>.size) ?? Data()
        guard bytes.count >= MemoryLayout<mach_header_64>.size else { return false }
        let header = bytes.withUnsafeBytes { $0.loadUnaligned(as: mach_header_64.self) }
        return header.magic == MH_MAGIC_64 && header.cputype == CPU_TYPE_ARM64
    }
}

struct ClaudeCodeProcessInvocation: Sendable {
    let executableURL: URL
    let trustedExecutableIdentity: ClaudeCodeExecutableIdentity
    let executableVerifier: any ClaudeCodeExecutableVerifying
    let promptAdmission: ClaudeCodePromptAdmission?
    let arguments: [String]
    let stdin: Data
    let environment: [String: String]
    let workingDirectory: URL
    let timeout: Duration
    let maximumStdoutBytes: Int
    let maximumStderrBytes: Int
}

struct ClaudeCodeProcessResult: Sendable, Equatable {
    let exitStatus: Int32
    let stdout: Data
    let stderr: Data
}

protocol ClaudeCodeProcessTransport: Sendable {
    func run(_ invocation: ClaudeCodeProcessInvocation) async throws -> ClaudeCodeProcessResult
}

struct ClaudeCodePromptAdmission: Sendable {
    let snapshotProvider: any LLMSelectionSnapshotProviding
    let selection: ProviderSelectionSnapshot
    let consumer: AIConsumer
    private let state = ClaudeCodePromptAdmissionState()

    func cancel() { state.cancel() }

    func checkCancellation() throws {
        try state.checkCancellation()
    }

    func validate() async throws {
        try state.checkCancellation()
        guard await snapshotProvider.currentSnapshot(for: consumer) == selection else {
            throw ClaudeCodeAdapterError.authorizationChanged
        }
        try state.checkCancellation()
    }
}

private final class ClaudeCodePromptAdmissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { throw CancellationError() }
    }
}

private final class ClaudeProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var finished = false
    private var overflow = false
    private var terminationRequested = false

    func setPID(_ value: pid_t) {
        lock.lock()
        pid = value
        let shouldTerminate = terminationRequested
        lock.unlock()
        if shouldTerminate { Self.killProcessGroup(value) }
    }

    func markFinished() {
        lock.lock()
        finished = true
        pid = nil
        lock.unlock()
    }
    func markOverflow() { lock.lock(); overflow = true; lock.unlock(); terminate() }
    func didOverflow() -> Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    func shouldTerminate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationRequested
    }

    func terminate() {
        lock.lock()
        terminationRequested = true
        let target = finished ? nil : pid
        lock.unlock()
        guard let target else { return }
        Self.killProcessGroup(target)
    }

    private static func killProcessGroup(_ target: pid_t) {
        _ = kill(-target, SIGKILL)
        _ = kill(target, SIGKILL)
    }
}

private struct ClaudeSpawnedProcess: Sendable {
    let processIdentifier: pid_t
    let stdinFileDescriptor: Int32
    let stdoutFileDescriptor: Int32
    let stderrFileDescriptor: Int32

    init(_ process: CodexSpawnedProcess) {
        processIdentifier = process.processIdentifier
        stdinFileDescriptor = process.stdinFileDescriptor
        stdoutFileDescriptor = process.stdoutFileDescriptor
        stderrFileDescriptor = process.stderrFileDescriptor
    }
}

private struct ClaudeWaitResult: Sendable {
    let reaped: Bool
    let status: Int32
}

struct SystemClaudeCodeProcessTransport: ClaudeCodeProcessTransport {
    private let beforePromptDispatch: @Sendable () async -> Void

    init(
        beforePromptDispatch: @escaping @Sendable () async -> Void = {}
    ) {
        self.beforePromptDispatch = beforePromptDispatch
    }

    func run(_ invocation: ClaudeCodeProcessInvocation) async throws -> ClaudeCodeProcessResult {
        guard invocation.stdin.isEmpty || invocation.promptAdmission != nil else {
            throw ClaudeCodeAdapterError.authorizationChanged
        }
        guard invocation.stdin.count <= ClaudeCodeSecurityPolicy.maximumInputBytes,
              invocation.timeout > .zero,
              invocation.maximumStdoutBytes > 0,
              invocation.maximumStderrBytes > 0,
              invocation.executableURL.isFileURL,
              invocation.workingDirectory.isFileURL,
              invocation.arguments.allSatisfy({ !$0.contains("\0") }),
              invocation.environment.allSatisfy({ key, value in
                  !key.isEmpty && !key.contains("=") && !key.contains("\0")
                    && !value.contains("\0")
              }) else {
            throw ClaudeCodeAdapterError.outputTooLarge
        }
        let box = ClaudeProcessBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withThrowingTaskGroup(of: ClaudeCodeProcessResult.self) { group in
                group.addTask {
                    try await Self.spawn(
                        invocation,
                        box: box,
                        beforePromptDispatch: beforePromptDispatch
                    )
                }
                group.addTask {
                    try await Task.sleep(for: invocation.timeout)
                    box.terminate()
                    throw ClaudeCodeAdapterError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw ClaudeCodeAdapterError.processFailed
                }
                box.terminate()
                return result
            }
        } onCancel: {
            invocation.promptAdmission?.cancel()
            box.terminate()
        }
    }

    private static func spawn(
        _ invocation: ClaudeCodeProcessInvocation,
        box: ClaudeProcessBox,
        beforePromptDispatch: @escaping @Sendable () async -> Void
    ) async throws -> ClaudeCodeProcessResult {
        try Task.checkCancellation()
        guard invocation.executableURL == invocation.trustedExecutableIdentity.canonicalURL else {
            throw ClaudeCodeAdapterError.executableRejected
        }
        try await invocation.executableVerifier.revalidate(
            invocation.trustedExecutableIdentity
        )
        try Task.checkCancellation()

        let spawned = try await launch(invocation, box: box)
        if !invocation.stdin.isEmpty {
            await beforePromptDispatch()
        }
        return try await communicate(
            invocation,
            spawned: spawned,
            box: box
        )
    }

    private static func launch(
        _ invocation: ClaudeCodeProcessInvocation,
        box: ClaudeProcessBox
    ) async throws -> ClaudeSpawnedProcess {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // The full hash/signature check above is asynchronous. Bind it
                // to the same vnode snapshot again at the synchronous spawn
                // boundary so an update during that hop fails closed.
                guard let currentFileIdentity = try? SystemClaudeCodeExecutableInspector
                    .currentFileIdentity(at: invocation.executableURL),
                      currentFileIdentity == invocation.trustedExecutableIdentity.fileIdentity else {
                    continuation.resume(throwing: ClaudeCodeAdapterError.executableRejected)
                    return
                }
                let specification = CodexLaunchSpecification(
                    executableURL: invocation.executableURL,
                    arguments: invocation.arguments,
                    environment: invocation.environment,
                    workingDirectoryURL: invocation.workingDirectory,
                    createsDedicatedProcessGroup: true,
                    usesLoginShell: false,
                    maximumStdoutBytes: invocation.maximumStdoutBytes,
                    maximumStderrBytes: invocation.maximumStderrBytes
                )
                let spawned: CodexSpawnedProcess
                do {
                    spawned = try CodexPOSIXSpawner.spawn(specification)
                } catch {
                    continuation.resume(throwing: ClaudeCodeAdapterError.processFailed)
                    return
                }
                let pid = spawned.processIdentifier
                Self.setBlocking(spawned.stdinFileDescriptor)
                Self.setBlocking(spawned.stdoutFileDescriptor)
                Self.setBlocking(spawned.stderrFileDescriptor)
                guard getpgid(pid) == pid else {
                    _ = kill(-pid, SIGKILL)
                    _ = kill(pid, SIGKILL)
                    Self.close(spawned)
                    Self.reap(pid)
                    continuation.resume(throwing: ClaudeCodeAdapterError.processFailed)
                    return
                }
                box.setPID(pid)
                continuation.resume(returning: ClaudeSpawnedProcess(spawned))
            }
        }
    }

    private static func communicate(
        _ invocation: ClaudeCodeProcessInvocation,
        spawned: ClaudeSpawnedProcess,
        box: ClaudeProcessBox
    ) async throws -> ClaudeCodeProcessResult {
        let outputTask = Task {
            await drainAsync(
                spawned.stdoutFileDescriptor,
                limit: invocation.maximumStdoutBytes,
                box: box
            )
        }
        let errorTask = Task {
            await drainAsync(
                spawned.stderrFileDescriptor,
                limit: invocation.maximumStderrBytes,
                box: box
            )
        }

        var writeFailure: (any Error)?
        var wroteInput = false
        do {
            wroteInput = try await writeAll(
                invocation.stdin,
                to: spawned.stdinFileDescriptor,
                promptAdmission: invocation.promptAdmission,
                box: box
            )
        } catch {
            writeFailure = error
        }
        Darwin.close(spawned.stdinFileDescriptor)
        if writeFailure != nil || !wroteInput { box.terminate() }

        let output = await outputTask.value
        let error = await errorTask.value
        Darwin.close(spawned.stdoutFileDescriptor)
        Darwin.close(spawned.stderrFileDescriptor)
        let wait = await reapAsync(spawned.processIdentifier)
        box.markFinished()

        if let writeFailure { throw writeFailure }
        if box.didOverflow() { throw ClaudeCodeAdapterError.outputTooLarge }
        guard wroteInput, wait.reaped else {
            throw ClaudeCodeAdapterError.processFailed
        }
        return ClaudeCodeProcessResult(
            exitStatus: exitStatus(wait.status),
            stdout: output,
            stderr: error
        )
    }

    private static func drain(_ fd: Int32, limit: Int, box: ClaudeProcessBox) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                if result.count + count > limit {
                    box.markOverflow()
                    return result
                }
                result.append(contentsOf: buffer[0..<count])
            } else if count == -1 && errno == EINTR {
                continue
            } else {
                return result
            }
        }
    }

    private static func drainAsync(
        _ descriptor: Int32,
        limit: Int,
        box: ClaudeProcessBox
    ) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: drain(descriptor, limit: limit, box: box))
            }
        }
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        promptAdmission: ClaudeCodePromptAdmission?,
        box: ClaudeProcessBox
    ) async throws -> Bool {
        var offset = 0
        let maximumChunkBytes = 4 * 1_024
        while offset < data.count {
            try await promptAdmission?.validate()
            try Task.checkCancellation()
            guard !box.shouldTerminate() else { throw CancellationError() }

            let end = min(offset + maximumChunkBytes, data.count)
            let chunk = data.subdata(in: offset..<end)
            let written = try await writeChunk(
                chunk,
                to: descriptor,
                promptAdmission: promptAdmission,
                box: box
            )
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }

    private static func writeChunk(
        _ data: Data,
        to descriptor: Int32,
        promptAdmission: ClaudeCodePromptAdmission?,
        box: ClaudeProcessBox
    ) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard !box.shouldTerminate() else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let written = data.withUnsafeBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    while true {
                        do {
                            try promptAdmission?.checkCancellation()
                        } catch {
                            return -2
                        }
                        let count = Darwin.write(descriptor, baseAddress, bytes.count)
                        if count < 0, errno == EINTR { continue }
                        return count
                    }
                }
                if written == -2 {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(returning: written)
                }
            }
        }
    }

    private static func setBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }
    }

    private static func close(_ process: CodexSpawnedProcess) {
        Darwin.close(process.stdinFileDescriptor)
        Darwin.close(process.stdoutFileDescriptor)
        Darwin.close(process.stderrFileDescriptor)
    }

    @discardableResult
    private static func reap(_ processIdentifier: pid_t) -> Bool {
        var status: Int32 = 0
        return reap(processIdentifier, status: &status)
    }

    private static func reap(_ processIdentifier: pid_t, status: inout Int32) -> Bool {
        var result: pid_t
        repeat {
            result = waitpid(processIdentifier, &status, 0)
        } while result < 0 && errno == EINTR
        return result == processIdentifier
    }

    private static func reapAsync(_ processIdentifier: pid_t) async -> ClaudeWaitResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var status: Int32 = 0
                let reaped = reap(processIdentifier, status: &status)
                continuation.resume(returning: ClaudeWaitResult(reaped: reaped, status: status))
            }
        }
    }

    private static func exitStatus(_ waitStatus: Int32) -> Int32 {
        let terminationSignal = waitStatus & 0x7f
        if terminationSignal == 0 { return (waitStatus >> 8) & 0xff }
        return 128 + terminationSignal
    }
}

actor ClaudeCodeAdapter: LLMAdapter {
    private let executableInspector: any ClaudeCodeExecutableInspecting
    private let transport: any ClaudeCodeProcessTransport
    private let snapshotProvider: any LLMSelectionSnapshotProviding
    private let workingDirectory: URL
    private let environmentSource: @Sendable () -> [String: String]

    init(
        executableInspector: any ClaudeCodeExecutableInspecting = SystemClaudeCodeExecutableInspector(),
        transport: any ClaudeCodeProcessTransport = SystemClaudeCodeProcessTransport(),
        snapshotProvider: any LLMSelectionSnapshotProviding,
        workingDirectory: URL,
        environmentSource: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.executableInspector = executableInspector
        self.transport = transport
        self.snapshotProvider = snapshotProvider
        self.workingDirectory = workingDirectory
        self.environmentSource = environmentSource
    }

    /// Prompt-free setup probe. It validates the exact signed/version-pinned
    /// executable and asks only Claude Code's documented auth-status command
    /// with empty stdin. No selection, prompt, or history is read or changed.
    func probeAuthentication(
        timeout: Duration = .seconds(10)
    ) async throws -> ClaudeCodeExecutableIdentity {
        guard timeout > .zero else { throw ClaudeCodeAdapterError.timedOut }
        let identity: ClaudeCodeExecutableIdentity
        do {
            identity = try await executableInspector.inspect()
            try ClaudeCodeSecurityPolicy.validate(identity)
        } catch let error as ClaudeCodeAdapterError {
            throw error
        } catch {
            throw ClaudeCodeAdapterError.executableRejected
        }

        let auth = try await run(
            identity: identity,
            arguments: ["auth", "status", "--json"],
            stdin: Data(),
            environment: Self.minimalEnvironment(environmentSource()),
            timeout: timeout,
            outputLimit: 16 * 1_024
        )
        try Self.validateAuth(auth)
        return identity
    }

    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        guard selection.providerID == AIProvider.claudeCode.rawValue,
              !selection.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ClaudeCodeAdapterError.invalidSelection }
        try await requireCurrent(selection, consumer: request.consumer)

        let identity = try await probeAuthentication(
            timeout: min(request.timeout, .seconds(10))
        )

        // Avoid materializing a prompt for an already-stale selection. The
        // transport checks again after executable verification, immediately
        // before prompt dispatch.
        try await requireCurrent(selection, consumer: request.consumer)
        let environment = Self.minimalEnvironment(environmentSource())
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose",
            "--safe-mode", "--no-session-persistence", "--disable-slash-commands",
            "--no-chrome", "--strict-mcp-config", "--tools", "",
            "--setting-sources", "",
        ]
        if selection.modelID != AIProvider.claudeCodeDefaultModel {
            arguments += ["--model", selection.modelID]
        }
        let prompt = Self.stdinPrompt(request)
        let output = try await run(
            identity: identity,
            arguments: arguments,
            stdin: prompt,
            promptAdmission: ClaudeCodePromptAdmission(
                snapshotProvider: snapshotProvider,
                selection: selection,
                consumer: request.consumer
            ),
            environment: environment,
            timeout: request.timeout,
            outputLimit: ClaudeCodeSecurityPolicy.maximumOutputBytes
        )
        let content = try Self.parseGeneration(output)
        try await requireCurrent(selection, consumer: request.consumer)
        return LLMResponse(
            content: content,
            truncated: false,
            provenance: AIExecutionProvenance(
                providerID: selection.providerID,
                modelID: selection.modelID,
                executedLocally: false,
                generatedAt: Date(),
                brokerUpstream: nil
            )
        )
    }

    private func requireCurrent(
        _ selection: ProviderSelectionSnapshot,
        consumer: AIConsumer
    ) async throws {
        guard await snapshotProvider.currentSnapshot(for: consumer) == selection else {
            throw ClaudeCodeAdapterError.authorizationChanged
        }
    }

    private func run(
        identity: ClaudeCodeExecutableIdentity,
        arguments: [String],
        stdin: Data,
        promptAdmission: ClaudeCodePromptAdmission? = nil,
        environment: [String: String],
        timeout: Duration,
        outputLimit: Int
    ) async throws -> Data {
        guard stdin.count <= ClaudeCodeSecurityPolicy.maximumInputBytes else {
            throw ClaudeCodeAdapterError.outputTooLarge
        }
        let invocation = ClaudeCodeProcessInvocation(
            executableURL: identity.canonicalURL,
            trustedExecutableIdentity: identity,
            executableVerifier: executableInspector,
            promptAdmission: promptAdmission,
            arguments: arguments,
            stdin: stdin,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout,
            maximumStdoutBytes: outputLimit,
            maximumStderrBytes: ClaudeCodeSecurityPolicy.maximumErrorBytes
        )
        do {
            let result = try await transport.run(invocation)
            guard result.stdout.count <= outputLimit else {
                throw ClaudeCodeAdapterError.outputTooLarge
            }
            guard result.exitStatus == 0 else { throw ClaudeCodeAdapterError.processFailed }
            return result.stdout
        } catch is CancellationError {
            throw ClaudeCodeAdapterError.cancelled
        } catch let error as ClaudeCodeAdapterError {
            throw error
        } catch {
            throw ClaudeCodeAdapterError.processFailed
        }
    }

    private static func validateAuth(_ data: Data) throws {
        guard data.count <= 16 * 1_024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["loggedIn"] as? Bool == true
        else { throw ClaudeCodeAdapterError.notAuthenticated }
        guard object["apiProvider"] as? String == "firstParty" else {
            throw ClaudeCodeAdapterError.unapprovedAPIProvider
        }
    }

    private static func parseGeneration(_ data: Data) throws -> String {
        guard data.count <= ClaudeCodeSecurityPolicy.maximumOutputBytes else {
            throw ClaudeCodeAdapterError.outputTooLarge
        }
        var sawSafeInit = false
        var resultText: String?
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard !lines.isEmpty else { throw ClaudeCodeAdapterError.malformedOutput }

        for line in lines {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = event["type"] as? String else {
                throw ClaudeCodeAdapterError.malformedOutput
            }
            switch type {
            case "system":
                guard event["subtype"] as? String == "init",
                      let tools = event["tools"] as? [Any], tools.isEmpty,
                      !sawSafeInit else {
                    throw ClaudeCodeAdapterError.forbiddenEvent
                }
                sawSafeInit = true

            case "assistant":
                guard let message = event["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]],
                      content.allSatisfy({ $0["type"] as? String == "text" }) else {
                    throw ClaudeCodeAdapterError.forbiddenEvent
                }

            case "result":
                guard sawSafeInit,
                      resultText == nil,
                      event["subtype"] as? String == "success",
                      event["is_error"] as? Bool != true,
                      let result = event["result"] as? String,
                      !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ClaudeCodeAdapterError.malformedOutput
                }
                resultText = result.trimmingCharacters(in: .whitespacesAndNewlines)

            default:
                throw ClaudeCodeAdapterError.forbiddenEvent
            }
        }
        guard sawSafeInit, let resultText else {
            throw ClaudeCodeAdapterError.malformedOutput
        }
        return resultText
    }

    private static func stdinPrompt(_ request: LLMRequest) -> Data {
        Data(
            """
            <system-instructions>
            \(request.systemPrompt)
            </system-instructions>
            <user-input>
            \(request.userPrompt)
            </user-input>
            """.utf8
        )
    }

    private static func minimalEnvironment(_ source: [String: String]) -> [String: String] {
        let allowed = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"]
        var result = Dictionary(uniqueKeysWithValues: allowed.compactMap { key in
            source[key].map { (key, $0) }
        })
        result["PATH"] = "/usr/bin:/bin"
        if result["LANG"] == nil { result["LANG"] = "en_US.UTF-8" }
        if result["LC_ALL"] == nil { result["LC_ALL"] = "en_US.UTF-8" }
        return result
    }
}
