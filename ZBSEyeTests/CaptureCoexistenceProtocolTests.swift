import Foundation
import XCTest

final class CaptureCoexistenceProtocolTests: XCTestCase {
    func testAutomatedBracketIsFixedAndBounded() throws {
        let script = try contents("scripts/verify-capture-coexistence.sh")

        XCTAssertTrue(script.contains("WARMUP_COUNT=5"))
        XCTAssertTrue(script.contains("MEASURED_COUNT=100"))
        XCTAssertTrue(script.contains("P95_ATTRIBUTABLE_LIMIT_MS=50"))
        XCTAssertTrue(script.contains("ACTIVE_MAX_DELTA_LIMIT_MS=100"))
        XCTAssertTrue(script.contains("BASELINE_P95_DRIFT_LIMIT_MS=50"))
        XCTAssertTrue(script.contains("BASELINE_MAX_DRIFT_LIMIT_MS=100"))
        XCTAssertTrue(script.contains("ABSOLUTE_MAX_LIMIT_MS=500"))
        XCTAssertTrue(script.contains("ATTEMPT_LIMIT_MS=500"))
        XCTAssertTrue(script.contains("RANDOM_DELAY_MIN_MS=100"))
        XCTAssertTrue(script.contains("RANDOM_DELAY_MAX_MS=900"))
        XCTAssertTrue(script.contains(
            "PHASES=(baseline-a eye baseline-b chatgpt-chronicle baseline-c "
                + "eye-chronicle baseline-d eye-chronicle-call baseline-e)"
        ))
        XCTAssertTrue(script.contains("/usr/sbin/screencapture -x -m -t png"))
        XCTAssertTrue(script.contains("/usr/bin/sips -g pixelWidth -g pixelHeight"))
        XCTAssertTrue(script.contains("/usr/bin/sips -s format bmp"))
        XCTAssertTrue(script.contains("attempt\\tdelay_ms\\tlatency_ms\\tstatus"))
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
        XCTAssertTrue(script.contains(".capture-current.bmp"))
        XCTAssertTrue(script.contains("/bin/rm -f \"$ACTIVE_SHOT\""))
        XCTAssertTrue(script.contains("evidence root must stay outside the repository"))
        XCTAssertTrue(script.contains("/bin/rm -f \"$scratch\""))
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
        XCTAssertTrue(document.contains("Repeat all three shortcuts ten times with Control held"))
        XCTAssertTrue(document.contains("Expected: Eye `0`, ChatGPT `0`, Chronicle `0`"))
        XCTAssertTrue(document.contains("Eye + ChatGPT + Chronicle + real call"))
        XCTAssertTrue(document.contains("run it **last**"))
        XCTAssertTrue(document.contains("30 minutes of rapid app switching"))
        XCTAssertTrue(document.contains("at least 120"))
        XCTAssertTrue(document.contains("every arm (1 through"))
        XCTAssertTrue(document.contains("At `+5 minutes`, `+1 hour`,"))
        XCTAssertTrue(document.contains("and `+2 hours`,"))
        XCTAssertTrue(document.contains("after 1, 3, and 10 seconds"))
        XCTAssertTrue(document.contains("no screenshots, pixel fingerprints, captured text, audio"))
        XCTAssertTrue(document.contains("picker-versus-persistent-stream comparison is research"))
        XCTAssertTrue(document.contains("Do not change the shipping capture path"))
    }

    func testProtocolChecksOnePersistentEyeStreamAndKnownBadLogs() throws {
        let script = try contents("scripts/verify-capture-coexistence.sh")
        let document = try contents("docs/CAPTURE_COEXISTENCE.md")

        for marker in [
            "SCScreenshotManager",
            "_SCRemoteQueue_Enqueue",
            "stream output NOT found",
            "eye_screen_stream_started",
        ] {
            XCTAssertTrue(script.contains(marker), marker)
            XCTAssertTrue(document.contains(marker), marker)
        }
        XCTAssertTrue(script.contains("eye_log_predicate"))
        XCTAssertTrue(script.contains("processIdentifier == %s"))
        XCTAssertTrue(script.contains("--data-root"))
        XCTAssertTrue(script.contains("read_eye_port"))
        XCTAssertTrue(script.contains("listener_pid_set_matches_eye"))
        XCTAssertFalse(script.contains("--predicate 'process == \"ZBS Eye\"'"))
        XCTAssertTrue(script.contains("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
        XCTAssertTrue(script.contains("/Applications/ChatGPT.app/Contents/Resources/codex_chronicle"))
        XCTAssertTrue(script.contains("exact_command_pids"))
        XCTAssertTrue(script.contains("process-state.tsv"))
        XCTAssertTrue(script.contains("phase_process_after\" != \"$phase_process_before"))
        XCTAssertFalse(script.contains("process_running \"Codex\""))
        XCTAssertTrue(script.contains("twoTrackCallAttested"))
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
