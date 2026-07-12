import Foundation
import XCTest

final class ScreenUnderstandingAdapterContractTests: XCTestCase {
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
        XCTAssertEqual(responses[0].status, "ready")
        XCTAssertEqual(responses[1].status, "ok")
        XCTAssertEqual(responses[1].normalized?.summary, "Synthetic visible activity")
        XCTAssertEqual(responses[2].status, "bye")
    }

    func testExplicitUnsupportedIsAuditableAndNotRetried() throws {
        let runner = try makeRunner(mode: "unsupported")
        let responses = try runner.run(
            messages: [.hello(id: "1", protocolID: "screen-understanding-v1")],
            timeoutSeconds: 5
        )
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses[0].status, "unsupported")
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

    private func makeRunner(mode: String) throws -> ScreenUnderstandingAdapterProcess {
        ScreenUnderstandingAdapterProcess(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [adapterScriptURL().path, "--mode", mode],
            environment: ScreenUnderstandingAdapterEnvironment.make(
                ephemeralHome: FileManager.default.temporaryDirectory
            )
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

    private func sandboxProfileURL() -> URL {
        repositoryRoot().appendingPathComponent(
            "tools/screen-understanding-bench/sandbox/adapter.sb"
        )
    }
}
