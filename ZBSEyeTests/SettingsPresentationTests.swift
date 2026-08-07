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

    func testTimelineCaptureControlsDoNotPretendToDisableAutomaticCalls() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func source(_ relativePath: String) throws -> String {
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }
        let menu = try source("ZBSEyeApp/Views/MenuBar/MenuBarContent.swift")
        let timeline = try source("ZBSEyeApp/Views/Timeline/TimelineView.swift")
        let workspace = try source("ZBSEyeApp/Views/Workspace/WorkspaceHeader.swift")
        let settings = try source("ZBSEyeApp/Views/Settings/FocusedSettingsViews.swift")
        let readme = try source("README.md")
        let normalizedReadme = readme
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let help = "Automatic Calls stay armed until Audio is Off or privacy pause is active."

        XCTAssertTrue(menu.contains("Stop Timeline capture"))
        XCTAssertTrue(menu.contains("Pause Timeline capture"))
        XCTAssertTrue(menu.contains("Start Timeline capture"))
        XCTAssertTrue(menu.contains(help))
        for surface in [timeline, workspace] {
            XCTAssertTrue(surface.contains("Stop Timeline"))
            XCTAssertTrue(surface.contains("Pause Timeline"))
            XCTAssertTrue(surface.contains("Record Timeline"))
            XCTAssertTrue(surface.contains(help))
            XCTAssertTrue(surface.contains("env.recording.lowDiskPaused && env.recording.wantsRecording"))
        }
        XCTAssertTrue(settings.contains("even while screen recording is stopped"))
        XCTAssertTrue(normalizedReadme.contains("does not disarm microphone-triggered Calls"))

        let pauseGuard = try XCTUnwrap(
            menu.range(of: #"if env.recording.pausedUntil == nil {"#)
        )
        let privacyButton = try XCTUnwrap(
            menu.range(of: #"Button("Don't record for 15 minutes")"#)
        )
        let captureGuard = try XCTUnwrap(
            menu.range(
                of: #"if env.recording.isCapturing {"#,
                range: privacyButton.upperBound..<menu.endIndex
            )
        )
        XCTAssertLessThan(pauseGuard.lowerBound, privacyButton.lowerBound)
        XCTAssertLessThan(privacyButton.lowerBound, captureGuard.lowerBound)
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
