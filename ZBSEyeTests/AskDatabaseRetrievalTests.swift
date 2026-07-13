import Foundation
import GRDB
import XCTest

final class AskDatabaseRetrievalTests: XCTestCase {
    func testScopedRetrievalPassesExactFiltersAndRevalidatesBothKindsInclusively() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let lowerMs: Int64 = 1_000_000
        let upperMs: Int64 = 2_000_000
        try seedScreen(fixture.db, id: 1, tsMs: lowerMs, text: "CURRENT lower screen")
        try seedScreen(fixture.db, id: 2, tsMs: lowerMs - 1, text: "outside before")
        try seedAudio(fixture.db, id: 3, tsMs: upperMs, text: "CURRENT upper audio")
        try seedAudio(fixture.db, id: 4, tsMs: upperMs + 1, text: "outside after")

        let search = RecordingAskSearch(hits: [
            hit(id: 1, kind: .screen, tsMs: lowerMs),
            hit(id: 2, kind: .screen, tsMs: lowerMs - 1),
            hit(id: 3, kind: .audio, tsMs: upperMs),
            hit(id: 4, kind: .audio, tsMs: upperMs + 1),
        ])
        let retrieval = AskDatabaseRetrieval(search: search, db: fixture.db)
        let scope = AskScope.range(
            from: dateFromMs(lowerMs),
            to: dateFromMs(upperMs)
        ).snapshot(revision: 9, calendar: utcCalendar())

        let evidence = try await retrieval.retrieve(
            question: "current",
            scope: scope,
            limit: 7
        )

        XCTAssertEqual(evidence.map(\.source.uniqueKey), ["screen:1", "audio:3"])
        XCTAssertTrue(evidence[0].text.contains("CURRENT lower screen"))
        XCTAssertTrue(evidence[1].text.contains("CURRENT upper audio"))
        XCTAssertFalse(evidence.contains(where: { $0.text.contains("STALE") }))
        XCTAssertTrue(evidence[0].source.snippet.contains("CURRENT lower screen"))
        XCTAssertTrue(evidence[1].source.snippet.contains("CURRENT upper audio"))

        let calls = await search.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].query, "current")
        XCTAssertEqual(calls[0].filters.from, dateFromMs(lowerMs))
        XCTAssertEqual(calls[0].filters.to, dateFromMs(upperMs))
        XCTAssertEqual(calls[0].filters.limit, 7)
    }

    func testSourceDeletedAfterSearchIsDroppedWithoutCachedSnippetFallback() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let tsMs: Int64 = 1_500_000
        try seedScreen(fixture.db, id: 9, tsMs: tsMs, text: "will disappear")
        let search = RecordingAskSearch(
            hits: [hit(id: 9, kind: .screen, tsMs: tsMs)],
            beforeReturn: {
                try fixture.db.pool.write { db in
                    try db.execute(
                        sql: "DELETE FROM screen_captures WHERE id = ?",
                        arguments: [9]
                    )
                }
            }
        )
        let retrieval = AskDatabaseRetrieval(search: search, db: fixture.db)
        let scope = AskScope.moment(dateFromMs(tsMs)).snapshot(
            revision: 1,
            calendar: utcCalendar()
        )

        let evidence = try await retrieval.retrieve(
            question: "disappear",
            scope: scope,
            limit: 10
        )

        XCTAssertTrue(evidence.isEmpty)
        let callCount = await search.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testParentWithoutCurrentTextIsNotEvidence() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let tsMs: Int64 = 1_500_000
        try seedScreen(fixture.db, id: 11, tsMs: tsMs, text: nil)
        let search = RecordingAskSearch(hits: [
            hit(id: 11, kind: .screen, tsMs: tsMs),
        ])
        let retrieval = AskDatabaseRetrieval(search: search, db: fixture.db)

        let evidence = try await retrieval.retrieve(
            question: "stale",
            scope: AskScope.moment(dateFromMs(tsMs)).snapshot(
                revision: 2,
                calendar: utcCalendar()
            ),
            limit: 10
        )

        XCTAssertTrue(evidence.isEmpty)
    }

    func testLegacyRetrievalRemainsAllHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let tsMs: Int64 = 1_500_000
        try seedScreen(fixture.db, id: 12, tsMs: tsMs, text: "legacy evidence")
        let search = RecordingAskSearch(hits: [
            hit(id: 12, kind: .screen, tsMs: tsMs),
        ])
        let retrieval = AskDatabaseRetrieval(search: search, db: fixture.db)

        let evidence = try await retrieval.retrieve(question: "legacy", limit: 4)

        XCTAssertEqual(evidence.map(\.source.id), [12])
        let calls = await search.recordedCalls()
        let filters = try XCTUnwrap(calls.only?.filters)
        XCTAssertNil(filters.from)
        XCTAssertNil(filters.to)
        XCTAssertEqual(filters.limit, 4)
    }

    private func makeFixture() throws -> DatabaseFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-ask-retrieval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return DatabaseFixture(
            root: root,
            db: try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        )
    }

    private func seedScreen(
        _ database: ZBSEyeDatabase,
        id: Int64,
        tsMs: Int64,
        text: String?
    ) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO screen_captures
                    (id, ts, monitorId, windowTitle, relativePath)
                VALUES (?, ?, 'main', 'Window', ?)
                """,
                arguments: [id, tsMs, "screens/\(id).heic"]
            )
            if let text {
                try db.execute(
                    sql: """
                    INSERT INTO text_blocks (captureId, source, text)
                    VALUES (?, 'ocr', ?)
                    """,
                    arguments: [id, text]
                )
            }
        }
    }

    private func seedAudio(
        _ database: ZBSEyeDatabase,
        id: Int64,
        tsMs: Int64,
        text: String
    ) throws {
        try database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO audio_captures
                    (id, ts, relativePath, durationSec, channel)
                VALUES (?, ?, ?, 12, 'system')
                """,
                arguments: [id, tsMs, "audio/\(id).m4a"]
            )
            try db.execute(
                sql: """
                INSERT INTO transcriptions
                    (audioId, text, language, engine)
                VALUES (?, ?, 'en', 'test')
                """,
                arguments: [id, text]
            )
        }
    }

    private func hit(id: Int64, kind: SearchKind, tsMs: Int64) -> SearchResult {
        SearchResult(
            id: id,
            kind: kind,
            ts: dateFromMs(tsMs),
            bundleId: kind == .screen ? "gg.stale" : nil,
            appName: kind == .screen ? "Stale App" : "Stale Audio",
            windowTitle: "Stale Window",
            browserURL: nil,
            snippet: "STALE cached snippet",
            relativePath: "stale/path"
        )
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private struct DatabaseFixture: @unchecked Sendable {
    let root: URL
    let db: ZBSEyeDatabase

    func remove() {
        try? db.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RecordingAskSearch: AskSearchProviding {
    struct Call: Sendable {
        let query: String
        let filters: SearchFilters
    }

    private let hits: [SearchResult]
    private let beforeReturn: @Sendable () throws -> Void
    private var calls: [Call] = []

    init(
        hits: [SearchResult],
        beforeReturn: @escaping @Sendable () throws -> Void = {}
    ) {
        self.hits = hits
        self.beforeReturn = beforeReturn
    }

    func search(
        query: String,
        filters: SearchFilters
    ) async throws -> [SearchResult] {
        calls.append(Call(query: query, filters: filters))
        try beforeReturn()
        return hits
    }

    func recordedCalls() -> [Call] { calls }
    func callCount() -> Int { calls.count }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
