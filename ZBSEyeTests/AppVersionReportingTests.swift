import Foundation
import XCTest

final class AppVersionReportingTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testRuntimeProtocolsReportTheBundleVersionInsteadOfAReleaseLiteral() throws {
        let environment = try String(
            contentsOf: repositoryRoot.appending(path: "ZBSEyeApp/App/AppEnvironment.swift"),
            encoding: .utf8
        )
        let mcp = try String(
            contentsOf: repositoryRoot.appending(path: "ZBSEyeApp/MCP/ZBSEyeMCPServer.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(environment.contains("version: AppVersion.current"))
        XCTAssertTrue(mcp.contains("version: AppVersion.current"))
        XCTAssertFalse(environment.contains(#"version: "0.4.0""#))
        XCTAssertFalse(mcp.contains(#"version: "0.4.0""#))
    }
}
