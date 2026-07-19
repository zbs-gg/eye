import Foundation
import XCTest

@MainActor
final class CallsStoreTests: XCTestCase {
    func testReloadShowsNewestCallsAndKeepsTheSearchQuery() async {
        let service = CallsListingFixture(pages: [
            .init(query: "Olga", limit: 25, offset: 0, hasMore: false, nextOffset: nil, calls: [
                Self.summary(id: 8, start: 8_000, title: "Visa call"),
                Self.summary(id: 7, start: 7_000, title: "Follow-up"),
            ]),
        ])
        let store = CallsStore(service: service)
        store.query = "Olga"

        await store.reload()

        XCTAssertEqual(store.calls.map(\.callId), ["call:8", "call:7"])
        XCTAssertEqual(store.query, "Olga")
        XCTAssertEqual(store.phase, .ready)
        XCTAssertFalse(store.hasMore)
    }

    func testLoadMoreAppendsWithoutDuplicatesAndOpensTheExistingCallID() async {
        let duplicate = Self.summary(id: 2, start: 2_000, title: "Second")
        let service = CallsListingFixture(pages: [
            .init(query: nil, limit: 25, offset: 0, hasMore: true, nextOffset: 2, calls: [
                Self.summary(id: 3, start: 3_000, title: "Third"),
                duplicate,
            ]),
            .init(query: nil, limit: 25, offset: 2, hasMore: false, nextOffset: nil, calls: [
                duplicate,
                Self.summary(id: 1, start: 1_000, title: "First"),
            ]),
        ])
        let store = CallsStore(service: service)

        await store.reload()
        await store.loadMore()
        store.open(store.calls[1])

        XCTAssertEqual(store.calls.map(\.callId), ["call:3", "call:2", "call:1"])
        XCTAssertEqual(store.selectedCallID, 2)
        XCTAssertFalse(store.hasMore)
        let offsets = await service.offsets()
        XCTAssertEqual(offsets, [0, 2])
    }

    func testLaterSearchWinsWhenAnOlderRequestFinishesLast() async {
        let service = DelayedCallsListingFixture()
        let store = CallsStore(service: service)
        store.query = "old"
        let old = Task { await store.reload() }
        try? await Task.sleep(for: .milliseconds(10))

        store.query = "new"
        await store.reload()
        await old.value

        XCTAssertEqual(store.calls.map(\.callId), ["call:2"])
        XCTAssertEqual(store.query, "new")
        XCTAssertEqual(store.phase, .ready)
    }

    func testFailureIsTruthfulAndRetryable() async {
        let store = CallsStore(service: FailingCallsListingFixture())

        await store.reload()

        guard case .failed(let message) = store.phase else {
            return XCTFail("Expected a failed state")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(store.calls.isEmpty)
    }

    private static func summary(
        id: Int64,
        start: Int64,
        title: String
    ) -> CallEvidenceSummary {
        CallEvidenceSummary(
            callId: "call:\(id)",
            startTs: start,
            endTs: start + 60_000,
            state: .ready,
            status: .ready,
            retryable: false,
            preferredRevisionKind: .final,
            title: title,
            participants: ["Olga"],
            sourceApp: "Telegram",
            bookmarkCount: 1,
            speakerStatus: .ready
        )
    }
}

private actor CallsListingFixture: CallLibraryQuerying {
    private var pages: [CallEvidenceListPage]
    private var requestedOffsets: [Int] = []

    init(pages: [CallEvidenceListPage]) {
        self.pages = pages
    }

    func listCalls(query: String?, limit: Int, offset: Int) async throws -> CallEvidenceListPage {
        requestedOffsets.append(offset)
        return pages.removeFirst()
    }

    func offsets() -> [Int] { requestedOffsets }
}

private actor DelayedCallsListingFixture: CallLibraryQuerying {
    func listCalls(query: String?, limit: Int, offset: Int) async throws -> CallEvidenceListPage {
        if query == "old" {
            try await Task.sleep(for: .milliseconds(120))
            return page(id: 1, query: query)
        }
        try await Task.sleep(for: .milliseconds(1))
        return page(id: 2, query: query)
    }

    private func page(id: Int64, query: String?) -> CallEvidenceListPage {
        .init(
            query: query,
            limit: 25,
            offset: 0,
            hasMore: false,
            nextOffset: nil,
            calls: [.init(
                callId: "call:\(id)",
                startTs: id * 1_000,
                endTs: id * 1_000 + 60_000,
                state: .ready,
                status: .ready,
                retryable: false,
                preferredRevisionKind: .final,
                title: query,
                participants: [],
                sourceApp: nil,
                bookmarkCount: 0,
                speakerStatus: .ready
            )]
        )
    }
}

private actor FailingCallsListingFixture: CallLibraryQuerying {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Database unavailable" }
    }

    func listCalls(query: String?, limit: Int, offset: Int) async throws -> CallEvidenceListPage {
        throw Failure()
    }
}
