import Foundation
import XCTest

final class SettingsPresentationTests: XCTestCase {
    func testAudioModeLabelsExposeMicTriggeredDefaultWithoutChangingStoredCase() {
        XCTAssertEqual(AudioMode.allCases.map(\.label), ["Off", "Mic in use", "Always"])
        XCTAssertEqual(AudioMode.meetingsOnly.rawValue, "meetingsOnly")
    }

    func testRecordingStatusDescribesMicrophoneUseInsteadOfMeetingOnlyDetection() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "ZBSEyeApp/Views/Components/RecordingStatusView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(#"String(localized: "Recording a Call")"#))
        XCTAssertTrue(source.contains(#"String(localized: "Listening for microphone use")"#))
        XCTAssertFalse(source.contains(#"text: "Recording this meeting""#))
        XCTAssertFalse(source.contains(#"text: "Listening for meetings""#))
    }

    func testPrimarySettingsContainFocusedRoutesInProductOrder() {
        XCTAssertEqual(
            SettingsRoute.allCases,
            [.permissions, .ai, .dataStorage, .browserCapture, .mcpTools]
        )
        XCTAssertEqual(SettingsRoute.allCases.map(\.title), [
            "Permissions",
            "AI",
            "Data Storage",
            "Browser Capture",
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
