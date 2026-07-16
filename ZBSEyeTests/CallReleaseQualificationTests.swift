import Foundation
import XCTest

final class CallReleaseQualificationTests: XCTestCase {
    @MainActor
    func testFreshInstallUsesFiveGiBWhileForeverRemainsExplicitlyAvailable() {
        let suite = "CallReleaseQualificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = StorageSettingsStore(defaults: defaults)
        let resolution = store.initializeKeepMediaPolicy(inventory: .positivelyEmpty)

        XCTAssertEqual(resolution.policy, .fiveGB)
        XCTAssertEqual(store.keepMediaPolicy, .fiveGB)
        XCTAssertEqual(
            KeepMediaPolicy.fiveGB.maxCapturedMediaBytes,
            5 * KeepMediaPolicy.bytesPerGB
        )
        XCTAssertTrue(KeepMediaPolicy.allCases.contains(.forever))
        XCTAssertNil(KeepMediaPolicy.forever.maxCapturedMediaBytes)
    }
}
