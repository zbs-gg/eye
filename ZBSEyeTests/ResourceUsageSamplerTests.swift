import XCTest

final class ResourceUsageSamplerTests: XCTestCase {
    func testCPUUsesProcessTimeDeltaOverWallTime() {
        let previous = ResourceUsageRawSample(
            processTimeSeconds: 10,
            monotonicSeconds: 100,
            physicalFootprintBytes: 512
        )
        let current = ResourceUsageRawSample(
            processTimeSeconds: 10.25,
            monotonicSeconds: 100.5,
            physicalFootprintBytes: 768
        )

        let usage = ResourceUsageSampler.measure(previous: previous, current: current)

        XCTAssertEqual(try XCTUnwrap(usage.cpuPercent), 50, accuracy: 0.001)
        XCTAssertEqual(usage.physicalFootprintBytes, 768)
    }

    func testInvalidOrReversedDeltasFailClosedWithoutInventingCPU() {
        let previous = ResourceUsageRawSample(
            processTimeSeconds: 10,
            monotonicSeconds: 100,
            physicalFootprintBytes: nil
        )
        let current = ResourceUsageRawSample(
            processTimeSeconds: 9,
            monotonicSeconds: 100,
            physicalFootprintBytes: nil
        )

        let usage = ResourceUsageSampler.measure(previous: previous, current: current)

        XCTAssertNil(usage.cpuPercent)
        XCTAssertNil(usage.physicalFootprintBytes)
    }

    @MainActor
    func testStoreCoalescesStartAndStopsOneSamplingLoop() async {
        let sampler = RecordingResourceSampler()
        let store = ResourceUsageStore(
            sampler: sampler,
            interval: .milliseconds(20),
            dataBytes: { 42 }
        )

        store.start()
        store.start()
        try? await Task.sleep(for: .milliseconds(75))
        store.stop()
        let stoppedAt = await sampler.callCount()
        try? await Task.sleep(for: .milliseconds(50))
        let finalCount = await sampler.callCount()

        XCTAssertGreaterThanOrEqual(stoppedAt, 2)
        XCTAssertEqual(finalCount, stoppedAt)
        XCTAssertEqual(store.dataBytes, 42)
    }
}

private actor RecordingResourceSampler: ResourceUsageSampling {
    private var calls = 0

    func sample() -> ResourceUsageRawSample? {
        calls += 1
        return ResourceUsageRawSample(
            processTimeSeconds: Double(calls),
            monotonicSeconds: Double(calls),
            physicalFootprintBytes: Int64(calls)
        )
    }

    func callCount() -> Int { calls }
}
