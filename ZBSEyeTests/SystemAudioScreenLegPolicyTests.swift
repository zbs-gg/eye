import CoreMedia
import ScreenCaptureKit
import XCTest

final class SystemAudioScreenLegPolicyTests: XCTestCase {
    func testAudioOnlyStreamKeepsItsVideoLegNearlyIdle() {
        let configuration = SCStreamConfiguration()

        SystemAudioScreenLegPolicy.apply(to: configuration)

        XCTAssertEqual(configuration.width, 2)
        XCTAssertEqual(configuration.height, 2)
        XCTAssertEqual(configuration.queueDepth, 1)
        XCTAssertEqual(configuration.minimumFrameInterval, CMTime(value: 60, timescale: 1))
        XCTAssertFalse(configuration.showsCursor)
    }
}
