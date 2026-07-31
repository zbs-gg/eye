import Foundation
import XCTest

final class CaptureCoexistenceProtocolTests: XCTestCase {
    func testAutomatedBracketIsFixedAndBounded() throws {
        let script = try contents("scripts/verify-capture-coexistence.sh")

        XCTAssertTrue(script.contains("WARMUP_COUNT=5"))
        XCTAssertTrue(script.contains("MEASURED_COUNT=40"))
        XCTAssertTrue(script.contains("P95_DELTA_LIMIT_MS=200"))
        XCTAssertTrue(script.contains("ATTEMPT_LIMIT_MS=1000"))
        XCTAssertTrue(script.contains(
            "PHASES=(baseline-a eye baseline-b codex baseline-c eye-codex baseline-d)"
        ))
        XCTAssertTrue(script.contains("/usr/sbin/screencapture -x -t png"))
        XCTAssertTrue(script.contains("/usr/bin/sips -g pixelWidth -g pixelHeight"))
        XCTAssertTrue(script.contains("count * 50 + 99"))
        XCTAssertTrue(script.contains("count * 95 + 99"))
        XCTAssertTrue(script.contains("classify_summary"))
        for result in ["pass", "Eye no-go", "upstream-blocked", "invalid"] {
            XCTAssertTrue(script.contains(result), "missing result: \(result)")
        }
    }

    func testProtocolCannotMutateGlobalCaptureOrApplicationState() throws {
        let script = try contents("scripts/verify-capture-coexistence.sh")
        let forbidden = [
            "killall ", "pkill ", "launchctl ", "tccutil ",
            "SIGKILL", "SIGTERM", "replayd", "open -a", "osascript",
        ]
        for token in forbidden {
            XCTAssertFalse(script.contains(token), "forbidden token: \(token)")
        }
        XCTAssertTrue(script.contains("validate_phase_state"))
        XCTAssertTrue(script.contains("No app will be launched or quit by this script."))
    }

    func testEvidenceIsPrivateAndEveryScreenshotIsDisposable() throws {
        let script = try contents("scripts/verify-capture-coexistence.sh")

        XCTAssertTrue(script.contains("ZBS Eye Qualification/capture-coexistence"))
        XCTAssertTrue(script.contains("chmod 700 \"$SESSION\""))
        XCTAssertTrue(script.contains("umask 077"))
        XCTAssertTrue(script.contains(".capture-current.png"))
        XCTAssertTrue(script.contains("/bin/rm -f \"$ACTIVE_SHOT\""))
        XCTAssertTrue(script.contains("evidence root must stay outside the repository"))
        XCTAssertFalse(script.contains("database.sqlite"))
        XCTAssertFalse(script.contains("api-token"))
    }

    func testSyntheticProtocolSelfTestCoversEveryClassification() throws {
        let root = repositoryRoot
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            root.appending(path: "scripts/verify-capture-coexistence.sh").path,
            "--self-test",
        ]
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("capture coexistence protocol self-test: ok"))
    }

    func testManualProtocolLocksPromptsHotkeysRecoveryAndSoak() throws {
        let document = try contents("docs/CAPTURE_COEXISTENCE.md")

        XCTAssertTrue(document.contains("Shift-Command-3 ten times"))
        XCTAssertTrue(document.contains("Shift-Command-4 ten times"))
        XCTAssertTrue(document.contains("Shift-Command-5 ten times"))
        XCTAssertTrue(document.contains("Expected: Eye `0`, Codex `0`"))
        XCTAssertTrue(document.contains("run it **last**"))
        XCTAssertTrue(document.contains("`+5 minutes`, `+1 hour`, `+4 hours`, and"))
        XCTAssertTrue(document.contains("`+24 hours`"))
        XCTAssertTrue(document.contains("more than one automatic recovery per hour"))
        XCTAssertTrue(document.contains("no screenshots, captured text, audio, database rows"))
        XCTAssertTrue(document.contains("picker-versus-persistent-stream comparison is research"))
        XCTAssertTrue(document.contains("Do not change the shipping capture path"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appending(path: relativePath),
            encoding: .utf8
        )
    }
}
