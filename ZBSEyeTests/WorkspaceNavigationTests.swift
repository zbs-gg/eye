import Foundation
import XCTest

@MainActor
final class WorkspaceNavigationTests: XCTestCase {
    func testWorkspaceStartsInTimelineWithoutASecondaryDestination() {
        let store = WorkspaceStore(now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(store.mode, .timeline)
        XCTAssertEqual(store.timelineRepresentation, .moments)
        XCTAssertNil(store.presentedFeature)
        XCTAssertNil(store.timelineMomentTarget)
    }

    func testTimelineAskTimelinePreservesRepresentationAndScope() {
        let moment = Date(timeIntervalSince1970: 900)
        let store = WorkspaceStore(
            now: Date(timeIntervalSince1970: 1_000),
            initialScope: .moment(moment)
        )
        store.showActivities()
        let scope = store.captureAskScope()

        store.openAsk()
        store.showTimeline()

        XCTAssertEqual(store.mode, .timeline)
        XCTAssertEqual(store.timelineRepresentation, .activities)
        XCTAssertEqual(store.captureAskScope(), scope)
    }

    func testCallsIsAPrimaryModeAndDismissesSecondaryFeatures() {
        let store = WorkspaceStore(now: Date(timeIntervalSince1970: 1_000))
        store.showActivities()
        store.present(.progress)

        store.openCalls()

        XCTAssertEqual(store.mode, .calls)
        XCTAssertNil(store.presentedFeature)
        XCTAssertEqual(store.timelineRepresentation, .activities)

        store.openAsk()
        XCTAssertEqual(store.mode, .ask)

        store.openCalls()
        XCTAssertEqual(store.mode, .calls)
        XCTAssertEqual(store.timelineRepresentation, .activities)
    }

    func testSecondaryFeaturesHaveOneWorkspaceOwnedRouteAndDismissInPlace() {
        let expected: Set<WorkspaceFeature> = [
            .insights,
            .automations,
            .progress,
            .achievements,
            .appearance,
            .settings,
        ]
        XCTAssertEqual(Set(WorkspaceFeature.allCases), expected)

        for feature in WorkspaceFeature.allCases {
            let store = WorkspaceStore(now: Date(timeIntervalSince1970: 1_000))
            store.showActivities()
            store.present(feature)

            XCTAssertEqual(store.presentedFeature, feature)
            XCTAssertEqual(store.mode, .timeline)
            XCTAssertEqual(store.timelineRepresentation, .activities)

            store.dismissFeature()
            XCTAssertNil(store.presentedFeature)
            XCTAssertEqual(store.mode, .timeline)
            XCTAssertEqual(store.timelineRepresentation, .activities)
        }
    }

    func testSecondaryFeatureDismissReturnsToAskWhenOpenedFromAsk() {
        let store = WorkspaceStore(now: Date(timeIntervalSince1970: 1_000))
        store.openAsk(scope: .moment(Date(timeIntervalSince1970: 900)))
        let scope = store.captureAskScope()

        store.present(.achievements)
        store.dismissFeature()

        XCTAssertEqual(store.mode, .ask)
        XCTAssertNil(store.presentedFeature)
        XCTAssertEqual(store.captureAskScope(), scope)
    }

    func testActivityMomentReturnsToTimelineWithoutCreatingADestination() {
        let target = Date(timeIntervalSince1970: 720)
        let store = WorkspaceStore(now: Date(timeIntervalSince1970: 1_000))
        store.showActivities()
        store.present(.achievements)

        store.returnToTimeline(moment: target)

        XCTAssertEqual(store.mode, .timeline)
        XCTAssertEqual(store.timelineRepresentation, .moments)
        XCTAssertNil(store.presentedFeature)
        XCTAssertEqual(store.consumeTimelineMomentTarget(), target)
        XCTAssertNil(store.consumeTimelineMomentTarget())
    }

    func testOpeningPrimaryModesDismissesSecondaryFeature() {
        let store = WorkspaceStore(now: Date(timeIntervalSince1970: 1_000))
        store.present(.progress)

        store.openAsk()
        XCTAssertEqual(store.mode, .ask)
        XCTAssertNil(store.presentedFeature)

        store.present(.settings)
        store.showTimeline(representation: .moments)
        XCTAssertEqual(store.mode, .timeline)
        XCTAssertEqual(store.timelineRepresentation, .moments)
        XCTAssertNil(store.presentedFeature)
    }

    func testSearchCitationClearsActivityMomentAndKeepsAskScope() {
        let store = WorkspaceStore(
            now: Date(timeIntervalSince1970: 1_000),
            initialScope: .range(
                from: Date(timeIntervalSince1970: 100),
                to: Date(timeIntervalSince1970: 200)
            )
        )
        let before = store.captureAskScope()
        store.returnToTimeline(moment: Date(timeIntervalSince1970: 120))

        store.returnToTimeline(source: SearchResult(
            id: 4,
            kind: .screen,
            ts: Date(timeIntervalSince1970: 150),
            bundleId: "gg.test",
            appName: "Test",
            windowTitle: nil,
            browserURL: nil,
            snippet: "Evidence",
            relativePath: nil
        ))

        XCTAssertNil(store.timelineMomentTarget)
        XCTAssertEqual(store.timelineReturnTarget?.id, 4)
        XCTAssertEqual(store.captureAskScope(), before)
    }
}
