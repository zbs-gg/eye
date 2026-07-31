import XCTest

final class RecordingMaintenanceAdmissionTests: XCTestCase {
    func testOverlappingOwnersCannotResumeRecordingEarly() {
        var admission = RecordingMaintenanceAdmission()
        XCTAssertTrue(admission.permitsStart)

        let relocation = admission.acquire(.relocation)
        let repair = admission.acquire(.repair)
        XCTAssertFalse(admission.permitsStart)
        XCTAssertEqual(Set(admission.activeOwners), [.relocation, .repair])

        XCTAssertTrue(admission.release(repair))
        XCTAssertFalse(admission.permitsStart)
        XCTAssertEqual(Set(admission.activeOwners), [.relocation])

        XCTAssertTrue(admission.release(relocation))
        XCTAssertTrue(admission.permitsStart)
    }

    func testDuplicateOwnerLeasesAreReferenceCountedAndReleaseIsIdempotent() {
        var admission = RecordingMaintenanceAdmission()
        let first = admission.acquire(.termination)
        let second = admission.acquire(.termination)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(admission.activeLeaseCount, 2)
        XCTAssertTrue(admission.release(first))
        XCTAssertFalse(admission.release(first))
        XCTAssertFalse(admission.permitsStart)
        XCTAssertEqual(admission.activeLeaseCount, 1)

        XCTAssertTrue(admission.release(second))
        XCTAssertTrue(admission.permitsStart)
    }

    func testForeignLeaseCannotReleaseAnotherAdmission() {
        var firstAdmission = RecordingMaintenanceAdmission()
        var secondAdmission = RecordingMaintenanceAdmission()
        let first = firstAdmission.acquire(.lowDisk)
        let foreign = secondAdmission.acquire(.lowDisk)

        XCTAssertFalse(firstAdmission.release(foreign))
        XCTAssertFalse(firstAdmission.permitsStart)
        XCTAssertTrue(firstAdmission.release(first))
    }
}
