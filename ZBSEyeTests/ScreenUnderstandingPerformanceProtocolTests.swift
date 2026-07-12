import XCTest

final class ScreenUnderstandingPerformanceProtocolTests: XCTestCase {
    func testLockedProtocolUsesRequiredOfflineSampling() throws {
        let benchmark = ScreenUnderstandingPerformanceProtocol.locked
        XCTAssertNoThrow(try benchmark.validate())
        XCTAssertTrue(benchmark.offline)
        XCTAssertTrue(benchmark.serial)
        XCTAssertEqual(benchmark.retryCount, 0)
        XCTAssertEqual(benchmark.coldSamples, 20)
        XCTAssertEqual(benchmark.warmSamples, 30)
        XCTAssertEqual(benchmark.soakSamples, 50)
        XCTAssertEqual(benchmark.counterbalancedBlocks, 3)
        XCTAssertEqual(benchmark.percentileMethod, "nearest-rank")
    }

    func testNearestRankAndCounterbalanceAreDeterministic() {
        XCTAssertEqual(
            ScreenUnderstandingPerformanceMath.nearestRank(
                Array(1...20).map(Double.init),
                percentile: 0.95
            ),
            19
        )
        XCTAssertEqual(
            ScreenUnderstandingPerformanceMath.counterbalanced(
                methods: ["a", "b", "c"],
                blocks: 3
            ),
            [["a", "b", "c"], ["b", "c", "a"], ["c", "a", "b"]]
        )
    }

    func testUnsafeOrUnderpoweredProtocolIsRejected() {
        var benchmark = ScreenUnderstandingPerformanceProtocol.locked
        benchmark.retryCount = 1
        XCTAssertThrowsError(try benchmark.validate())
        benchmark = .locked
        benchmark.coldSamples = 19
        XCTAssertThrowsError(try benchmark.validate())
    }

    func testFootprintCannotInheritCanonicalQuality() {
        let missingRuntimeQuality = ScreenUnderstandingRuntimeQualification(
            exactRuntimeQualityScored: false,
            canonicalUsefulness: 0.80,
            runtimeUsefulness: 0.80,
            canonicalCriticalTextRecall: 0.90,
            runtimeCriticalTextRecall: 0.90,
            canonicalHallucination: 1,
            runtimeHallucination: 1
        )
        XCTAssertFalse(missingRuntimeQuality.qualifies)

        let degraded = ScreenUnderstandingRuntimeQualification(
            exactRuntimeQualityScored: true,
            canonicalUsefulness: 0.80,
            runtimeUsefulness: 0.77,
            canonicalCriticalTextRecall: 0.90,
            runtimeCriticalTextRecall: 0.90,
            canonicalHallucination: 1,
            runtimeHallucination: 1
        )
        XCTAssertFalse(degraded.qualifies)
    }
}
