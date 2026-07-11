import XCTest

final class StorageLocationTests: XCTestCase {
    func testHeadlessAvailabilityGuardFailsInsteadOfFallingBackToLegacyRoot() {
        XCTAssertThrowsError(
            try StorageLocation.validateConfiguredRootAvailability("/Volumes/Missing/ZBS Eye")
        ) { error in
            XCTAssertEqual(
                error as? StorageLocationError,
                .configuredRootUnavailable("/Volumes/Missing/ZBS Eye")
            )
        }
    }

    func testHeadlessAvailabilityGuardAcceptsAnAvailableConfiguration() {
        XCTAssertNoThrow(try StorageLocation.validateConfiguredRootAvailability(nil))
    }
}
