import Darwin
import Foundation
import XCTest

final class ClaudeCodeAdapterTests: XCTestCase {
    private let snapshot = ProviderSelectionSnapshot(
        providerID: AIProvider.claudeCode.rawValue,
        modelID: "claude-haiku-4-5-20251001",
        selectionRevision: SelectionRevision(rawValue: 4),
        authorizationEpoch: AuthorizationEpoch(rawValue: 9)
    )

    func testQualifiedReleasePinIsExact() {
        XCTAssertEqual(ClaudeCodeSecurityPolicy.allowedVersion, "2.1.220")
        XCTAssertEqual(
            ClaudeCodeSecurityPolicy.allowedSHA256,
            "8addc857f3fe64d5a0368af9ee50321b50afb4a6918ba3ef018ab84f5dbbe081"
        )
    }

    func testExactSignedIdentityIsTheOnlyAllowedExecutable() throws {
        let accepted = ClaudeCodeExecutableIdentity(
            canonicalURL: URL(fileURLWithPath: "/trusted/claude"),
            fileIdentity: .fixture(),
            version: "2.1.220",
            sha256: ClaudeCodeSecurityPolicy.allowedSHA256,
            signingIdentifier: ClaudeCodeSecurityPolicy.signingIdentifier,
            teamIdentifier: ClaudeCodeSecurityPolicy.teamIdentifier,
            ownerUserID: 501,
            currentUserID: 501,
            permissions: 0o755,
            isRegularFile: true,
            isArm64MachO: true
        )
        XCTAssertNoThrow(try ClaudeCodeSecurityPolicy.validate(accepted))

        let rejected = [
            accepted.replacing(sha256: "deadbeef"),
            accepted.replacing(signingIdentifier: "evil"),
            accepted.replacing(teamIdentifier: "EVIL"),
            accepted.replacing(ownerUserID: 0),
            accepted.replacing(permissions: 0o775),
            accepted.replacing(isRegularFile: false),
            accepted.replacing(isArm64MachO: false),
            accepted.replacing(version: "2.1.221"),
        ]
        for identity in rejected {
            XCTAssertThrowsError(try ClaudeCodeSecurityPolicy.validate(identity))
        }
    }

    func testOfficialStandaloneInstallDerivesVersionFromCanonicalExecutableName() {
        XCTAssertEqual(
            SystemClaudeCodeExecutableInspector.releaseVersion(
                at: URL(fileURLWithPath: "/Users/test/.local/share/claude/versions/2.1.220")
            ),
            ClaudeCodeSecurityPolicy.allowedVersion
        )
        XCTAssertEqual(
            SystemClaudeCodeExecutableInspector.releaseVersion(
                at: URL(fileURLWithPath: "/opt/claude/2.1.220/claude")
            ),
            ClaudeCodeSecurityPolicy.allowedVersion
        )
    }

    func testInstalledOfficialBinaryMatchesReleasePinWhenPresent() async throws {
        let launcher = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/bin/claude")
        guard FileManager.default.fileExists(atPath: launcher.path) else { return }
        let identity = try await SystemClaudeCodeExecutableInspector(
            candidates: [launcher]
        ).inspect()
        XCTAssertNoThrow(try ClaudeCodeSecurityPolicy.validate(identity))
    }

    func testAuthenticationProbeUsesOnlyEmptyStdinAuthStatusAndReturnsPinnedIdentity() async throws {
        let transport = MockClaudeTransport(results: [
            .success(stdout: Data(#"{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}"#.utf8)),
        ])
        let adapter = makeAdapter(
            transport: transport,
            snapshots: MockClaudeSnapshots(nil)
        )

        let identity = try await adapter.probeAuthentication(timeout: .seconds(2))

        XCTAssertEqual(identity.canonicalURL.path, "/trusted/claude")
        XCTAssertEqual(identity.version, ClaudeCodeSecurityPolicy.allowedVersion)
        let calls = await transport.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments, ["auth", "status", "--json"])
        XCTAssertTrue(calls[0].stdin.isEmpty)
        XCTAssertEqual(calls[0].workingDirectory.path, "/trusted/empty")
    }

    func testAuthenticationProbeRejectsRoutedAccountWithoutPromptDispatch() async {
        let transport = MockClaudeTransport(results: [
            .success(stdout: Data(#"{"loggedIn":true,"apiProvider":"bedrock"}"#.utf8)),
        ])
        let adapter = makeAdapter(
            transport: transport,
            snapshots: MockClaudeSnapshots(nil)
        )

        do {
            _ = try await adapter.probeAuthentication(timeout: .seconds(2))
            XCTFail("expected routed auth rejection")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeAdapterError, .unapprovedAPIProvider)
        }
        let calls = await transport.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].arguments, ["auth", "status", "--json"])
        XCTAssertTrue(calls[0].stdin.isEmpty)
    }

    func testGenerationUsesMinimalEnvironmentAndAllIsolationFlags() async throws {
        let transport = MockClaudeTransport(results: [
            .success(stdout: Data(#"{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}"#.utf8)),
            .success(stdout: Self.cleanStream("ok")),
        ])
        let snapshots = MockClaudeSnapshots(snapshot)
        let adapter = makeAdapter(transport: transport, snapshots: snapshots)

        let response = try await adapter.generate(request: request(secret: "PRIVATE-CANARY"), selection: snapshot)

        XCTAssertEqual(response.content, "ok")
        XCTAssertEqual(response.provenance.providerID, AIProvider.claudeCode.rawValue)
        XCTAssertEqual(response.provenance.modelID, snapshot.modelID)
        XCTAssertFalse(response.provenance.executedLocally)

        let calls = await transport.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].arguments, ["auth", "status", "--json"])
        let generation = calls[1]
        for flag in [
            "--safe-mode", "--no-session-persistence", "--disable-slash-commands",
            "--no-chrome", "--strict-mcp-config", "--tools", "--setting-sources",
        ] {
            XCTAssertTrue(generation.arguments.contains(flag), flag)
        }
        XCTAssertEqual(Array(generation.arguments.suffix(2)), ["--model", snapshot.modelID])
        XCTAssertFalse(generation.arguments.joined().contains("PRIVATE-CANARY"))
        XCTAssertTrue(String(data: generation.stdin, encoding: .utf8)!.contains("PRIVATE-CANARY"))
        XCTAssertEqual(Set(generation.environment.keys), Set(["HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL"]))
        XCTAssertFalse(generation.environment.keys.contains(where: { $0.contains("ANTHROPIC") || $0.contains("CLAUDE") }))
        XCTAssertEqual(generation.workingDirectory.path, "/trusted/empty")
    }

    func testExecutableReplacementAfterAuthProbeFailsClosedBeforePromptDispatch() async throws {
        let trusted = try await FixedClaudeInspector().inspect()
        let inspector = MutableClaudeInspector(trusted)
        let transport = MockClaudeTransport(results: [
            .success(stdout: Data(#"{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}"#.utf8)),
            .success(stdout: Self.cleanStream("must-not-run")),
        ])
        await transport.onCall(1) {
            await inspector.replace(with: trusted.replacing(
                fileIdentity: trusted.fileIdentity.replacing(fileID: 999)
            ))
        }
        let adapter = makeAdapter(
            transport: transport,
            snapshots: MockClaudeSnapshots(snapshot),
            executableInspector: inspector
        )

        do {
            _ = try await adapter.generate(
                request: request(secret: "PRIVATE-CANARY"),
                selection: snapshot
            )
            XCTFail("a replaced executable reached the prompt-bearing spawn")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeAdapterError, .executableRejected)
        }

        let calls = await transport.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].stdin.isEmpty)
    }

    func testSelectionRevokedAfterExecutableRevalidationFailsClosedBeforePromptDispatch() async {
        let snapshots = MockClaudeSnapshots(snapshot)
        let inspector = RevokingClaudeInspector(snapshots: snapshots)
        let transport = MockClaudeTransport(results: [
            .success(stdout: Data(#"{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}"#.utf8)),
            .success(stdout: Self.cleanStream("must-not-run")),
        ])
        let adapter = makeAdapter(
            transport: transport,
            snapshots: snapshots,
            executableInspector: inspector
        )
        let generationRequest = request(secret: "PRIVATE-CANARY")
        let generationSelection = snapshot

        await assertError(.authorizationChanged, from: Task {
            try await adapter.generate(
                request: generationRequest,
                selection: generationSelection
            )
        })

        let calls = await transport.calls()
        XCTAssertEqual(calls.count, 1, "revocation after binary revalidation must stop prompt dispatch")
        XCTAssertFalse(calls.contains { invocation in
            String(data: invocation.stdin, encoding: .utf8)?.contains("PRIVATE-CANARY") == true
        })
    }

    func testRoutedAuthAndStaleAuthorizationFailBeforePromptDispatch() async {
        for provider in ["bedrock", "vertex", "foundry"] {
            let transport = MockClaudeTransport(results: [
                .success(stdout: Data(("{\"loggedIn\":true,\"apiProvider\":\"" + provider + "\"}").utf8)),
            ])
            let snapshots = MockClaudeSnapshots(snapshot)
            let adapter = makeAdapter(transport: transport, snapshots: snapshots)
            let routedRequest = request()
            let routedSelection = snapshot
            await assertError(.unapprovedAPIProvider, from: Task {
                try await adapter.generate(request: routedRequest, selection: routedSelection)
            })
            let callCount = await transport.callCount()
            XCTAssertEqual(callCount, 1)
        }

        let transport = MockClaudeTransport(results: [
            .success(stdout: Data(#"{"loggedIn":true,"apiProvider":"firstParty"}"#.utf8)),
        ])
        let snapshots = MockClaudeSnapshots(snapshot)
        await transport.onCall(1) {
            await snapshots.set(nil)
        }
        let adapter = makeAdapter(transport: transport, snapshots: snapshots)
        let staleRequest = request()
        let staleSelection = snapshot
        await assertError(.authorizationChanged, from: Task {
            try await adapter.generate(request: staleRequest, selection: staleSelection)
        })
        let callCount = await transport.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testToolFileHookAndUnknownEventsFailClosedWithoutLeakingPrompt() async {
        let hostileLines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}"#,
            #"{"type":"tool_use","name":"Read"}"#,
            #"{"type":"hook_started","hook":"evil"}"#,
            #"{"type":"file_write","path":"/tmp/x"}"#,
            #"{"type":"future_event","data":"unknown"}"#,
        ]

        for line in hostileLines {
            let transport = MockClaudeTransport(results: [
                .success(stdout: Data(#"{"loggedIn":true,"apiProvider":"firstParty"}"#.utf8)),
                .success(stdout: Data((line + "\n").utf8)),
            ])
            let adapter = makeAdapter(transport: transport, snapshots: MockClaudeSnapshots(snapshot))
            do {
                _ = try await adapter.generate(request: request(secret: "PRIVATE-CANARY"), selection: snapshot)
                XCTFail("expected security rejection for \(line)")
            } catch {
                XCTAssertEqual(error as? ClaudeCodeAdapterError, .forbiddenEvent)
                XCTAssertFalse(String(describing: error).contains("PRIVATE-CANARY"))
                XCTAssertFalse(String(describing: error).contains("/tmp/x"))
            }
        }
    }

    func testInitMustAdvertiseNoToolsAndResultMustBeBoundedAndWellFormed() async {
        let withTools = [
            #"{"type":"system","subtype":"init","tools":["Read"]}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#,
        ].joined(separator: "\n") + "\n"
        let toolTransport = MockClaudeTransport(results: [
            .success(stdout: Data(#"{"loggedIn":true,"apiProvider":"firstParty"}"#.utf8)),
            .success(stdout: Data(withTools.utf8)),
        ])
        let toolSelection = snapshot
        let toolRequest = request()
        let toolAdapter = makeAdapter(
            transport: toolTransport,
            snapshots: MockClaudeSnapshots(toolSelection)
        )
        await assertError(.forbiddenEvent, from: Task {
            try await toolAdapter.generate(request: toolRequest, selection: toolSelection)
        })

        let oversizedTransport = MockClaudeTransport(results: [
            .success(stdout: Data(#"{"loggedIn":true,"apiProvider":"firstParty"}"#.utf8)),
            .success(stdout: Data(repeating: 65, count: ClaudeCodeSecurityPolicy.maximumOutputBytes + 1)),
        ])
        let oversizedSelection = snapshot
        let oversizedRequest = request()
        let oversizedAdapter = makeAdapter(
            transport: oversizedTransport,
            snapshots: MockClaudeSnapshots(oversizedSelection)
        )
        await assertError(.outputTooLarge, from: Task {
            try await oversizedAdapter.generate(
                request: oversizedRequest,
                selection: oversizedSelection
            )
        })
    }

    func testTransportErrorsAreNormalizedAndNeverEchoStderrOrPrompt() async {
        let transport = MockClaudeTransport(results: [
            .failure(.processFailed),
        ])
        let adapter = makeAdapter(transport: transport, snapshots: MockClaudeSnapshots(snapshot))
        do {
            _ = try await adapter.generate(request: request(secret: "PRIVATE-CANARY"), selection: snapshot)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeAdapterError, .processFailed)
            XCTAssertFalse(String(describing: error).contains("PRIVATE-CANARY"))
        }
    }

    func testSystemTransportDoesNotLaunchWhenAlreadyCancelled() async throws {
        let sentinel = FileManager.default.temporaryDirectory
            .appending(path: "claude-pre-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let gate = ClaudeCancellationGate()
        let invocation = processInvocation(
            script: "printf launched > '\(sentinel.path)'; sleep 0.25"
        )
        let task = Task {
            await gate.wait()
            return try await SystemClaudeCodeProcessTransport().run(invocation)
        }
        await gate.waitUntilEntered()

        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("an already-cancelled transport unexpectedly launched")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sentinel.path),
            "cancellation before PID publication must prevent launch"
        )
    }

    func testSystemTransportRejectsRevocationAfterSpawnBeforePromptDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "claude-post-spawn-admission-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let captured = directory.appending(path: "captured")
        let snapshots = MockClaudeSnapshots(snapshot)
        let gate = ClaudeCancellationGate()
        let admission = ClaudeCodePromptAdmission(
            snapshotProvider: snapshots,
            selection: snapshot,
            consumer: .ask
        )
        let invocation = processInvocation(
            script: "cat > '\(captured.path)'",
            stdin: Data("PRIVATE-CANARY".utf8),
            promptAdmission: admission
        )
        let task = Task {
            try await SystemClaudeCodeProcessTransport(
                beforePromptDispatch: { await gate.wait() }
            ).run(invocation)
        }

        await gate.waitUntilEntered()
        await snapshots.set(nil)
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("revocation after process spawn must stop prompt dispatch")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeAdapterError, .authorizationChanged)
        }
        XCTAssertFalse(
            (try? Data(contentsOf: captured).contains(Data("PRIVATE-CANARY".utf8))) == true,
            "revoked prompt bytes reached provider stdin"
        )
    }

    func testSystemTransportStopsBetweenPromptChunksAfterRevocation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "claude-mid-prompt-revocation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let captured = directory.appending(path: "captured")
        let firstChunkRead = directory.appending(path: "first-chunk-read")
        let snapshots = RevokingAfterFirstChunkClaudeSnapshots(
            selection: snapshot,
            firstChunkReadURL: firstChunkRead
        )
        let admission = ClaudeCodePromptAdmission(
            snapshotProvider: snapshots,
            selection: snapshot,
            consumer: .ask
        )
        var prompt = Data(repeating: 65, count: 4 * 1_024)
        prompt.append(Data("PRIVATE-CANARY".utf8))
        let invocation = processInvocation(
            script: "/bin/dd bs=4096 count=1 of='\(captured.path)' 2>/dev/null; : > '\(firstChunkRead.path)'; cat >> '\(captured.path)'",
            stdin: prompt,
            promptAdmission: admission
        )

        do {
            _ = try await SystemClaudeCodeProcessTransport().run(invocation)
            XCTFail("revocation between prompt chunks must stop dispatch")
        } catch {
            XCTAssertEqual(error as? ClaudeCodeAdapterError, .authorizationChanged)
        }

        let capturedPrompt = try Data(contentsOf: captured)
        XCTAssertEqual(capturedPrompt.count, 4 * 1_024)
        XCTAssertFalse(capturedPrompt.contains(Data("PRIVATE-CANARY".utf8)))
    }

    func testSystemTransportCreatesAndReapsDedicatedProcessGroup() async throws {
        let state = FileManager.default.temporaryDirectory
            .appending(path: "claude-process-group-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let invocation = processInvocation(
            script: "sleep 5 & child=$!; pgid=$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' '); printf '%s %s %s' $$ \"$pgid\" \"$child\" > '\(state.path)'; wait \"$child\""
        )
        let task = Task {
            try await SystemClaudeCodeProcessTransport().run(invocation)
        }
        let identifiers = try await waitForProcessIdentifiers(at: state)
        let parent = identifiers[0]
        let group = identifiers[1]
        let child = identifiers[2]
        defer {
            _ = Darwin.kill(-parent, SIGKILL)
            _ = Darwin.kill(parent, SIGKILL)
            _ = Darwin.kill(child, SIGKILL)
        }

        XCTAssertEqual(group, parent, "the CLI must lead its process group at exec time")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled transport unexpectedly completed")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        let parentGone = await waitUntilProcessGone(parent)
        let childGone = await waitUntilProcessGone(child)
        XCTAssertTrue(parentGone, "parent process was not reaped")
        XCTAssertTrue(childGone, "child process survived group cancellation")
    }

    func testRouterShutdownReapsActiveProcessProviderGroup() async throws {
        let state = FileManager.default.temporaryDirectory
            .appending(path: "claude-router-shutdown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: state) }
        let snapshots = MockClaudeSnapshots(snapshot)
        let adapter = LongRunningClaudeProcessAdapter(stateURL: state)
        let registry = SingleClaudeAdapterRegistry(
            registration: LLMAdapterRegistration(
                providerID: snapshot.providerID,
                executedLocally: false,
                adapter: adapter
            )
        )
        let router = LLMRouter(
            snapshotProvider: snapshots,
            adapterRegistry: registry,
            drainAcknowledgementTimeout: .milliseconds(300)
        )
        let generationRequest = request()
        let generation = Task {
            try await router.generate(generationRequest)
        }
        let identifiers = try await waitForProcessIdentifiers(at: state)
        let parent = identifiers[0]
        let group = identifiers[1]
        let child = identifiers[2]
        defer {
            _ = Darwin.kill(-parent, SIGKILL)
            _ = Darwin.kill(parent, SIGKILL)
            _ = Darwin.kill(child, SIGKILL)
        }

        XCTAssertEqual(group, parent, "the provider must lead its process group")
        let completed = await router.shutdown(timeout: .seconds(2))

        XCTAssertTrue(completed, "termination must wait for process cleanup acknowledgement")
        do {
            _ = try await generation.value
            XCTFail("shutdown generation unexpectedly completed")
        } catch {
            XCTAssertEqual(error as? LLMRouterError, .routerShuttingDown)
        }
        let parentGone = await waitUntilProcessGone(parent)
        let childGone = await waitUntilProcessGone(child)
        XCTAssertTrue(parentGone, "provider parent process was not reaped")
        XCTAssertTrue(childGone, "provider child process survived app shutdown")
    }

    private func makeAdapter(
        transport: MockClaudeTransport,
        snapshots: MockClaudeSnapshots,
        executableInspector: any ClaudeCodeExecutableInspecting = FixedClaudeInspector()
    ) -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(
            executableInspector: executableInspector,
            transport: transport,
            snapshotProvider: snapshots,
            workingDirectory: URL(fileURLWithPath: "/trusted/empty", isDirectory: true),
            environmentSource: {
                [
                    "HOME": "/Users/test", "USER": "test", "LOGNAME": "test",
                    "TMPDIR": "/tmp", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
                    "LC_ALL": "en_US.UTF-8", "ANTHROPIC_API_KEY": "must-not-pass",
                    "CLAUDE_CONFIG_DIR": "/evil",
                ]
            }
        )
    }

    private func request(secret: String = "hello") -> LLMRequest {
        LLMRequest(
            id: UUID(), consumer: .ask, priority: .ask,
            systemPrompt: "system", userPrompt: secret,
            maximumOutputTokens: 64, timeout: .seconds(5)
        )
    }

    private func processInvocation(
        script: String,
        stdin: Data = Data(),
        promptAdmission: ClaudeCodePromptAdmission? = nil
    ) -> ClaudeCodeProcessInvocation {
        let executableURL = URL(fileURLWithPath: "/bin/sh")
        let fileIdentity = try! SystemClaudeCodeExecutableInspector
            .currentFileIdentity(at: executableURL)
        return ClaudeCodeProcessInvocation(
            executableURL: executableURL,
            trustedExecutableIdentity: FixedClaudeInspector.identity.replacing(
                canonicalURL: executableURL,
                fileIdentity: fileIdentity
            ),
            executableVerifier: AllowingClaudeVerifier(),
            promptAdmission: promptAdmission,
            arguments: ["-c", script],
            stdin: stdin,
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: .seconds(10),
            maximumStdoutBytes: 4_096,
            maximumStderrBytes: 4_096
        )
    }

    private func waitForProcessIdentifiers(at url: URL) async throws -> [pid_t] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: url),
               let text = String(data: data, encoding: .utf8) {
                let values = text.split(whereSeparator: \.isWhitespace).compactMap {
                    pid_t($0)
                }
                if values.count == 3 { return values }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ClaudeTransportTestError.processStateUnavailable
    }

    private func waitUntilProcessGone(_ processIdentifier: pid_t) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            errno = 0
            if Darwin.kill(processIdentifier, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static func cleanStream(_ answer: String) -> Data {
        Data(([
            #"{"type":"system","subtype":"init","tools":[]}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"partial"}]}}"#,
            "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"\(answer)\"}",
        ].joined(separator: "\n") + "\n").utf8)
    }

    private func assertError(
        _ expected: ClaudeCodeAdapterError,
        from task: Task<LLMResponse, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ClaudeCodeAdapterError, expected, file: file, line: line)
        }
    }
}

private enum ClaudeTransportTestError: Error {
    case processStateUnavailable
}

private actor ClaudeCancellationGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        while !entered { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct FixedClaudeInspector: ClaudeCodeExecutableInspecting {
    static let identity = ClaudeCodeExecutableIdentity(
        canonicalURL: URL(fileURLWithPath: "/trusted/claude"),
        fileIdentity: .fixture(),
        version: "2.1.220",
        sha256: ClaudeCodeSecurityPolicy.allowedSHA256,
        signingIdentifier: ClaudeCodeSecurityPolicy.signingIdentifier,
        teamIdentifier: ClaudeCodeSecurityPolicy.teamIdentifier,
        ownerUserID: 501,
        currentUserID: 501,
        permissions: 0o755,
        isRegularFile: true,
        isArm64MachO: true
    )

    func inspect() async throws -> ClaudeCodeExecutableIdentity {
        Self.identity
    }
}

private struct AllowingClaudeVerifier: ClaudeCodeExecutableVerifying {
    func revalidate(_ trustedIdentity: ClaudeCodeExecutableIdentity) async throws {}
}

private actor MutableClaudeInspector: ClaudeCodeExecutableInspecting {
    private var identity: ClaudeCodeExecutableIdentity

    init(_ identity: ClaudeCodeExecutableIdentity) {
        self.identity = identity
    }

    func inspect() async throws -> ClaudeCodeExecutableIdentity { identity }

    func replace(with identity: ClaudeCodeExecutableIdentity) {
        self.identity = identity
    }
}

private actor RevokingClaudeInspector: ClaudeCodeExecutableInspecting {
    private let snapshots: MockClaudeSnapshots
    private var revalidationCount = 0

    init(snapshots: MockClaudeSnapshots) {
        self.snapshots = snapshots
    }

    func inspect() async throws -> ClaudeCodeExecutableIdentity {
        FixedClaudeInspector.identity
    }

    func revalidate(_ trustedIdentity: ClaudeCodeExecutableIdentity) async throws {
        guard trustedIdentity == FixedClaudeInspector.identity else {
            throw ClaudeCodeAdapterError.executableRejected
        }
        revalidationCount += 1
        if revalidationCount == 2 {
            await snapshots.set(nil)
        }
    }
}

private actor MockClaudeSnapshots: LLMSelectionSnapshotProviding {
    private var value: ProviderSelectionSnapshot?
    init(_ value: ProviderSelectionSnapshot?) { self.value = value }
    func currentSnapshot(for consumer: AIConsumer) async -> ProviderSelectionSnapshot? { value }
    func set(_ value: ProviderSelectionSnapshot?) { self.value = value }
}

private actor RevokingAfterFirstChunkClaudeSnapshots: LLMSelectionSnapshotProviding {
    private let selection: ProviderSelectionSnapshot
    private let firstChunkReadURL: URL
    private var validationCount = 0

    init(selection: ProviderSelectionSnapshot, firstChunkReadURL: URL) {
        self.selection = selection
        self.firstChunkReadURL = firstChunkReadURL
    }

    func currentSnapshot(for consumer: AIConsumer) async -> ProviderSelectionSnapshot? {
        validationCount += 1
        guard validationCount > 1 else { return selection }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: firstChunkReadURL.path) { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }
}

private actor SingleClaudeAdapterRegistry: LLMAdapterRegistering {
    private let registration: LLMAdapterRegistration

    init(registration: LLMAdapterRegistration) {
        self.registration = registration
    }

    func registration(for providerID: String) async -> LLMAdapterRegistration? {
        registration.providerID == providerID ? registration : nil
    }
}

private actor LongRunningClaudeProcessAdapter: LLMAdapter {
    private let stateURL: URL
    private let transport = SystemClaudeCodeProcessTransport()

    init(stateURL: URL) {
        self.stateURL = stateURL
    }

    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        let script = "sleep 30 & child=$!; pgid=$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' '); printf '%s %s %s' $$ \"$pgid\" \"$child\" > '\(stateURL.path)'; wait \"$child\""
        let executableURL = URL(fileURLWithPath: "/bin/sh")
        let fileIdentity = try SystemClaudeCodeExecutableInspector
            .currentFileIdentity(at: executableURL)
        let invocation = ClaudeCodeProcessInvocation(
            executableURL: executableURL,
            trustedExecutableIdentity: FixedClaudeInspector.identity.replacing(
                canonicalURL: executableURL,
                fileIdentity: fileIdentity
            ),
            executableVerifier: AllowingClaudeVerifier(),
            promptAdmission: nil,
            arguments: ["-c", script],
            stdin: Data(),
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: .seconds(30),
            maximumStdoutBytes: 4_096,
            maximumStderrBytes: 4_096
        )
        _ = try await transport.run(invocation)
        throw ClaudeCodeAdapterError.processFailed
    }
}

private actor MockClaudeTransport: ClaudeCodeProcessTransport {
    enum ResultFixture: Sendable {
        case success(stdout: Data)
        case failure(ClaudeCodeAdapterError)
    }

    private var results: [ResultFixture]
    private var invocations: [ClaudeCodeProcessInvocation] = []
    private var callbacks: [Int: @Sendable () async -> Void] = [:]

    init(results: [ResultFixture]) { self.results = results }

    func run(_ invocation: ClaudeCodeProcessInvocation) async throws -> ClaudeCodeProcessResult {
        guard invocation.stdin.isEmpty || invocation.promptAdmission != nil else {
            throw ClaudeCodeAdapterError.authorizationChanged
        }
        guard invocation.executableURL == invocation.trustedExecutableIdentity.canonicalURL else {
            throw ClaudeCodeAdapterError.executableRejected
        }
        try await invocation.executableVerifier.revalidate(
            invocation.trustedExecutableIdentity
        )
        try await invocation.promptAdmission?.validate()
        invocations.append(invocation)
        let index = invocations.count
        if let callback = callbacks[index] { await callback() }
        guard !results.isEmpty else { throw ClaudeCodeAdapterError.processFailed }
        switch results.removeFirst() {
        case .success(let stdout):
            return ClaudeCodeProcessResult(exitStatus: 0, stdout: stdout, stderr: Data())
        case .failure(let error):
            throw error
        }
    }

    func onCall(_ index: Int, _ callback: @escaping @Sendable () async -> Void) {
        callbacks[index] = callback
    }
    func calls() -> [ClaudeCodeProcessInvocation] { invocations }
    func callCount() -> Int { invocations.count }
}

private extension ClaudeCodeExecutableIdentity {
    func replacing(
        canonicalURL: URL? = nil,
        fileIdentity: ClaudeCodeFileIdentity? = nil,
        version: String? = nil,
        sha256: String? = nil,
        signingIdentifier: String? = nil,
        teamIdentifier: String? = nil,
        ownerUserID: UInt32? = nil,
        permissions: UInt16? = nil,
        isRegularFile: Bool? = nil,
        isArm64MachO: Bool? = nil
    ) -> Self {
        Self(
            canonicalURL: canonicalURL ?? self.canonicalURL,
            fileIdentity: fileIdentity ?? self.fileIdentity,
            version: version ?? self.version,
            sha256: sha256 ?? self.sha256,
            signingIdentifier: signingIdentifier ?? self.signingIdentifier,
            teamIdentifier: teamIdentifier ?? self.teamIdentifier,
            ownerUserID: ownerUserID ?? self.ownerUserID,
            currentUserID: currentUserID,
            permissions: permissions ?? self.permissions,
            isRegularFile: isRegularFile ?? self.isRegularFile,
            isArm64MachO: isArm64MachO ?? self.isArm64MachO
        )
    }
}

private extension ClaudeCodeFileIdentity {
    static func fixture() -> Self {
        Self(
            deviceID: 1,
            fileID: 2,
            byteCount: 3,
            mode: 0o100755,
            ownerUserID: 501,
            modifiedSeconds: 4,
            modifiedNanoseconds: 5,
            changedSeconds: 6,
            changedNanoseconds: 7
        )
    }

    func replacing(fileID: UInt64) -> Self {
        Self(
            deviceID: deviceID,
            fileID: fileID,
            byteCount: byteCount,
            mode: mode,
            ownerUserID: ownerUserID,
            modifiedSeconds: modifiedSeconds,
            modifiedNanoseconds: modifiedNanoseconds,
            changedSeconds: changedSeconds,
            changedNanoseconds: changedNanoseconds
        )
    }
}
