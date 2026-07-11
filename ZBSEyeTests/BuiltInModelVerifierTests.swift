import CryptoKit
import Foundation
import XCTest

final class BuiltInModelVerifierTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-model-verifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testAcceptsAnExactRegularFileInventory() throws {
        let payload = Data("tiny model fixture".utf8)
        try payload.write(to: directory.appendingPathComponent("weights.bin"))

        let result = try BuiltInModelVerifier.verify(
            directory: directory,
            manifest: fixtureManifest(payload: payload)
        )

        XCTAssertEqual(result.verifiedBytes, Int64(payload.count))
        XCTAssertEqual(result.verifiedFileCount, 1)
    }

    func testRejectsMissingRequiredFile() throws {
        XCTAssertThrowsError(
            try BuiltInModelVerifier.verify(
                directory: directory,
                manifest: fixtureManifest(payload: Data("missing".utf8))
            )
        ) { error in
            XCTAssertEqual(error as? BuiltInModelVerificationError, .missingFile("weights.bin"))
        }
    }

    func testRejectsUnexpectedFile() throws {
        let payload = Data("tiny model fixture".utf8)
        try payload.write(to: directory.appendingPathComponent("weights.bin"))
        try Data("surprise".utf8).write(to: directory.appendingPathComponent("extra.bin"))

        XCTAssertThrowsError(
            try BuiltInModelVerifier.verify(
                directory: directory,
                manifest: fixtureManifest(payload: payload)
            )
        ) { error in
            XCTAssertEqual(error as? BuiltInModelVerificationError, .unexpectedFile("extra.bin"))
        }
    }

    func testRejectsSymbolicLinkEvenWhenItsTargetMatches() throws {
        let payload = Data("tiny model fixture".utf8)
        let target = directory.appendingPathComponent("target.bin")
        try payload.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("weights.bin"),
            withDestinationURL: target
        )
        try FileManager.default.removeItem(at: target)
        let outsideTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-model-target-\(UUID().uuidString)")
        try payload.write(to: outsideTarget)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("weights.bin"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("weights.bin"),
            withDestinationURL: outsideTarget
        )
        defer { try? FileManager.default.removeItem(at: outsideTarget) }

        XCTAssertThrowsError(
            try BuiltInModelVerifier.verify(
                directory: directory,
                manifest: fixtureManifest(payload: payload)
            )
        ) { error in
            XCTAssertEqual(error as? BuiltInModelVerificationError, .nonRegularFile("weights.bin"))
        }
    }

    func testRejectsHardLinkEvenWhenItsPayloadMatches() throws {
        let payload = Data("tiny model fixture".utf8)
        let outsideTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-model-hard-link-target-\(UUID().uuidString)")
        try payload.write(to: outsideTarget)
        defer { try? FileManager.default.removeItem(at: outsideTarget) }

        try FileManager.default.linkItem(
            at: outsideTarget,
            to: directory.appendingPathComponent("weights.bin")
        )

        XCTAssertThrowsError(
            try BuiltInModelVerifier.verify(
                directory: directory,
                manifest: fixtureManifest(payload: payload)
            )
        ) { error in
            XCTAssertEqual(error as? BuiltInModelVerificationError, .nonRegularFile("weights.bin"))
        }
    }

    func testRejectsByteCountBeforeHashing() throws {
        let expected = Data("tiny model fixture".utf8)
        try Data("short".utf8).write(to: directory.appendingPathComponent("weights.bin"))

        XCTAssertThrowsError(
            try BuiltInModelVerifier.verify(
                directory: directory,
                manifest: fixtureManifest(payload: expected)
            )
        ) { error in
            guard case .byteCountMismatch(let path, let expectedBytes, let actualBytes) =
                    error as? BuiltInModelVerificationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, "weights.bin")
            XCTAssertEqual(expectedBytes, Int64(expected.count))
            XCTAssertEqual(actualBytes, 5)
        }
    }

    func testRejectsDigestMismatch() throws {
        let expected = Data("alpha".utf8)
        try Data("omega".utf8).write(to: directory.appendingPathComponent("weights.bin"))

        XCTAssertThrowsError(
            try BuiltInModelVerifier.verify(
                directory: directory,
                manifest: fixtureManifest(payload: expected)
            )
        ) { error in
            guard case .digestMismatch(let path, _, _) = error as? BuiltInModelVerificationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(path, "weights.bin")
        }
    }

    private func fixtureManifest(payload: Data) -> BuiltInModelManifest {
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return BuiltInModelManifest(
            id: "fixture-v1",
            artifactVersion: 1,
            repositoryID: "local/fixture",
            revision: String(repeating: "a", count: 40),
            displayName: "Fixture",
            modelFamily: "Fixture",
            license: BuiltInModelLicense(
                spdxIdentifier: "Apache-2.0",
                displayName: "Apache License 2.0",
                upstreamModelID: "local/fixture",
                upstreamLicenseURL: URL(string: "https://example.invalid/license")!,
                immutableProvenanceURL: URL(string: "https://example.invalid/provenance")!
            ),
            hardware: BuiltInModelHardwareEnvelope(
                minimumUnifiedMemoryBytes: 1,
                maximumUnifiedMemoryBytesExclusive: nil,
                minimumMacOSMajorVersion: 15,
                supportedArchitectures: ["arm64"],
                maximumIncrementalMemoryBytes: 1
            ),
            generation: BuiltInModelGenerationProfile(
                contextTokenCeiling: 32,
                thinkingMode: .disabled,
                temperature: 0.2,
                topP: 0.95,
                benchmarkProtocol: "fixture"
            ),
            expectedDownloadBytes: Int64(payload.count),
            aggregateFingerprintSHA256: String(repeating: "0", count: 64),
            files: [
                BuiltInModelFile(
                    relativePath: "weights.bin",
                    sourceURL: URL(string: "https://example.invalid/weights.bin")!,
                    expectedBytes: Int64(payload.count),
                    sha256: digest,
                    role: .weights,
                    requirement: .required
                )
            ]
        )
    }
}
