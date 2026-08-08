import Foundation
import XCTest

final class VisualTimelinePresentationTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testTimelinePresentsClickableSelectedFilmstripAndRespectsReducedMotion() throws {
        let view = try source("ZBSEyeApp/Views/Timeline/TimelineView.swift")
        let store = try source("ZBSEyeApp/State/TimelineStore.swift")

        XCTAssertTrue(view.contains("VisualFilmstrip("))
        XCTAssertTrue(view.contains("Button(action: onSelect)"))
        XCTAssertTrue(view.contains("selected ? Color.accentColor"))
        XCTAssertTrue(view.contains("maxPixel: 360"))
        XCTAssertTrue(view.contains("if reduceMotion"))
        XCTAssertTrue(view.contains(".animation(reduceMotion ? .none"))
        XCTAssertTrue(store.contains("maxPixel: 2_400"))
    }

    func testActivityCardUsesExactImageSizeAndKeepsIconFallback() throws {
        let view = try source("ZBSEyeApp/Views/Activities/ActivitiesView.swift")

        XCTAssertTrue(view.contains("if let visualImage"))
        XCTAssertTrue(view.contains(".frame(width: 160, height: 90)"))
        XCTAssertTrue(view.contains("maxPixel: 480"))
        XCTAssertTrue(view.contains("} else {\n            appIconView"))
    }

    func testActivityAsyncImagesRejectCancelledAndStaleAssignments() throws {
        let view = try source("ZBSEyeApp/Views/Activities/ActivitiesView.swift")

        XCTAssertTrue(view.contains("guard !Task.isCancelled, visualImageIdentity == path else { return }"))
        XCTAssertGreaterThanOrEqual(
            view.components(separatedBy: "guard !Task.isCancelled, appIconIdentity == bundleID else { return }").count - 1,
            3
        )
    }

    func testManualPrivacyDeleteInvalidatesDecodedPixelsBeforeAndAfterMutation() throws {
        let environment = try source("ZBSEyeApp/App/AppEnvironment.swift")
        let start = try XCTUnwrap(environment.range(of: "func deleteHistory(lastSeconds:"))
        let end = try XCTUnwrap(
            environment.range(of: "func changeKeepMediaPolicy(", range: start.upperBound..<environment.endIndex)
        )
        let method = String(environment[start.lowerBound..<end.lowerBound])

        XCTAssertEqual(
            method.components(separatedBy: "visualFrameImageLoader?.invalidateAllForPrivacyErase()").count - 1,
            2
        )
        XCTAssertEqual(
            method.components(separatedBy: "timelineStore?.discardVisualStateForPrivacyErase()").count - 1,
            2
        )
    }
}
