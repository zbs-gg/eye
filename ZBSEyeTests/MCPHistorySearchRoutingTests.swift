import XCTest

final class MCPHistorySearchRoutingTests: XCTestCase {
    func testCrossLanguageQueryUsesAuthenticatedGUIHybridPathWithoutFallback() async throws {
        let requestProbe = MCPRequestProbe()
        let fallbackCalls = MCPCallCounter()
        let response = Data(#"""
        {
          "query": "где обсуждали бюджет",
          "total": 1,
          "limit": 25,
          "offset": 0,
          "semanticMode": "hybrid",
          "semanticFallbackReason": null,
          "results": [{
            "id": 41,
            "kind": "screen",
            "ts": 1752300000000,
            "tsISO": "2025-07-12T07:20:00Z",
            "app": {"bundleId": "com.apple.Safari", "name": "Safari"},
            "windowTitle": "Planning",
            "browserUrl": "https://example.invalid/plan",
            "snippet": "We discussed the launch budget and runway.",
            "media": {"frameUrl": "/v1/frame/image?id=41"}
          }]
        }
        """#.utf8)
        let client = MCPGUIHistorySearchClient { request in
            await requestProbe.record(request)
            return MCPGUIHistorySearchHTTPResponse(statusCode: 200, data: response)
        }
        let coordinator = MCPHistorySearchCoordinator(
            guiSearch: { query, filters in
                try await client.search(
                    port: 8_731,
                    token: "test-token",
                    query: query,
                    filters: filters
                )
            },
            fallbackSearch: { _, _ in
                await fallbackCalls.increment()
                return SearchExecution(
                    results: [],
                    semanticMode: .ftsOnly(.secondaryProcess)
                )
            }
        )

        let result = try await coordinator.search(
            query: "где обсуждали бюджет",
            filters: SearchFilters(app: "Safari", kind: .screen, limit: 25)
        )

        XCTAssertEqual(result.source, .guiHybrid)
        XCTAssertEqual(result.semanticMode, .hybrid)
        XCTAssertEqual(result.results.map(\.id), [41])
        XCTAssertEqual(result.results.first?.snippet, "We discussed the launch budget and runway.")
        let fallbackCount = await fallbackCalls.value()
        XCTAssertEqual(fallbackCount, 0)

        let recordedRequest = await requestProbe.value()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/search")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let queryItems = Dictionary(uniqueKeysWithValues: (query.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(queryItems["q"], "где обсуждали бюджет")
        XCTAssertEqual(queryItems["app"], "Safari")
        XCTAssertEqual(queryItems["kind"], "screen")
        XCTAssertEqual(queryItems["limit"], "25")
        XCTAssertEqual(queryItems["offset"], "0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testAbsentGUIUsesFTSOnlyHelperFallback() async throws {
        let guiCalls = MCPCallCounter()
        let fallbackCalls = MCPCallCounter()
        let fallbackHit = SearchResult(
            id: 7,
            kind: .audio,
            ts: Date(timeIntervalSince1970: 1_752_300_000),
            bundleId: nil,
            appName: nil,
            windowTitle: nil,
            browserURL: nil,
            snippet: "exact phrase",
            relativePath: nil
        )
        let coordinator = MCPHistorySearchCoordinator(
            guiSearch: { _, _ in
                await guiCalls.increment()
                return nil
            },
            fallbackSearch: { _, _ in
                await fallbackCalls.increment()
                return SearchExecution(
                    results: [fallbackHit],
                    semanticMode: .ftsOnly(.secondaryProcess)
                )
            }
        )

        let result = try await coordinator.search(
            query: "exact phrase",
            filters: SearchFilters(kind: .audio, limit: 10)
        )

        XCTAssertEqual(result.source, .helperFTS)
        XCTAssertEqual(result.semanticMode, .ftsOnly(.secondaryProcess))
        XCTAssertEqual(result.results.map(\.id), [7])
        let guiCount = await guiCalls.value()
        let fallbackCount = await fallbackCalls.value()
        XCTAssertEqual(guiCount, 1)
        XCTAssertEqual(fallbackCount, 1)
    }

    func testHealthyGUIErrorDoesNotSilentlyDowngradeToHelperFTS() async throws {
        let fallbackCalls = MCPCallCounter()
        let client = MCPGUIHistorySearchClient { _ in
            MCPGUIHistorySearchHTTPResponse(statusCode: 500, data: Data())
        }
        let coordinator = MCPHistorySearchCoordinator(
            guiSearch: { query, filters in
                try await client.search(
                    port: 8_731,
                    token: "test-token",
                    query: query,
                    filters: filters
                )
            },
            fallbackSearch: { _, _ in
                await fallbackCalls.increment()
                return SearchExecution(
                    results: [],
                    semanticMode: .ftsOnly(.secondaryProcess)
                )
            }
        )

        do {
            _ = try await coordinator.search(
                query: "budget",
                filters: SearchFilters(limit: 25)
            )
            XCTFail("expected the healthy GUI search failure to remain visible")
        } catch {
            XCTAssertEqual(error as? MCPHistorySearchRoutingError, .httpStatus(500))
        }
        let fallbackCount = await fallbackCalls.value()
        XCTAssertEqual(fallbackCount, 0)
    }

    func testHealthyGUIDisclosesFTSOnlyFallbackReason() async throws {
        let response = Data(#"""
        {
          "query": "budget",
          "total": 0,
          "limit": 25,
          "offset": 0,
          "semanticMode": "ftsOnly",
          "semanticFallbackReason": "localGeneration",
          "results": []
        }
        """#.utf8)
        let client = MCPGUIHistorySearchClient { _ in
            MCPGUIHistorySearchHTTPResponse(statusCode: 200, data: response)
        }

        let execution = try await client.search(
            port: 8_731,
            token: "test-token",
            query: "budget",
            filters: SearchFilters(limit: 25)
        )

        XCTAssertEqual(execution.semanticMode, .ftsOnly(.localGeneration))
        XCTAssertTrue(execution.results.isEmpty)
    }

    func testLocalPeerProofRejectsForgedHealthResponse() throws {
        let challenge = String(repeating: "a", count: 64)
        let proof = try XCTUnwrap(
            LocalPeerAuthenticator.proof(
                token: "real-token",
                challenge: challenge,
                listeningPort: 8_731
            )
        )

        XCTAssertTrue(
            LocalPeerAuthenticator.verify(
                proof: proof,
                token: "real-token",
                challenge: challenge,
                listeningPort: 8_731
            )
        )
        XCTAssertFalse(
            LocalPeerAuthenticator.verify(
                proof: proof,
                token: "impostor-token",
                challenge: challenge,
                listeningPort: 8_731
            )
        )
        XCTAssertFalse(
            LocalPeerAuthenticator.verify(
                proof: proof,
                token: "real-token",
                challenge: challenge,
                listeningPort: 8_732
            ),
            "a relayed proof from the genuine app must not authenticate a fake port"
        )
        XCTAssertNil(
            LocalPeerAuthenticator.proof(
                token: "real-token",
                challenge: "too-short",
                listeningPort: 8_731
            )
        )
    }
}

private actor MCPRequestProbe {
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        self.request = request
    }

    func value() -> URLRequest? {
        request
    }
}

private actor MCPCallCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
