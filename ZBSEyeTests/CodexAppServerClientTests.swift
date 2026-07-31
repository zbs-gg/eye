import Darwin
import Foundation
import XCTest

final class CodexAppServerClientTests: XCTestCase {
    private let selection = ProviderSelectionSnapshot(
        providerID: "codex",
        modelID: "gpt-5.4-mini",
        selectionRevision: SelectionRevision(rawValue: 3),
        authorizationEpoch: AuthorizationEpoch(rawValue: 9)
    )

    func testQualifiedReleasePinIsExact() {
        XCTAssertEqual(CodexBinaryPolicy.allowedVersion, "0.145.0")
        XCTAssertEqual(
            CodexBinaryPolicy.allowedSHA256,
            "1da3f4e0e96028b8a771814293c3033dafd1971f943f6c7e79b0897fe705f590"
        )
    }

    func testRealStdinWriterChecksCancellationAtFileDescriptorBoundary() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&descriptors), 0)
        let reader = descriptors[0]
        let writer = CodexStdinWriter(descriptor: descriptors[1])
        defer { Darwin.close(reader) }
        let admission = CodexPromptAdmission(
            snapshotProvider: CodexMockSnapshotProvider(selection),
            selection: selection,
            consumer: .ask
        )
        admission.cancel()

        do {
            try await writer.write(Data("PRIVATE-CANARY".utf8), promptAdmission: admission)
            XCTFail("cancelled prompt reached the real fd writer")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        await writer.close()
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(reader, &byte, 1), 0)
    }

    func testBinaryPolicyAcceptsOnlyExactNativeSignedArtifact() throws {
        let trusted = CodexBinaryInspection.trustedFixture(
            url: URL(fileURLWithPath: "/trusted/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"),
            ownerUID: 501
        )
        XCTAssertNoThrow(try CodexBinaryPolicy.validate(trusted, currentUID: 501))

        let hostile: [CodexBinaryInspection] = [
            trusted.with(version: "0.145.1-darwin-arm64"),
            trusted.with(sha256: String(repeating: "0", count: 64)),
            trusted.with(teamIdentifier: "EVILTEAM"),
            trusted.with(signingAuthority: "Developer ID Application: Not OpenAI (EVILTEAM)"),
            trusted.with(format: .javaScript),
            trusted.with(format: .machOX86_64),
            trusted.with(isSymlink: true),
            trusted.with(isRegularFile: false),
            trusted.with(linkCount: 2),
            trusted.with(ownerUID: 777),
            trusted.with(mode: 0o100777),
            trusted.with(packageLayoutIsCanonical: false),
        ]

        for inspection in hostile {
            XCTAssertThrowsError(
                try CodexBinaryPolicy.validate(inspection, currentUID: 501),
                "\(inspection)"
            )
        }
    }

    func testLocatorDerivesNativePackageBinaryWithoutExecutingJSWrapper() async throws {
        let wrapper = URL(
            fileURLWithPath: "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"
        )
        let expectedNativePath = "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        let native = CodexNativeBinaryLocator.nativeCandidate(
            fromCanonicalLauncher: wrapper
        )
        XCTAssertEqual(native?.path, expectedNativePath)
        XCTAssertEqual(
            native.flatMap(CodexNativeBinaryLocator.packageRoot(fromNativeCandidate:))?.path,
            "/opt/homebrew/lib/node_modules/@openai/codex"
        )

        if FileManager.default.fileExists(atPath: expectedNativePath) {
            let inspection = try await CodexSystemBinaryInspector().inspect(
                URL(fileURLWithPath: expectedNativePath)
            )
            XCTAssertNoThrow(try CodexBinaryPolicy.validate(inspection))
        }

        let scriptOutsidePackage = URL(fileURLWithPath: "/tmp/codex.js")
        XCTAssertNil(
            CodexNativeBinaryLocator.nativeCandidate(
                fromCanonicalLauncher: scriptOutsidePackage
            )
        )
    }

    func testSystemResolverHasSafeDefaultLaunchersAndDistinguishesMissingFromUntrusted() async {
        let home = URL(fileURLWithPath: "/Users/tester")
        XCTAssertEqual(
            CodexSystemExecutableResolver.defaultLauncherURLs(homeDirectory: home).map(\.path),
            [
                "/Users/tester/.local/bin/codex",
                "/Users/tester/.npm-global/bin/codex",
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
            ]
        )

        let missing = CodexSystemExecutableResolver(
            launcherURLs: [],
            inspector: RejectingCodexBinaryInspector()
        )
        await assertResolveError(.executableMissing, resolver: missing)

        let untrusted = CodexSystemExecutableResolver(
            launcherURLs: [URL(fileURLWithPath: "/installed/codex")],
            inspector: RejectingCodexBinaryInspector(),
            launcherExists: { _ in true }
        )
        await assertResolveError(.untrustedBinary, resolver: untrusted)
    }

    func testBinaryDriftAfterResolutionFailsClosedBeforeProcessOpen() async {
        let resolver = CodexDriftingExecutableResolver()
        let home = CodexMockHomeManager()
        let connection = CodexScriptedConnection()
        let transport = CodexScriptedTransport(connection: connection)
        let client = CodexAppServerClient(
            executableResolver: resolver,
            homeManager: home,
            processTransport: transport,
            snapshotProvider: CodexMockSnapshotProvider(selection)
        )

        do {
            _ = try await client.probeConnection(timeout: .seconds(1))
            XCTFail("expected executable drift to fail closed")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .untrustedBinary)
        }

        let resolveCount = await resolver.resolveCount()
        let launch = await transport.lastLaunch()
        let destroyCount = await home.destroyCount()
        XCTAssertEqual(resolveCount, 2)
        XCTAssertNil(launch)
        XCTAssertEqual(destroyCount, 1)
    }

    func testCurrentCatalogUsesOnlyInitializeAccountAndModelListWithoutPromptDispatch() async throws {
        let fixture = Fixture(selection: selection)
        await fixture.connection.enqueue(contentsOf: [
            fixture.initializeFrame(),
            fixture.accountFrame(),
            fixture.modelListFrame(models: ["gpt-5.4-mini", "gpt-5.4"]),
        ])

        let catalog = try await fixture.client.currentModelCatalog(timeout: .seconds(2))

        XCTAssertEqual(catalog, ["gpt-5.4-mini", "gpt-5.4"])
        let methods = await fixture.connection.sentMethods()
        let terminations = await fixture.connection.terminationCount()
        let destroys = await fixture.home.destroyCount()
        XCTAssertEqual(methods, ["initialize", "initialized", "account/read", "model/list"])
        XCTAssertEqual(terminations, 1)
        XCTAssertEqual(destroys, 1)
    }

    func testCurrentCatalogReportsReadyWhenChatGPTLoginIsMissingWithoutStartingLoginOrPrompt() async throws {
        let fixture = Fixture(selection: selection)
        await fixture.connection.enqueue(contentsOf: [
            fixture.initializeFrame(),
            fixture.accountFrame(account: NSNull()),
        ])

        let status = try await fixture.client.probeConnection(timeout: .seconds(2))

        XCTAssertEqual(status, .ready(version: CodexBinaryPolicy.allowedVersion))
        let methods = await fixture.connection.sentMethods()
        let terminations = await fixture.connection.terminationCount()
        let destroys = await fixture.home.destroyCount()
        XCTAssertEqual(methods, ["initialize", "initialized", "account/read"])
        XCTAssertEqual(terminations, 1)
        XCTAssertEqual(destroys, 1)
    }

    func testDedicatedHomeIsPrivateGeneratedAndDoesNotImportHostileUserConfig() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostileGlobal = root.appending(path: "hostile-user-config.toml")
        try Data("CANARY_PROMPT = 'steal history'".utf8).write(to: hostileGlobal)
        let manager = CodexSystemHomeManager(rootURL: root.appending(path: "ZBS Eye Codex"))

        let prepared = try await manager.prepareSession()
        let config = try String(contentsOf: prepared.configURL, encoding: .utf8)
        var info = stat()
        XCTAssertEqual(lstat(prepared.homeURL.path, &info), 0)

        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertFalse(config.contains("CANARY_PROMPT"))
        XCTAssertTrue(config.contains("cli_auth_credentials_store = \"keyring\""))
        XCTAssertTrue(config.contains("mcp_oauth_credentials_store = \"keyring\""))
        XCTAssertTrue(config.contains("persistence = \"none\""))
        XCTAssertTrue(config.contains("shell_tool = false"))
        XCTAssertTrue(config.contains("plugins = false"))
        XCTAssertTrue(config.contains("apps = false"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.homeURL.appending(path: "auth.json").path))

        try await manager.audit(prepared, phase: .beforeLaunch)
        await manager.destroy(prepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.homeURL.path))
    }

    func testDedicatedHomeKeepsStableKeyringIdentityAcrossSessions() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = CodexSystemHomeManager(rootURL: root.appending(path: "ZBS Eye Codex"))

        let login = try await manager.prepareSession()
        do {
            _ = try await manager.prepareSession()
            XCTFail("a second process must not share the stable CODEX_HOME")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .unavailable)
        }
        await manager.destroy(login)
        let generation = try await manager.prepareSession()

        XCTAssertEqual(
            login.homeURL,
            generation.homeURL,
            "Codex hashes the canonical CODEX_HOME path into its Keychain account name"
        )
        await manager.destroy(login)
        try await manager.audit(generation, phase: .beforeLaunch)
        await manager.destroy(generation)
    }

    func testDedicatedHomeRemovesCrashLeftoversBeforeReuse() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let managerRoot = root.appending(path: "ZBS Eye Codex")
        let staleSession = managerRoot.appending(path: "session")
        try FileManager.default.createDirectory(
            at: staleSession,
            withIntermediateDirectories: true
        )
        try Data("stale prompt state".utf8).write(
            to: staleSession.appending(path: "unexpected.json")
        )
        let manager = CodexSystemHomeManager(rootURL: managerRoot)

        let prepared = try await manager.prepareSession()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: prepared.homeURL.appending(path: "unexpected.json").path
            )
        )
        try await manager.audit(prepared, phase: .beforeLaunch)
        await manager.destroy(prepared)
    }

    func testPOSIXTransportCreatesAndReapsDedicatedProcessGroup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let specification = CodexLaunchSpecification(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            trustedExecutable: try verifiedExecutable(at: URL(fileURLWithPath: "/bin/sh")),
            arguments: ["-c", "printf '%s\\n' '{\"ready\":true}'; sleep 30 & wait"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin",
                "LANG": "C",
            ],
            workingDirectoryURL: root,
            createsDedicatedProcessGroup: true,
            usesLoginShell: false,
            maximumStdoutBytes: 4_096,
            maximumStderrBytes: 4_096
        )
        let opened = try await CodexPOSIXProcessTransport(
            executableVerifier: CodexAcceptingExecutableVerifier()
        ).open(specification)
        let connection = try XCTUnwrap(opened as? CodexPOSIXConnection)
        let processIdentifier = connection.processIdentifier

        let frame = try await connection.receive(
            maximumLineBytes: 1_024,
            timeout: .seconds(2)
        )
        XCTAssertEqual(String(data: frame.stdoutLine, encoding: .utf8), "{\"ready\":true}")
        XCTAssertEqual(getpgid(processIdentifier), processIdentifier)

        await connection.terminateProcessGroup(gracePeriod: .milliseconds(100))
        errno = 0
        XCTAssertEqual(Darwin.kill(-processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testPOSIXTransportRejectsReplacedExecutableAtSpawnBoundary() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let replacement = root.appending(path: "codex")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: replacement)
        XCTAssertEqual(chmod(replacement.path, 0o700), 0)
        let trustedExecutable = try verifiedExecutable(at: replacement)
        let specification = CodexLaunchSpecification(
            executableURL: replacement,
            trustedExecutable: trustedExecutable,
            arguments: [],
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "LANG": "C"],
            workingDirectoryURL: root,
            createsDedicatedProcessGroup: true,
            usesLoginShell: false,
            maximumStdoutBytes: 4_096,
            maximumStderrBytes: 4_096
        )

        do {
            let connection = try await CodexPOSIXProcessTransport(
                executableVerifier: CodexReplacingExecutableVerifier(
                    executableURL: replacement
                )
            ).open(specification)
            await connection.terminateProcessGroup(gracePeriod: .milliseconds(100))
            XCTFail("expected the replacement executable to be rejected before spawn")
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, .untrustedBinary)
        }
    }

    func testPOSIXTransportNeverBlocksWhenChildStopsReadingStdin() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let specification = CodexLaunchSpecification(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            trustedExecutable: try verifiedExecutable(at: URL(fileURLWithPath: "/bin/sh")),
            arguments: ["-c", "sleep 30"],
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "LANG": "C"],
            workingDirectoryURL: root,
            createsDedicatedProcessGroup: true,
            usesLoginShell: false,
            maximumStdoutBytes: 1_048_576,
            maximumStderrBytes: 4_096
        )
        let connection = try await CodexPOSIXProcessTransport(
            executableVerifier: CodexAcceptingExecutableVerifier()
        ).open(specification)
        let line = Data(repeating: 0x78, count: CodexAppServerClient.maximumLineBytes - 1)
        var failedClosed = false
        for _ in 0..<32 {
            do {
                try await connection.send(line, promptAdmission: nil)
            } catch CodexAppServerError.transportUnavailable {
                failedClosed = true
                break
            }
        }
        await connection.terminateProcessGroup(gracePeriod: .milliseconds(100))
        XCTAssertTrue(failedClosed)
    }

    func testTerminalPipeFailureWinsOverPreviouslyQueuedStdout() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let specification = CodexLaunchSpecification(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            trustedExecutable: try verifiedExecutable(at: URL(fileURLWithPath: "/bin/sh")),
            arguments: [
                "-c",
                "printf '%s\\n' '{\"content\":\"must-discard\"}'; printf 'stderr-flood' >&2; sleep 30",
            ],
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "LANG": "C"],
            workingDirectoryURL: root,
            createsDedicatedProcessGroup: true,
            usesLoginShell: false,
            maximumStdoutBytes: 4_096,
            maximumStderrBytes: 4
        )
        let connection = try await CodexPOSIXProcessTransport(
            executableVerifier: CodexAcceptingExecutableVerifier()
        ).open(specification)
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await connection.receive(maximumLineBytes: 1_024, timeout: .seconds(1))
            XCTFail("terminal stderr failure must discard queued stdout")
        } catch let error as CodexAppServerError {
            XCTAssertEqual(error, .outputLimitExceeded)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await connection.terminateProcessGroup(gracePeriod: .milliseconds(100))
    }

    func testSignalTargetNeverFallsBackToPossiblyReusedPIDAfterGetpgidFailure() {
        XCTAssertEqual(
            CodexProcessGroupSafety.signalTarget(
                processIdentifier: 99,
                reportedGroupIdentifier: 99
            ),
            -99
        )
        XCTAssertEqual(
            CodexProcessGroupSafety.signalTarget(
                processIdentifier: 99,
                reportedGroupIdentifier: 77
            ),
            99
        )
        XCTAssertNil(
            CodexProcessGroupSafety.signalTarget(
                processIdentifier: 99,
                reportedGroupIdentifier: -1
            )
        )
        XCTAssertNil(
            CodexProcessGroupSafety.signalTarget(
                processIdentifier: 1,
                reportedGroupIdentifier: 1
            )
        )
    }

    func testHappyGenerationUsesLockedTextOnlyProtocolAndReturnsStrictOutput() async throws {
        let fixture = Fixture(selection: selection)
        await fixture.connection.enqueue(contentsOf: fixture.happyGenerationFrames(content: "hello"))
        let request = makeRequest(user: "SECRET_USER_PROMPT")

        let response = try await fixture.client.generate(
            request: request,
            selection: selection
        )

        XCTAssertEqual(response.content, "hello")
        XCTAssertEqual(response.provenance.providerID, selection.providerID)
        XCTAssertEqual(response.provenance.modelID, selection.modelID)
        XCTAssertFalse(response.provenance.executedLocally)

        let methods = await fixture.connection.sentMethods()
        XCTAssertEqual(
            methods,
            ["initialize", "initialized", "account/read", "model/list", "thread/start", "turn/start"]
        )
        let receivedInitialize = await fixture.connection.sentParams(for: "initialize")
        let initialize = try XCTUnwrap(receivedInitialize)
        let capabilities = try XCTUnwrap(initialize.object(for: "capabilities"))
        XCTAssertEqual(capabilities.bool(for: "experimentalApi"), true)
        XCTAssertEqual(capabilities.bool(for: "requestAttestation"), false)
        let receivedThreadStart = await fixture.connection.sentParams(for: "thread/start")
        let threadStart = try XCTUnwrap(receivedThreadStart)
        XCTAssertEqual(threadStart.string(for: "model"), selection.modelID)
        XCTAssertEqual(threadStart.bool(for: "ephemeral"), true)
        XCTAssertEqual(threadStart.string(for: "approvalPolicy"), "never")
        XCTAssertEqual(threadStart.string(for: "approvalsReviewer"), "user")
        XCTAssertEqual(threadStart.string(for: "sandbox"), "read-only")
        XCTAssertEqual(threadStart.array(for: "runtimeWorkspaceRoots")?.count, 0)
        XCTAssertEqual(threadStart.array(for: "environments")?.count, 0)
        XCTAssertEqual(threadStart.array(for: "dynamicTools")?.count, 0)
        XCTAssertEqual(threadStart.bool(for: "experimentalRawEvents"), false)

        let receivedTurnStart = await fixture.connection.sentParams(for: "turn/start")
        let turnStart = try XCTUnwrap(receivedTurnStart)
        XCTAssertEqual(turnStart.string(for: "approvalPolicy"), "never")
        XCTAssertEqual(turnStart.string(for: "approvalsReviewer"), "user")
        XCTAssertEqual(turnStart.array(for: "environments")?.count, 0)
        XCTAssertEqual(turnStart.array(for: "runtimeWorkspaceRoots")?.count, 0)
        XCTAssertEqual(turnStart.object(for: "additionalContext")?.objectCount, 0)
        let inputs = try XCTUnwrap(turnStart.array(for: "input"))
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].string(for: "type"), "text")
        XCTAssertEqual(inputs[0].string(for: "text"), request.userPrompt)

        let receivedLaunch = await fixture.transport.lastLaunch()
        let launch = try XCTUnwrap(receivedLaunch)
        XCTAssertEqual(launch.arguments, ["app-server", "--stdio", "--strict-config"])
        XCTAssertTrue(launch.createsDedicatedProcessGroup)
        XCTAssertFalse(launch.usesLoginShell)
        XCTAssertEqual(Set(launch.environment.keys), ["CODEX_HOME", "HOME", "PATH", "LANG", "LC_ALL", "TMPDIR"])
        XCTAssertEqual(
            launch.environment["HOME"],
            FileManager.default.homeDirectoryForCurrentUser.path,
            "Codex needs the real user home to resolve the default macOS Keychain"
        )
        XCTAssertEqual(launch.environment["CODEX_HOME"], "/safe/home")
        XCTAssertFalse(String(describing: launch).contains("SECRET_USER_PROMPT"))
        let terminationCount = await fixture.connection.terminationCount()
        let destroyCount = await fixture.home.destroyCount()
        XCTAssertEqual(terminationCount, 1)
        XCTAssertEqual(destroyCount, 1)
    }

    func testAccountMustBeFirstPartyChatGPTAndSelectedModelMustExist() async {
        for account in [
            NSNull(),
            ["type": "apiKey"],
            ["type": "amazonBedrock"],
        ] as [Any] {
            let fixture = Fixture(selection: selection)
            await fixture.connection.enqueue(contentsOf: [
                fixture.initializeFrame(),
                fixture.accountFrame(account: account),
            ])
            let client = fixture.client
            let request = makeRequest()
            let expectedSelection = selection
            await assertError(
                .notAuthenticatedWithChatGPT,
                from: Task {
                    try await client.generate(
                        request: request,
                        selection: expectedSelection
                    )
                }
            )
        }

        let missingModel = Fixture(selection: selection)
        await missingModel.connection.enqueue(contentsOf: [
            missingModel.initializeFrame(),
            missingModel.accountFrame(),
            missingModel.modelListFrame(models: ["another-model"]),
        ])
        let request = makeRequest()
        let client = missingModel.client
        let expectedSelection = selection
        await assertError(
            .selectedModelUnavailable,
            from: Task {
                try await client.generate(
                    request: request,
                    selection: expectedSelection
                )
            }
        )
    }

    func testInitializeCapabilityMismatchFailsClosed() async {
        for mutation in ["version", "home", "platform"] {
            let fixture = Fixture(selection: selection)
            await fixture.connection.enqueue(
                fixture.initializeFrame(mutation: mutation)
            )
            let request = makeRequest()
            let client = fixture.client
            let expectedSelection = selection
            await assertError(
                .capabilityMismatch,
                from: Task {
                    try await client.generate(
                        request: request,
                        selection: expectedSelection
                    )
                }
            )
            let terminationCount = await fixture.connection.terminationCount()
            let isUnavailable = await fixture.client.isUnavailable
            XCTAssertEqual(terminationCount, 1)
            XCTAssertTrue(isUnavailable)
        }
    }

    func testThreadEffectivePermissionMismatchFailsClosed() async {
        for mutation in [
            "approvalPolicy",
            "approvalsReviewer",
            "sandboxType",
            "sandboxNetwork",
            "sandboxExtraField",
            "activePermissionProfile",
            "missingActivePermissionProfile",
            "multiAgentMode",
        ] {
            let fixture = Fixture(selection: selection)
            await fixture.connection.enqueue(contentsOf: [
                fixture.initializeFrame(),
                fixture.accountFrame(),
                fixture.modelListFrame(models: [selection.modelID]),
                fixture.threadStartFrame(mutation: mutation),
            ])
            let request = makeRequest()
            let client = fixture.client
            let expectedSelection = selection

            await assertError(
                .capabilityMismatch,
                from: Task {
                    try await client.generate(
                        request: request,
                        selection: expectedSelection
                    )
                }
            )
            let methods = await fixture.connection.sentMethods()
            let terminationCount = await fixture.connection.terminationCount()
            let isUnavailable = await fixture.client.isUnavailable
            XCTAssertEqual(
                methods,
                ["initialize", "initialized", "account/read", "model/list", "thread/start"],
                mutation
            )
            XCTAssertEqual(terminationCount, 1, mutation)
            XCTAssertTrue(isUnavailable, mutation)
        }
    }

    func testEveryToolOrSideEffectEventInterruptsTurnAndPoisonsConnection() async {
        let hostile: [[String: Any]] = [
            Fixture.notification("item/started", itemType: "commandExecution"),
            Fixture.notification("item/started", itemType: "fileChange"),
            Fixture.notification("item/started", itemType: "mcpToolCall"),
            Fixture.notification("item/started", itemType: "dynamicToolCall"),
            Fixture.notification("item/started", itemType: "collabAgentToolCall"),
            Fixture.notification("item/started", itemType: "webSearch"),
            Fixture.notification("item/started", itemType: "imageView"),
            Fixture.notification("item/started", itemType: "imageGeneration"),
            ["method": "hook/started", "params": ["threadId": "thread-1", "turnId": "turn-1"]],
            ["method": "item/commandExecution/outputDelta", "params": [:]],
            ["method": "mcpServer/tool/call", "id": 900, "params": [:]],
            ["method": "future/unknown", "params": [:]],
        ]

        for event in hostile {
            let fixture = Fixture(selection: selection)
            var frames = fixture.framesThroughTurnStart()
            frames.append(Fixture.frame(event))
            await fixture.connection.enqueue(contentsOf: frames)
            let request = makeRequest()
            let client = fixture.client
            let expectedSelection = selection

            await assertOneOf(
                [.forbiddenEvent, .protocolViolation],
                from: Task {
                    try await client.generate(
                        request: request,
                        selection: expectedSelection
                    )
                }
            )
            let methods = await fixture.connection.sentMethods()
            let terminationCount = await fixture.connection.terminationCount()
            let isUnavailable = await fixture.client.isUnavailable
            XCTAssertTrue(methods.contains("turn/interrupt"), "\(event)")
            XCTAssertEqual(terminationCount, 1)
            XCTAssertTrue(isUnavailable)
        }
    }

    func testMalformedFloodAndUnexpectedStateFilesFailClosedWithoutLeakingPrompt() async {
        let cases: [CodexProcessFrame] = [
            CodexProcessFrame(stdoutLine: Data("{".utf8), totalStdoutBytes: 1, totalStderrBytes: 0),
            CodexProcessFrame(
                stdoutLine: Data("{}".utf8),
                totalStdoutBytes: CodexAppServerClient.maximumStdoutBytes + 1,
                totalStderrBytes: 0
            ),
            CodexProcessFrame(
                stdoutLine: Data("{}".utf8),
                totalStdoutBytes: 2,
                totalStderrBytes: CodexAppServerClient.maximumStderrBytes + 1
            ),
        ]

        for badFrame in cases {
            let fixture = Fixture(selection: selection)
            await fixture.connection.enqueue(badFrame)
            let secret = "PROMPT_CANARY_123"
            let request = makeRequest(user: secret)
            do {
                _ = try await fixture.client.generate(request: request, selection: selection)
                XCTFail("expected failure")
            } catch {
                XCTAssertFalse(String(describing: error).contains(secret))
            }
            let terminationCount = await fixture.connection.terminationCount()
            XCTAssertEqual(terminationCount, 1)
        }

        let unexpectedFile = Fixture(selection: selection)
        await unexpectedFile.home.failAudit(with: .unexpectedStateFile)
        await unexpectedFile.connection.enqueue(unexpectedFile.initializeFrame())
        let request = makeRequest()
        let client = unexpectedFile.client
        let expectedSelection = selection
        await assertError(
            .unexpectedStateFile,
            from: Task {
                try await client.generate(
                    request: request,
                    selection: expectedSelection
                )
            }
        )
        let terminationCount = await unexpectedFile.connection.terminationCount()
        let launch = await unexpectedFile.transport.lastLaunch()
        let destroyCount = await unexpectedFile.home.destroyCount()
        XCTAssertEqual(terminationCount, 0)
        XCTAssertNil(launch)
        XCTAssertEqual(destroyCount, 1)
    }

    func testStrictFinalOutputRejectsMarkdownExtraFieldsMemoryAndForbiddenTurnItems() async {
        let badFinals: [CodexProcessFrame] = [
            Fixture.turnCompleted(text: "```json\n{\"content\":\"x\"}\n```"),
            Fixture.turnCompleted(text: "{\"content\":\"x\",\"extra\":true}"),
            Fixture.turnCompleted(text: "{\"content\":\"\"}"),
            Fixture.turnCompleted(text: "{\"content\":\"x\"}", memoryCitation: ["source": "memory"]),
            Fixture.turnCompleted(text: "{\"content\":\"x\"}", extraItemType: "commandExecution"),
        ]

        for final in badFinals {
            let fixture = Fixture(selection: selection)
            var frames = fixture.framesThroughTurnStart()
            frames.append(final)
            await fixture.connection.enqueue(contentsOf: frames)
            let request = makeRequest()
            let client = fixture.client
            let expectedSelection = selection
            await assertOneOf(
                [.invalidOutput, .forbiddenEvent],
                from: Task {
                    try await client.generate(
                        request: request,
                        selection: expectedSelection
                    )
                }
            )
        }
    }

    func testStaleSelectionIsRejectedBeforeLaunchAndAfterResponse() async {
        let fixture = Fixture(selection: selection)
        await fixture.snapshots.set(
            ProviderSelectionSnapshot(
                providerID: selection.providerID,
                modelID: selection.modelID,
                selectionRevision: SelectionRevision(rawValue: 4),
                authorizationEpoch: selection.authorizationEpoch
            )
        )
        let request = makeRequest()
        let client = fixture.client
        let expectedSelection = selection
        await assertError(
            .staleSelection,
            from: Task {
                try await client.generate(
                    request: request,
                    selection: expectedSelection
                )
            }
        )
        let launch = await fixture.transport.lastLaunch()
        XCTAssertNil(launch)

        let after = Fixture(selection: selection)
        await after.connection.enqueue(contentsOf: after.happyGenerationFrames(content: "discard"))
        let snapshots = after.snapshots
        let originalSelection = selection
        await after.connection.onFrameDelivered(index: 5) {
            await snapshots.set(
                ProviderSelectionSnapshot(
                    providerID: originalSelection.providerID,
                    modelID: originalSelection.modelID,
                    selectionRevision: originalSelection.selectionRevision,
                    authorizationEpoch: AuthorizationEpoch(rawValue: 10)
                )
            )
        }
        let afterClient = after.client
        await assertError(
            .staleSelection,
            from: Task {
                try await afterClient.generate(
                    request: request,
                    selection: originalSelection
                )
            }
        )
    }

    func testRevokedSelectionAfterModelValidationNeverSendsAnyPromptBearingRequest() async {
        let fixture = Fixture(selection: selection)
        await fixture.connection.enqueue(
            contentsOf: fixture.happyGenerationFrames(content: "must-discard")
        )
        let gate = CodexAsyncGate()
        await fixture.connection.onFrameDelivered(index: 3) {
            await gate.pause()
        }
        let request = makeRequest(user: "PRIVATE_USER_PROMPT_MUST_NOT_LEAVE")
        let client = fixture.client
        let expectedSelection = selection
        let task = Task {
            try await client.generate(
                request: request,
                selection: expectedSelection
            )
        }

        await gate.waitUntilPaused()
        await fixture.snapshots.set(nil)
        await gate.resume()

        await assertError(.staleSelection, from: task)
        let methods = await fixture.connection.sentMethods()
        let threadStart = await fixture.connection.sentParams(for: "thread/start")
        let turnStart = await fixture.connection.sentParams(for: "turn/start")
        XCTAssertEqual(methods, ["initialize", "initialized", "account/read", "model/list"])
        XCTAssertNil(threadStart, "developerInstructions must not leave after consent revocation")
        XCTAssertNil(turnStart, "userPrompt must not leave after consent revocation")
    }

    func testRevocationWhileThreadStartIsQueuedInWriterPreventsAllPromptBytes() async {
        let fixture = Fixture(selection: selection)
        await fixture.connection.enqueue(
            contentsOf: fixture.happyGenerationFrames(content: "must-discard")
        )
        await fixture.connection.pauseNextPromptWrite(method: "thread/start")
        let request = makeRequest(user: "PRIVATE_USER_PROMPT_MUST_NOT_LEAVE")
        let client = fixture.client
        let expectedSelection = selection
        let task = Task {
            try await client.generate(
                request: request,
                selection: expectedSelection
            )
        }

        await fixture.connection.waitUntilPromptWritePaused()
        await fixture.snapshots.set(nil)
        await fixture.connection.resumePromptWrite()

        await assertError(.staleSelection, from: task)
        let promptByteCount = await fixture.connection.sentPromptBearingByteCount()
        XCTAssertEqual(
            promptByteCount,
            0,
            "revocation at the serialized writer boundary must prevent every prompt byte"
        )
    }

    func testRevocationWhileTurnStartIsQueuedInWriterPreventsUserPromptBytes() async {
        let fixture = Fixture(selection: selection)
        await fixture.connection.enqueue(
            contentsOf: fixture.happyGenerationFrames(content: "must-discard")
        )
        await fixture.connection.pauseNextPromptWrite(method: "turn/start")
        let request = makeRequest(user: "PRIVATE_USER_PROMPT_MUST_NOT_LEAVE")
        let client = fixture.client
        let expectedSelection = selection
        let task = Task {
            try await client.generate(
                request: request,
                selection: expectedSelection
            )
        }

        await fixture.connection.waitUntilPromptWritePaused()
        await fixture.snapshots.set(nil)
        await fixture.connection.resumePromptWrite()

        await assertError(.staleSelection, from: task)
        let threadStart = await fixture.connection.sentParams(for: "thread/start")
        let turnStart = await fixture.connection.sentParams(for: "turn/start")
        let turnPromptBytes = await fixture.connection.sentPromptBearingByteCount(
            for: "turn/start"
        )
        XCTAssertNotNil(threadStart)
        XCTAssertNil(turnStart)
        XCTAssertEqual(
            turnPromptBytes,
            0,
            "revocation at the serialized writer boundary must prevent every user-prompt byte"
        )
    }

    func testCancellationAfterModelValidationNeverSendsAnyPromptBearingRequest() async {
        let fixture = Fixture(selection: selection)
        await fixture.connection.enqueue(
            contentsOf: fixture.happyGenerationFrames(content: "must-discard")
        )
        let gate = CodexAsyncGate()
        await fixture.connection.onFrameDelivered(index: 3) {
            await gate.pause()
        }
        let request = makeRequest(user: "CANCELLED_USER_PROMPT_MUST_NOT_LEAVE")
        let client = fixture.client
        let expectedSelection = selection
        let task = Task {
            try await client.generate(
                request: request,
                selection: expectedSelection
            )
        }

        await gate.waitUntilPaused()
        task.cancel()
        await gate.resume()

        await assertError(.cancelled, from: task)
        let methods = await fixture.connection.sentMethods()
        let threadStart = await fixture.connection.sentParams(for: "thread/start")
        let turnStart = await fixture.connection.sentParams(for: "turn/start")
        XCTAssertEqual(methods, ["initialize", "initialized", "account/read", "model/list"])
        XCTAssertNil(threadStart, "developerInstructions must not leave after cancellation")
        XCTAssertNil(turnStart, "userPrompt must not leave after cancellation")
    }

    func testRevokedSelectionAfterThreadSetupNeverReachesPromptBearingTurnStart() async {
        let fixture = Fixture(selection: selection)
        await fixture.connection.enqueue(
            contentsOf: fixture.happyGenerationFrames(content: "must-discard")
        )
        let gate = CodexAsyncGate()
        await fixture.connection.onFrameDelivered(index: 4) {
            await gate.pause()
        }
        let request = makeRequest(user: "PRIVATE_PROMPT_MUST_NOT_LEAVE")
        let client = fixture.client
        let expectedSelection = selection
        let task = Task {
            try await client.generate(
                request: request,
                selection: expectedSelection
            )
        }

        await gate.waitUntilPaused()
        await fixture.snapshots.set(nil)
        await gate.resume()

        await assertError(.staleSelection, from: task)
        let methods = await fixture.connection.sentMethods()
        let turnStart = await fixture.connection.sentParams(for: "turn/start")
        XCTAssertEqual(
            methods,
            ["initialize", "initialized", "account/read", "model/list", "thread/start"]
        )
        XCTAssertNil(turnStart)
    }

    func testCancellationAfterThreadSetupNeverReachesPromptBearingTurnStart() async {
        let fixture = Fixture(selection: selection)
        await fixture.connection.enqueue(
            contentsOf: fixture.happyGenerationFrames(content: "must-discard")
        )
        let gate = CodexAsyncGate()
        await fixture.connection.onFrameDelivered(index: 4) {
            await gate.pause()
        }
        let request = makeRequest(user: "CANCELLED_PROMPT_MUST_NOT_LEAVE")
        let client = fixture.client
        let expectedSelection = selection
        let task = Task {
            try await client.generate(
                request: request,
                selection: expectedSelection
            )
        }

        await gate.waitUntilPaused()
        task.cancel()
        await gate.resume()

        await assertError(.cancelled, from: task)
        let methods = await fixture.connection.sentMethods()
        let turnStart = await fixture.connection.sentParams(for: "turn/start")
        XCTAssertEqual(
            methods,
            ["initialize", "initialized", "account/read", "model/list", "thread/start"]
        )
        XCTAssertNil(turnStart)
    }

    func testTimeoutAndCallerCancellationInterruptAndTerminateWholeGroup() async {
        let timeoutFixture = Fixture(selection: selection)
        await timeoutFixture.connection.enqueue(contentsOf: timeoutFixture.framesThroughTurnStart())
        await timeoutFixture.connection.blockWhenEmpty()
        var timed = makeRequest()
        timed = LLMRequest(
            id: timed.id,
            consumer: timed.consumer,
            priority: timed.priority,
            systemPrompt: timed.systemPrompt,
            userPrompt: timed.userPrompt,
            maximumOutputTokens: timed.maximumOutputTokens,
            timeout: .milliseconds(30)
        )
        let timeoutClient = timeoutFixture.client
        let expectedSelection = selection
        await assertError(
            .timedOut,
            from: Task {
                try await timeoutClient.generate(
                    request: timed,
                    selection: expectedSelection
                )
            }
        )
        let timeoutMethods = await timeoutFixture.connection.sentMethods()
        let timeoutTerminations = await timeoutFixture.connection.terminationCount()
        XCTAssertTrue(timeoutMethods.contains("turn/interrupt"))
        XCTAssertEqual(timeoutTerminations, 1)

        let cancelFixture = Fixture(selection: selection)
        await cancelFixture.connection.enqueue(contentsOf: cancelFixture.framesThroughTurnStart())
        await cancelFixture.connection.blockWhenEmpty()
        let request = makeRequest()
        let cancelClient = cancelFixture.client
        let cancelSelection = selection
        let task = Task {
            try await cancelClient.generate(
                request: request,
                selection: cancelSelection
            )
        }
        await cancelFixture.connection.waitUntilBlocked()
        task.cancel()
        await assertError(.cancelled, from: task)
        let cancelMethods = await cancelFixture.connection.sentMethods()
        let cancelTerminations = await cancelFixture.connection.terminationCount()
        XCTAssertTrue(cancelMethods.contains("turn/interrupt"))
        XCTAssertEqual(cancelTerminations, 1)
    }

    func testLoginStartAndCancelStayOnSameIsolatedProcess() async throws {
        let fixture = Fixture(selection: selection)
        await fixture.connection.enqueue(contentsOf: [
            fixture.initializeFrame(),
            Fixture.response(
                id: 2,
                result: [
                    "type": "chatgpt",
                    "loginId": "login-1",
                    "authUrl": "https://auth.openai.com/oauth/authorize",
                ]
            ),
            Fixture.response(id: 3, result: ["status": "canceled"]),
        ])

        let challenge = try await fixture.client.startLogin()
        XCTAssertEqual(challenge.loginID, "login-1")
        XCTAssertEqual(challenge.authorizationURL.host, "auth.openai.com")
        let terminationsBeforeCancel = await fixture.connection.terminationCount()
        XCTAssertEqual(terminationsBeforeCancel, 0)

        try await fixture.client.cancelLogin(loginID: challenge.loginID)
        let terminationsAfterCancel = await fixture.connection.terminationCount()
        let sentMethods = await fixture.connection.sentMethods()
        XCTAssertEqual(terminationsAfterCancel, 1)
        XCTAssertEqual(
            sentMethods,
            ["initialize", "initialized", "account/login/start", "account/login/cancel"]
        )
    }

    func testLoginCompletionConfirmsChatGPTAccountBeforeDestroyingIsolatedHome() async throws {
        let fixture = Fixture(selection: selection)
        await fixture.connection.enqueue(contentsOf: [
            fixture.initializeFrame(),
            Fixture.response(
                id: 2,
                result: [
                    "type": "chatgpt",
                    "loginId": "login-1",
                    "authUrl": "https://auth.openai.com/oauth/authorize",
                ]
            ),
            Fixture.frame([
                "method": "account/updated",
                "params": ["authMode": "chatgpt", "planType": "plus"],
            ]),
            Fixture.frame([
                "method": "account/login/completed",
                "params": [
                    "loginId": "login-1",
                    "success": true,
                    "error": NSNull(),
                ],
            ]),
            fixture.accountFrame(id: 3),
        ])

        let challenge = try await fixture.client.startLogin()
        try await fixture.client.completeLogin(
            loginID: challenge.loginID,
            timeout: .seconds(2)
        )

        let methods = await fixture.connection.sentMethods()
        let accountRead = await fixture.connection.sentParams(for: "account/read")
        let terminations = await fixture.connection.terminationCount()
        let destroys = await fixture.home.destroyCount()
        XCTAssertEqual(
            methods,
            ["initialize", "initialized", "account/login/start", "account/read"]
        )
        XCTAssertEqual(accountRead?.bool(for: "refreshToken"), true)
        XCTAssertEqual(terminations, 1)
        XCTAssertEqual(destroys, 1)
    }

    private func makeRequest(user: String = "question") -> LLMRequest {
        LLMRequest(
            id: UUID(),
            consumer: .ask,
            priority: .ask,
            systemPrompt: "Answer only from the supplied history.",
            userPrompt: user,
            maximumOutputTokens: 128,
            timeout: .seconds(2)
        )
    }

    private func assertError(
        _ expected: CodexAppServerError,
        from task: Task<LLMResponse, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await assertOneOf([expected], from: task, file: file, line: line)
    }

    private func assertOneOf(
        _ expected: Set<CodexAppServerError>,
        from task: Task<LLMResponse, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("expected failure", file: file, line: line)
        } catch {
            guard let actual = error as? CodexAppServerError else {
                return XCTFail("unexpected error: \(error)", file: file, line: line)
            }
            XCTAssertTrue(expected.contains(actual), "\(actual)", file: file, line: line)
        }
    }

    private func assertResolveError(
        _ expected: CodexAppServerError,
        resolver: CodexSystemExecutableResolver,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await resolver.resolve()
            XCTFail("expected resolver failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CodexAppServerError, expected, file: file, line: line)
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "zbs-eye-codex-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func verifiedExecutable(at url: URL) throws -> CodexVerifiedExecutable {
        let fileIdentity = try CodexFileIdentity.capture(at: url)
        return CodexVerifiedExecutable(
            trustedInspection: .trustedFixture(
                url: url,
                ownerUID: fileIdentity.ownerUID,
                fileIdentity: fileIdentity
            )
        )
    }
}

private actor CodexAsyncGate {
    private var isPaused = false
    private var isReleased = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private struct Fixture {
    let selection: ProviderSelectionSnapshot
    let snapshots: CodexMockSnapshotProvider
    let resolver: CodexMockExecutableResolver
    let home: CodexMockHomeManager
    let connection: CodexScriptedConnection
    let transport: CodexScriptedTransport
    let client: CodexAppServerClient

    init(selection: ProviderSelectionSnapshot) {
        self.selection = selection
        snapshots = CodexMockSnapshotProvider(selection)
        resolver = CodexMockExecutableResolver()
        home = CodexMockHomeManager()
        connection = CodexScriptedConnection()
        transport = CodexScriptedTransport(connection: connection)
        client = CodexAppServerClient(
            executableResolver: resolver,
            homeManager: home,
            processTransport: transport,
            snapshotProvider: snapshots
        )
    }

    func happyGenerationFrames(content: String) -> [CodexProcessFrame] {
        framesThroughTurnStart() + [Self.turnCompleted(text: jsonText(["content": content]))]
    }

    func framesThroughTurnStart() -> [CodexProcessFrame] {
        [
            initializeFrame(),
            accountFrame(),
            modelListFrame(models: [selection.modelID]),
            threadStartFrame(),
            Self.response(
                id: 5,
                result: ["turn": ["id": "turn-1", "status": "inProgress"]]
            ),
        ]
    }

    func threadStartFrame(mutation: String? = nil) -> CodexProcessFrame {
        var result: [String: Any] = [
            "thread": [
                "id": "thread-1",
                "ephemeral": true,
                "modelProvider": "openai",
                "cwd": "/safe/work",
                "cliVersion": "0.145.0",
                "path": NSNull(),
            ],
            "model": selection.modelID,
            "modelProvider": "openai",
            "cwd": "/safe/work",
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "sandbox": [
                "type": "readOnly",
                "networkAccess": false,
            ],
            "activePermissionProfile": NSNull(),
            "multiAgentMode": "explicitRequestOnly",
            "runtimeWorkspaceRoots": [],
            "instructionSources": [],
        ]
        switch mutation {
        case "approvalPolicy":
            result["approvalPolicy"] = "on-request"
        case "approvalsReviewer":
            result["approvalsReviewer"] = "auto_review"
        case "sandboxType":
            result["sandbox"] = ["type": "workspaceWrite", "networkAccess": false]
        case "sandboxNetwork":
            result["sandbox"] = ["type": "readOnly", "networkAccess": true]
        case "sandboxExtraField":
            result["sandbox"] = [
                "type": "readOnly",
                "networkAccess": false,
                "writableRoots": ["/"],
            ]
        case "activePermissionProfile":
            result["activePermissionProfile"] = ["id": ":workspace"]
        case "missingActivePermissionProfile":
            result.removeValue(forKey: "activePermissionProfile")
        case "multiAgentMode":
            result["multiAgentMode"] = "proactive"
        default:
            break
        }
        return Self.response(id: 4, result: result)
    }

    func initializeFrame(mutation: String? = nil) -> CodexProcessFrame {
        var result: [String: Any] = [
            "userAgent": "zbs-eye/0.145.0 (Mac OS; arm64)",
            "codexHome": "/safe/home",
            "platformFamily": "unix",
            "platformOs": "macos",
        ]
        if mutation == "version" { result["userAgent"] = "zbs-eye/0.144.7" }
        if mutation == "home" { result["codexHome"] = "/Users/victim/.codex" }
        if mutation == "platform" { result["platformOs"] = "linux" }
        return Self.response(id: 1, result: result)
    }

    func accountFrame(account: Any = [
        "type": "chatgpt",
        "email": "fixture@example.invalid",
        "planType": "plus",
    ], id: Int = 2) -> CodexProcessFrame {
        Self.response(
            id: id,
            result: ["account": account, "requiresOpenaiAuth": true]
        )
    }

    func modelListFrame(models: [String]) -> CodexProcessFrame {
        Self.response(
            id: 3,
            result: [
                "data": models.map { ["id": $0, "model": $0, "hidden": false] },
                "nextCursor": NSNull(),
            ]
        )
    }

    static func response(id: Int, result: [String: Any]) -> CodexProcessFrame {
        frame(["id": id, "result": result])
    }

    static func notification(_ method: String, itemType: String) -> [String: Any] {
        [
            "method": method,
            "params": [
                "threadId": "thread-1",
                "turnId": "turn-1",
                "startedAtMs": 1,
                "item": ["type": itemType, "id": "hostile-1"],
            ],
        ]
    }

    static func turnCompleted(
        text: String,
        memoryCitation: Any = NSNull(),
        extraItemType: String? = nil
    ) -> CodexProcessFrame {
        var items: [[String: Any]] = [[
            "type": "agentMessage",
            "id": "agent-1",
            "text": text,
            "phase": "final_answer",
            "memoryCitation": memoryCitation,
        ]]
        if let extraItemType {
            items.append(["type": extraItemType, "id": "hostile-final"])
        }
        return frame([
            "method": "turn/completed",
            "params": [
                "threadId": "thread-1",
                "turn": [
                    "id": "turn-1",
                    "status": "completed",
                    "error": NSNull(),
                    "items": items,
                ],
            ],
        ])
    }

    static func frame(_ object: [String: Any]) -> CodexProcessFrame {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return CodexProcessFrame(
            stdoutLine: data,
            totalStdoutBytes: data.count,
            totalStderrBytes: 0
        )
    }

    private func jsonText(_ object: [String: Any]) -> String {
        String(
            data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8
        )!
    }
}

private actor CodexMockSnapshotProvider: LLMSelectionSnapshotProviding {
    private var snapshot: ProviderSelectionSnapshot?
    init(_ snapshot: ProviderSelectionSnapshot?) { self.snapshot = snapshot }
    func currentSnapshot(for consumer: AIConsumer) async -> ProviderSelectionSnapshot? { snapshot }
    func set(_ snapshot: ProviderSelectionSnapshot?) { self.snapshot = snapshot }
}

private struct CodexMockExecutableResolver: CodexExecutableResolving {
    func resolve() async throws -> CodexVerifiedExecutable {
        CodexVerifiedExecutable(
            trustedInspection: .trustedFixture(
                url: URL(fileURLWithPath: "/trusted/native/codex"),
                ownerUID: getuid()
            )
        )
    }
}

private actor CodexDriftingExecutableResolver: CodexExecutableResolving {
    private var resolves = 0

    func resolve() async throws -> CodexVerifiedExecutable {
        resolves += 1
        let inspection = CodexBinaryInspection.trustedFixture(
            url: URL(fileURLWithPath: "/trusted/native/codex"),
            ownerUID: getuid()
        )
        if resolves == 1 {
            return CodexVerifiedExecutable(trustedInspection: inspection)
        }
        return CodexVerifiedExecutable(
            trustedInspection: inspection.with(
                fileIdentity: inspection.fileIdentity.with(
                    fileID: inspection.fileIdentity.fileID + 1
                )
            )
        )
    }

    func resolveCount() -> Int { resolves }
}

private struct CodexAcceptingExecutableVerifier: CodexExecutableVerifying {
    func revalidate(
        _ executable: CodexVerifiedExecutable
    ) async throws -> CodexVerifiedExecutable {
        executable
    }
}

private actor CodexReplacingExecutableVerifier: CodexExecutableVerifying {
    private let executableURL: URL

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func revalidate(
        _ executable: CodexVerifiedExecutable
    ) async throws -> CodexVerifiedExecutable {
        try FileManager.default.removeItem(at: executableURL)
        try Data("#!/bin/sh\nexec /bin/sleep 30\n# replacement\n".utf8)
            .write(to: executableURL)
        guard chmod(executableURL.path, 0o700) == 0 else {
            throw CodexAppServerError.untrustedBinary
        }
        return executable
    }
}

private struct RejectingCodexBinaryInspector: CodexBinaryInspecting {
    func inspect(_ url: URL) async throws -> CodexBinaryInspection {
        throw CodexAppServerError.untrustedBinary
    }
}

private actor CodexMockHomeManager: CodexHomeManaging {
    private var auditFailure: CodexAppServerError?
    private var destroys = 0

    func prepareSession() async throws -> CodexPreparedHome {
        CodexPreparedHome(
            leaseID: UUID(),
            homeURL: URL(fileURLWithPath: "/safe/home"),
            configURL: URL(fileURLWithPath: "/safe/home/config.toml"),
            workingDirectoryURL: URL(fileURLWithPath: "/safe/work"),
            temporaryDirectoryURL: URL(fileURLWithPath: "/safe/tmp")
        )
    }

    func audit(_ home: CodexPreparedHome, phase: CodexHomeAuditPhase) async throws {
        if let auditFailure { throw auditFailure }
    }

    func destroy(_ home: CodexPreparedHome) async { destroys += 1 }
    func failAudit(with error: CodexAppServerError) { auditFailure = error }
    func destroyCount() -> Int { destroys }
}

private actor CodexScriptedTransport: CodexAppServerProcessTransport {
    private let connection: CodexScriptedConnection
    private var launch: CodexLaunchSpecification?

    init(connection: CodexScriptedConnection) { self.connection = connection }

    func open(_ specification: CodexLaunchSpecification) async throws -> any CodexAppServerConnection {
        launch = specification
        return connection
    }

    func lastLaunch() -> CodexLaunchSpecification? { launch }
}

private actor CodexScriptedConnection: CodexAppServerConnection {
    private var frames: [CodexProcessFrame] = []
    private var sentObjects: [AnySendableJSON] = []
    private var terminations = 0
    private var shouldBlockWhenEmpty = false
    private var isBlocked = false
    private var delivered = 0
    private var deliveryHooks: [Int: @Sendable () async -> Void] = [:]
    private var promptWriteMethodToPause: String?
    private let promptWriteGate = CodexAsyncGate()
    private var sentPromptBearingBytes = 0
    private var sentPromptBearingBytesByMethod: [String: Int] = [:]

    func send(
        _ line: Data,
        promptAdmission: CodexPromptAdmission?
    ) async throws {
        let object = try JSONSerialization.jsonObject(with: line)
        guard let dictionary = object as? [String: Any] else {
            throw CodexAppServerError.protocolViolation
        }
        if dictionary["method"] as? String == promptWriteMethodToPause {
            promptWriteMethodToPause = nil
            await promptWriteGate.pause()
        }
        try await promptAdmission?.validate()
        if Self.isPromptBearing(dictionary) {
            sentPromptBearingBytes += line.count
            if let method = dictionary["method"] as? String {
                sentPromptBearingBytesByMethod[method, default: 0] += line.count
            }
        }
        sentObjects.append(.object(try AnySendableJSON.dictionary(dictionary)))
    }

    func receive(maximumLineBytes: Int, timeout: Duration) async throws -> CodexProcessFrame {
        if frames.isEmpty, shouldBlockWhenEmpty {
            isBlocked = true
            do {
                try await Task.sleep(for: timeout)
                throw CodexAppServerError.timedOut
            } catch is CancellationError {
                throw CancellationError()
            }
        }
        guard !frames.isEmpty else { throw CodexAppServerError.transportUnavailable }
        let frame = frames.removeFirst()
        delivered += 1
        if let hook = deliveryHooks.removeValue(forKey: delivered) { await hook() }
        return frame
    }

    func terminateProcessGroup(gracePeriod: Duration) async { terminations += 1 }

    func enqueue(_ frame: CodexProcessFrame) { frames.append(frame) }
    func enqueue(contentsOf newFrames: [CodexProcessFrame]) { frames.append(contentsOf: newFrames) }
    func blockWhenEmpty() { shouldBlockWhenEmpty = true }
    func terminationCount() -> Int { terminations }
    func onFrameDelivered(index: Int, _ hook: @escaping @Sendable () async -> Void) {
        deliveryHooks[index] = hook
    }

    func pauseNextPromptWrite(method: String) {
        promptWriteMethodToPause = method
    }

    func waitUntilPromptWritePaused() async {
        await promptWriteGate.waitUntilPaused()
    }

    func resumePromptWrite() async {
        await promptWriteGate.resume()
    }

    func sentPromptBearingByteCount() -> Int { sentPromptBearingBytes }
    func sentPromptBearingByteCount(for method: String) -> Int {
        sentPromptBearingBytesByMethod[method, default: 0]
    }

    func waitUntilBlocked() async {
        for _ in 0..<2_000 {
            if isBlocked { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func sentMethods() -> [String] {
        sentObjects.compactMap { $0.string(for: "method") }
    }

    func sentParams(for method: String) -> AnySendableJSON? {
        guard let object = sentObjects.first(where: { $0.string(for: "method") == method }),
              let params = object.object(for: "params") else { return nil }
        return params
    }

    private static func isPromptBearing(_ object: [String: Any]) -> Bool {
        guard let method = object["method"] as? String else { return false }
        return method == "thread/start" || method == "turn/start"
    }
}

private enum AnySendableJSON: Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([AnySendableJSON])
    case object([String: AnySendableJSON])

    static func dictionary(_ value: [String: Any]) throws -> [String: AnySendableJSON] {
        var result: [String: AnySendableJSON] = [:]
        for (key, value) in value { result[key] = try convert(value) }
        return result
    }

    static func convert(_ value: Any) throws -> AnySendableJSON {
        switch value {
        case let value as String: return .string(value)
        case let value as Bool: return .bool(value)
        case let value as NSNumber: return .number(value.doubleValue)
        case is NSNull: return .null
        case let value as [Any]: return .array(try value.map(convert))
        case let value as [String: Any]: return .object(try dictionary(value))
        default: throw CodexAppServerError.protocolViolation
        }
    }

    func string(for key: String) -> String? {
        guard case .object(let object) = self,
              case .string(let value) = object[key] else { return nil }
        return value
    }

    func object(for key: String) -> AnySendableJSON? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    func bool(for key: String) -> Bool? {
        guard case .object(let object) = self,
              case .bool(let value) = object[key] else { return nil }
        return value
    }

    func array(for key: String) -> [AnySendableJSON]? {
        guard case .object(let object) = self,
              case .array(let value) = object[key] else { return nil }
        return value
    }

    var objectCount: Int? {
        guard case .object(let object) = self else { return nil }
        return object.count
    }
}

private extension CodexBinaryInspection {
    static func trustedFixture(
        url: URL,
        ownerUID: uid_t,
        fileIdentity: CodexFileIdentity? = nil
    ) -> Self {
        let identity = fileIdentity ?? .fixture(ownerUID: ownerUID)
        return CodexBinaryInspection(
            url: url,
            fileIdentity: identity,
            format: .machOArm64,
            isSymlink: false,
            isRegularFile: true,
            linkCount: identity.linkCount,
            ownerUID: identity.ownerUID,
            mode: identity.mode,
            packageLayoutIsCanonical: true,
            version: "0.145.0-darwin-arm64",
            sha256: CodexBinaryPolicy.allowedSHA256,
            teamIdentifier: CodexBinaryPolicy.allowedTeamIdentifier,
            signingAuthority: CodexBinaryPolicy.allowedSigningAuthority
        )
    }

    func with(
        fileIdentity: CodexFileIdentity? = nil,
        format: CodexBinaryFormat? = nil,
        isSymlink: Bool? = nil,
        isRegularFile: Bool? = nil,
        linkCount: UInt64? = nil,
        ownerUID: uid_t? = nil,
        mode: mode_t? = nil,
        packageLayoutIsCanonical: Bool? = nil,
        version: String? = nil,
        sha256: String? = nil,
        teamIdentifier: String? = nil,
        signingAuthority: String? = nil
    ) -> Self {
        CodexBinaryInspection(
            url: url,
            fileIdentity: fileIdentity ?? self.fileIdentity,
            format: format ?? self.format,
            isSymlink: isSymlink ?? self.isSymlink,
            isRegularFile: isRegularFile ?? self.isRegularFile,
            linkCount: linkCount ?? self.linkCount,
            ownerUID: ownerUID ?? self.ownerUID,
            mode: mode ?? self.mode,
            packageLayoutIsCanonical: packageLayoutIsCanonical ?? self.packageLayoutIsCanonical,
            version: version ?? self.version,
            sha256: sha256 ?? self.sha256,
            teamIdentifier: teamIdentifier ?? self.teamIdentifier,
            signingAuthority: signingAuthority ?? self.signingAuthority
        )
    }
}

private extension CodexFileIdentity {
    static func fixture(ownerUID: uid_t) -> Self {
        CodexFileIdentity(
            deviceID: 1,
            fileID: 2,
            byteCount: 3,
            mode: 0o100755,
            ownerUID: ownerUID,
            linkCount: 1,
            modifiedSeconds: 4,
            modifiedNanoseconds: 5,
            changedSeconds: 6,
            changedNanoseconds: 7
        )
    }

    func with(fileID: UInt64) -> Self {
        CodexFileIdentity(
            deviceID: deviceID,
            fileID: fileID,
            byteCount: byteCount,
            mode: mode,
            ownerUID: ownerUID,
            linkCount: linkCount,
            modifiedSeconds: modifiedSeconds,
            modifiedNanoseconds: modifiedNanoseconds,
            changedSeconds: changedSeconds,
            changedNanoseconds: changedNanoseconds
        )
    }
}
