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

    func testNotarizedBuildFailsClosedOnTheReleaseSigningContract() throws {
        let url = repositoryRoot.appending(path: "scripts/build-notarized.sh")
        let script = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(script.contains("EXPECTED_TEAM=\"44N4NZ86S5\""))
        XCTAssertTrue(script.contains("DEVID_COUNT"))
        XCTAssertTrue(script.contains("-ne 1"))
        XCTAssertTrue(script.contains("Print :com.apple.security.device.audio-input"))
        XCTAssertTrue(script.contains("Print :com.apple.security.get-task-allow"))
        XCTAssertTrue(script.contains("Print :com.apple.security.app-sandbox"))
        XCTAssertTrue(script.contains(#"[[ "${SIGNING_DETAILS}" != *"flags="*"runtime"* ]]"#))
        XCTAssertTrue(script.contains("TeamIdentifier=${EXPECTED_TEAM}"))
        XCTAssertTrue(script.contains("CANDIDATE_REQUIREMENT"))
        XCTAssertTrue(script.contains("INSTALLED_REQUIREMENT"))
    }

    func testNotarizedBuildDoesNotUseQuietGrepPipelinesUnderPipefail() throws {
        let url = repositoryRoot.appending(path: "scripts/build-notarized.sh")
        let script = try String(contentsOf: url, encoding: .utf8)

        XCTAssertFalse(script.contains("echo \"${SIGNING_DETAILS}\" | grep"))
        XCTAssertFalse(script.contains("echo \"${GATEKEEPER_OUTPUT}\" | grep"))
    }

    func testNotarizedBuildEmitsAUniqueExactCandidateManifest() throws {
        let url = repositoryRoot.appending(path: "scripts/build-notarized.sh")
        let script = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(script.contains("git diff --quiet"))
        XCTAssertTrue(script.contains("SOURCE_REVISION=$(git rev-parse --verify HEAD)"))
        XCTAssertTrue(script.contains("ARTIFACT_STEM=\"ZBSEye-${VERSION}-${BUILD_NUMBER}-${SOURCE_SHORT}-notarized\""))
        XCTAssertTrue(script.contains("Refusing to overwrite an existing release artifact"))
        XCTAssertTrue(script.contains("zipSHA256"))
        XCTAssertTrue(script.contains("executableSHA256"))
        XCTAssertTrue(script.contains("sourceRevision"))
        XCTAssertTrue(script.contains("teamIdentifier"))
        XCTAssertTrue(script.contains("cdHash"))
        XCTAssertTrue(script.contains("codesign -dvvv"))
        XCTAssertTrue(script.contains("Could not read the candidate CDHash"))
        XCTAssertTrue(script.contains("designatedRequirement"))
    }

    func testReleaseCandidateHasANewVersionAndBuildIdentity() throws {
        let url = repositoryRoot.appending(path: "project.yml")
        let project = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(project.contains("MARKETING_VERSION: \"0.4.1\""))
        XCTAssertTrue(project.contains("CURRENT_PROJECT_VERSION: \"6\""))
    }

    func testSelfSignedBuildPreservesEntitlementsWhenBundlingTheModel() throws {
        let url = repositoryRoot.appending(path: "scripts/build-release.sh")
        let script = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(script.contains("--preserve-metadata=entitlements,requirements"))
        XCTAssertTrue(script.contains("codesign -d --entitlements"))
        XCTAssertTrue(script.contains("Print :com.apple.security.device.audio-input"))
        XCTAssertTrue(script.contains("Print :keychain-access-groups:0"))
    }

    func testLocalAIVerificationUsesTheUnhostedTestScheme() throws {
        let url = repositoryRoot.appending(path: "scripts/verify-local-ai.sh")
        let script = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(script.contains("-scheme ZBSEyeUnitTests"))
        XCTAssertFalse(script.contains("-scheme ZBSEye -configuration"))
    }

    func testDebugVerificationDoesNotInventAnAdHocAppIdentity() throws {
        let url = repositoryRoot.appending(path: "scripts/verify.sh")
        let script = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(script.contains("CODE_SIGNING_ALLOWED=NO"))
        XCTAssertFalse(script.contains("CODE_SIGN_IDENTITY=-"))
        XCTAssertTrue(script.contains("ZBS Eye executable is missing"))
    }

    func testTinyWorkspaceRetiresTheOldProviderDestinations() {
        let fileManager = FileManager.default

        XCTAssertFalse(fileManager.fileExists(
            atPath: repositoryRoot.appending(path: "ZBSEyeApp/Views/AIModels/AIModelsView.swift").path
        ))
        XCTAssertFalse(fileManager.fileExists(
            atPath: repositoryRoot.appending(path: "ZBSEyeApp/Views/Connections/ConnectionsView.swift").path
        ))
    }

    func testTinyWorkspaceProductStringsHaveRussianLocalization() throws {
        let url = repositoryRoot.appending(path: "ZBSEyeApp/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])

        XCTAssertNil(strings["AI Models"])
        XCTAssertNil(strings["Connections"])

        let requiredKeys = [
            "Timeline",
            "Ask",
            "Permissions",
            "AI",
            "Data Storage",
            "MCP & AI Tools",
            "System Audio",
            "Keep Media",
            "Memory · read only",
            "Off · optional",
            "Capture is paused because disk space is low. Eye will not delete history to self-heal."
        ]

        for key in requiredKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing catalog entry: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let russian = try XCTUnwrap(localizations["ru"] as? [String: Any])
            let unit = try XCTUnwrap(russian["stringUnit"] as? [String: Any])
            XCTAssertEqual(unit["state"] as? String, "translated", "Untranslated key: \(key)")
            XCTAssertFalse((unit["value"] as? String)?.isEmpty ?? true, "Empty Russian value: \(key)")
        }
    }
}
