import XCTest

final class BuiltInModelRuntimeSupportTests: XCTestCase {
    func testOnlyQualifiedPhysicalEnvelopeAdmitsProductManifest() {
        XCTAssertTrue(
            BuiltInModelHardwareSnapshot(
                isAppleSilicon: true,
                unifiedMemoryBytes: 64 * 1_024 * 1_024 * 1_024,
                machineIdentifier: "Mac16,5",
                macOSMajorVersion: 15
            ).supports(.regular)
        )
        XCTAssertFalse(
            BuiltInModelHardwareSnapshot(
                isAppleSilicon: true,
                unifiedMemoryBytes: 64 * 1_024 * 1_024 * 1_024,
                machineIdentifier: "Mac16,6",
                macOSMajorVersion: 15
            ).supports(.regular)
        )
        for unqualifiedMemory in [
            UInt64(64 * 1_024 * 1_024 * 1_024 + 1),
            UInt64(128 * 1_024 * 1_024 * 1_024),
        ] {
            XCTAssertFalse(
                BuiltInModelHardwareSnapshot(
                    isAppleSilicon: true,
                    unifiedMemoryBytes: unqualifiedMemory,
                    machineIdentifier: "Mac16,5",
                    macOSMajorVersion: 15
                ).supports(.regular)
            )
        }
        XCTAssertFalse(
            BuiltInModelHardwareSnapshot(
                isAppleSilicon: true,
                unifiedMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
                machineIdentifier: "Mac16,5",
                macOSMajorVersion: 15
            ).supports(.regular)
        )
        XCTAssertFalse(
            BuiltInModelHardwareSnapshot(
                isAppleSilicon: true,
                unifiedMemoryBytes: 64 * 1_024 * 1_024 * 1_024,
                machineIdentifier: "Mac16,5",
                macOSMajorVersion: 14
            ).supports(.regular)
        )
    }

    func testAssetHostAllowlistPinsManifestAndProductionRedirectAuthorities() {
        XCTAssertEqual(
            BuiltInModelRuntimeSupport.allowedAssetHosts,
            ["huggingface.co", "us.aws.cdn.hf.co"]
        )
    }
}
