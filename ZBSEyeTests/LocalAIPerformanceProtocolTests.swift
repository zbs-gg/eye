import Foundation
import XCTest

final class LocalAIPerformanceProtocolTests: XCTestCase {
    func testCheckedInProtocolLocksQualifiedArtifactHardwareAndSampling() throws {
        let protocolURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals/local-ai-performance-v1.json")

        let benchmark = try LocalAIPerformanceProtocol.load(from: protocolURL)
        try benchmark.validate(against: BuiltInModelManifest.regular)

        XCTAssertEqual(benchmark.protocolID, "local-ai-performance-v1")
        XCTAssertEqual(benchmark.artifactID, BuiltInModelManifest.regular.id)
        XCTAssertEqual(benchmark.hardware.machineIdentifier, "Mac16,5")
        XCTAssertEqual(benchmark.hardware.physicalMemoryBytes, 64 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(benchmark.generation.temperature, 0.2)
        XCTAssertEqual(benchmark.generation.topP, 0.95)
        XCTAssertEqual(benchmark.generation.prefillStepSize, 256)
        XCTAssertEqual(benchmark.generation.thinkingMode, "disabled")
        XCTAssertEqual(benchmark.generation.maximumOutputTokens, 256)
        XCTAssertEqual(benchmark.generation.safetyTokens, 64)
        XCTAssertEqual(benchmark.contexts.map(\.preparedInputTokens), [2_048, 7_872])
        XCTAssertEqual(benchmark.sampling.coldPerContext, 20)
        XCTAssertEqual(benchmark.sampling.warmPerContext, 30)
        XCTAssertEqual(benchmark.sampling.retainedMemoryGenerations, 50)
        XCTAssertEqual(benchmark.sampling.retainedMemoryContextID, "prepared-full")
        XCTAssertEqual(benchmark.aggregation.percentileMethod, "nearest-rank")
        XCTAssertEqual(benchmark.thresholds.twoKColdTTFTP95Seconds, 5)
        XCTAssertEqual(benchmark.thresholds.fullColdTTFTP95Seconds, 15)
        XCTAssertEqual(benchmark.thresholds.fullWarmTTFTP95Seconds, 10)
        XCTAssertEqual(benchmark.thresholds.minimumDecodeTokensPerSecond, 12)
        XCTAssertEqual(benchmark.thresholds.maximumCancellationSeconds, 1)
        XCTAssertEqual(benchmark.thresholds.maximumIncrementalPeakBytes, 5.5 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(benchmark.thresholds.maximumRetainedGrowthBytes, 100 * 1_024 * 1_024)
        XCTAssertEqual(benchmark.thresholds.minimumUnloadReleaseFraction, 0.9)
        XCTAssertEqual(benchmark.thresholds.maximumUnloadSeconds, 10)
    }

    func testNearestRankDoesNotInterpolate() {
        let values = (1...20).map(Double.init)

        XCTAssertEqual(LocalAIPerformanceMath.nearestRank(values, percentile: 0.50), 10)
        XCTAssertEqual(LocalAIPerformanceMath.nearestRank(values, percentile: 0.95), 19)
        XCTAssertNil(LocalAIPerformanceMath.nearestRank([], percentile: 0.95))
    }

    func testLanguageScheduleIsBalancedAndDeterministic() {
        let twenty = LocalAIPerformanceMath.balancedLanguages(count: 20)
        let thirty = LocalAIPerformanceMath.balancedLanguages(count: 30)

        XCTAssertEqual(twenty.filter { $0 == .english }.count, 10)
        XCTAssertEqual(twenty.filter { $0 == .russian }.count, 10)
        XCTAssertEqual(thirty.filter { $0 == .english }.count, 15)
        XCTAssertEqual(thirty.filter { $0 == .russian }.count, 15)
        XCTAssertEqual(Array(twenty.prefix(4)), [.english, .russian, .english, .russian])
    }

    func testValidationRejectsAProtocolThatDoesNotFitManifestCeiling() throws {
        var benchmark = try fixtureProtocol()
        benchmark.contexts[1].preparedInputTokens += 1

        XCTAssertThrowsError(try benchmark.validate(against: BuiltInModelManifest.regular))
    }

    func testCapabilityAssertionsFailClosedInsteadOfInventingCoverage() throws {
        let benchmark = try fixtureProtocol()
        let failures = LocalAIPerformanceMath.capabilityFailures(
            protocol: benchmark,
            coldSemantics: .unsupported(reason: "requires process isolation"),
            wiredTicket: .unsupported(reason: "not connected")
        )

        XCTAssertEqual(failures.count, 2)
        XCTAssertTrue(failures.contains { $0.contains("cold") })
        XCTAssertTrue(failures.contains { $0.contains("wired") })
    }

    private func fixtureProtocol() throws -> LocalAIPerformanceProtocol {
        let protocolURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals/local-ai-performance-v1.json")
        return try LocalAIPerformanceProtocol.load(from: protocolURL)
    }
}
