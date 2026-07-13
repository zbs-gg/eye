import Foundation
import XCTest

final class ProcessProviderConnectionTests: XCTestCase {
    func testFactoryRootsIsolatedHomesUnderResolvedGenerativeRootAndRejectsNonemptyWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "zbs-eye-process-provider-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try ProcessProviderRuntimeFactory.make(
            snapshotProvider: NilProcessProviderSnapshots(),
            dataRoot: root
        )

        XCTAssertEqual(
            runtime.codexHomeRootURL.path,
            root.appending(path: "ai/process-providers/v1/codex-app-server").path
        )
        XCTAssertEqual(
            runtime.claudeWorkingDirectoryURL.path,
            root.appending(path: "ai/process-providers/v1/claude-code/empty-workspace").path
        )
        var info = stat()
        XCTAssertEqual(lstat(runtime.claudeWorkingDirectoryURL.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)

        try Data("CANARY".utf8).write(
            to: runtime.claudeWorkingDirectoryURL.appending(path: "CLAUDE.md")
        )
        XCTAssertThrowsError(
            try ProcessProviderRuntimeFactory.make(
                snapshotProvider: NilProcessProviderSnapshots(),
                dataRoot: root
            )
        ) { error in
            XCTAssertEqual(
                error as? ProcessProviderRuntimeFactoryError,
                .unsafeWorkingDirectory
            )
        }
    }

    func testCodexProbePublishesOnlyAuthenticatedAuthoritativeCatalogAndRegistration() async throws {
        let client = MockCodexConnectionClient(
            probeResults: [
                .success(.authenticated(
                    version: CodexBinaryPolicy.allowedVersion,
                    models: ["gpt-5.4-mini", "gpt-5.4"]
                )),
            ]
        )
        let connection = CodexProviderConnection(clientFactory: { client })

        let update = await connection.probe()

        XCTAssertEqual(
            update.state,
            .authenticated(
                version: CodexBinaryPolicy.allowedVersion,
                models: ["gpt-5.4-mini", "gpt-5.4"]
            )
        )
        let registration = try XCTUnwrap(update.registration)
        XCTAssertEqual(registration.providerID, AIProvider.codex.rawValue)
        XCTAssertFalse(registration.executedLocally)
        let probeCalls = await client.probeCallCount()
        let generationCalls = await client.generateCallCount()
        XCTAssertEqual(probeCalls, 1)
        XCTAssertEqual(generationCalls, 0)
    }

    func testAuthenticatedCodexClientIsRetainedUntilReplacementAndShutdown() async throws {
        let first = MockCodexConnectionClient(
            probeResults: [
                .success(.authenticated(
                    version: CodexBinaryPolicy.allowedVersion,
                    models: ["gpt-5.4-mini"]
                )),
            ]
        )
        let second = MockCodexConnectionClient(
            probeResults: [
                .success(.authenticated(
                    version: CodexBinaryPolicy.allowedVersion,
                    models: ["gpt-5.4"]
                )),
            ]
        )
        let factory = SequencedCodexClientFactory(clients: [first, second])
        let connection = CodexProviderConnection(clientFactory: { factory.make() })

        let firstUpdate = await connection.probe()
        XCTAssertNotNil(firstUpdate.registration)
        let firstBeforeReplacement = await first.shutdownCallCount()
        XCTAssertEqual(firstBeforeReplacement, 0)

        let secondUpdate = await connection.probe()
        XCTAssertNotNil(secondUpdate.registration)
        let firstAfterReplacement = await first.shutdownCallCount()
        let secondBeforeShutdown = await second.shutdownCallCount()
        XCTAssertEqual(firstAfterReplacement, 1)
        XCTAssertEqual(secondBeforeShutdown, 0)

        await connection.shutdown()
        await connection.shutdown()
        let firstFinal = await first.shutdownCallCount()
        let secondFinal = await second.shutdownCallCount()
        XCTAssertEqual(firstFinal, 1)
        XCTAssertEqual(secondFinal, 1)
    }

    func testCodexProbeDistinguishesMissingUntrustedAndReadyWithoutRegistration() async {
        let cases: [(CodexAppServerError?, CodexConnectionState)] = [
            (.executableMissing, .missing),
            (.untrustedBinary, .untrusted),
            (nil, .ready(version: CodexBinaryPolicy.allowedVersion)),
        ]
        for (error, expected) in cases {
            let result: Result<CodexConnectionState, CodexAppServerError> = if let error {
                .failure(error)
            } else {
                .success(expected)
            }
            let client = MockCodexConnectionClient(probeResults: [result])
            let connection = CodexProviderConnection(clientFactory: { client })

            let update = await connection.probe()

            XCTAssertEqual(update.state, expected)
            XCTAssertNil(update.registration)
            let generationCalls = await client.generateCallCount()
            XCTAssertEqual(generationCalls, 0)
        }
    }

    func testCodexLoginStartCompleteAndCancelStayOnOwnedClient() async throws {
        let challenge = CodexLoginChallenge(
            loginID: "login-1",
            authorizationURL: URL(string: "https://auth.openai.com/oauth/authorize")!
        )
        let completedClient = MockCodexConnectionClient(
            probeResults: [
                .success(.authenticated(
                    version: CodexBinaryPolicy.allowedVersion,
                    models: ["gpt-5.4-mini"]
                )),
            ],
            challenge: challenge
        )
        let completed = CodexProviderConnection(clientFactory: { completedClient })

        let pending = await completed.startLogin()
        XCTAssertEqual(
            pending.state,
            .loginPending(
                loginID: challenge.loginID,
                authorizationURL: challenge.authorizationURL
            )
        )
        XCTAssertNil(pending.registration)

        let authenticated = await completed.completeLogin(loginID: challenge.loginID)
        XCTAssertEqual(
            authenticated.state,
            .authenticated(
                version: CodexBinaryPolicy.allowedVersion,
                models: ["gpt-5.4-mini"]
            )
        )
        XCTAssertNotNil(authenticated.registration)
        let startCalls = await completedClient.startLoginCallCount()
        let completeIDs = await completedClient.completeLoginIDs()
        let completedGenerationCalls = await completedClient.generateCallCount()
        XCTAssertEqual(startCalls, 1)
        XCTAssertEqual(completeIDs, [challenge.loginID])
        XCTAssertEqual(completedGenerationCalls, 0)

        let cancelledClient = MockCodexConnectionClient(challenge: challenge)
        let cancelled = CodexProviderConnection(clientFactory: { cancelledClient })
        _ = await cancelled.startLogin()
        let ready = await cancelled.cancelLogin(loginID: challenge.loginID)
        XCTAssertEqual(ready.state, .ready(version: CodexBinaryPolicy.allowedVersion))
        XCTAssertNil(ready.registration)
        let cancelIDs = await cancelledClient.cancelLoginIDs()
        let cancelledGenerationCalls = await cancelledClient.generateCallCount()
        XCTAssertEqual(cancelIDs, [challenge.loginID])
        XCTAssertEqual(cancelledGenerationCalls, 0)
    }

    func testCodexRejectsStaleLoginIDAndClosesEveryOwnedLoginSession() async {
        let challenge = CodexLoginChallenge(
            loginID: "login-current",
            authorizationURL: URL(string: "https://auth.openai.com/oauth/authorize")!
        )
        let client = MockCodexConnectionClient(challenge: challenge)
        let connection = CodexProviderConnection(clientFactory: { client })
        _ = await connection.startLogin()

        let stale = await connection.completeLogin(loginID: "login-stale")

        guard case .error = stale.state else {
            return XCTFail("stale login must fail without replacing the pending login")
        }
        XCTAssertNil(stale.registration)
        let stillPending = await connection.probe()
        XCTAssertEqual(
            stillPending.state,
            .loginPending(
                loginID: challenge.loginID,
                authorizationURL: challenge.authorizationURL
            )
        )

        await connection.shutdown()
        let shutdownCalls = await client.shutdownCallCount()
        let generationCalls = await client.generateCallCount()
        XCTAssertEqual(shutdownCalls, 1)
        XCTAssertEqual(generationCalls, 0)

        let failedClient = MockCodexConnectionClient(
            challenge: challenge,
            startError: .timedOut
        )
        let failed = CodexProviderConnection(clientFactory: { failedClient })
        let failedUpdate = await failed.startLogin()
        guard case .error = failedUpdate.state else {
            return XCTFail("failed login start must surface an error")
        }
        let failedShutdownCalls = await failedClient.shutdownCallCount()
        XCTAssertEqual(failedShutdownCalls, 1)
    }

    func testCodexShutdownCancelsAndDrainsInFlightLoginOperation() async {
        let client = GatedCodexLoginClient()
        let connection = CodexProviderConnection(clientFactory: { client })
        let login = Task { await connection.startLogin() }
        await client.waitUntilStartEntered()

        await connection.shutdown()
        let shutdownCalls = await client.shutdownCallCount()
        XCTAssertEqual(shutdownCalls, 1, "shutdown must close the in-flight owned client")

        // Always release the test double so a regression cannot strand the test process.
        await client.releaseStart()
        let update = await login.value
        guard case .error = update.state else {
            return XCTFail("an in-flight login must not commit after shutdown")
        }
        XCTAssertNil(update.registration)
    }

    func testRuntimeOwnerBoundsShutdownWhenProviderDoesNotAcknowledgeCancellation() async {
        let provider = BlockingShutdownCodexProvider()
        let owner = ProcessProviderRuntimeOwner(codex: provider)
        let started = ContinuousClock.now

        let completed = await owner.shutdown(timeout: .milliseconds(30))

        XCTAssertFalse(completed)
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(1))
        await provider.waitUntilShutdownEntered()
        let shutdownCalls = await provider.shutdownCallCount()
        XCTAssertEqual(shutdownCalls, 1)
        await provider.releaseShutdown()
    }

    func testClaudeRegistrationRequiresPinnedFirstPartyAuthentication() async throws {
        let authenticatedAdapter = MockClaudeConnectionAdapter(
            result: .success(.trustedFixture())
        )
        let authenticated = ClaudeCodeProviderConnection(adapter: authenticatedAdapter)

        let accepted = await authenticated.probe()

        XCTAssertEqual(
            accepted.state,
            .authenticated(
                version: ClaudeCodeSecurityPolicy.allowedVersion,
                executablePath: "/trusted/claude"
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(accepted.registration).providerID,
            AIProvider.claudeCode.rawValue
        )
        let authenticatedProbeCalls = await authenticatedAdapter.probeCallCount()
        let authenticatedGenerationCalls = await authenticatedAdapter.generateCallCount()
        XCTAssertEqual(authenticatedProbeCalls, 1)
        XCTAssertEqual(authenticatedGenerationCalls, 0)

        for (error, expected) in [
            (ClaudeCodeAdapterError.executableUnavailable, ClaudeCodeConnectionState.missing),
            (ClaudeCodeAdapterError.executableRejected, .untrusted),
            (ClaudeCodeAdapterError.notAuthenticated, .notAuthenticated),
            (ClaudeCodeAdapterError.unapprovedAPIProvider, .unsupportedAccount),
        ] {
            let adapter = MockClaudeConnectionAdapter(result: .failure(error))
            let connection = ClaudeCodeProviderConnection(adapter: adapter)
            let rejected = await connection.probe()
            XCTAssertEqual(rejected.state, expected)
            XCTAssertNil(rejected.registration)
            let generationCalls = await adapter.generateCallCount()
            XCTAssertEqual(generationCalls, 0)
        }
    }
}

private actor NilProcessProviderSnapshots: LLMSelectionSnapshotProviding {
    func currentSnapshot(for consumer: AIConsumer) async -> ProviderSelectionSnapshot? { nil }
}

private final class SequencedCodexClientFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [any CodexAppServerConnecting]

    init(clients: [any CodexAppServerConnecting]) {
        self.clients = clients
    }

    func make() -> any CodexAppServerConnecting {
        lock.lock()
        defer { lock.unlock() }
        precondition(!clients.isEmpty, "unexpected extra Codex client request")
        return clients.removeFirst()
    }
}

private actor MockCodexConnectionClient: CodexAppServerConnecting {
    private var probeResults: [Result<CodexConnectionState, CodexAppServerError>]
    private let challenge: CodexLoginChallenge
    private let startError: CodexAppServerError?
    private var probes = 0
    private var generations = 0
    private var loginStarts = 0
    private var completed: [String] = []
    private var cancelled: [String] = []
    private var shutdowns = 0

    init(
        probeResults: [Result<CodexConnectionState, CodexAppServerError>] = [],
        challenge: CodexLoginChallenge = CodexLoginChallenge(
            loginID: "login-1",
            authorizationURL: URL(string: "https://auth.openai.com/oauth/authorize")!
        ),
        startError: CodexAppServerError? = nil
    ) {
        self.probeResults = probeResults
        self.challenge = challenge
        self.startError = startError
    }

    func probeConnection(timeout: Duration) async throws -> CodexConnectionState {
        probes += 1
        guard !probeResults.isEmpty else { return .ready(version: CodexBinaryPolicy.allowedVersion) }
        return try probeResults.removeFirst().get()
    }

    func startLogin() async throws -> CodexLoginChallenge {
        loginStarts += 1
        if let startError { throw startError }
        return challenge
    }

    func cancelLogin(loginID: String) async throws { cancelled.append(loginID) }
    func completeLogin(loginID: String, timeout: Duration) async throws { completed.append(loginID) }
    func shutdown() async { shutdowns += 1 }

    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        generations += 1
        throw CodexAppServerError.unavailable
    }

    func probeCallCount() -> Int { probes }
    func generateCallCount() -> Int { generations }
    func startLoginCallCount() -> Int { loginStarts }
    func completeLoginIDs() -> [String] { completed }
    func cancelLoginIDs() -> [String] { cancelled }
    func shutdownCallCount() -> Int { shutdowns }
}

private actor MockClaudeConnectionAdapter: ClaudeCodeConnecting {
    private let result: Result<ClaudeCodeExecutableIdentity, ClaudeCodeAdapterError>
    private var probes = 0
    private var generations = 0

    init(result: Result<ClaudeCodeExecutableIdentity, ClaudeCodeAdapterError>) {
        self.result = result
    }

    func probeAuthentication(timeout: Duration) async throws -> ClaudeCodeExecutableIdentity {
        probes += 1
        return try result.get()
    }

    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        generations += 1
        throw ClaudeCodeAdapterError.processFailed
    }

    func probeCallCount() -> Int { probes }
    func generateCallCount() -> Int { generations }
}

private actor GatedCodexLoginClient: CodexAppServerConnecting {
    private let challenge = CodexLoginChallenge(
        loginID: "login-gated",
        authorizationURL: URL(string: "https://auth.openai.com/oauth/authorize")!
    )
    private var startEntered = false
    private var startReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdowns = 0

    func probeConnection(timeout: Duration) async throws -> CodexConnectionState {
        .ready(version: CodexBinaryPolicy.allowedVersion)
    }

    func startLogin() async throws -> CodexLoginChallenge {
        startEntered = true
        if !startReleased {
            await withCheckedContinuation { startWaiters.append($0) }
        }
        try Task.checkCancellation()
        return challenge
    }

    func cancelLogin(loginID: String) async throws {}
    func completeLogin(loginID: String, timeout: Duration) async throws {}

    func shutdown() async {
        shutdowns += 1
        releaseStart()
    }

    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        throw CodexAppServerError.unavailable
    }

    func waitUntilStartEntered() async {
        while !startEntered { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func releaseStart() {
        startReleased = true
        let pending = startWaiters
        startWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func shutdownCallCount() -> Int { shutdowns }
}

private actor BlockingShutdownCodexProvider: CodexProviderConnecting {
    private var shutdowns = 0
    private var shutdownEntered = false
    private var shutdownReleased = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    func probe() async -> CodexConnectionUpdate {
        CodexConnectionUpdate(state: .missing, registration: nil)
    }

    func startLogin() async -> CodexConnectionUpdate { await probe() }
    func cancelLogin(loginID: String) async -> CodexConnectionUpdate { await probe() }
    func completeLogin(loginID: String) async -> CodexConnectionUpdate { await probe() }

    func shutdown() async {
        shutdowns += 1
        shutdownEntered = true
        guard !shutdownReleased else { return }
        await withCheckedContinuation { shutdownWaiters.append($0) }
    }

    func waitUntilShutdownEntered() async {
        while !shutdownEntered { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func releaseShutdown() {
        shutdownReleased = true
        let pending = shutdownWaiters
        shutdownWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func shutdownCallCount() -> Int { shutdowns }
}

private extension ClaudeCodeExecutableIdentity {
    static func trustedFixture() -> Self {
        Self(
            canonicalURL: URL(fileURLWithPath: "/trusted/claude"),
            fileIdentity: ClaudeCodeFileIdentity(
                deviceID: 1,
                fileID: 2,
                byteCount: 3,
                mode: 0o100755,
                ownerUserID: 501,
                modifiedSeconds: 4,
                modifiedNanoseconds: 5,
                changedSeconds: 6,
                changedNanoseconds: 7
            ),
            version: ClaudeCodeSecurityPolicy.allowedVersion,
            sha256: ClaudeCodeSecurityPolicy.allowedSHA256,
            signingIdentifier: ClaudeCodeSecurityPolicy.signingIdentifier,
            teamIdentifier: ClaudeCodeSecurityPolicy.teamIdentifier,
            ownerUserID: 501,
            currentUserID: 501,
            permissions: 0o755,
            isRegularFile: true,
            isArm64MachO: true
        )
    }
}
