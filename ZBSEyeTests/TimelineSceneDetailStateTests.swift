import Foundation
import XCTest

final class TimelineSceneDetailStateTests: XCTestCase {
    func testSceneStoreBecomingReadyRestartsLoadForTheSameFrame() {
        let beforeBootstrap = TimelineSceneLoadKey(frameID: 42, sceneStoreReady: false)
        let afterBootstrap = TimelineSceneLoadKey(frameID: 42, sceneStoreReady: true)

        XCTAssertNotEqual(beforeBootstrap, afterBootstrap)
    }

    func testVisibleFrameAlwaysHasASceneCardBeforeGroupingLoads() {
        let frame = makeFrame(
            id: 42,
            ts: Date(timeIntervalSince1970: 100),
            appName: "ChatGPT",
            windowTitle: "Inbox"
        )

        var state = TimelineSceneDetailState()
        XCTAssertTrue(state.beginLoading(for: frame))
        let card = state.card(for: frame)

        XCTAssertEqual(card.summary, "ChatGPT · Inbox")
        XCTAssertEqual(card.frameCount, 1)
        XCTAssertNil(card.jumpToStart)
    }

    func testLoadedSceneReplacesFallbackOnlyWhenItContainsTheVisibleFrame() {
        let frame = makeFrame(id: 8, ts: Date(timeIntervalSince1970: 100))
        let matching = makeScene(id: "matching", start: 90, end: 110, frameCount: 2, captureIDs: [8])
        let foreign = makeScene(id: "foreign", start: 120, end: 140, frameCount: 3, captureIDs: [8])

        var state = TimelineSceneDetailState()
        XCTAssertTrue(state.beginLoading(for: frame))
        state.finishLoading(matching, forFrameID: frame.id)
        XCTAssertEqual(state.card(for: frame).summary, "matching")
        XCTAssertEqual(state.card(for: frame).jumpToStart, matching.startTs)

        var foreignState = TimelineSceneDetailState()
        XCTAssertTrue(foreignState.beginLoading(for: frame))
        foreignState.finishLoading(foreign, forFrameID: frame.id)
        XCTAssertEqual(foreignState.card(for: frame).frameCount, 1)
        XCTAssertNil(foreignState.card(for: frame).jumpToStart)
    }

    func testFrameInsideLoadedSceneReusesItWithoutAnotherLookup() {
        let firstFrame = makeFrame(id: 8, ts: Date(timeIntervalSince1970: 100))
        let nextFrame = makeFrame(id: 9, ts: Date(timeIntervalSince1970: 105))
        let matching = makeScene(id: "matching", start: 90, end: 110, frameCount: 2, captureIDs: [8, 9])

        var state = TimelineSceneDetailState()
        XCTAssertTrue(state.beginLoading(for: firstFrame))
        state.finishLoading(matching, forFrameID: firstFrame.id)

        XCTAssertFalse(state.beginLoading(for: nextFrame))
        XCTAssertEqual(state.card(for: nextFrame).summary, "matching")
    }

    func testSameTimestampFromAnotherAppDoesNotReuseLoadedScene() {
        let firstFrame = makeFrame(
            id: 8,
            ts: Date(timeIntervalSince1970: 100),
            bundleID: "first.app"
        )
        let otherDisplayFrame = makeFrame(
            id: 9,
            ts: Date(timeIntervalSince1970: 100),
            bundleID: "other.app"
        )
        let firstScene = makeScene(
            id: "first",
            start: 90,
            end: 110,
            frameCount: 2,
            bundleID: "first.app",
            captureIDs: [8]
        )

        var state = TimelineSceneDetailState()
        XCTAssertTrue(state.beginLoading(for: firstFrame))
        state.finishLoading(firstScene, forFrameID: firstFrame.id)

        XCTAssertTrue(state.beginLoading(for: otherDisplayFrame))
        XCTAssertEqual(state.card(for: otherDisplayFrame).frameCount, 1)
        XCTAssertNil(state.card(for: otherDisplayFrame).jumpToStart)
    }

    func testLateResultForPreviousFrameCannotReplaceCurrentCard() {
        let oldFrame = makeFrame(id: 1, ts: Date(timeIntervalSince1970: 100))
        let currentFrame = makeFrame(id: 2, ts: Date(timeIntervalSince1970: 200))
        let oldScene = makeScene(id: "old", start: 90, end: 110, frameCount: 4, captureIDs: [1])

        var state = TimelineSceneDetailState()
        XCTAssertTrue(state.beginLoading(for: oldFrame))
        XCTAssertTrue(state.beginLoading(for: currentFrame))
        state.finishLoading(oldScene, forFrameID: oldFrame.id)

        XCTAssertEqual(state.card(for: currentFrame).frameCount, 1)
        XCTAssertNil(state.card(for: currentFrame).jumpToStart)
    }

    func testEqualTimeSameAppCaptureOutsideLoadedSceneRequiresExactLookup() {
        let firstFrame = makeFrame(id: 8, ts: Date(timeIntervalSince1970: 100), bundleID: "same.app")
        let laterSameAppFrame = makeFrame(id: 10, ts: Date(timeIntervalSince1970: 100), bundleID: "same.app")
        let firstScene = makeScene(
            id: "first-a",
            start: 100,
            end: 100,
            frameCount: 1,
            bundleID: "same.app",
            captureIDs: [8]
        )

        var state = TimelineSceneDetailState()
        XCTAssertTrue(state.beginLoading(for: firstFrame))
        state.finishLoading(firstScene, forFrameID: firstFrame.id)

        XCTAssertTrue(state.beginLoading(for: laterSameAppFrame))
        XCTAssertEqual(state.card(for: laterSameAppFrame).frameCount, 1)
        XCTAssertNil(state.card(for: laterSameAppFrame).jumpToStart)
    }

    func testSceneServiceSelectorUsesCaptureIDWhenTimestampsMatch() {
        let first = ActivitySession(captures: [
            makeCapture(id: 11, ts: 100_000, bundleID: "first.app"),
        ])
        let second = ActivitySession(captures: [
            makeCapture(id: 22, ts: 100_000, bundleID: "other.app"),
        ])

        let selected = SceneService.session(containingCaptureID: 22, in: [first, second])

        XCTAssertEqual(selected?.captureIds, [22])
        XCTAssertEqual(selected?.first.bundleId, "other.app")
    }

    func testTimelineSceneStringsHaveRussianTranslations() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZBSEyeApp/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])

        XCTAssertEqual(russianValue(for: "1 moment", in: strings), "1 момент")
        XCTAssertEqual(russianValue(for: "Extracted text", in: strings), "Извлечённый текст")
    }

    private func russianValue(for key: String, in strings: [String: Any]) -> String? {
        let entry = strings[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let russian = localizations?["ru"] as? [String: Any]
        let unit = russian?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    private func makeFrame(
        id: Int64,
        ts: Date,
        appName: String? = "App",
        windowTitle: String? = nil,
        bundleID: String? = "example.app"
    ) -> FrameDetail {
        FrameDetail(
            id: id,
            ts: ts,
            relativePath: nil,
            bundleId: bundleID,
            appName: appName,
            windowTitle: windowTitle,
            browserURL: nil,
            text: "raw extracted text",
            axQuality: "fullUseful"
        )
    }

    private func makeCapture(id: Int64, ts: Int64, bundleID: String) -> CaptureLite {
        CaptureLite(
            id: id,
            ts: ts,
            appId: id,
            appName: bundleID,
            bundleId: bundleID,
            windowTitle: nil,
            browserUrl: nil
        )
    }

    private func makeScene(
        id: String,
        start: TimeInterval,
        end: TimeInterval,
        frameCount: Int,
        bundleID: String? = "example.app",
        captureIDs: Set<Int64> = [8]
    ) -> ActivityScene {
        ActivityScene(
            id: id,
            captureIds: captureIDs,
            appId: 1,
            bundleId: bundleID,
            appName: "App",
            repWindowTitle: nil,
            browserURL: nil,
            startTs: Date(timeIntervalSince1970: start),
            endTs: Date(timeIntervalSince1970: end),
            durationSec: end - start,
            frameCount: frameCount,
            summary: id,
            isSystem: false
        )
    }
}
