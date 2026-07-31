import XCTest

final class MCPSetupPresentationTests: XCTestCase {
    func testDefaultPresentationIsTokenlessAndUsesReadOnlyProfile() throws {
        let executable = URL(
            fileURLWithPath: "/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye"
        )
        let presentation = try MCPSetupPresentation(
            executableURL: executable,
            profile: .memoryReadOnly
        )

        XCTAssertEqual(
            presentation.codexCommand,
            "codex mcp add zbs-eye -- '/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye' --mcp-read-only"
        )
        XCTAssertEqual(
            presentation.claudeCodeCommand,
            "claude mcp add zbs-eye -- '/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye' --mcp-read-only"
        )
        XCTAssertEqual(
            presentation.hermesCommand,
            "hermes mcp add zbs-eye --command '/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye' --args --mcp-read-only"
        )
        let claude = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(presentation.claudeJSON.utf8))
                as? [String: Any]
        )
        let servers = try XCTUnwrap(claude["mcpServers"] as? [String: Any])
        let eye = try XCTUnwrap(servers["zbs-eye"] as? [String: Any])
        XCTAssertEqual(eye["command"] as? String, executable.path)
        XCTAssertEqual(eye["args"] as? [String], ["--mcp-read-only"])
        XCTAssertEqual(
            presentation.claudeDesktopConfigurationPath,
            "~/Library/Application Support/Claude/claude_desktop_config.json"
        )

        let primary = presentation.codexCommand
            + presentation.claudeCodeCommand
            + presentation.hermesCommand
            + presentation.claudeJSON
        for forbidden in ["Bearer", "api-token", "http://", "/v1", "secret-canary"] {
            XCTAssertFalse(primary.localizedCaseInsensitiveContains(forbidden))
        }
        XCTAssertEqual(presentation.statusLabel, "Ready to connect")
        XCTAssertTrue(presentation.restartInstruction.contains("Restart"))
        XCTAssertTrue(presentation.restartInstruction.contains("Hermes"))
    }

    func testAdvancedPresentationUsesExplicitFullProfile() throws {
        let presentation = try MCPSetupPresentation(
            executableURL: URL(fileURLWithPath: "/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye"),
            profile: .advancedFull
        )

        XCTAssertTrue(presentation.codexCommand.hasSuffix(" --mcp-full"))
        XCTAssertTrue(presentation.claudeJSON.contains("--mcp-full"))
        XCTAssertTrue(presentation.hermesCommand.hasSuffix(" --args --mcp-read-only"))
        XCTAssertFalse(presentation.hermesCommand.contains("--mcp-full"))
        XCTAssertTrue(presentation.accessSummary.contains("screenshot"))
        XCTAssertTrue(presentation.accessSummary.contains("recording"))
    }

    func testShellAndJSONEscapingKeepInjectionShapedPathData() throws {
        let path = "/Applications/ZBS 'Eye'; $(touch nope).app/Contents/MacOS/ZBS Eye"
        let presentation = try MCPSetupPresentation(
            executableURL: URL(fileURLWithPath: path),
            profile: .memoryReadOnly
        )
        let quotedInjectionPath = presentation.codexCommand
            .dropFirst("codex mcp add zbs-eye -- ".count)
            .dropLast(" --mcp-read-only".count)
        XCTAssertEqual(
            presentation.hermesCommand,
            "hermes mcp add zbs-eye --command \(quotedInjectionPath) --args --mcp-read-only"
        )

        XCTAssertEqual(
            presentation.codexCommand,
            "codex mcp add zbs-eye -- '/Applications/ZBS '\"'\"'Eye'\"'\"'; $(touch nope).app/Contents/MacOS/ZBS Eye' --mcp-read-only"
        )
        let claude = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(presentation.claudeJSON.utf8))
                as? [String: Any]
        )
        let servers = try XCTUnwrap(claude["mcpServers"] as? [String: Any])
        let eye = try XCTUnwrap(servers["zbs-eye"] as? [String: Any])
        XCTAssertEqual(eye["command"] as? String, path)
    }

    func testNULPathIsRejected() {
        XCTAssertThrowsError(
            try MCPSetupPresentation(
                executableURL: URL(string: "file:///Applications/ZBS%00Eye")!,
                profile: .memoryReadOnly
            )
        )
    }
}
