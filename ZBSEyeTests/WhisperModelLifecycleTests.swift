import CryptoKit
import XCTest

final class WhisperModelLifecycleTests: XCTestCase {
    func testManifestPinsRuntimeModelAndLicense() {
        let manifest = WhisperModelManifest.largeV3Turbo
        XCTAssertEqual(manifest.runtimeRelease, "v1.9.1")
        XCTAssertEqual(
            manifest.runtimeArchiveSHA256,
            "8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
        )
        XCTAssertEqual(manifest.expectedBytes, 1_624_555_275)
        XCTAssertEqual(
            manifest.sha256,
            "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        )
        XCTAssertEqual(manifest.licenseSPDX, "MIT")
        XCTAssertTrue(manifest.revision.hasPrefix("98aa99a"))
    }

    func testSpeechRootIsSeparateFromGenerativeAssets() {
        let root = URL(fileURLWithPath: "/tmp/eye-root", isDirectory: true)
        XCTAssertEqual(
            StorageLocation.speechModelRoot(under: root).path,
            "/tmp/eye-root/ai/speech/v1"
        )
        XCTAssertNotEqual(
            StorageLocation.speechModelRoot(under: root),
            StorageLocation.builtInModelRoot(under: root)
        )
    }

    func testExactCompletedPartialIsVerifiedSmokeTestedAndPromoted() async throws {
        let fixture = try WhisperModelFixture(payload: Data("tiny-whisper-model".utf8))
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()

        let installed = try await store.install()

        XCTAssertEqual(installed.state, .ready)
        XCTAssertEqual(installed.receivedBytes, Int64(fixture.payload.count))
        XCTAssertEqual(try Data(contentsOf: fixture.activeModelURL), fixture.payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL.path))

        let relaunched = try fixture.makeStore()
        let refreshed = await relaunched.refresh()
        XCTAssertEqual(refreshed.state, .ready)
    }

    func testWrongDigestNeverPromotesCandidate() async throws {
        let fixture = try WhisperModelFixture(
            payload: Data("candidate".utf8),
            expectedSHA256: String(repeating: "0", count: 64)
        )
        defer { fixture.cleanup() }
        let store = try fixture.makeStore()

        do {
            _ = try await store.install()
            XCTFail("wrong digest must fail")
        } catch {
            XCTAssertEqual(error as? WhisperModelStoreError, .verificationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.activeModelURL.path))
        let failed = await store.snapshot()
        XCTAssertEqual(failed.state, .failed)
    }

    func testMaintenanceDrainWaitsUntilPausedResumeStateIsDurable() async throws {
        let payload = Data("streamed-model".utf8)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-whisper-drain-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifest = WhisperModelManifest(
            id: "drain-fixture",
            displayName: "Fixture",
            repositoryID: "local/fixture",
            revision: String(repeating: "a", count: 40),
            sourceURL: URL(string: "https://example.invalid/model.bin")!,
            relativePath: "model/model.bin",
            expectedBytes: Int64(payload.count),
            sha256: digest,
            licenseSPDX: "MIT",
            licenseURL: URL(string: "https://example.invalid/license")!,
            runtimeRelease: "v1.9.1",
            runtimeArchiveSHA256: String(repeating: "b", count: 64)
        )
        let transport = BlockingWhisperDownloadTransport(
            sourceURL: manifest.sourceURL,
            expectedBytes: manifest.expectedBytes
        )
        let store = WhisperModelStore(
            root: root,
            manifest: manifest,
            downloadClient: ManagedAssetDownloadClient(
                transport: transport,
                allowedAssetHosts: ["example.invalid"]
            ),
            smokeTest: { _ in }
        )
        let install = Task { try await store.install() }
        try await waitUntil { await transport.hasOpened }

        await store.suspendAndDrain()

        let paused = await store.snapshot()
        XCTAssertEqual(paused.state, .paused)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("staging/resume.json").path
            )
        )
        let installResult = try await install.value
        XCTAssertEqual(installResult.state, .paused)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition timed out")
    }
}

private actor BlockingWhisperDownloadTransport: BuiltInDownloadTransport {
    let sourceURL: URL
    let expectedBytes: Int64
    private(set) var hasOpened = false
    private var waiter: CheckedContinuation<Data?, any Error>?

    init(sourceURL: URL, expectedBytes: Int64) {
        self.sourceURL = sourceURL
        self.expectedBytes = expectedBytes
    }

    func open(_ request: BuiltInDownloadHTTPRequest) async throws -> BuiltInDownloadStream {
        hasOpened = true
        return BuiltInDownloadStream(
            response: BuiltInDownloadHTTPResponse(
                url: sourceURL,
                statusCode: 200,
                headers: [
                    "Content-Length": String(expectedBytes),
                    "Content-Encoding": "identity",
                    "ETag": #""fixture""#,
                ]
            ),
            nextChunk: { try await self.nextChunk() },
            cancel: { Task { await self.cancelPendingRequests() } }
        )
    }

    func cancelPendingRequests() async {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    private func nextChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }
}

private struct WhisperModelFixture {
    let root: URL
    let payload: Data
    let manifest: WhisperModelManifest

    init(payload: Data, expectedSHA256: String? = nil) throws {
        self.payload = payload
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-whisper-model-\(UUID().uuidString)", isDirectory: true)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        manifest = WhisperModelManifest(
            id: "whisper-fixture",
            displayName: "Fixture",
            repositoryID: "local/fixture",
            revision: String(repeating: "a", count: 40),
            sourceURL: URL(string: "https://example.invalid/model.bin")!,
            relativePath: "model/model.bin",
            expectedBytes: Int64(payload.count),
            sha256: expectedSHA256 ?? digest,
            licenseSPDX: "MIT",
            licenseURL: URL(string: "https://example.invalid/license")!,
            runtimeRelease: "v1.9.1",
            runtimeArchiveSHA256: String(repeating: "b", count: 64)
        )
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try payload.write(to: partialURL)
        let resume = ManagedAssetDownloadResumeState(
            sourceURL: manifest.sourceURL,
            revision: manifest.revision,
            manifestFingerprintSHA256: manifest.sha256,
            expectedBytes: manifest.expectedBytes,
            strongETag: #""fixture""#,
            receivedBytes: manifest.expectedBytes
        )
        try JSONEncoder().encode(resume).write(to: resumeURL)
    }

    var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }
    var partialURL: URL { stagingDirectory.appendingPathComponent("model.partial") }
    var resumeURL: URL { stagingDirectory.appendingPathComponent("resume.json") }
    var activeModelURL: URL { root.appendingPathComponent(manifest.relativePath) }

    func makeStore() throws -> WhisperModelStore {
        WhisperModelStore(
            root: root,
            manifest: manifest,
            downloadClient: ManagedAssetDownloadClient(
                allowedAssetHosts: ["example.invalid"]
            ),
            smokeTest: { url in
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw WhisperModelStoreError.smokeTestFailed
                }
            }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
