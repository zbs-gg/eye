import XCTest

final class MCPReadinessServiceTests: XCTestCase {
    func testReadyStateRequiresExpectedReadOnlyToolContractAndRetrieval() async {
        let selfTest = MCPFakeSelfTester(result: .success(Self.successfulSelfTest))
        let service = Self.service(selfTester: selfTest)

        let state = await service.check()
        let callCount = await selfTest.calls()

        XCTAssertEqual(state, .readyToConnect(Self.identity.executableURL.path))
        XCTAssertEqual(callCount, 1)
    }

    func testMissingApplicationHasFiniteCorrectiveState() async {
        let service = MCPReadinessService(
            applicationURL: Self.applicationURL,
            identityInspector: MCPFakeIdentityInspector(result: .failure(.applicationMissing)),
            dataRootResolver: MCPFakeDataRootResolver(result: .success(Self.rootIdentity)),
            selfTester: MCPFakeSelfTester(result: .success(Self.successfulSelfTest))
        )

        let state = await service.check()
        XCTAssertEqual(state, .notReady(.applicationMissing))
    }

    func testIdentityMismatchAndUnavailableRootStayDistinct() async {
        let mismatch = MCPReadinessService(
            applicationURL: Self.applicationURL,
            identityInspector: MCPFakeIdentityInspector(result: .failure(.identityMismatch)),
            dataRootResolver: MCPFakeDataRootResolver(result: .success(Self.rootIdentity)),
            selfTester: MCPFakeSelfTester(result: .success(Self.successfulSelfTest))
        )
        let mismatchState = await mismatch.check()
        XCTAssertEqual(mismatchState, .notReady(.identityMismatch))

        let unavailable = MCPReadinessService(
            applicationURL: Self.applicationURL,
            identityInspector: MCPFakeIdentityInspector(result: .success(Self.identity)),
            dataRootResolver: MCPFakeDataRootResolver(result: .failure(.dataRootUnavailable)),
            selfTester: MCPFakeSelfTester(result: .success(Self.successfulSelfTest))
        )
        let unavailableState = await unavailable.check()
        XCTAssertEqual(unavailableState, .notReady(.dataRootUnavailable))
    }

    func testSelfTestFailuresMapToFiniteStates() async {
        let cases: [(MCPSelfTestError, MCPReadinessFailure)] = [
            (.timedOut, .initializationTimedOut),
            (.outputLimitExceeded, .outputLimitExceeded),
            (.initializationFailed, .initializationFailed),
            (.retrievalFailed, .retrievalFailed),
            (.noHistory, .noHistory),
        ]
        for (error, expected) in cases {
            let service = Self.service(
                selfTester: MCPFakeSelfTester(result: .failure(error))
            )
            let state = await service.check()
            XCTAssertEqual(state, .notReady(expected))
        }
    }

    func testMissingOrAdvancedDefaultToolsRejectTheContract() async {
        let missing = MCPSelfTestResult(
            toolNames: ["search_history", "get_status"],
            retrievalSucceeded: true
        )
        let missingService = Self.service(
            selfTester: MCPFakeSelfTester(result: .success(missing))
        )
        let missingState = await missingService.check()
        XCTAssertEqual(missingState, .notReady(.toolContractMismatch))

        let unsafe = MCPSelfTestResult(
            toolNames: MCPToolPolicy.toolNames(for: .memoryReadOnly) + ["get_frame_image"],
            retrievalSucceeded: true
        )
        let unsafeService = Self.service(
            selfTester: MCPFakeSelfTester(result: .success(unsafe))
        )
        let unsafeState = await unsafeService.check()
        XCTAssertEqual(unsafeState, .notReady(.toolContractMismatch))
    }

    func testExactIdentityAndRootResultIsCachedUntilForced() async {
        let selfTest = MCPFakeSelfTester(result: .success(Self.successfulSelfTest))
        let service = Self.service(selfTester: selfTest)

        _ = await service.check()
        _ = await service.check()
        let cachedCallCount = await selfTest.calls()
        XCTAssertEqual(cachedCallCount, 1)

        _ = await service.check(force: true)
        let forcedCallCount = await selfTest.calls()
        XCTAssertEqual(forcedCallCount, 2)
    }

    func testReplacingDatabaseInvalidatesCachedReadyState() async {
        let selfTest = MCPFakeSelfTester(result: .success(Self.successfulSelfTest))
        let replacementRoot = MCPDataRootIdentity(
            url: Self.rootIdentity.url,
            device: Self.rootIdentity.device,
            inode: Self.rootIdentity.inode,
            databaseIdentity: .init(
                device: 5, inode: 99, size: 4_096, modifiedSeconds: 10
            ),
            frameWitness: Self.rootIdentity.frameWitness
        )
        let service = MCPReadinessService(
            applicationURL: Self.applicationURL,
            identityInspector: MCPFakeIdentityInspector(result: .success(Self.identity)),
            dataRootResolver: MCPSequenceDataRootResolver(
                values: [Self.rootIdentity, replacementRoot]
            ),
            selfTester: selfTest
        )

        _ = await service.check()
        _ = await service.check()

        let callCount = await selfTest.calls()
        XCTAssertEqual(callCount, 2)
    }

    func testExistingNonZBSEyeApplicationIsIdentityMismatch() async throws {
        let applicationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        try FileManager.default.createDirectory(
            at: applicationURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: applicationURL) }

        do {
            _ = try await SystemMCPInstalledApplicationInspector().inspect(
                applicationURL: applicationURL
            )
            XCTFail("Expected identity mismatch")
        } catch let error as MCPReadinessDependencyError {
            XCTAssertEqual(error, .identityMismatch)
        }
    }

    func testHandshakeSeparatesInitializeFromPostInitializationMessages() throws {
        let messages = try SystemMCPSelfTester.handshakeMessages(nowMs: 123)
        let initialize = try Self.jsonObject(messages.initialize)
        XCTAssertEqual(initialize["method"] as? String, "initialize")

        XCTAssertEqual(messages.afterInitialization.count, 3)
        let methods = try messages.afterInitialization.map {
            try Self.jsonObject($0)["method"] as? String
        }
        XCTAssertEqual(
            methods,
            ["notifications/initialized", "tools/list", "tools/call"]
        )
    }

    func testRetrievalValidationRequiresTheExactWitnessFrame() throws {
        let toolResult: [String: Any] = [
            "result": [
                "tools": MCPToolPolicy.toolNames(for: .memoryReadOnly).map { ["name": $0] },
            ],
        ]
        let emptyTimelineResult: [String: Any] = [
            "result": [
                "content": [["type": "text", "text": "There is no frame for this moment."]],
                "isError": false,
            ],
        ]
        XCTAssertThrowsError(try SystemMCPSelfTester.validatePostInitialize(
            [2: toolResult, 3: emptyTimelineResult],
            expectedFrameID: 42
        )) { error in
            XCTAssertEqual(error as? MCPSelfTestError, .retrievalFailed)
        }

        let witnessedResult: [String: Any] = [
            "result": [
                "content": [["type": "text", "text": "Frame #42 at Jul 14, 4:00 AM — Codex"]],
                "isError": false,
            ],
        ]
        let validated = try SystemMCPSelfTester.validatePostInitialize(
            [2: toolResult, 3: witnessedResult],
            expectedFrameID: 42
        )
        XCTAssertTrue(validated.retrievalSucceeded)
    }

    func testSystemSelfTesterCompletesARealPOSIXProcessLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZBSEyeMCPProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("fixture-mcp")
        let tools = MCPToolPolicy.toolNames(for: .memoryReadOnly)
            .map { "{\"name\":\"\($0)\"}" }
            .joined(separator: ",")
        let script = """
        #!/bin/sh
        IFS= read -r initialize || exit 1
        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"zbseye"}}}'
        IFS= read -r initialized || exit 1
        IFS= read -r list || exit 1
        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[\(tools)]}}'
        IFS= read -r call || exit 1
        printf '%s\\n' '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"Frame #42 at fixture moment"}],"isError":false}}'
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let fileIdentity = try MCPExecutableFileIdentity.capture(at: executable)
        let identity = MCPInstalledApplicationIdentity(
            applicationURL: root,
            executableURL: executable,
            bundleIdentifier: "gg.zbs.eye",
            teamIdentifier: "44N4NZ86S5",
            codeHash: "fixture",
            fileIdentity: fileIdentity
        )
        let dataRoot = MCPDataRootIdentity(
            url: root,
            device: fileIdentity.device,
            inode: fileIdentity.inode,
            databaseIdentity: fileIdentity,
            frameWitness: MCPFrameWitness(frameID: 42, timestampMs: 123)
        )

        let result = try await SystemMCPSelfTester().run(MCPSelfTestRequest(
            identity: identity,
            dataRoot: dataRoot,
            profile: .memoryReadOnly,
            timeout: .seconds(2),
            maximumOutputBytes: 64 * 1_024
        ))

        XCTAssertEqual(result.toolNames, MCPToolPolicy.toolNames(for: .memoryReadOnly))
        XCTAssertTrue(result.retrievalSucceeded)
    }

    func testReadinessCacheAndToolContractAreProfileSpecific() async {
        let readOnly = MCPSelfTestResult(
            toolNames: MCPToolPolicy.toolNames(for: .memoryReadOnly),
            retrievalSucceeded: true
        )
        let selfTest = MCPProfileAwareSelfTester(results: [
            .memoryReadOnly: readOnly,
            .advancedFull: MCPSelfTestResult(
                toolNames: MCPToolPolicy.toolNames(for: .advancedFull),
                retrievalSucceeded: true
            ),
        ])
        let service = MCPReadinessService(
            applicationURL: Self.applicationURL,
            identityInspector: MCPFakeIdentityInspector(result: .success(Self.identity)),
            dataRootResolver: MCPFakeDataRootResolver(result: .success(Self.rootIdentity)),
            selfTester: selfTest
        )

        let readOnlyState = await service.check(profile: .memoryReadOnly)
        let advancedState = await service.check(profile: .advancedFull)
        let profiles = await selfTest.profiles()
        XCTAssertEqual(readOnlyState, .readyToConnect(Self.identity.executableURL.path))
        XCTAssertEqual(advancedState, .readyToConnect(Self.identity.executableURL.path))
        XCTAssertEqual(profiles, [.memoryReadOnly, .advancedFull])
    }

    func testToolPolicyGuardsListingAndDirectCalls() {
        XCTAssertEqual(
            MCPToolPolicy.toolNames(for: .memoryReadOnly),
            [
                "search_history", "get_transcript", "get_context_at",
                "get_timeline", "list_calls", "get_call",
                "list_call_bookmarks", "read_call_transcript",
                "get_status", "get_diagnostics",
            ]
        )
        for tool in ["list_calls", "get_call", "list_call_bookmarks", "read_call_transcript"] {
            XCTAssertTrue(MCPToolPolicy.allows(tool, profile: .memoryReadOnly))
        }
        XCTAssertFalse(MCPToolPolicy.allows("get_frame_image", profile: .memoryReadOnly))
        XCTAssertFalse(MCPToolPolicy.allows("toggle_recording", profile: .memoryReadOnly))
        XCTAssertTrue(MCPToolPolicy.allows("get_frame_image", profile: .advancedFull))
        XCTAssertTrue(MCPToolPolicy.allows("toggle_recording", profile: .advancedFull))
        XCTAssertEqual(
            MCPToolPolicy.toolNames(for: .advancedFull),
            MCPToolPolicy.toolNames(for: .memoryReadOnly)
                + ["get_frame_image", "toggle_recording"]
        )
    }

    private static func service(selfTester: MCPFakeSelfTester) -> MCPReadinessService {
        MCPReadinessService(
            applicationURL: applicationURL,
            identityInspector: MCPFakeIdentityInspector(result: .success(identity)),
            dataRootResolver: MCPFakeDataRootResolver(result: .success(rootIdentity)),
            selfTester: selfTester
        )
    }

    private static let applicationURL = URL(fileURLWithPath: "/Applications/ZBS Eye.app")
    private static let identity = MCPInstalledApplicationIdentity(
        applicationURL: applicationURL,
        executableURL: applicationURL.appendingPathComponent("Contents/MacOS/ZBS Eye"),
        bundleIdentifier: "gg.zbs.eye",
        teamIdentifier: "44N4NZ86S5",
        codeHash: "fixture-cdhash",
        fileIdentity: .init(device: 1, inode: 2, size: 3, modifiedSeconds: 4)
    )
    private static let rootIdentity = MCPDataRootIdentity(
        url: URL(fileURLWithPath: "/tmp/zbseye-fixture"),
        device: 5,
        inode: 6,
        databaseIdentity: .init(
            device: 5, inode: 7, size: 4_096, modifiedSeconds: 8
        ),
        frameWitness: MCPFrameWitness(frameID: 42, timestampMs: 1_720_922_400_000)
    )
    private static let successfulSelfTest = MCPSelfTestResult(
        toolNames: MCPToolPolicy.toolNames(for: .memoryReadOnly),
        retrievalSucceeded: true
    )

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}

private actor MCPProfileAwareSelfTester: MCPSelfTesting {
    let results: [MCPAccessProfile: MCPSelfTestResult]
    private var observedProfiles: [MCPAccessProfile] = []

    init(results: [MCPAccessProfile: MCPSelfTestResult]) {
        self.results = results
    }

    func run(_ request: MCPSelfTestRequest) async throws -> MCPSelfTestResult {
        observedProfiles.append(request.profile)
        guard let result = results[request.profile] else {
            throw MCPSelfTestError.initializationFailed
        }
        return result
    }

    func profiles() -> [MCPAccessProfile] { observedProfiles }
}

private struct MCPFakeIdentityInspector: MCPInstalledApplicationInspecting {
    let result: Result<MCPInstalledApplicationIdentity, MCPReadinessDependencyError>

    func inspect(applicationURL: URL) async throws -> MCPInstalledApplicationIdentity {
        try result.get()
    }
}

private struct MCPFakeDataRootResolver: MCPDataRootResolving {
    let result: Result<MCPDataRootIdentity, MCPReadinessDependencyError>

    func resolve() async throws -> MCPDataRootIdentity {
        try result.get()
    }
}

private actor MCPSequenceDataRootResolver: MCPDataRootResolving {
    private var values: [MCPDataRootIdentity]

    init(values: [MCPDataRootIdentity]) {
        self.values = values
    }

    func resolve() async throws -> MCPDataRootIdentity {
        guard !values.isEmpty else {
            throw MCPReadinessDependencyError.dataRootUnavailable
        }
        if values.count == 1 { return values[0] }
        return values.removeFirst()
    }
}

private actor MCPFakeSelfTester: MCPSelfTesting {
    let result: Result<MCPSelfTestResult, MCPSelfTestError>
    private var callCount = 0

    init(result: Result<MCPSelfTestResult, MCPSelfTestError>) {
        self.result = result
    }

    func run(_ request: MCPSelfTestRequest) async throws -> MCPSelfTestResult {
        callCount += 1
        return try result.get()
    }

    func calls() -> Int { callCount }
}
