import Foundation
import XCTest

final class BrowserSnapshotTests: XCTestCase {
    func testStrictDecoderAcceptsVersionOneAndRejectsUnknownOrOversizedPayload() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let valid = try JSONSerialization.data(withJSONObject: validJSONObject(now: now))
        XCTAssertEqual(try BrowserSnapshotDecoder.decode(valid, now: now).combinedText, "Rendered article")

        var unknown = validJSONObject(now: now)
        unknown["unexpected"] = true
        XCTAssertThrowsError(try BrowserSnapshotDecoder.decode(
            JSONSerialization.data(withJSONObject: unknown), now: now
        ))
        XCTAssertThrowsError(try BrowserSnapshotDecoder.decode(
            Data(repeating: 0, count: BrowserSnapshotLimits.maximumPayloadBytes + 1), now: now
        ))
    }

    func testWriteOnlyTokenCannotAuthorizeReadTokenBoundary() {
        XCTAssertTrue(BrowserIngestAuthorization.allows(
            hostHeader: "127.0.0.1:8731",
            authorizationHeader: "Bearer browser-secret",
            browserToken: "browser-secret"
        ))
        XCTAssertFalse(APILocalAuthorization.allows(
            hostHeader: "127.0.0.1:8731",
            authorizationHeader: "Bearer browser-secret",
            token: "read-secret"
        ))
    }

    func testHTTPBoundaryCodesAre401202413And422() {
        XCTAssertEqual(BrowserIngestHTTPPolicy.statusCode(
            authorized: false, bodyWithinLimit: true, validPayload: true,
            capturing: true, activeFocused: true
        ), 401)
        XCTAssertEqual(BrowserIngestHTTPPolicy.statusCode(
            authorized: true, bodyWithinLimit: true, validPayload: true,
            capturing: true, activeFocused: true
        ), 202)
        XCTAssertEqual(BrowserIngestHTTPPolicy.statusCode(
            authorized: true, bodyWithinLimit: true, validPayload: true,
            capturing: false, activeFocused: true
        ), 202)
        XCTAssertEqual(BrowserIngestHTTPPolicy.statusCode(
            authorized: true, bodyWithinLimit: false, validPayload: true,
            capturing: true, activeFocused: true
        ), 413)
        XCTAssertEqual(BrowserIngestHTTPPolicy.statusCode(
            authorized: true, bodyWithinLimit: true, validPayload: false,
            capturing: true, activeFocused: true
        ), 422)
    }

    func testStoreRejectsBackgroundStaleAndMismatchedBrowserContent() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = BrowserContentStore()
        let snapshot = try decodedSnapshot(now: now)
        let accepted = await store.ingest(snapshot, now: now)
        let mismatched = await store.match(
            bundleID: "company.thebrowser.arc",
            windowTitle: "Different document — Arc",
            browserURL: nil,
            now: now
        )
        let matching = await store.match(
            bundleID: "company.thebrowser.dia",
            windowTitle: "Fixture article — Dia",
            browserURL: nil,
            now: now
        )
        let stale = await store.match(
            bundleID: "company.thebrowser.dia",
            windowTitle: "Fixture article — Dia",
            browserURL: nil,
            now: now.addingTimeInterval(BrowserSnapshotLimits.freshnessInterval + 1)
        )
        XCTAssertEqual(accepted, .accepted)
        XCTAssertNil(mismatched)
        XCTAssertEqual(matching?.text, "Rendered article")
        XCTAssertNil(stale)

        var background = validJSONObject(now: now)
        background["active"] = false
        let decoded = try BrowserSnapshotDecoder.decode(
            JSONSerialization.data(withJSONObject: background), now: now
        )
        let ignored = await store.ingest(decoded, now: now)
        XCTAssertEqual(ignored, .ignoredInactive)
    }

    func testHeartbeatRequiresSameTabDocumentURLAndHashAndClearModelsPause() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = BrowserContentStore()
        let snapshot = try decodedSnapshot(now: now)
        _ = await store.ingest(snapshot, now: now)
        let valid = heartbeat(snapshot: snapshot, now: now.addingTimeInterval(4))
        let refreshed = await store.heartbeat(valid, now: now.addingTimeInterval(4))
        XCTAssertTrue(refreshed)
        let wrongDocument = BrowserPageHeartbeat(
            schemaVersion: valid.schemaVersion,
            capturedAtMs: valid.capturedAtMs,
            browserInstanceId: valid.browserInstanceId,
            tabId: valid.tabId,
            windowId: valid.windowId,
            documentId: "other-document",
            url: valid.url,
            title: valid.title,
            contentHash: valid.contentHash,
            active: true,
            windowFocused: true
        )
        let rejected = await store.heartbeat(wrongDocument, now: now.addingTimeInterval(4))
        XCTAssertFalse(rejected)

        let later = heartbeat(snapshot: snapshot, now: now.addingTimeInterval(35))
        let laterRefreshed = await store.heartbeat(later, now: now.addingTimeInterval(35))
        XCTAssertTrue(laterRefreshed)
        let stillCurrent = await store.match(
            bundleID: "company.thebrowser.dia",
            windowTitle: "Fixture article — Dia",
            browserURL: nil,
            now: now.addingTimeInterval(36)
        )
        XCTAssertEqual(stillCurrent?.text, "Rendered article")

        await store.clear()
        let disconnected = await store.status(now: now.addingTimeInterval(4))
        XCTAssertEqual(disconnected, .disconnected)
    }

    func testStoreNeverGuessesBetweenMatchingSnapshotsFromDifferentBrowsers() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = BrowserContentStore()
        _ = await store.ingest(try decodedSnapshot(now: now), now: now)

        var secondObject = validJSONObject(now: now)
        secondObject["browserInstanceId"] = "second-browser-5678"
        secondObject["contentHash"] = String(repeating: "b", count: 64)
        let second = try BrowserSnapshotDecoder.decode(
            JSONSerialization.data(withJSONObject: secondObject), now: now
        )
        _ = await store.ingest(second, now: now.addingTimeInterval(0.1))

        let ambiguous = await store.match(
            bundleID: "com.brave.Browser",
            windowTitle: "Fixture article — Brave",
            browserURL: nil,
            now: now.addingTimeInterval(0.2)
        )
        XCTAssertNil(ambiguous)
    }

    private func decodedSnapshot(now: Date) throws -> BrowserPageSnapshot {
        try BrowserSnapshotDecoder.decode(
            JSONSerialization.data(withJSONObject: validJSONObject(now: now)), now: now
        )
    }

    private func heartbeat(snapshot: BrowserPageSnapshot, now: Date) -> BrowserPageHeartbeat {
        BrowserPageHeartbeat(
            schemaVersion: 1,
            capturedAtMs: Int64(now.timeIntervalSince1970 * 1_000),
            browserInstanceId: snapshot.browserInstanceId,
            tabId: snapshot.tabId,
            windowId: snapshot.windowId,
            documentId: snapshot.documentId,
            url: snapshot.url,
            title: snapshot.title,
            contentHash: snapshot.contentHash,
            active: true,
            windowFocused: true
        )
    }

    private func validJSONObject(now: Date) -> [String: Any] {
        [
            "schemaVersion": 1,
            "capturedAtMs": Int64(now.timeIntervalSince1970 * 1_000),
            "browserInstanceId": "fixture-browser-1234",
            "tabId": 7,
            "windowId": 3,
            "documentId": "document-1",
            "url": "https://example.com/article",
            "title": "Fixture article",
            "contentHash": String(repeating: "a", count: 64),
            "active": true,
            "windowFocused": true,
            "pixelOnly": false,
            "frames": [[
                "frameId": 0,
                "parentFrameId": NSNull(),
                "documentId": "document-1",
                "url": "https://example.com/article",
                "text": "Rendered article",
            ]],
        ]
    }
}
