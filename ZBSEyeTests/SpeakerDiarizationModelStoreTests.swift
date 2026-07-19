import CryptoKit
import Foundation
import XCTest

final class SpeakerDiarizationModelStoreTests: XCTestCase {
    func testExplicitInstallPromotesOnlyCompleteVerifiedDirectory() async throws {
        let fixture = try SpeakerModelStoreFixture()
        let store = fixture.makeStore()

        let installed = try await store.install()

        XCTAssertEqual(installed.state, .ready)
        XCTAssertEqual(installed.receivedBytes, fixture.manifest.expectedBytes)
        let ready = await store.isReady()
        XCTAssertTrue(ready)
        XCTAssertEqual(
            try SpeakerDiarizationModelVerifier.verify(
                directory: fixture.activeDirectory,
                manifest: fixture.manifest
            ),
            fixture.manifest.expectedBytes
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stagingDirectory.path))
    }

    func testCorruptDownloadFailsClosedWithoutPublishingModel() async throws {
        let fixture = try SpeakerModelStoreFixture(corruptFirstFile: true)
        let store = fixture.makeStore()

        do {
            _ = try await store.install()
            XCTFail("corrupt assets must not install")
        } catch {
            XCTAssertEqual(error as? SpeakerDiarizationModelStoreError, .verificationFailed)
        }

        let ready = await store.isReady()
        let snapshot = await store.snapshot()
        XCTAssertFalse(ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.activeDirectory.path))
        XCTAssertEqual(snapshot.state, .failed)
    }

    func testRemoveDeletesInstalledAssetsAndReturnsToAbsent() async throws {
        let fixture = try SpeakerModelStoreFixture()
        let store = fixture.makeStore()
        _ = try await store.install()

        let removed = try await store.remove()

        XCTAssertEqual(removed.state, .absent)
        let ready = await store.isReady()
        XCTAssertFalse(ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.activeDirectory.path))
    }
}

private final class SpeakerModelStoreFixture {
    let root: URL
    let manifest: SpeakerDiarizationModelManifest
    private let payloads: [Int64: Data]
    private let corruptFirstFile: Bool

    init(corruptFirstFile: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("speaker-model-store-tests-\(UUID().uuidString)", isDirectory: true)
        self.corruptFirstFile = corruptFirstFile
        let first = Data("first-model".utf8)
        let second = Data("second-model-file".utf8)
        payloads = [Int64(first.count): first, Int64(second.count): second]
        manifest = SpeakerDiarizationModelManifest(
            packageVersion: "test",
            packageCommit: "test",
            repositoryID: "test/repository",
            modelRevision: "test-revision",
            packageLicense: "test",
            modelLicense: "test",
            files: [
                .init(
                    relativePath: "A.mlmodelc/model.bin",
                    expectedBytes: Int64(first.count),
                    sha256: Self.sha256(first)
                ),
                .init(
                    relativePath: "B.mlmodelc/model.bin",
                    expectedBytes: Int64(second.count),
                    sha256: Self.sha256(second)
                ),
            ]
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var activeDirectory: URL {
        root.appendingPathComponent(DiarizationHelperCommand.modelRepositoryDirectory, isDirectory: true)
    }

    var stagingDirectory: URL { root.appendingPathComponent("staging", isDirectory: true) }

    func makeStore() -> SpeakerDiarizationModelStore {
        let payloads = payloads
        let firstSize = manifest.files[0].expectedBytes
        let corruptFirstFile = corruptFirstFile
        let transport = SpeakerDiarizationModelTransport(
            download: { plan, _, progress in
                var data = try XCTUnwrap(payloads[plan.expectedBytes])
                if corruptFirstFile, plan.expectedBytes == firstSize {
                    data = Data(repeating: 0x78, count: Int(plan.expectedBytes))
                }
                try FileManager.default.createDirectory(
                    at: plan.partialFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: plan.partialFileURL)
                let state = ManagedAssetDownloadResumeState(
                    sourceURL: plan.sourceURL,
                    revision: plan.revision,
                    manifestFingerprintSHA256: plan.manifestFingerprintSHA256,
                    expectedBytes: plan.expectedBytes,
                    strongETag: "\"test-etag\"",
                    receivedBytes: Int64(data.count)
                )
                await progress(state)
                return .completed(state)
            },
            suspendAndDrain: {},
            resumeAfterDrain: {},
            cancelAndDrain: {}
        )
        return SpeakerDiarizationModelStore(
            root: root,
            manifest: manifest,
            transport: transport
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
