import Foundation
import XCTest

final class ReleaseConfigurationTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testApplicationEntitlementsAuthorizeTheDataProtectionKeychain() throws {
        let url = repositoryRoot.appending(path: "ZBSEyeApp/ZBSEye.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(
            plist["keychain-access-groups"] as? [String],
            ["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"]
        )
    }

    func testNotarizedBuildPreservesProvisionedEntitlements() throws {
        let url = repositoryRoot.appending(path: "scripts/build-notarized.sh")
        let script = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(script.contains("CODE_SIGN_STYLE=Automatic"))
        XCTAssertTrue(script.contains("-allowProvisioningUpdates"))
        XCTAssertTrue(script.contains(" archive "))
        XCTAssertTrue(script.contains("-exportArchive"))
        XCTAssertTrue(script.contains("developer-id"))
        XCTAssertTrue(script.contains("--preserve-metadata=entitlements"))
        XCTAssertTrue(script.contains("embedded.provisionprofile"))
    }

    func testSelfSignedBuildPreservesEntitlementsWhenBundlingTheModel() throws {
        let url = repositoryRoot.appending(path: "scripts/build-release.sh")
        let script = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(script.contains("--preserve-metadata=entitlements,requirements"))
    }
}
