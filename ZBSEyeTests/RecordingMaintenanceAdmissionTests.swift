import XCTest

final class RecordingMaintenanceAdmissionTests: XCTestCase {
    func testMaintenanceSuspensionRefusesRestartUntilExplicitResume() {
        var admission = RecordingMaintenanceAdmission()
        XCTAssertTrue(admission.permitsStart)

        admission.suspend()
        XCTAssertFalse(admission.permitsStart)

        admission.resume()
        XCTAssertTrue(admission.permitsStart)
    }
}
