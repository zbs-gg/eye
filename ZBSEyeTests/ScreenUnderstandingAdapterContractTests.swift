import Foundation
import XCTest

final class ScreenUnderstandingAdapterContractTests: XCTestCase {
    func testNormalizedResultRejectsUnknownKeysNullArraysNonObjectRegionsAndDuplicates() throws {
        let invalidNormalizedResults = [
            """
            {"methodID":"test","capabilities":["summary"],"runtimeMetadata":{},"extra":true}
            """,
            """
            {"methodID":"test","capabilities":["summary"],"runtimeMetadata":{},"atomicFacts":null}
            """,
            """
            {"methodID":"test","capabilities":["regions"],"runtimeMetadata":{},"regions":["not-an-object"]}
            """,
            """
            {"methodID":"test","capabilities":["summary","summary"],"runtimeMetadata":{}}
            """,
        ]

        for json in invalidNormalizedResults {
            XCTAssertThrowsError(try JSONDecoder().decode(
                ScreenUnderstandingNormalizedAdapterResult.self,
                from: Data(json.utf8)
            ), "Accepted invalid normalized result: \(json)")
        }
    }

    func testAdapterRejectsSuccessErrorsAndStatusSpecificPayloads() throws {
        let runner = try makeRunner(mode: "synthetic")
        let messages: [ScreenUnderstandingAdapterMessage] = [
            .hello(id: "1", protocolID: "screen-understanding-v1"),
            .caseRequest(id: "2", caseID: "abc", imagePath: "/case/image.heic"),
            .shutdown(id: "3"),
        ]
        let normalized = try decodeResponse(
            """
            {"id":"2","status":"ok","normalized":{"methodID":"test","capabilities":["summary"],"runtimeMetadata":{}}}
            """
        ).normalized
        let invalidResponses: [[ScreenUnderstandingAdapterResponse]] = [
            [
                try decodeResponse(#"{"id":"1","status":"ready","error":"warning"}"#),
                ScreenUnderstandingAdapterResponse(id: "2", status: .ok, normalized: normalized),
                try decodeResponse(#"{"id":"3","status":"bye"}"#),
            ],
            [
                try decodeResponse(#"{"id":"1","status":"ready","normalized":{"methodID":"test","capabilities":["summary"],"runtimeMetadata":{}}}"#),
                ScreenUnderstandingAdapterResponse(id: "2", status: .ok, normalized: normalized),
                try decodeResponse(#"{"id":"3","status":"bye"}"#),
            ],
            [
                try decodeResponse(#"{"id":"1","status":"ready"}"#),
                try decodeResponse(#"{"id":"2","status":"ok","normalized":{"methodID":"test","capabilities":["summary"],"runtimeMetadata":{}},"error":"partial failure"}"#),
                try decodeResponse(#"{"id":"3","status":"bye"}"#),
            ],
            [
                try decodeResponse(#"{"id":"1","status":"ready"}"#),
                ScreenUnderstandingAdapterResponse(id: "2", status: .ok, normalized: normalized),
                try decodeResponse(#"{"id":"3","status":"bye","error":"warning"}"#),
            ],
        ]

        for responses in invalidResponses {
            XCTAssertThrowsError(try runner.validate(messages: messages, responses: responses))
        }

        XCTAssertThrowsError(try runner.validate(
            messages: [.hello(id: "1", protocolID: "screen-understanding-v1")],
            responses: [try decodeResponse(#"{"id":"1","status":"unsupported"}"#)]
        ))
        XCTAssertThrowsError(try runner.validate(
            messages: [.hello(id: "1", protocolID: "screen-understanding-v1")],
            responses: [try decodeResponse(
                """
                {"id":"1","status":"unsupported","error":"not provisioned","normalized":{"methodID":"test","capabilities":["summary"],"runtimeMetadata":{}}}
                """
            )]
        ))
    }

    func testSyntheticAdapterCompletesHandshakeCaseAndShutdown() throws {
        let runner = try makeRunner(mode: "synthetic")
        let responses = try runner.run(
            messages: [
                .hello(id: "1", protocolID: "screen-understanding-v1"),
                .caseRequest(id: "2", caseID: "abc", imagePath: "/case/image.heic"),
                .shutdown(id: "3"),
            ],
            timeoutSeconds: 5
        )

        XCTAssertEqual(responses.map(\.id), ["1", "2", "3"])
        XCTAssertEqual(responses[0].status, .ready)
        XCTAssertEqual(responses[1].status, .ok)
        XCTAssertEqual(responses[1].normalized?.summary, "Synthetic visible activity")
        XCTAssertEqual(responses[1].normalized?.methodID, "synthetic-contract")
        XCTAssertEqual(responses[2].status, .bye)
    }

    func testExplicitUnsupportedIsAuditableAndNotRetried() throws {
        let runner = try makeRunner(mode: "unsupported")
        let responses = try runner.run(
            messages: [.hello(id: "1", protocolID: "screen-understanding-v1")],
            timeoutSeconds: 5
        )
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses[0].status, .unsupported)
        XCTAssertTrue(responses[0].error?.contains("runtime not provisioned") == true)
    }

    func testMalformedOutputCrashAndTimeoutFailClosed() throws {
        XCTAssertThrowsError(try makeRunner(mode: "malformed").run(
            messages: [.hello(id: "1", protocolID: "screen-understanding-v1")],
            timeoutSeconds: 5
        ))
        XCTAssertThrowsError(try makeRunner(mode: "crash").run(
            messages: [.hello(id: "1", protocolID: "screen-understanding-v1")],
            timeoutSeconds: 5
        ))
        XCTAssertThrowsError(try makeRunner(mode: "hang").run(
            messages: [.hello(id: "1", protocolID: "screen-understanding-v1")],
            timeoutSeconds: 0.2
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("timeout"))
        }
    }

    func testPhaseStatusMismatchFailsClosed() throws {
        XCTAssertThrowsError(try makeRunner(mode: "wrong-status").run(
            messages: [
                .hello(id: "1", protocolID: "screen-understanding-v1"),
                .caseRequest(id: "2", caseID: "abc", imagePath: "/case/image.heic"),
            ],
            timeoutSeconds: 5
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("did not match"))
        }
    }

    func testTimeoutKillsTheAdapterDescendantProcessGroup() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "screen-understanding-child-\(UUID().uuidString).pid"
        )
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let runner = try makeRunner(
            mode: "hang-child",
            extraArguments: ["--child-pid-file", pidFile.path]
        )

        XCTAssertThrowsError(try runner.run(
            messages: [.hello(id: "1", protocolID: "screen-understanding-v1")],
            timeoutSeconds: 1
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("timeout"))
        }
        let childPID = try XCTUnwrap(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        errno = 0
        XCTAssertEqual(Darwin.kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testLargeStdoutAndStderrAreDrainedAndRejectedWithoutDeadlock() throws {
        XCTAssertThrowsError(try makeRunner(mode: "flood").run(
            messages: [.hello(id: "1", protocolID: "screen-understanding-v1")],
            timeoutSeconds: 5
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("bounded capture limit"))
        }
    }

    func testManifestLocksEveryMethodAndRejectsUnsafeEntries() throws {
        let manifest = try ScreenUnderstandingAdapterManifest.load(from: manifestURL())
        XCTAssertNoThrow(try manifest.validate())
        XCTAssertEqual(Set(manifest.adapters.map(\.id)), [
            "metadata-ax-ocr", "apple-vision", "deterministic-hybrid",
            "florence-2-base", "smolvlm-256m-instruct", "lfm2-vl-450m",
            "fastvlm-0.5b", "smolvlm2-256m-video-instruct", "omniparser-v2",
        ])
        XCTAssertTrue(manifest.adapters.allSatisfy { !$0.remote && $0.retryCount == 0 })

        var unsafe = manifest
        unsafe.adapters[0].remote = true
        XCTAssertThrowsError(try unsafe.validate())
        unsafe = manifest
        unsafe.adapters[0].artifactRevision = "main"
        XCTAssertThrowsError(try unsafe.validate())
        unsafe = manifest
        unsafe.adapters[0].allowsRemoteCode = true
        XCTAssertThrowsError(try unsafe.validate())
    }

    func testSandboxProfileDeclaresNetworkAndFilesystemDenyByDefault() throws {
        let profile = try String(contentsOf: sandboxProfileURL(), encoding: .utf8)
        XCTAssertTrue(profile.contains("(deny default)"))
        XCTAssertTrue(profile.contains("(deny network*)"))
        XCTAssertTrue(profile.contains("CASE_ROOT"))
        XCTAssertTrue(profile.contains("MODEL_ROOT"))
        XCTAssertTrue(profile.contains("RESULT_ROOT"))
        XCTAssertFalse(profile.contains("home-subpath"))
    }

    func testThirdPartyAdaptersRemainUnsupportedUntilSandboxBoundaryIsProven() throws {
        let manifest = try ScreenUnderstandingAdapterManifest.load(from: manifestURL())
        let builtIns = Set(["metadata-ax-ocr", "apple-vision", "deterministic-hybrid"])
        let thirdParty = manifest.adapters.filter { !builtIns.contains($0.id) }
        XCTAssertTrue(thirdParty.allSatisfy { $0.status == "security-unsupported" })
        XCTAssertTrue(thirdParty.allSatisfy {
            $0.reason?.contains("boundary unproven") == true
        })
    }

    private func makeRunner(
        mode: String,
        extraArguments: [String] = []
    ) throws -> ScreenUnderstandingAdapterProcess {
        ScreenUnderstandingAdapterProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [adapterScriptURL().path, "--mode", mode] + extraArguments,
            environment: ScreenUnderstandingAdapterEnvironment.make(
                ephemeralHome: FileManager.default.temporaryDirectory
            ),
            processGroupLauncher: processGroupLauncherURL()
        )
    }

    private func decodeResponse(_ json: String) throws -> ScreenUnderstandingAdapterResponse {
        try JSONDecoder().decode(
            ScreenUnderstandingAdapterResponse.self,
            from: Data(json.utf8)
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func adapterScriptURL() -> URL {
        repositoryRoot().appendingPathComponent(
            "tools/screen-understanding-bench/adapters/contract_adapter.py"
        )
    }

    private func manifestURL() -> URL {
        repositoryRoot().appendingPathComponent(
            "tools/screen-understanding-bench/adapters/manifest.json"
        )
    }

    private func processGroupLauncherURL() -> URL {
        repositoryRoot().appendingPathComponent(
            "tools/screen-understanding-bench/adapters/process_group_launcher.py"
        )
    }

    private func sandboxProfileURL() -> URL {
        repositoryRoot().appendingPathComponent(
            "tools/screen-understanding-bench/sandbox/adapter.sb"
        )
    }
}
