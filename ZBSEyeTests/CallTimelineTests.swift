import XCTest

final class CallTimelineTests: XCTestCase {
    func testTimelineAndDayRepositorySkipLegacyAuthenticationFrames() async throws {
        let fixture = try CallTimelineFixture()
        let ordinaryID = try await fixture.insertScreen(
            timestampMs: 1_000,
            bundleID: "com.example.editor",
            appName: "Editor"
        )
        let protectedID = try await fixture.insertScreen(
            timestampMs: 2_000,
            bundleID: "com.apple.LocalAuthentication.UIAgent",
            appName: "LocalAuthentication UIAgent"
        )
        let importedProtectedID = try await fixture.insertScreen(
            timestampMs: 2_500,
            bundleID: "imported.LocalAuthenticationRemoteService",
            appName: "LocalAuthenticationRemoteService"
        )

        let nearest = try await fixture.timeline.frameAt(dateFromMs(3_000))
        let directProtected = try await fixture.timeline.frameDetail(id: protectedID)
        let directImportedProtected = try await fixture.timeline.frameDetail(id: importedProtectedID)
        let bounds = try await fixture.timeline.bounds()
        let density = try await fixture.timeline.density(
            from: dateFromMs(0),
            to: dateFromMs(3_000),
            bucketMs: 1_000
        )
        let visibleStats = try await fixture.database.pool.read {
            try SystemAppFilter.visibleScreenCaptureStats(in: $0)
        }
        let captures = try await DayActivityRepository(db: fixture.database).captures(
            fromMs: 0,
            toMs: 3_000
        )

        XCTAssertEqual(nearest?.id, ordinaryID)
        XCTAssertNil(directProtected)
        XCTAssertNil(directImportedProtected)
        XCTAssertEqual(bounds.oldest, dateFromMs(1_000))
        XCTAssertEqual(bounds.newest, dateFromMs(1_000))
        XCTAssertEqual(density.count, 1)
        XCTAssertEqual(density.first?.ts, dateFromMs(1_000))
        XCTAssertEqual(density.first?.count, 1)
        XCTAssertEqual(visibleStats.frames, 1)
        XCTAssertEqual(visibleStats.apps, 1)
        XCTAssertEqual(visibleStats.oldestMs, 1_000)
        XCTAssertEqual(visibleStats.newestMs, 1_000)
        XCTAssertEqual(captures.map(\.id), [ordinaryID])
    }

    func testCallOnlyHistoryContributesBoundsAndBookmarkMarkers() async throws {
        let fixture = try CallTimelineFixture()
        let call = try await fixture.repository.createCall(
            startedAtMs: 10_000,
            idempotencyKey: "call"
        )
        let callID = try XCTUnwrap(call.id)
        _ = try await fixture.repository.createBookmark(
            callID: callID,
            idempotencyKey: "bookmark",
            acceptedAtMs: 20_000,
            meIngressTarget: 0,
            systemIngressTarget: 0,
            logicalStartMs: 10_000,
            logicalEndMs: 20_000,
            contextStartMs: 10_000
        )
        _ = try await fixture.repository.createBookmark(
            callID: callID,
            idempotencyKey: "later-bookmark",
            acceptedAtMs: 40_000,
            meIngressTarget: 0,
            systemIngressTarget: 0,
            logicalStartMs: 20_000,
            logicalEndMs: 40_000,
            contextStartMs: 10_000
        )

        let bounds = try await fixture.timeline.bounds()
        let spans = try await fixture.timeline.callSpans(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(bounds.oldest, dateFromMs(10_000))
        XCTAssertEqual(bounds.newest, dateFromMs(10_000))
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.id, callID)
        XCTAssertEqual(spans.first?.status, .processing)
        XCTAssertEqual(spans.first?.bookmarks.map { $0.acceptedAt }, [dateFromMs(20_000)])
    }

    func testTimelineStateIsReadyDegradedOrRetryableWithoutInventingCompletion() async throws {
        let fixture = try CallTimelineFixture()
        let ready = try await fixture.insertFinishedCall(
            startMs: 10_000,
            endMs: 20_000,
            state: .ready,
            degradationReason: nil
        )
        let degraded = try await fixture.insertFinishedCall(
            startMs: 30_000,
            endMs: 40_000,
            state: .ready,
            degradationReason: "system_gap"
        )
        let failed = try await fixture.insertFinishedCall(
            startMs: 50_000,
            endMs: 60_000,
            state: .failed,
            degradationReason: "system_gap"
        )

        let spans = try await fixture.timeline.callSpans(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 70)
        )
        let statuses = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0.status) })

        XCTAssertEqual(statuses[ready], .ready)
        XCTAssertEqual(statuses[degraded], .degraded)
        XCTAssertEqual(statuses[failed], .retryable)
    }

    func testVisualWindowCarriesOnlyTheNearestPastRealImage() async throws {
        let fixture = try CallTimelineFixture()
        let first = try await fixture.insertScreen(
            timestampMs: 500,
            bundleID: "com.example.first",
            appName: "First",
            relativePath: "frames/first.heic"
        )
        let selected = try await fixture.insertScreen(
            timestampMs: 1_000,
            bundleID: "com.example.selected",
            appName: "Selected",
            relativePath: "frames/selected.heic"
        )
        let contextOnly = try await fixture.insertScreen(
            timestampMs: 1_500,
            bundleID: "com.example.context",
            appName: "Context",
            relativePath: nil
        )
        _ = try await fixture.insertScreen(
            timestampMs: 1_600,
            bundleID: "com.example.imported",
            appName: "Imported",
            relativePath: "imported"
        )
        _ = try await fixture.insertScreen(
            timestampMs: 1_700,
            bundleID: "com.apple.LocalAuthentication.UIAgent",
            appName: "LocalAuthentication UIAgent",
            relativePath: "frames/private.heic"
        )
        let future = try await fixture.insertScreen(
            timestampMs: 2_000,
            bundleID: "com.example.future",
            appName: "Future",
            relativePath: "frames/future.heic"
        )

        let context = try await fixture.timeline.frameAt(dateFromMs(1_500))
        let visual = try await fixture.timeline.visualWindow(atOrBefore: dateFromMs(1_500))

        XCTAssertEqual(context?.id, contextOnly)
        XCTAssertNil(context?.relativePath)
        XCTAssertEqual(visual.selectedID, selected)
        XCTAssertEqual(visual.frames.map(\.id), [first, selected, future])
        XCTAssertEqual(visual.selected?.appLabel, "Selected")
        XCTAssertLessThanOrEqual(try XCTUnwrap(visual.selected).ts, dateFromMs(1_500))
    }

    func testVisualWindowIsExactlyTwoPreviousCurrentAndFourNext() async throws {
        let fixture = try CallTimelineFixture()
        var ids: [Int64] = []
        for index in 1...10 {
            ids.append(try await fixture.insertScreen(
                timestampMs: Int64(index * 1_000),
                bundleID: "com.example.app-\(index)",
                appName: "App \(index)",
                relativePath: "frames/\(index).heic"
            ))
        }

        let visual = try await fixture.timeline.visualWindow(atOrBefore: dateFromMs(6_000))

        XCTAssertEqual(visual.selectedID, ids[5])
        XCTAssertEqual(visual.frames.map(\.id), Array(ids[3...9]))
        XCTAssertEqual(visual.frames.count, 7)
    }

    func testInvalidPreferredVisualFallsBackOnlyBackward() async throws {
        let fixture = try CallTimelineFixture()
        let earlier = try await fixture.insertScreen(
            timestampMs: 1_000,
            bundleID: "com.example.earlier",
            appName: "Earlier",
            relativePath: "frames/earlier.heic"
        )
        let imported = try await fixture.insertScreen(
            timestampMs: 2_000,
            bundleID: "com.example.imported",
            appName: "Imported",
            relativePath: "imported"
        )
        let later = try await fixture.insertScreen(
            timestampMs: 3_000,
            bundleID: "com.example.later",
            appName: "Later",
            relativePath: "frames/later.heic"
        )

        let visual = try await fixture.timeline.visualWindow(
            atOrBefore: dateFromMs(2_000),
            anchorID: imported
        )

        XCTAssertEqual(visual.selectedID, earlier)
        XCTAssertEqual(visual.frames.map(\.id), [earlier, later])
        XCTAssertLessThanOrEqual(try XCTUnwrap(visual.selected).ts, dateFromMs(2_000))
    }

    func testContextOnlyEqualTimestampAnchorCannotSelectLaterVisual() async throws {
        let fixture = try CallTimelineFixture()
        let first = try await fixture.insertScreen(
            timestampMs: 1_000,
            bundleID: "com.example.first",
            appName: "First",
            relativePath: "frames/first.heic"
        )
        let contextOnly = try await fixture.insertScreen(
            timestampMs: 1_000,
            bundleID: "com.example.context",
            appName: "Context",
            relativePath: nil
        )
        let laterAtSameTimestamp = try await fixture.insertScreen(
            timestampMs: 1_000,
            bundleID: "com.example.later",
            appName: "Later",
            relativePath: "frames/later.heic"
        )

        let visual = try await fixture.timeline.visualWindow(
            atOrBefore: dateFromMs(1_000),
            anchorID: contextOnly
        )

        XCTAssertEqual(visual.selectedID, first)
        XCTAssertNotEqual(visual.selectedID, laterAtSameTimestamp)
        XCTAssertEqual(visual.frames.map(\.id), [first, laterAtSameTimestamp])
    }
}

private final class CallTimelineFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let repository: CallRepository
    let timeline: TimelineService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-timeline-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        repository = CallRepository(database: database)
        timeline = TimelineService(db: database)
    }

    func insertFinishedCall(
        startMs: Int64,
        endMs: Int64,
        state: CallLifecycleState,
        degradationReason: String?
    ) async throws -> Int64 {
        let created = try await repository.createCall(
            startedAtMs: startMs,
            idempotencyKey: "call-\(startMs)"
        )
        let id = try XCTUnwrap(created.id)
        if state == .ready {
            _ = try await repository.endCall(
                callID: id,
                idempotencyKey: "end-\(startMs)",
                endedAtMs: endMs
            )
            let candidate = try await repository.claimNextTranscriptJob(nowMs: endMs + 1)
            let job = try XCTUnwrap(candidate)
            _ = try await repository.commitTranscriptJob(
                jobID: try XCTUnwrap(job.id),
                segments: [.init(source: .me, startMs: startMs, endMs: endMs, text: "finished")],
                language: "en",
                engine: "fixture",
                modelRevision: "fixture-v1",
                degraded: degradationReason != nil,
                nowMs: endMs + 2
            )
            if let degradationReason {
                try await database.pool.write { db in
                    try db.execute(
                        sql: "UPDATE calls SET degradationReason = ? WHERE id = ?",
                        arguments: [degradationReason, id]
                    )
                }
            }
            return id
        }
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE calls SET endTs = ?, state = ?, degradationReason = ?, preferredRevisionId = ? WHERE id = ?",
                arguments: [endMs, state.rawValue, degradationReason, nil, id]
            )
        }
        return id
    }

    func insertScreen(
        timestampMs: Int64,
        bundleID: String,
        appName: String,
        relativePath: String? = nil
    ) async throws -> Int64 {
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO apps(bundleId, name) VALUES (?, ?)",
                arguments: [bundleID, appName]
            )
            let appID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO screen_captures(ts, appId, monitorId, windowTitle, relativePath)
                    VALUES (?, ?, 'main', 'Fixture', ?)
                    """,
                arguments: [timestampMs, appID, relativePath]
            )
            return db.lastInsertedRowID
        }
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}
