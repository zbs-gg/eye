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
            "codex mcp add zbs-eye -- '/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye' --mcp"
        )
        let claude = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(presentation.claudeJSON.utf8))
                as? [String: Any]
        )
        let servers = try XCTUnwrap(claude["mcpServers"] as? [String: Any])
        let eye = try XCTUnwrap(servers["zbs-eye"] as? [String: Any])
        XCTAssertEqual(eye["command"] as? String, executable.path)
        XCTAssertEqual(eye["args"] as? [String], ["--mcp"])

        let primary = presentation.codexCommand + presentation.claudeJSON
        for forbidden in ["Bearer", "api-token", "http://", "/v1", "secret-canary"] {
            XCTAssertFalse(primary.localizedCaseInsensitiveContains(forbidden))
        }
        XCTAssertEqual(presentation.statusLabel, "Ready to connect")
        XCTAssertTrue(presentation.restartInstruction.contains("Restart"))
    }

    func testAdvancedPresentationUsesExplicitFullProfile() throws {
        let presentation = try MCPSetupPresentation(
            executableURL: URL(fileURLWithPath: "/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye"),
            profile: .advancedFull
        )

        XCTAssertTrue(presentation.codexCommand.hasSuffix(" --mcp-full"))
        XCTAssertTrue(presentation.claudeJSON.contains("--mcp-full"))
        XCTAssertTrue(presentation.accessSummary.contains("screenshot"))
        XCTAssertTrue(presentation.accessSummary.contains("recording"))
    }

    func testShellAndJSONEscapingKeepInjectionShapedPathData() throws {
        let path = "/Applications/ZBS 'Eye'; $(touch nope).app/Contents/MacOS/ZBS Eye"
        let presentation = try MCPSetupPresentation(
            executableURL: URL(fileURLWithPath: path),
            profile: .memoryReadOnly
        )

        XCTAssertEqual(
            presentation.codexCommand,
            "codex mcp add zbs-eye -- '/Applications/ZBS '\"'\"'Eye'\"'\"'; $(touch nope).app/Contents/MacOS/ZBS Eye' --mcp"
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
