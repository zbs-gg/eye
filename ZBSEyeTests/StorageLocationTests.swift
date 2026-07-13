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

    func testHeadlessResolutionNeverFallsBackWhenConfiguredRootIsMissing() throws {
        let name = "StorageLocationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let missing = "/Volumes/Missing-\(UUID().uuidString)/ZBS Eye"
        let survivingLegacy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: survivingLegacy,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: survivingLegacy) }
        defaults.set(missing, forKey: StorageLocation.pathKey)

        XCTAssertThrowsError(
            try StorageLocation.resolveHeadlessRoot(
                defaults: defaults,
                legacy: survivingLegacy
            )
        ) { error in
            XCTAssertEqual(
                error as? StorageLocationError,
                .configuredRootUnavailable(missing)
            )
        }
    }
}
