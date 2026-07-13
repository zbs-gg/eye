import CryptoKit
import Foundation
import XCTest

final class ScreenUnderstandingEvalProtocolTests: XCTestCase {
    func testCheckedInProtocolLocksIdentityMatrixLanesAndPrivacyBoundary() throws {
        let url = protocolURL()
        let data = try Data(contentsOf: url)
        let benchmark = try ScreenUnderstandingEvalProtocol.load(from: url)

        XCTAssertNoThrow(try benchmark.validate())
        XCTAssertEqual(benchmark.identity.id, "screen-understanding-v1")
        XCTAssertEqual(benchmark.identity.revision, 1)
        XCTAssertEqual(benchmark.execution.offline, true)
        XCTAssertEqual(benchmark.execution.retryCount, 0)
        XCTAssertEqual(Set(benchmark.lanes), [.officialCheckpointQuality, .productFootprint])
        XCTAssertEqual(
            Set(benchmark.methods.map(\.id)),
            [
                "metadata-ax-ocr",
                "apple-vision",
                "deterministic-hybrid",
                "florence-2-base",
                "smolvlm-256m-instruct",
                "lfm2-vl-450m",
                "fastvlm-0.5b",
                "smolvlm2-256m-video-instruct",
                "omniparser-v2",
            ]
        )
        XCTAssertEqual(
            benchmark.methods.first(where: { $0.id == "fastvlm-0.5b" })?.disposition,
            .researchOnly
        )
        XCTAssertEqual(
            benchmark.methods.first(where: { $0.id == "smolvlm2-256m-video-instruct" })?
                .inputCapabilities,
            [.singleImage, .temporalPair]
        )
        XCTAssertEqual(
            benchmark.methods.first(where: { $0.id == "omniparser-v2" })?
                .outputCapabilities,
            [.labels, .regions, .visibleText, .confidence, .abstention, .errors, .runtimeMetadata]
        )
        XCTAssertEqual(benchmark.corpus.lockedSingleFrameCount, 200)
        XCTAssertEqual(benchmark.corpus.lockedTemporalPairCount, 100)
        XCTAssertGreaterThanOrEqual(benchmark.corpus.minimumHeldOutSingleFrames, 60)
        XCTAssertGreaterThanOrEqual(benchmark.corpus.minimumHeldOutTemporalPairs, 30)
        XCTAssertEqual(benchmark.publication.allowCaseMaterial, false)

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "b59f66ffa515af2260b2c27cc9da31be24a51f356690a303192ef6807244440f")
    }

    func testValidationRejectsForbiddenExecutionAndUnpinnedMethods() throws {
        var benchmark = try fixtureProtocol()
        benchmark.execution.offline = false
        assertRejected(benchmark, containing: "offline")

        benchmark = try fixtureProtocol()
        benchmark.execution.retryCount = 1
        assertRejected(benchmark, containing: "retry")

        benchmark = try fixtureProtocol()
        benchmark.methods[0].remote = true
        assertRejected(benchmark, containing: "remote")

        benchmark = try fixtureProtocol()
        benchmark.methods[0].sizeClass = .large
        assertRejected(benchmark, containing: "large")

        benchmark = try fixtureProtocol()
        benchmark.methods[0].artifactRevision = ""
        assertRejected(benchmark, containing: "revision")

        benchmark = try fixtureProtocol()
        benchmark.methods[0].artifactSHA256 = "not-a-hash"
        assertRejected(benchmark, containing: "hash")

        benchmark = try fixtureProtocol()
        benchmark.methods[0].license = ""
        assertRejected(benchmark, containing: "license")
    }

    func testValidationRejectsLiveWritesUnlockedSplitsAndMixedLaneScores() throws {
        var benchmark = try fixtureProtocol()
        benchmark.corpus.liveSourceAccess = .readWrite
        assertRejected(benchmark, containing: "read-only")

        benchmark = try fixtureProtocol()
        benchmark.corpus.splitsLockedBeforeOutputs = false
        assertRejected(benchmark, containing: "split")

        benchmark = try fixtureProtocol()
        benchmark.reporting.combinedQualityFootprintScoreAllowed = true
        assertRejected(benchmark, containing: "lane")
    }

    func testValidationRejectsTemporalClaimsFromSingleImageMethods() throws {
        var benchmark = try fixtureProtocol()
        benchmark.methods[0].outputCapabilities.append(.changeFacts)

        assertRejected(benchmark, containing: "temporal")
    }

    func testQualificationRequiresExactRuntimeR20PowerAndReliableCanonicalAnnotations() throws {
        let benchmark = try fixtureProtocol()
        let accepted = ScreenUnderstandingQualificationEvidence(
            exactProductRuntimeScored: true,
            exactProductRuntimeArtifactSHA256: String(repeating: "a", count: 64),
            overallUsefulnessGainPoints: 3,
            weakStratumUsefulnessGainPoints: 10,
            criticalTextRecallDeltaPoints: -2,
            severityWeightedHallucinationDeltaPoints: 1,
            minimumDecisionCellCount: 15,
            duplicateLabelFraction: 0.15,
            factAgreement: 0.90,
            decisionAgreement: 0.80
        )

        XCTAssertEqual(benchmark.qualificationFailures(for: accepted), [])

        var evidence = accepted
        evidence.exactProductRuntimeScored = false
        XCTAssertTrue(benchmark.qualificationFailures(for: evidence).contains { $0.contains("runtime") })

        evidence = accepted
        evidence.overallUsefulnessGainPoints = 2.99
        XCTAssertTrue(benchmark.qualificationFailures(for: evidence).contains { $0.contains("overall") })

        evidence = accepted
        evidence.minimumDecisionCellCount = 14
        XCTAssertTrue(benchmark.qualificationFailures(for: evidence).contains { $0.contains("cell") })

        evidence = accepted
        evidence.factAgreement = 0.89
        XCTAssertTrue(benchmark.qualificationFailures(for: evidence).contains { $0.contains("agreement") })
    }

    func testSchemasExposeCapabilityAwarePrivateResultsAndAggregateOnlyPublicOutput() throws {
        let root = repositoryRoot().appendingPathComponent(
            "tools/screen-understanding-bench/schemas",
            isDirectory: true
        )
        let normalized = try schemaObject(root.appendingPathComponent("normalized-result.schema.json"))
        let publicAggregate = try schemaObject(
            root.appendingPathComponent("public-aggregate.schema.json")
        )

        XCTAssertEqual(normalized["additionalProperties"] as? Bool, false)
        let normalizedProperties = try XCTUnwrap(normalized["properties"] as? [String: Any])
        XCTAssertTrue(Set([
            "summary", "atomicFacts", "visibleText", "labels", "regions", "changeFacts",
            "confidence", "abstention", "errors", "runtimeMetadata",
        ]).isSubset(of: Set(normalizedProperties.keys)))

        XCTAssertEqual(publicAggregate["additionalProperties"] as? Bool, false)
        let encodedPublicSchema = String(
            data: try JSONSerialization.data(withJSONObject: publicAggregate, options: [.sortedKeys]),
            encoding: .utf8
        ) ?? ""
        for forbidden in ["frame", "caption", "labelText", "caseID", "timestamp", "sourcePath", "rawError"] {
            XCTAssertFalse(encodedPublicSchema.contains(forbidden), forbidden)
        }
    }

    private func fixtureProtocol() throws -> ScreenUnderstandingEvalProtocol {
        try ScreenUnderstandingEvalProtocol.load(from: protocolURL())
    }

    private func assertRejected(
        _ benchmark: ScreenUnderstandingEvalProtocol,
        containing expectedFragment: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try benchmark.validate(), file: file, line: line) { error in
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(expectedFragment),
                "\(error)",
                file: file,
                line: line
            )
        }
    }

    private func protocolURL() -> URL {
        repositoryRoot().appendingPathComponent("docs/evals/screen-understanding-v1.json")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func schemaObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }
}
