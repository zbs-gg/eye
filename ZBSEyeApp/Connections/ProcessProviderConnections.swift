import Darwin
import Foundation

/// Narrow prompt-free/control surface used by the Codex provider lifecycle.
/// Keeping it separate from `LLMAdapter` makes setup testable without ever
/// manufacturing a generation request.
protocol CodexAppServerConnecting: LLMAdapter {
    func probeConnection(timeout: Duration) async throws -> CodexConnectionState
    func startLogin() async throws -> CodexLoginChallenge
    func cancelLogin(loginID: String) async throws
    func completeLogin(loginID: String, timeout: Duration) async throws
    func shutdown() async
}

extension CodexAppServerClient: CodexAppServerConnecting {}

struct CodexConnectionUpdate: Sendable {
    enum RuntimeDisposition: Sendable, Equatable {
        /// The candidate never replaced the currently registered runtime, so
        /// a cancelled caller may safely restore its last-known-good state.
        case previousPreserved
        /// The provider crossed its replacement boundary. A late cancellation
        /// must publish this update instead of reviving the retired adapter.
        case committed
    }

    let state: CodexConnectionState
    let registration: LLMAdapterRegistration?
    let runtimeDisposition: RuntimeDisposition

    init(
        state: CodexConnectionState,
        registration: LLMAdapterRegistration?,
        runtimeDisposition: RuntimeDisposition = .previousPreserved
    ) {
        self.state = state
        self.registration = registration
        self.runtimeDisposition = runtimeDisposition
    }

    func committingRuntime() -> Self {
        Self(
            state: state,
            registration: registration,
            runtimeDisposition: .committed
        )
    }
}

protocol CodexProviderConnecting: Sendable {
    func probe() async -> CodexConnectionUpdate
    func startLogin() async -> CodexConnectionUpdate
    func cancelLogin(loginID: String) async -> CodexConnectionUpdate
    func completeLogin(loginID: String) async -> CodexConnectionUpdate
    func shutdown() async
}

/// Owns Codex setup/login sessions. An adapter registration is emitted only
/// after the exact pinned App Server has initialized, a first-party ChatGPT
/// account has been confirmed, and its live model catalog has been read.
actor CodexProviderConnection: CodexProviderConnecting {
    typealias ClientFactory = @Sendable () -> any CodexAppServerConnecting

    private actor ShutdownGate {
        let client: any CodexAppServerConnecting
        private var didShutdown = false

        init(client: any CodexAppServerConnecting) {
            self.client = client
        }

        func shutdown() async {
            guard !didShutdown else { return }
            didShutdown = true
            await client.shutdown()
        }
    }

    private struct PendingLogin: Sendable {
        let client: any CodexAppServerConnecting
        let shutdownGate: ShutdownGate
        let challenge: CodexLoginChallenge
    }

    private struct OperationOutcome: Sendable {
        let update: CodexConnectionUpdate
        let pendingLogin: PendingLogin?
        let authenticatedClient: ShutdownGate?
    }

    private struct ActiveOperation: Sendable {
        let id: UUID
        let task: Task<OperationOutcome, Never>
        let shutdownGate: ShutdownGate
    }

    private let clientFactory: ClientFactory
    private var pendingLogin: PendingLogin?
    private var authenticatedClient: ShutdownGate?
    private var activeOperation: ActiveOperation?
    private var shutdownRequested = false

    init(clientFactory: @escaping ClientFactory) {
        self.clientFactory = clientFactory
    }

    func probe() async -> CodexConnectionUpdate {
        guard !shutdownRequested else { return Self.failure("Codex connection is shutting down.") }
        guard activeOperation == nil else { return Self.failure("Codex connection is busy.") }
        if let pendingLogin {
            return CodexConnectionUpdate(
                state: .loginPending(
                    loginID: pendingLogin.challenge.loginID,
                    authorizationURL: pendingLogin.challenge.authorizationURL
                ),
                registration: nil
            )
        }
        let client = clientFactory()
        let shutdownGate = ShutdownGate(client: client)
        return await perform(shutdownGate: shutdownGate) {
            do {
                let state = try await client.probeConnection(timeout: .seconds(10))
                let update = Self.authenticatedUpdate(state: state, client: client)
                return OperationOutcome(
                    update: update,
                    pendingLogin: nil,
                    authenticatedClient: update.registration == nil ? nil : shutdownGate
                )
            } catch {
                await shutdownGate.shutdown()
                return OperationOutcome(
                    update: Self.mappedFailure(error),
                    pendingLogin: nil,
                    authenticatedClient: nil
                )
            }
        }
    }

    func startLogin() async -> CodexConnectionUpdate {
        guard !shutdownRequested else { return Self.failure("Codex connection is shutting down.") }
        guard activeOperation == nil else { return Self.failure("Codex connection is busy.") }
        if let pendingLogin {
            return CodexConnectionUpdate(
                state: .loginPending(
                    loginID: pendingLogin.challenge.loginID,
                    authorizationURL: pendingLogin.challenge.authorizationURL
                ),
                registration: nil
            )
        }
        let client = clientFactory()
        let shutdownGate = ShutdownGate(client: client)
        return await perform(shutdownGate: shutdownGate) {
            do {
                let challenge = try await client.startLogin()
                let pending = PendingLogin(
                    client: client,
                    shutdownGate: shutdownGate,
                    challenge: challenge
                )
                return OperationOutcome(
                    update: CodexConnectionUpdate(
                        state: .loginPending(
                            loginID: challenge.loginID,
                            authorizationURL: challenge.authorizationURL
                        ),
                        registration: nil
                    ),
                    pendingLogin: pending,
                    authenticatedClient: nil
                )
            } catch {
                await shutdownGate.shutdown()
                return OperationOutcome(
                    update: Self.mappedFailure(error),
                    pendingLogin: nil,
                    authenticatedClient: nil
                )
            }
        }
    }

    func cancelLogin(loginID: String) async -> CodexConnectionUpdate {
        guard !shutdownRequested,
              activeOperation == nil,
              let pending = pendingLogin,
              pending.challenge.loginID == loginID else {
            return Self.failure("The Codex login attempt is no longer current.")
        }
        pendingLogin = nil
        return await perform(shutdownGate: pending.shutdownGate) {
            do {
                try await pending.client.cancelLogin(loginID: loginID)
                await pending.shutdownGate.shutdown()
                return OperationOutcome(
                    update: CodexConnectionUpdate(
                        state: .ready(version: CodexBinaryPolicy.allowedVersion),
                        registration: nil
                    ),
                    pendingLogin: nil,
                    authenticatedClient: nil
                )
            } catch {
                await pending.shutdownGate.shutdown()
                return OperationOutcome(
                    update: Self.mappedFailure(error),
                    pendingLogin: nil,
                    authenticatedClient: nil
                )
            }
        }
    }

    func completeLogin(loginID: String) async -> CodexConnectionUpdate {
        guard !shutdownRequested,
              activeOperation == nil,
              let pending = pendingLogin,
              pending.challenge.loginID == loginID else {
            return Self.failure("The Codex login attempt is no longer current.")
        }
        pendingLogin = nil
        return await perform(shutdownGate: pending.shutdownGate) {
            do {
                try await pending.client.completeLogin(
                    loginID: loginID,
                    timeout: .seconds(120)
                )
                let state = try await pending.client.probeConnection(timeout: .seconds(10))
                let update = Self.authenticatedUpdate(state: state, client: pending.client)
                return OperationOutcome(
                    update: update,
                    pendingLogin: nil,
                    authenticatedClient: update.registration == nil ? nil : pending.shutdownGate
                )
            } catch {
                await pending.shutdownGate.shutdown()
                return OperationOutcome(
                    update: Self.mappedFailure(error),
                    pendingLogin: nil,
                    authenticatedClient: nil
                )
            }
        }
    }

    func shutdown() async {
        shutdownRequested = true
        let active = activeOperation
        activeOperation = nil
        let pending = pendingLogin
        pendingLogin = nil
        let authenticated = authenticatedClient
        authenticatedClient = nil
        active?.task.cancel()
        if let active { await active.shutdownGate.shutdown() }
        if let pending { await pending.shutdownGate.shutdown() }
        if let authenticated { await authenticated.shutdown() }
        if let active { _ = await active.task.value }
    }

    private func perform(
        shutdownGate: ShutdownGate,
        operation: @escaping @Sendable () async -> OperationOutcome
    ) async -> CodexConnectionUpdate {
        let id = UUID()
        let task = Task { await operation() }
        activeOperation = ActiveOperation(
            id: id,
            task: task,
            shutdownGate: shutdownGate
        )
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard activeOperation?.id == id,
              !shutdownRequested,
              !Task.isCancelled else {
            await shutdownGate.shutdown()
            if activeOperation?.id == id {
                activeOperation = nil
            }
            return Self.failure("Codex connection was cancelled.")
        }
        let previousAuthenticated = authenticatedClient
        if let previousAuthenticated {
            await previousAuthenticated.shutdown()
        }
        if outcome.pendingLogin == nil, outcome.authenticatedClient == nil {
            await shutdownGate.shutdown()
        }
        guard activeOperation?.id == id,
              !shutdownRequested else {
            await shutdownGate.shutdown()
            if activeOperation?.id == id {
                activeOperation = nil
            }
            return Self.failure("Codex connection was cancelled.")
        }
        activeOperation = nil
        pendingLogin = outcome.pendingLogin
        authenticatedClient = outcome.authenticatedClient
        return outcome.update.committingRuntime()
    }

    private nonisolated static func authenticatedUpdate(
        state: CodexConnectionState,
        client: any CodexAppServerConnecting
    ) -> CodexConnectionUpdate {
        switch state {
        case .authenticated(let version, let rawModels):
            guard version == CodexBinaryPolicy.allowedVersion,
                  case .authoritative(let models) = ProviderCatalogState
                    .validatingSuccessfulPayload(rawModels) else {
                return CodexConnectionUpdate(state: .untrusted, registration: nil)
            }
            return CodexConnectionUpdate(
                state: .authenticated(version: version, models: models),
                registration: LLMAdapterRegistration(
                    providerID: AIProvider.codex.rawValue,
                    executedLocally: false,
                    adapter: client
                )
            )
        case .ready(let version):
            guard version == CodexBinaryPolicy.allowedVersion else {
                return CodexConnectionUpdate(state: .untrusted, registration: nil)
            }
            return CodexConnectionUpdate(state: state, registration: nil)
        case .unknown, .checking, .missing, .untrusted, .loginPending, .error:
            return CodexConnectionUpdate(state: state, registration: nil)
        }
    }

    private nonisolated static func mappedFailure(_ error: Error) -> CodexConnectionUpdate {
        switch error as? CodexAppServerError {
        case .executableMissing:
            return CodexConnectionUpdate(state: .missing, registration: nil)
        case .untrustedBinary:
            return CodexConnectionUpdate(state: .untrusted, registration: nil)
        case .notAuthenticatedWithChatGPT:
            return CodexConnectionUpdate(
                state: .ready(version: CodexBinaryPolicy.allowedVersion),
                registration: nil
            )
        default:
            return failure("Codex connection failed.")
        }
    }

    private nonisolated static func failure(_ message: String) -> CodexConnectionUpdate {
        CodexConnectionUpdate(state: .error(message), registration: nil)
    }
}

protocol ClaudeCodeConnecting: LLMAdapter {
    func probeAuthentication(timeout: Duration) async throws -> ClaudeCodeExecutableIdentity
}

extension ClaudeCodeAdapter: ClaudeCodeConnecting {}

enum ClaudeCodeConnectionState: Sendable, Equatable {
    case missing
    case untrusted
    case notAuthenticated
    case unsupportedAccount
    case authenticated(version: String, executablePath: String)
    case error(String)
}

struct ClaudeCodeConnectionUpdate: Sendable {
    let state: ClaudeCodeConnectionState
    let registration: LLMAdapterRegistration?
}

protocol ClaudeCodeProviderConnecting: Sendable {
    func probe() async -> ClaudeCodeConnectionUpdate
}

/// Claude Code has no live model-list surface. Its catalog remains the curated
/// release list; this service gates only the exact binary + first-party auth and
/// returns the adapter overlay after both checks pass.
actor ClaudeCodeProviderConnection: ClaudeCodeProviderConnecting {
    private let adapter: any ClaudeCodeConnecting

    init(adapter: any ClaudeCodeConnecting) {
        self.adapter = adapter
    }

    func probe() async -> ClaudeCodeConnectionUpdate {
        do {
            let identity = try await adapter.probeAuthentication(timeout: .seconds(10))
            try ClaudeCodeSecurityPolicy.validate(identity)
            guard identity.version == ClaudeCodeSecurityPolicy.allowedVersion else {
                return ClaudeCodeConnectionUpdate(state: .untrusted, registration: nil)
            }
            return ClaudeCodeConnectionUpdate(
                state: .authenticated(
                    version: identity.version,
                    executablePath: identity.canonicalURL.path
                ),
                registration: LLMAdapterRegistration(
                    providerID: AIProvider.claudeCode.rawValue,
                    executedLocally: false,
                    adapter: adapter
                )
            )
        } catch ClaudeCodeAdapterError.executableUnavailable {
            return ClaudeCodeConnectionUpdate(state: .missing, registration: nil)
        } catch ClaudeCodeAdapterError.executableRejected {
            return ClaudeCodeConnectionUpdate(state: .untrusted, registration: nil)
        } catch ClaudeCodeAdapterError.notAuthenticated {
            return ClaudeCodeConnectionUpdate(state: .notAuthenticated, registration: nil)
        } catch ClaudeCodeAdapterError.unapprovedAPIProvider {
            return ClaudeCodeConnectionUpdate(state: .unsupportedAccount, registration: nil)
        } catch {
            return ClaudeCodeConnectionUpdate(
                state: .error("Claude Code connection failed."),
                registration: nil
            )
        }
    }
}

struct ProcessProviderRuntimeConnections: Sendable {
    let codex: CodexProviderConnection
    let claudeCode: ClaudeCodeProviderConnection
    let owner: ProcessProviderRuntimeOwner
    let codexHomeRootURL: URL
    let claudeWorkingDirectoryURL: URL
}

private actor ProcessProviderShutdownResult {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func resolve(_ value: Bool) {
        guard result == nil else { return }
        result = value
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: value) }
    }

    func value() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// App-lifetime owner for process-provider control state. Its deadline is a
/// real upper bound: a non-cooperative subprocess cleanup may continue in the
/// background, but it cannot hold macOS termination open forever.
actor ProcessProviderRuntimeOwner {
    private let codex: any CodexProviderConnecting
    private var shutdownTask: Task<Void, Never>?

    init(codex: any CodexProviderConnecting) {
        self.codex = codex
    }

    @discardableResult
    func shutdown(timeout: Duration) async -> Bool {
        let operation: Task<Void, Never>
        if let shutdownTask {
            operation = shutdownTask
        } else {
            operation = Task { await codex.shutdown() }
            shutdownTask = operation
        }

        let result = ProcessProviderShutdownResult()
        let completion = Task {
            await operation.value
            await result.resolve(true)
        }
        let deadline = Task {
            guard timeout > .zero else {
                await result.resolve(false)
                return
            }
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await result.resolve(false)
        }
        let completed = await result.value()
        deadline.cancel()
        completion.cancel()
        if !completed { operation.cancel() }
        return completed
    }
}

enum ProcessProviderRuntimeFactoryError: Error, Sendable, Equatable {
    case unsafeWorkingDirectory
}

/// Production constructors. Ephemeral process state is rooted under the
/// already-resolved data root, as a sibling of the relocatable built-in model
/// tree. It must not be copied as model inventory during relocation.
enum ProcessProviderRuntimeFactory {
    static func make(
        snapshotProvider: any LLMSelectionSnapshotProviding,
        dataRoot: URL
    ) throws -> ProcessProviderRuntimeConnections {
        let providersRoot = dataRoot.appending(path: "ai/process-providers/v1")
        let codexHomeManager = CodexSystemHomeManager(
            rootURL: providersRoot.appending(path: "codex-app-server")
        )
        let executableResolver = CodexSystemExecutableResolver()
        let transport = CodexPOSIXProcessTransport()
        let codex = CodexProviderConnection(clientFactory: {
            CodexAppServerClient(
                executableResolver: executableResolver,
                homeManager: codexHomeManager,
                processTransport: transport,
                snapshotProvider: snapshotProvider
            )
        })

        let claudeWorkingDirectory = providersRoot
            .appending(path: "claude-code")
            .appending(path: "empty-workspace")
        try preparePrivateEmptyDirectory(claudeWorkingDirectory)
        let claudeAdapter = ClaudeCodeAdapter(
            snapshotProvider: snapshotProvider,
            workingDirectory: claudeWorkingDirectory
        )
        let claudeCode = ClaudeCodeProviderConnection(adapter: claudeAdapter)
        let owner = ProcessProviderRuntimeOwner(codex: codex)
        return ProcessProviderRuntimeConnections(
            codex: codex,
            claudeCode: claudeCode,
            owner: owner,
            codexHomeRootURL: codexHomeManager.rootURL,
            claudeWorkingDirectoryURL: claudeWorkingDirectory
        )
    }

    private static func preparePrivateEmptyDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw ProcessProviderRuntimeFactoryError.unsafeWorkingDirectory
        }
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw ProcessProviderRuntimeFactoryError.unsafeWorkingDirectory
        }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_mode & 0o077 == 0,
              info.st_uid == getuid(),
              (try? FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty) == true else {
            throw ProcessProviderRuntimeFactoryError.unsafeWorkingDirectory
        }
    }
}
