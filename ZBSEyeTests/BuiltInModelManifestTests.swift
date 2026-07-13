import CryptoKit
import Foundation
import XCTest

final class BuiltInModelManifestTests: XCTestCase {
    private let gibibyte = UInt64(1_024 * 1_024 * 1_024)

    func testProductCatalogContainsOnlyTheQualifiedFourBArtifact() {
        XCTAssertEqual(BuiltInModelManifest.all.map(\.id), [BuiltInModelManifest.regular.id])
        XCTAssertEqual(BuiltInModelManifest.regular.expectedDownloadBytes, 3_061_129_077)
        XCTAssertEqual(BuiltInModelManifest.regular.generation.benchmarkProtocol, "local-ai-v9")
        XCTAssertEqual(BuiltInModelManifest.regular.generation.temperature, 0.2)
        XCTAssertEqual(BuiltInModelManifest.regular.generation.topP, 0.95)

        let rejectedIDs = Set([
            BuiltInModelManifest.smallCandidate.id,
            BuiltInModelManifest.qwen35_2BCandidate.id,
            BuiltInModelManifest.qwen3_4BCandidate.id,
        ])
        XCTAssertTrue(rejectedIDs.isDisjoint(with: BuiltInModelManifest.all.map(\.id)))
    }

    func testHardwareRecommendationIsNarrowedToThePhysicalQualificationMachine() {
        XCTAssertNil(
            BuiltInModelManifest.recommended(
                isAppleSilicon: true,
                unifiedMemoryBytes: 64 * gibibyte,
                machineIdentifier: "Mac16,6"
            )
        )
        XCTAssertNil(
            BuiltInModelManifest.recommended(
                isAppleSilicon: true,
                unifiedMemoryBytes: 64 * gibibyte - 1,
                machineIdentifier: "Mac16,5"
            )
        )
        XCTAssertEqual(
            BuiltInModelManifest.recommended(
                isAppleSilicon: true,
                unifiedMemoryBytes: 64 * gibibyte,
                machineIdentifier: "Mac16,5"
            )?.id,
            BuiltInModelManifest.regular.id
        )
        for unqualifiedMemory in [64 * gibibyte + 1, 128 * gibibyte] {
            XCTAssertNil(
                BuiltInModelManifest.recommended(
                    isAppleSilicon: true,
                    unifiedMemoryBytes: unqualifiedMemory,
                    machineIdentifier: "Mac16,5"
                )
            )
        }
        XCTAssertNil(
            BuiltInModelManifest.recommended(
                isAppleSilicon: false,
                unifiedMemoryBytes: 64 * gibibyte,
                machineIdentifier: "Mac16,5"
            )
        )
    }

    func testHardwareMetadataAndQualificationCandidatesRemainAuditable() {
        XCTAssertEqual(BuiltInModelManifest.smallCandidate.hardware.minimumUnifiedMemoryBytes, 8 * gibibyte)
        XCTAssertEqual(BuiltInModelManifest.smallCandidate.hardware.maximumUnifiedMemoryBytesExclusive, 16 * gibibyte)
        XCTAssertEqual(BuiltInModelManifest.qwen35_2BCandidate.hardware.minimumUnifiedMemoryBytes, 16 * gibibyte)
        XCTAssertEqual(BuiltInModelManifest.regular.hardware.minimumUnifiedMemoryBytes, 64 * gibibyte)
        XCTAssertEqual(
            BuiltInModelManifest.regular.hardware.maximumUnifiedMemoryBytesExclusive,
            64 * gibibyte + 1
        )

        for manifest in BuiltInModelManifest.qualificationCandidates {
            XCTAssertEqual(manifest.hardware.minimumMacOSMajorVersion, 15)
            XCTAssertEqual(manifest.hardware.supportedArchitectures, ["arm64"])
        }
    }

    func testFilesAreRevisionPinnedIntegrityCheckedAndPathSafe() {
        for manifest in BuiltInModelManifest.qualificationCandidates {
            let paths = manifest.files.map(\.relativePath)
            XCTAssertEqual(Set(paths).count, paths.count, "\(manifest.id) has duplicate output paths")
            XCTAssertEqual(
                manifest.files.reduce(Int64.zero) { $0 + $1.expectedBytes },
                manifest.expectedDownloadBytes
            )

            for file in manifest.files {
                XCTAssertFalse(file.relativePath.hasPrefix("/"))
                XCTAssertFalse(
                    NSString(string: file.relativePath).pathComponents.contains(".."),
                    "\(file.relativePath) must not escape the model directory"
                )
                XCTAssertTrue(
                    file.sourceURL.absoluteString.contains("/resolve/\(manifest.revision)/"),
                    "\(file.relativePath) must include the exact repository revision"
                )
                XCTAssertNotNil(
                    file.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression),
                    "\(file.relativePath) must have a lowercase SHA-256 digest"
                )
            }
        }
    }

    func testAggregateFingerprintMatchesCanonicalPayload() {
        for manifest in BuiltInModelManifest.qualificationCandidates {
            let digest = SHA256.hash(data: Data(manifest.canonicalFingerprintPayload.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(digest, manifest.aggregateFingerprintSHA256, manifest.id)
        }
    }
}
