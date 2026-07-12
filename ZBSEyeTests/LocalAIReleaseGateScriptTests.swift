import Foundation
import XCTest

final class LocalAIReleaseGateScriptTests: XCTestCase {
    func testRecorderCoexistenceGateIsExplicitOptInAndFailClosed() throws {
        let script = try contents("scripts/verify-local-ai.sh")
        XCTAssertTrue(script.contains("--recorder-coexistence-gate"))
        XCTAssertTrue(script.contains("ZBS_EYE_LOCAL_AI_RECORDER_COEXISTENCE_GATE"))
        XCTAssertTrue(script.contains("LocalAIRecorderCoexistenceGateTests"))
        XCTAssertTrue(script.contains("recorder coexistence gate was skipped"))
        XCTAssertTrue(script.contains("requires an explicit --model-dir PATH"))
    }

    func testConcurrencyStressAndTSanModesAreDedicatedReleaseInvocations() throws {
        let script = try contents("scripts/verify-local-ai.sh")
        XCTAssertTrue(script.contains("--concurrency-stress"))
        XCTAssertTrue(script.contains("--concurrency-stress-tsan"))
        XCTAssertTrue(script.contains("LocalAIConcurrencyStressTests"))
        XCTAssertTrue(script.contains("-enableThreadSanitizer"))
        XCTAssertTrue(script.contains("require_test_case_passed"))
        XCTAssertTrue(script.contains("testStaleActivationOutboxIsAcknowledgedWithoutReplayAfterRestart"))
        XCTAssertTrue(script.contains("testRelocationDrainWaitsForEntireInFlightCandidateLoad"))
        XCTAssertTrue(script.contains("testRelocationCancelsSuspendedVerificationAndPreservesRetryableCandidate"))
        XCTAssertTrue(script.contains("testShutdownCancelsSuspendedVerificationAndLeavesRestartRecoveryPoint"))
    }

    func testLocalAIDocumentationNamesPhysicalLimitAndExactCommands() throws {
        let documentation = try contents("docs/LOCAL_AI.md")
        XCTAssertTrue(documentation.contains("--recorder-coexistence-gate --model-dir"))
        XCTAssertTrue(documentation.contains("--concurrency-stress-tsan"))
        XCTAssertTrue(documentation.contains("MLX/Metal"))
        XCTAssertTrue(documentation.contains("does not replace the staging-app hardware recorder run"))
    }

    private func contents(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
    }
}
