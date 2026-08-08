import Foundation
import XCTest

final class ActivityVisualSelectionTests: XCTestCase {
    func testSceneVisualIsClosestRealImageToTemporalMidpoint() throws {
        let session = ActivitySession(captures: [
            capture(id: 1, ts: 0, path: "frames/early.heic"),
            capture(id: 2, ts: 9_000, path: nil),
            capture(id: 3, ts: 10_000, path: "imported"),
            capture(id: 4, ts: 20_000, path: "frames/late.heic"),
        ])

        let selected = try XCTUnwrap(session.representativeVisualCapture)
        XCTAssertEqual(selected.id, 1, "An equal-distance tie must prefer the earlier real frame")
        XCTAssertEqual(selected.relativePath, "frames/early.heic")
    }

    func testBlockPrefersLongestVisualSceneFromDominantApp() throws {
        let scenes = [
            scene(id: "dominant-long", app: "Xcode", start: 0, duration: 80, path: "xcode.heic"),
            scene(id: "dominant-no-image", app: "Xcode", start: 90, duration: 100, path: nil),
            scene(id: "other-longer-image", app: "Safari", start: 200, duration: 90, path: "safari.heic"),
        ]

        let block = try XCTUnwrap(ActivityBlockBuilder.blocks(from: scenes).first)
        XCTAssertEqual(block.topApps.first?.name, "Xcode")
        XCTAssertEqual(block.representativeVisualScene?.id, "dominant-long")
        XCTAssertEqual(block.representativeVisualPath, "xcode.heic")
    }

    func testBlockFallsBackToLongestVisualSceneWhenDominantAppHasNone() throws {
        let scenes = [
            scene(id: "dominant", app: "Xcode", start: 0, duration: 120, path: nil),
            scene(id: "short", app: "Safari", start: 130, duration: 20, path: "short.heic"),
            scene(id: "long", app: "Finder", start: 160, duration: 40, path: "long.heic"),
        ]

        let block = try XCTUnwrap(ActivityBlockBuilder.blocks(from: scenes).first)
        XCTAssertEqual(block.representativeVisualScene?.id, "long")
    }

    func testBlockWithoutARealImageKeepsTheIconOnlyFallback() throws {
        let scenes = [
            scene(id: "missing", app: "Xcode", start: 0, duration: 120, path: nil),
            scene(id: "imported", app: "Safari", start: 130, duration: 60, path: "imported"),
        ]

        let block = try XCTUnwrap(ActivityBlockBuilder.blocks(from: scenes).first)
        XCTAssertNil(block.representativeVisualScene)
        XCTAssertNil(block.representativeVisualPath)
    }

    private func capture(id: Int64, ts: Int64, path: String?) -> CaptureLite {
        CaptureLite(
            id: id,
            ts: ts,
            appId: 1,
            appName: "App",
            bundleId: "com.example.app",
            windowTitle: nil,
            browserUrl: nil,
            relativePath: path
        )
    }

    private func scene(
        id: String,
        app: String,
        start: TimeInterval,
        duration: TimeInterval,
        path: String?
    ) -> ActivityScene {
        ActivityScene(
            id: id,
            captureIds: [Int64(start)],
            appId: nil,
            bundleId: "com.example.\(app.lowercased())",
            appName: app,
            repWindowTitle: nil,
            browserURL: nil,
            startTs: Date(timeIntervalSince1970: start),
            endTs: Date(timeIntervalSince1970: start + duration),
            durationSec: duration,
            frameCount: 1,
            summary: id,
            isSystem: false,
            representativeCaptureID: path == nil ? nil : Int64(start),
            representativeVisualPath: path
        )
    }
}
