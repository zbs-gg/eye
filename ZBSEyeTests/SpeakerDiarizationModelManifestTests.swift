import CryptoKit
import Foundation
import XCTest

final class SpeakerDiarizationModelManifestTests: XCTestCase {
    func testPinnedManifestIsImmutableAndSmall() {
        let manifest = SpeakerDiarizationModelManifest.fluidAudio0155

        XCTAssertEqual(manifest.packageVersion, "0.15.5")
        XCTAssertEqual(manifest.packageCommit, "19600a485baa4998812e4654b70d2bab8f2c9949")
        XCTAssertEqual(manifest.modelRevision, "1ed7a662fdc7109e36d822db793ee6eebdaf8594")
        XCTAssertEqual(manifest.files.count, 21)
        XCTAssertEqual(manifest.expectedBytes, 21_599_417)
        XCTAssertEqual(manifest.packageLicense, "Apache-2.0")
        XCTAssertEqual(manifest.modelLicense, "CC-BY-4.0")
        XCTAssertTrue(manifest.files.allSatisfy { $0.sha256.count == 64 })
        XCTAssertTrue(manifest.files.allSatisfy {
            manifest.sourceURL(for: $0).absoluteString.contains(manifest.modelRevision)
        })
    }

    func testVerifierAcceptsExactInventoryAndRejectsTamperingAndExtraFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerDiarizationManifestTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("fixture".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest = SpeakerDiarizationModelManifest(
            packageVersion: "test",
            packageCommit: String(repeating: "0", count: 40),
            repositoryID: "fixture/repo",
            modelRevision: String(repeating: "1", count: 40),
            packageLicense: "Apache-2.0",
            modelLicense: "CC-BY-4.0",
            files: [
                SpeakerDiarizationModelFile(
                    relativePath: "Model.mlmodelc/weights.bin",
                    expectedBytes: Int64(bytes.count),
                    sha256: digest
                ),
            ]
        )
        let model = root.appendingPathComponent("Model.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let weights = model.appendingPathComponent("weights.bin")
        try bytes.write(to: weights)

        XCTAssertEqual(
            try SpeakerDiarizationModelVerifier.verify(directory: root, manifest: manifest),
            Int64(bytes.count)
        )

        let extra = root.appendingPathComponent("voiceprint.bin")
        try Data([1]).write(to: extra)
        XCTAssertThrowsError(
            try SpeakerDiarizationModelVerifier.verify(directory: root, manifest: manifest)
        ) { error in
            XCTAssertEqual(
                error as? SpeakerDiarizationModelVerificationError,
                .unexpectedFile("voiceprint.bin")
            )
        }
        try FileManager.default.removeItem(at: extra)

        try Data("tampered".utf8).write(to: weights)
        XCTAssertThrowsError(
            try SpeakerDiarizationModelVerifier.verify(directory: root, manifest: manifest)
        )
    }
}
