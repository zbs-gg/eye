import Foundation
import XCTest

final class AskScopeWorkspaceTests: XCTestCase {
    func testAllHistoryHasNoBounds() {
        let snapshot = AskScope.all.snapshot(revision: 7, calendar: utcCalendar())

        XCTAssertEqual(snapshot.revision, 7)
        XCTAssertNil(snapshot.from)
        XCTAssertNil(snapshot.to)
        XCTAssertTrue(snapshot.isAllHistory)
    }

    func testMomentUsesNamedInclusiveRadius() throws {
        let cursor = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = AskScope.moment(cursor).snapshot(
            revision: 1,
            calendar: utcCalendar()
        )

        XCTAssertEqual(
            try XCTUnwrap(snapshot.from),
            cursor.addingTimeInterval(-AskScope.momentRadius)
        )
        XCTAssertEqual(
            try XCTUnwrap(snapshot.to),
            cursor.addingTimeInterval(AskScope.momentRadius)
        )
        XCTAssertTrue(snapshot.includes(cursor.addingTimeInterval(-AskScope.momentRadius)))
        XCTAssertTrue(snapshot.includes(cursor.addingTimeInterval(AskScope.momentRadius)))
        XCTAssertFalse(snapshot.includes(
            cursor.addingTimeInterval(-AskScope.momentRadius - 0.001)
        ))
        XCTAssertFalse(snapshot.includes(
            cursor.addingTimeInterval(AskScope.momentRadius + 0.001)
        ))
    }

    func testExplicitRangePreservesInclusiveEndpointsAndReversedRangeFailsClosed() throws {
        let lower = Date(timeIntervalSince1970: 100)
        let upper = Date(timeIntervalSince1970: 200)
        let snapshot = AskScope.range(from: lower, to: upper).snapshot(
            revision: 2,
            calendar: utcCalendar()
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.from), lower)
        XCTAssertEqual(try XCTUnwrap(snapshot.to), upper)
        XCTAssertTrue(snapshot.includes(lower))
        XCTAssertTrue(snapshot.includes(upper))
        XCTAssertFalse(snapshot.includes(lower.addingTimeInterval(-0.001)))
        XCTAssertFalse(snapshot.includes(upper.addingTimeInterval(0.001)))

        let reversed = AskScope.range(from: upper, to: lower).snapshot(
            revision: 3,
            calendar: utcCalendar()
        )
        XCTAssertFalse(reversed.includes(Date(timeIntervalSince1970: 150)))
    }

    func testSpringDSTDayUsesLocalCalendarAndExcludesNextMidnight() throws {
        let calendar = losAngelesCalendar()
        let anchor = try localDate(
            year: 2026,
            month: 3,
            day: 8,
            hour: 12,
            calendar: calendar
        )
        let snapshot = AskScope.day(anchor).snapshot(revision: 1, calendar: calendar)
        let from = try XCTUnwrap(snapshot.from)
        let to = try XCTUnwrap(snapshot.to)
        let nextMidnight = try XCTUnwrap(
            calendar.date(byAdding: .day, value: 1, to: from)
        )

        XCTAssertEqual(msFromDate(to), msFromDate(nextMidnight) - 1)
        XCTAssertEqual(msFromDate(nextMidnight) - msFromDate(from), 23 * 60 * 60 * 1_000)
        XCTAssertTrue(snapshot.includes(to))
        XCTAssertFalse(snapshot.includes(nextMidnight))
    }

    func testFallDSTDayUsesLocalCalendarAndExcludesNextMidnight() throws {
        let calendar = losAngelesCalendar()
        let anchor = try localDate(
            year: 2026,
            month: 11,
            day: 1,
            hour: 12,
            calendar: calendar
        )
        let snapshot = AskScope.day(anchor).snapshot(revision: 1, calendar: calendar)
        let from = try XCTUnwrap(snapshot.from)
        let to = try XCTUnwrap(snapshot.to)
        let nextMidnight = try XCTUnwrap(
            calendar.date(byAdding: .day, value: 1, to: from)
        )

        XCTAssertEqual(msFromDate(to), msFromDate(nextMidnight) - 1)
        XCTAssertEqual(msFromDate(nextMidnight) - msFromDate(from), 25 * 60 * 60 * 1_000)
        XCTAssertTrue(snapshot.includes(to))
        XCTAssertFalse(snapshot.includes(nextMidnight))
    }

    @MainActor
    func testWorkspaceDefaultsToTodayAndFreezesScopePerSnapshot() throws {
        let calendar = losAngelesCalendar()
        let now = try localDate(
            year: 2026,
            month: 7,
            day: 14,
            hour: 15,
            calendar: calendar
        )
        let store = WorkspaceStore(now: now, calendar: calendar)

        let sent = store.captureAskScope()
        guard case .day = sent.value else {
            return XCTFail("Expected Today as the initial Ask scope")
        }

        let later = now.addingTimeInterval(90 * 60)
        store.setAskScope(.moment(later))
        let visible = store.captureAskScope()

        XCTAssertNotEqual(sent, visible)
        XCTAssertEqual(sent.revision, 0)
        XCTAssertEqual(visible.revision, 1)
        XCTAssertTrue(sent.includes(now))
        XCTAssertFalse(visible.includes(now))
    }

    @MainActor
    func testCitationReturnPreservesPriorAskScope() {
        let store = WorkspaceStore(
            now: Date(timeIntervalSince1970: 1_000),
            calendar: utcCalendar(),
            initialScope: .range(
                from: Date(timeIntervalSince1970: 100),
                to: Date(timeIntervalSince1970: 200)
            )
        )
        store.openAsk()
        let before = store.captureAskScope()
        let source = SearchResult(
            id: 42,
            kind: .screen,
            ts: Date(timeIntervalSince1970: 150),
            bundleId: "gg.test",
            appName: "Test",
            windowTitle: "Window",
            browserURL: nil,
            snippet: "Evidence",
            relativePath: nil
        )

        store.returnToTimeline(source: source)

        XCTAssertEqual(store.mode, .timeline)
        XCTAssertEqual(store.timelineReturnTarget?.id, 42)
        XCTAssertEqual(store.captureAskScope(), before)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func losAngelesCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func localDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        )))
    }
}
