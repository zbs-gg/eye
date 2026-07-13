import XCTest

final class SettingsPresentationTests: XCTestCase {
    func testPrimarySettingsContainExactlyFourFocusedRoutesInProductOrder() {
        XCTAssertEqual(
            SettingsRoute.allCases,
            [.permissions, .ai, .dataStorage, .mcpTools]
        )
        XCTAssertEqual(SettingsRoute.allCases.map(\.title), [
            "Permissions",
            "AI",
            "Data Storage",
            "MCP & AI Tools",
        ])
    }

    func testKeepMediaPresentationContainsOnlyDiscreteProductPolicies() {
        XCTAssertEqual(
            KeepMediaPolicy.allCases,
            [.fiveGB, .tenGB, .twentyGB, .fiftyGB, .forever]
        )
        XCTAssertEqual(
            KeepMediaPolicy.allCases.map(\.settingsLabel),
            ["5 GB", "10 GB", "20 GB", "50 GB", "Forever"]
        )
    }
}
