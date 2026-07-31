import Foundation
import XCTest

final class ReleaseConfigurationTests: XCTestCase {
    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private final class ReleaseFixture {
        let root: URL
        let remote: URL
        let worktree: URL
        let script: URL

        init(root: URL, remote: URL, worktree: URL, script: URL) {
            self.root = root
            self.remote = remote
            self.worktree = worktree
            self.script = script
        }

        func runPreflight(
            expectedVersion: String = "0.4.5",
            expectedBuild: String = "10",
            remoteOverride: URL? = nil,
            verifyOnly: Bool = false
        ) throws -> CommandResult {
            try Self.run(
                "/bin/bash",
                [script.path] + (verifyOnly ? ["--verify-only"] : []) + ["--fixture", worktree.path],
                environment: [
                    "ZBSEYE_RELEASE_PREFLIGHT_FIXTURE": "1",
                    "ZBSEYE_RELEASE_PREFLIGHT_FIXTURE_REMOTE": (remoteOverride ?? remote).path,
                    "ZBSEYE_PREFLIGHT_EXPECT_VERSION": expectedVersion,
                    "ZBSEYE_PREFLIGHT_EXPECT_BUILD": expectedBuild,
                ]
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func git(_ arguments: String...) throws -> CommandResult {
            try Self.runChecked("/usr/bin/git", arguments, directory: worktree)
        }

        func setCandidate(
            appVersion: String,
            appBuild: String,
            testVersion: String? = nil,
            testBuild: String? = nil
        ) throws {
            try Self.writeProject(
                to: worktree,
                appVersion: appVersion,
                appBuild: appBuild,
                testVersion: testVersion ?? appVersion,
                testBuild: testBuild ?? appBuild
            )
            _ = try git("add", "project.yml")
            _ = try git("commit", "-m", "candidate \(appVersion) (\(appBuild))")
            _ = try Self.runChecked("/usr/bin/git", ["push", remote.path, "HEAD:main"], directory: worktree)
        }

        func advanceRemote() throws {
            let updater = root.appending(path: "updater-\(UUID().uuidString)")
            _ = try Self.runChecked("/usr/bin/git", ["clone", remote.path, updater.path])
            try "remote advanced\n".write(
                to: updater.appending(path: "remote.txt"),
                atomically: true,
                encoding: .utf8
            )
            _ = try Self.runChecked("/usr/bin/git", ["config", "user.name", "Release Fixture"], directory: updater)
            _ = try Self.runChecked("/usr/bin/git", ["config", "user.email", "fixture@example.invalid"], directory: updater)
            _ = try Self.runChecked("/usr/bin/git", ["add", "remote.txt"], directory: updater)
            _ = try Self.runChecked("/usr/bin/git", ["commit", "-m", "advance remote"], directory: updater)
            _ = try Self.runChecked("/usr/bin/git", ["push", "origin", "main"], directory: updater)
        }

        static func make(script: URL, includeBaseline: Bool = true) throws -> ReleaseFixture {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "zbseye-release-preflight-\(UUID().uuidString)")
            let remote = root.appending(path: "remote.git")
            let seed = root.appending(path: "seed")
            let worktree = root.appending(path: "candidate")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            _ = try runChecked("/usr/bin/git", ["init", "--bare", "--initial-branch=main", remote.path])
            _ = try runChecked("/usr/bin/git", ["init", "--initial-branch=main", seed.path])
            _ = try runChecked("/usr/bin/git", ["config", "user.name", "Release Fixture"], directory: seed)
            _ = try runChecked("/usr/bin/git", ["config", "user.email", "fixture@example.invalid"], directory: seed)
            try writeProject(to: seed, appVersion: "0.4.2", appBuild: "7", testVersion: "0.4.2", testBuild: "7")
            try "baseline\n".write(to: seed.appending(path: "README.md"), atomically: true, encoding: .utf8)
            _ = try runChecked("/usr/bin/git", ["add", "."], directory: seed)
            _ = try runChecked("/usr/bin/git", ["commit", "-m", "baseline"], directory: seed)
            if includeBaseline {
                _ = try runChecked("/usr/bin/git", ["tag", "v0.4.2"], directory: seed)
            }
            _ = try runChecked("/usr/bin/git", ["remote", "add", "origin", remote.path], directory: seed)
            _ = try runChecked("/usr/bin/git", ["push", "origin", "main", "--tags"], directory: seed)

            _ = try runChecked("/usr/bin/git", ["clone", remote.path, worktree.path])
            _ = try runChecked("/usr/bin/git", ["config", "user.name", "Release Fixture"], directory: worktree)
            _ = try runChecked("/usr/bin/git", ["config", "user.email", "fixture@example.invalid"], directory: worktree)
            _ = try runChecked(
                "/usr/bin/git",
                ["remote", "set-url", "origin", "git@github.com:zbs-gg/eye.git"],
                directory: worktree
            )

            let fixture = ReleaseFixture(root: root, remote: remote, worktree: worktree, script: script)
            try fixture.setCandidate(appVersion: "0.4.5", appBuild: "10")
            return fixture
        }

        private static func writeProject(
            to repository: URL,
            appVersion: String,
            appBuild: String,
            testVersion: String,
            testBuild: String
        ) throws {
            let project = """
            targets:
              ZBSEye:
                settings:
                  base:
                    MARKETING_VERSION: "\(appVersion)"
                    CURRENT_PROJECT_VERSION: "\(appBuild)"
              ZBSEyeTests:
                settings:
                  base:
                    MARKETING_VERSION: "\(testVersion)"
                    CURRENT_PROJECT_VERSION: "\(testBuild)"
            """
            try project.write(
                to: repository.appending(path: "project.yml"),
                atomically: true,
                encoding: .utf8
            )
        }

        @discardableResult
        static func run(
            _ executable: String,
            _ arguments: [String],
            directory: URL? = nil,
            environment: [String: String] = [:]
        ) throws -> CommandResult {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }

        @discardableResult
        static func runChecked(
            _ executable: String,
            _ arguments: [String],
            directory: URL? = nil,
            environment: [String: String] = [:]
        ) throws -> CommandResult {
            let result = try run(executable, arguments, directory: directory, environment: environment)
            guard result.status == 0 else {
                throw NSError(
                    domain: "ZBSEye.ReleaseFixture",
                    code: Int(result.status),
                    userInfo: [NSLocalizedDescriptionKey: result.output]
                )
            }
            return result
        }
    }

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

    func testReleaseBuildsRepairOnlyThePinnedTranscribeFrameworkBeforeCompilation() throws {
        let notarized = try String(
            contentsOf: repositoryRoot.appending(path: "scripts/build-notarized.sh"),
            encoding: .utf8
        )
        let local = try String(
            contentsOf: repositoryRoot.appending(path: "scripts/build-release.sh"),
            encoding: .utf8
        )
        let repair = try String(
            contentsOf: repositoryRoot.appending(path: "scripts/repair-transcribe-framework.sh"),
            encoding: .utf8
        )

        for script in [notarized, local] {
            XCTAssertTrue(script.contains("-resolvePackageDependencies"))
            XCTAssertTrue(script.contains("scripts/repair-transcribe-framework.sh"))
            XCTAssertLessThan(
                try XCTUnwrap(script.range(of: "scripts/repair-transcribe-framework.sh")?.lowerBound),
                try XCTUnwrap(script.range(of: "xcodebuild archive")?.lowerBound
                    ?? script.range(of: "xcodebuild -project")?.lowerBound)
            )
        }
        XCTAssertTrue(repair.contains("9bb4ece5101e4efab3bc584e95a744c7c3ecc80295c463372b43b6d2232af8d5"))
        XCTAssertTrue(repair.contains("diff -qr \"${CURRENT}\" \"${CANONICAL}\""))
        XCTAssertTrue(repair.contains("ln -s A \"${CURRENT}\""))
        XCTAssertTrue(repair.contains("codesign --verify --strict \"${FRAMEWORK}\""))
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
        XCTAssertTrue(script.contains("XCODE_XCCONFIG_FILE"))
        XCTAssertTrue(script.contains("ZBSEYE_RELEASE_PREFLIGHT_IDENTITY"))
        XCTAssertTrue(script.contains("Exported app identity"))
        XCTAssertTrue(script.contains("scripts/release-preflight.sh --verify-only"))
        XCTAssertTrue(script.contains("FINAL_PREFLIGHT_OUTPUT"))
        XCTAssertTrue(script.contains("FINAL_QUALIFIED_IDENTITY"))
        XCTAssertTrue(script.contains("Release identity changed during the qualified build"))
        XCTAssertTrue(script.contains("scripts/validate-notary-evidence.sh"))
        XCTAssertLessThan(
            try XCTUnwrap(script.range(of: "scripts/release-preflight.sh --verify-only")?.lowerBound),
            try XCTUnwrap(script.range(of: "xcrun notarytool submit")?.lowerBound)
        )
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
        XCTAssertTrue(script.contains("notaryStatus"))
        XCTAssertTrue(script.contains("notarySubmissionID"))
        XCTAssertTrue(script.contains("notaryLogSHA256"))
        XCTAssertTrue(script.contains("--output-format json"))
        XCTAssertTrue(script.contains("xcrun notarytool log"))
        XCTAssertTrue(script.contains("chmod 700"))
        XCTAssertTrue(script.contains("chmod 600"))
        XCTAssertTrue(script.contains("scripts/release-preflight.sh"))
        XCTAssertLessThan(
            try XCTUnwrap(script.range(of: "scripts/release-preflight.sh")?.lowerBound),
            try XCTUnwrap(script.range(of: "xcodegen generate")?.lowerBound)
        )
    }

    func testReleaseCandidateHasANewVersionAndBuildIdentity() throws {
        let url = repositoryRoot.appending(path: "project.yml")
        let project = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(project.components(separatedBy: "MARKETING_VERSION:").count - 1, 2)
        XCTAssertEqual(project.components(separatedBy: "MARKETING_VERSION: \"0.7.0\"").count - 1, 2)
        XCTAssertEqual(project.components(separatedBy: "CURRENT_PROJECT_VERSION:").count - 1, 2)
        XCTAssertEqual(project.components(separatedBy: "CURRENT_PROJECT_VERSION: \"20\"").count - 1, 2)
    }

    func testReleaseDocumentationRequiresAnExactManifestBoundArtifactPair() throws {
        let readme = try String(
            contentsOf: repositoryRoot.appending(path: "README.md"),
            encoding: .utf8
        )
        let notarize = try String(
            contentsOf: repositoryRoot.appending(path: "docs/NOTARIZE.md"),
            encoding: .utf8
        )

        XCTAssertFalse(readme.contains("ZBSEye-notarized-*.zip"))
        XCTAssertFalse(notarize.contains("ZBSEye-notarized-*.zip"))
        XCTAssertTrue(readme.contains("matching `.manifest.json` path printed by the script"))
        XCTAssertTrue(readme.contains("release asset by wildcard"))
        XCTAssertTrue(readme.contains("scripts/verify-release-artifact.sh"))
        XCTAssertTrue(notarize.contains("final two `✅` lines print the exact release paths"))
        XCTAssertTrue(notarize.contains("Attach exactly `$ZIP` and `$MANIFEST`"))
        XCTAssertTrue(notarize.contains("scripts/verify-release-artifact.sh"))
        XCTAssertTrue(notarize.contains("$DOWNLOADED_MANIFEST\" \"$QUALIFIED_MANIFEST"))
    }

    func testReleaseArtifactVerifierPinsTheIndependentPublisherIdentity() throws {
        let url = repositoryRoot.appending(path: "scripts/verify-release-artifact.sh")
        let script = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(script.contains("EXPECTED_TEAM=\"44N4NZ86S5\""))
        XCTAssertTrue(script.contains("EXPECTED_BUNDLE_ID=\"gg.zbs.eye\""))
        XCTAssertTrue(script.contains("cmp -s"))
        XCTAssertTrue(script.contains("codesign --verify --strict"))
        XCTAssertTrue(script.contains("TeamIdentifier=${EXPECTED_TEAM}"))
        XCTAssertTrue(script.contains("CDHash="))
        XCTAssertTrue(script.contains("codesign -d -r-"))
        XCTAssertTrue(script.contains("xcrun stapler validate"))
        XCTAssertTrue(script.contains("spctl -a -vvv -t exec"))
        XCTAssertTrue(script.contains("/usr/bin/unzip -Z1"))
        XCTAssertTrue(script.contains("unexpected archive entry outside ZBS Eye.app"))
        XCTAssertTrue(script.contains("[ ! -L \"${APP}\" ]"))
    }

    func testReleaseArtifactVerifierRejectsExtraArchiveEntriesBeforeExtraction() throws {
        let directory = try makeTemporaryDirectory(prefix: "zbseye-release-extra-entry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appending(path: "ZBS Eye.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "placeholder".write(to: app.appending(path: "placeholder.txt"), atomically: true, encoding: .utf8)
        try "unexpected".write(
            to: directory.appending(path: "extra.txt"),
            atomically: true,
            encoding: .utf8
        )
        let zip = directory.appending(path: "candidate.zip")
        _ = try ReleaseFixture.runChecked(
            "/usr/bin/zip",
            ["-qry", zip.path, "ZBS Eye.app", "extra.txt"],
            directory: directory
        )
        let hashResult = try ReleaseFixture.runChecked("/usr/bin/shasum", ["-a", "256", zip.path])
        let zipHash = try XCTUnwrap(hashResult.output.split(separator: " ").first.map(String.init))
        let manifest: [String: Any] = [
            "artifact": zip.lastPathComponent,
            "version": "0.4.3",
            "build": "8",
            "sourceRevision": String(repeating: "a", count: 40),
            "teamIdentifier": "44N4NZ86S5",
            "cdHash": "candidate-cdhash",
            "designatedRequirement": #"identifier "gg.zbs.eye""#,
            "zipSHA256": zipHash,
            "executableSHA256": String(repeating: "b", count: 64),
            "notaryStatus": "Accepted",
            "notarySubmissionID": "submission-123",
            "notaryLogSHA256": String(repeating: "c", count: 64),
        ]
        let manifestURL = directory.appending(path: "candidate.manifest.json")
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        let result = try ReleaseFixture.run(
            "/bin/bash",
            [repositoryRoot.appending(path: "scripts/verify-release-artifact.sh").path, zip.path, manifestURL.path]
        )

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("unexpected archive entry"), result.output)
    }

    func testNotaryEvidenceValidatorAcceptsOnlyCompleteAcceptedEvidence() throws {
        for issues in ["null", "[]"] {
            let directory = try makeTemporaryDirectory(prefix: "zbseye-notary-valid")
            defer { try? FileManager.default.removeItem(at: directory) }
            let submission = directory.appending(path: "submission.json")
            let log = directory.appending(path: "log.json")
            try #"{"status":"Accepted","id":"submission-123"}"#.write(
                to: submission,
                atomically: true,
                encoding: .utf8
            )
            try "{\"jobId\":\"SUBMISSION-123\",\"status\":\"Accepted\",\"issues\":\(issues)}".write(
                to: log,
                atomically: true,
                encoding: .utf8
            )

            let result = try runNotaryEvidenceValidator(submission: submission, log: log)

            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.hasPrefix("Accepted\tsubmission-123\t"), result.output)
            let fields = result.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t")
            XCTAssertEqual(fields.count, 3, result.output)
            XCTAssertTrue(fields.last?.allSatisfy(\.isHexDigit) == true, result.output)
            XCTAssertEqual(fields.last?.count, 64, result.output)
        }
    }

    func testNotaryEvidenceValidatorFailsClosedOnRejectedOrMalformedEvidence() throws {
        let cases: [(String, String, String)] = [
            (#"{"status":"Rejected","id":"submission-123"}"#, #"{"jobId":"submission-123","status":"Accepted","issues":[]}"#, "submission status"),
            (#"{"status":"Accepted"}"#, #"{"jobId":"submission-123","status":"Accepted","issues":[]}"#, "string ID"),
            (#"{"status":"Accepted","id":"submission-123"}"#, "", "missing or empty"),
            (#"{"status":"Accepted","id":"submission-123"}"#, "not-json", "string status"),
            (#"{"status":"Accepted","id":"submission-123"}"#, #"{"jobId":"submission-123","status":"Rejected","issues":[]}"#, "log status"),
            (#"{"status":"Accepted","id":"submission-123"}"#, #"{"jobId":"different-submission","status":"Accepted","issues":[]}"#, "does not match"),
            (#"{"status":"Accepted","id":"submission-123"}"#, #"{"status":"Accepted","issues":[]}"#, "string jobId"),
            (#"{"status":"Accepted","id":"submission-123"}"#, #"{"jobId":"submission-123","status":"Accepted"}"#, "null or an array"),
            (#"{"status":"Accepted","id":"submission-123"}"#, #"{"jobId":"submission-123","status":"Accepted","issues":{}}"#, "null or an array"),
            (#"{"status":"Accepted","id":"submission-123"}"#, #"{"jobId":"submission-123","status":"Accepted","issues":[{"severity":"error"}]}"#, "error issue"),
        ]

        for (submissionJSON, logJSON, expectedMessage) in cases {
            let directory = try makeTemporaryDirectory(prefix: "zbseye-notary-invalid")
            defer { try? FileManager.default.removeItem(at: directory) }
            let submission = directory.appending(path: "submission.json")
            let log = directory.appending(path: "log.json")
            try submissionJSON.write(to: submission, atomically: true, encoding: .utf8)
            try logJSON.write(to: log, atomically: true, encoding: .utf8)

            let result = try runNotaryEvidenceValidator(submission: submission, log: log)

            XCTAssertNotEqual(result.status, 0, "case unexpectedly passed: \(submissionJSON) / \(logJSON)")
            XCTAssertTrue(result.output.contains(expectedMessage), result.output)
        }
    }

    func testReleasePreflightAcceptsOnlyAnExactCleanFreshMainCandidate() throws {
        let fixture = try ReleaseFixture.make(script: releasePreflightScript)
        let result = try fixture.runPreflight()

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("release preflight passed"), result.output)
        XCTAssertTrue(result.output.contains("ZBSEYE_RELEASE_PREFLIGHT_IDENTITY=0.4.5:10:"), result.output)
    }

    func testReleasePreflightRejectsTrackedStagedAndUntrackedChanges() throws {
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            try "dirty\n".append(to: fixture.worktree.appending(path: "README.md"))
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("dirty worktree"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            try "staged\n".write(to: fixture.worktree.appending(path: "staged.txt"), atomically: true, encoding: .utf8)
            _ = try fixture.git("add", "staged.txt")
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("dirty worktree"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            try "untracked\n".write(to: fixture.worktree.appending(path: "untracked.txt"), atomically: true, encoding: .utf8)
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("dirty worktree"), result.output)
        }
    }

    func testReleasePreflightRejectsHiddenTrackedAndIgnoredBuildInputs() throws {
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            _ = try fixture.git("update-index", "--assume-unchanged", "README.md")
            try "hidden change\n".append(to: fixture.worktree.appending(path: "README.md"))

            let result = try fixture.runPreflight()

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("assume-unchanged or skip-worktree"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            _ = try fixture.git("update-index", "--skip-worktree", "README.md")
            try "hidden change\n".append(to: fixture.worktree.appending(path: "README.md"))

            let result = try fixture.runPreflight()

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("assume-unchanged or skip-worktree"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            try "workspace/\n".write(
                to: fixture.worktree.appending(path: ".gitignore"),
                atomically: true,
                encoding: .utf8
            )
            _ = try fixture.git("add", ".gitignore")
            _ = try fixture.git("commit", "-m", "add source ignore rule")
            _ = try ReleaseFixture.runChecked(
                "/usr/bin/git",
                ["push", fixture.remote.path, "HEAD:main"],
                directory: fixture.worktree
            )
            let ignoredDirectory = fixture.worktree.appending(path: "ZBSEyeApp/workspace")
            try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: true)
            try "struct HiddenReleaseInput {}\n".write(
                to: ignoredDirectory.appending(path: "Evil.swift"),
                atomically: true,
                encoding: .utf8
            )

            let result = try fixture.runPreflight()

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("ignored files exist inside shipping source roots"), result.output)
        }
    }

    func testReleasePreflightFailsClosedOnRemoteAndFetchAmbiguity() throws {
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            _ = try fixture.git("remote", "remove", "origin")
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("origin"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            _ = try fixture.git("remote", "set-url", "origin", "git@github.com:someone/else.git")
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("canonical"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            let hostile = "file://\(fixture.root.appending(path: "hostile.git").path)"
            _ = try fixture.git(
                "config",
                "url.\(hostile).insteadOf",
                "git@github.com:zbs-gg/eye.git"
            )
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("effective origin"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            _ = try fixture.git(
                "remote",
                "set-url",
                "origin",
                "https://x-access-token:sentinel-secret@github.com/zbs-gg/eye.git"
            )
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertFalse(result.output.contains("sentinel-secret"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            let missingRemote = fixture.root.appending(path: "missing.git")
            let result = try fixture.runPreflight(remoteOverride: missingRemote)
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("fetch"), result.output)
        }
    }

    func testReleasePreflightRefreshesStaleTrackingStateAndRejectsBehindAheadAndDivergentCandidates() throws {
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            try fixture.advanceRemote()
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("behind"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            try "ahead\n".write(to: fixture.worktree.appending(path: "ahead.txt"), atomically: true, encoding: .utf8)
            _ = try fixture.git("add", "ahead.txt")
            _ = try fixture.git("commit", "-m", "ahead")
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("ahead"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            try "local\n".write(to: fixture.worktree.appending(path: "local.txt"), atomically: true, encoding: .utf8)
            _ = try fixture.git("add", "local.txt")
            _ = try fixture.git("commit", "-m", "local")
            try fixture.advanceRemote()
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("divergent"), result.output)
        }
    }

    func testReleasePreflightRejectsMissingBaselineAndExistingCandidateTag() throws {
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript, includeBaseline: false)
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("release baseline"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            _ = try fixture.git("tag", "v0.4.5")
            _ = try ReleaseFixture.runChecked(
                "/usr/bin/git",
                ["push", fixture.remote.path, "v0.4.5"],
                directory: fixture.worktree
            )
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("already exists"), result.output)
        }
    }

    func testReleasePreflightVerifyOnlyStillRejectsAnExistingCandidateTag() throws {
        let fixture = try ReleaseFixture.make(script: releasePreflightScript)
        _ = try fixture.git("tag", "v0.4.5")
        _ = try ReleaseFixture.runChecked(
            "/usr/bin/git",
            ["push", fixture.remote.path, "v0.4.5"],
            directory: fixture.worktree
        )

        let result = try fixture.runPreflight(verifyOnly: true)

        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("already exists"), result.output)
    }

    func testReleaseFixtureCheckedRunnerRejectsGitSetupFailures() {
        XCTAssertThrowsError(
            try ReleaseFixture.runChecked("/usr/bin/git", ["not-a-real-git-command"])
        )
    }

    func testReleasePreflightRejectsRegressedIdentityAndTargetDisagreement() throws {
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            try fixture.setCandidate(appVersion: "0.4.2", appBuild: "8")
            let result = try fixture.runPreflight(expectedVersion: "0.4.2", expectedBuild: "8")
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("already exists"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            try fixture.setCandidate(appVersion: "0.4.1", appBuild: "8")
            let result = try fixture.runPreflight(expectedVersion: "0.4.1", expectedBuild: "8")
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("newer than"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            try fixture.setCandidate(appVersion: "0.4.3", appBuild: "7")
            let result = try fixture.runPreflight(expectedVersion: "0.4.3", expectedBuild: "7")
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("build"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            try fixture.setCandidate(appVersion: "0.4.3", appBuild: "6")
            let result = try fixture.runPreflight(expectedVersion: "0.4.3", expectedBuild: "6")
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("build"), result.output)
        }
        do {
            let fixture = try ReleaseFixture.make(script: releasePreflightScript)
            try fixture.setCandidate(appVersion: "0.4.3", appBuild: "8", testBuild: "9")
            let result = try fixture.runPreflight()
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("disagree"), result.output)
        }
    }

    func testReleasePreflightIgnoresPrereleaseAndNonreleaseVPrefixedTags() throws {
        let fixture = try ReleaseFixture.make(script: releasePreflightScript)
        _ = try fixture.git("tag", "v999.0.0-beta")
        _ = try fixture.git("tag", "version-not-a-release")
        _ = try ReleaseFixture.runChecked(
            "/usr/bin/git",
            ["push", fixture.remote.path, "--tags"],
            directory: fixture.worktree
        )

        let result = try fixture.runPreflight()
        XCTAssertEqual(result.status, 0, result.output)
    }

    private var releasePreflightScript: URL {
        repositoryRoot.appending(path: "scripts/release-preflight.sh")
    }

    private func runNotaryEvidenceValidator(submission: URL, log: URL) throws -> CommandResult {
        try ReleaseFixture.run(
            "/bin/bash",
            [repositoryRoot.appending(path: "scripts/validate-notary-evidence.sh").path, submission.path, log.path]
        )
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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

private extension String {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }
}
