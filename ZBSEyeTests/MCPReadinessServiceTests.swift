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
            )
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

    func testToolPolicyGuardsListingAndDirectCalls() {
        XCTAssertEqual(
            MCPToolPolicy.toolNames(for: .memoryReadOnly),
            [
                "search_history", "get_transcript", "get_context_at",
                "get_timeline", "get_status", "get_diagnostics",
            ]
        )
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
        )
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
