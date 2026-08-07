import CoreGraphics
import Foundation
import XCTest

final class ScreenshotPriorityYieldGateTests: XCTestCase {
    func testExactScreenshotProcessIdentitiesAreKeptSeparate() {
        XCTAssertTrue(ScreenshotPriorityProcessPolicy.isNativeScreenshotProcess(
            bundleIdentifier: "com.apple.screenshot.launcher",
            executablePath: "/System/Applications/Utilities/Screenshot.app/Contents/MacOS/Screenshot"
        ))
        XCTAssertTrue(ScreenshotPriorityProcessPolicy.isNativeScreenshotProcess(
            bundleIdentifier: "com.apple.screencaptureui",
            executablePath: "/System/Library/CoreServices/screencaptureui.app/Contents/MacOS/screencaptureui"
        ))
        XCTAssertTrue(ScreenshotPriorityProcessPolicy.isNativeScreenshotProcess(
            bundleIdentifier: nil,
            executablePath: "/usr/sbin/screencapture"
        ))

        XCTAssertFalse(ScreenshotPriorityProcessPolicy.isNativeScreenshotProcess(
            bundleIdentifier: "com.apple.screenshot.launcher.helper",
            executablePath: nil
        ))
        XCTAssertFalse(ScreenshotPriorityProcessPolicy.isNativeScreenshotProcess(
            bundleIdentifier: "com.apple.screenshot.launcher",
            executablePath: "/Applications/Fake.app/Contents/MacOS/Screenshot"
        ))
        XCTAssertFalse(ScreenshotPriorityProcessPolicy.isNativeScreenshotProcess(
            bundleIdentifier: "com.example.fake-screenshot",
            executablePath: "/Applications/Fake.app/Contents/MacOS/screencapture"
        ))
        XCTAssertFalse(ScreenshotPriorityProcessPolicy.isNativeScreenshotProcess(
            bundleIdentifier: nil,
            executablePath: "/tmp/screencapture"
        ))
        XCTAssertFalse(ScreenshotPriorityProcessPolicy.isNativeScreenshotProcess(
            bundleIdentifier: "gg.zbs.eye",
            executablePath: "/Applications/ZBS Eye.app/Contents/MacOS/ZBS Eye"
        ))

        XCTAssertTrue(ScreenshotPriorityProcessPolicy.isNativeScreenshotApplication(
            bundleIdentifier: "com.apple.screencaptureui"
        ))
        XCTAssertFalse(ScreenshotPriorityProcessPolicy.isNativeScreenshotApplication(
            bundleIdentifier: "com.example.fake-screenshot"
        ))
    }

    func testOnlyNativeScreenshotHotkeysMatch() {
        for keyCode: CGKeyCode in [20, 21, 23] {
            XCTAssertTrue(ScreenshotHotkeyPolicy.isNativeScreenshotHotkey(
                keyCode: keyCode,
                flags: [.maskCommand, .maskShift]
            ))
            XCTAssertTrue(ScreenshotHotkeyPolicy.isNativeScreenshotHotkey(
                keyCode: keyCode,
                flags: [.maskCommand, .maskShift, .maskControl]
            ))
        }
        XCTAssertFalse(ScreenshotHotkeyPolicy.isNativeScreenshotHotkey(
            keyCode: 20,
            flags: [.maskCommand]
        ))
        XCTAssertFalse(ScreenshotHotkeyPolicy.isNativeScreenshotHotkey(
            keyCode: 20,
            flags: [.maskCommand, .maskShift, .maskAlternate]
        ))
        XCTAssertFalse(ScreenshotHotkeyPolicy.isNativeScreenshotHotkey(
            keyCode: 22,
            flags: [.maskCommand, .maskShift]
        ))
    }

    @MainActor
    func testHotkeyOpensAndRepeatedHotkeyExtendsTwoSecondWindow() {
        let gate = ScreenshotPriorityYieldGate(nowMilliseconds: { 1_000 })

        gate.openSuppression()
        XCTAssertTrue(gate.isSuppressed(now: 2_999))
        XCTAssertFalse(gate.isSuppressed(now: 3_000))

        gate.openSuppression(now: 2_500)
        XCTAssertTrue(gate.isSuppressed(now: 4_499))
        XCTAssertFalse(gate.isSuppressed(now: 4_500))
    }

    @MainActor
    func testActiveScreenshotUIExtendsPastDeadlineAndExitLeavesQuietTail() {
        let gate = ScreenshotPriorityYieldGate(nowMilliseconds: { 10_000 })

        gate.replaceActiveScreenshotProcesses([42])
        XCTAssertTrue(gate.isSuppressed(now: 99_000))

        gate.replaceActiveScreenshotProcesses([], now: 99_000)
        XCTAssertTrue(gate.isSuppressed(now: 100_999))
        XCTAssertFalse(gate.isSuppressed(now: 101_000))
    }

    @MainActor
    func testSuppressionCallbackAndRevisionAdvanceSynchronously() {
        let gate = ScreenshotPriorityYieldGate(nowMilliseconds: { 500 })
        var observed: [UInt64] = []
        gate.onSuppressionOpened = { observed.append($0) }

        let revision = gate.openSuppression()

        XCTAssertEqual(revision, 1)
        XCTAssertEqual(gate.revision, 1)
        XCTAssertEqual(observed, [1])
    }

    func testMonitorIsListenOnlyAndNeverRequestsNewTCC() throws {
        let source = try String(
            contentsOf: repositoryRoot.appending(path: "ZBSEyeApp/Capture/ScreenshotHotkeyMonitor.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("options: .listenOnly"))
        XCTAssertTrue(source.contains("CGPreflightListenEventAccess()"))
        XCTAssertTrue(source.contains("gate.openSuppression()"))
        XCTAssertTrue(source.contains("return Unmanaged.passUnretained(event)"))
        XCTAssertTrue(source.contains("\\.runningApplications"))
        XCTAssertTrue(source.contains("options: [.initial, .new]"))
        XCTAssertTrue(source.contains("runCaptureObservationOnMainActorSynchronously"))
        for forbidden in [
            "CGRequestListenEventAccess",
            "AXIsProcessTrustedWithOptions",
            "tccutil",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
