import Foundation
import XCTest

final class CaptureStatusAPITests: XCTestCase {
    func testCaptureStatusAndRepairUseTheAuthenticatedLocalAPIGate() {
        XCTAssertFalse(APILocalAuthorization.allows(
            hostHeader: "127.0.0.1:8731",
            authorizationHeader: nil,
            token: "secret"
        ))
        XCTAssertFalse(APILocalAuthorization.allows(
            hostHeader: "example.com:8731",
            authorizationHeader: "Bearer secret",
            token: "secret"
        ))
        XCTAssertTrue(APILocalAuthorization.allows(
            hostHeader: "localhost:8731",
            authorizationHeader: "Bearer secret",
            token: "secret"
        ))
    }

    func testOpenAPIAdvertisesAuthenticatedStatusRepairAndCoverage() throws {
        let source = try String(
            contentsOf: repositoryRoot.appending(
                path: "ZBSEyeApp/Server/ZBSEyeHTTPServer.swift"
            ),
            encoding: .utf8
        )
        let startMarker = "static let openAPISpec = #\"\"\""
        let endMarker = "\n    \"\"\"#"
        let start = try XCTUnwrap(source.range(of: startMarker)?.upperBound)
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(source[start..<end].utf8))
                as? [String: Any]
        )
        let paths = try XCTUnwrap(object["paths"] as? [String: Any])
        let components = try XCTUnwrap(object["components"] as? [String: Any])
        let responses = try XCTUnwrap(components["responses"] as? [String: Any])
        let schemas = try XCTUnwrap(components["schemas"] as? [String: Any])

        XCTAssertNotNil(paths["/v1/capture/status"])
        XCTAssertNotNil(paths["/v1/capture/repair"])
        XCTAssertNotNil(responses["Unauthorized"])
        XCTAssertNotNil(schemas["CaptureStatus"])
        XCTAssertNotNil(schemas["CaptureCoverage"])
    }

    func testAuthenticatedStatusRoundTripsEveryStableHealthField() throws {
        let snapshot = Self.snapshot(state: .recovering)
        let coverage = CaptureCoverageDisclosure(
            availability: .available,
            intervals: [Self.gap]
        )
        let payload = CaptureStatusDTO(snapshot: snapshot, coverage: coverage)

        let decoded = try JSONDecoder().decode(
            CaptureStatusDTO.self,
            from: JSONEncoder().encode(payload)
        )

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.state, snapshot.aggregate)
        XCTAssertEqual(decoded.legs.map(\.leg), CaptureLeg.allCases)
        XCTAssertEqual(decoded.coverage.intervals, [Self.gap])
    }

    func testUnauthenticatedHealthKeepsCompatibilityAndOnlyCoarseCaptureState() throws {
        let data = try JSONEncoder().encode(APIDTO.Health(
            status: "ok",
            version: "0.4.2",
            capturing: true,
            proof: "synthetic-proof",
            captureState: CaptureAggregateState.recovering.rawValue
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["status"] as? String, "ok")
        XCTAssertEqual(object["version"] as? String, "0.4.2")
        XCTAssertEqual(object["capturing"] as? Bool, true)
        XCTAssertEqual(object["captureState"] as? String, "recovering")
        XCTAssertNil(object["legs"])
        XCTAssertNil(object["reason"])
        XCTAssertNil(object["coverage"])
    }

    func testAuthenticatedSearchAddsCoverageWithoutChangingResultsOrCount() throws {
        let hit = APIDTO.SearchHit(
            id: 9,
            kind: "screen",
            ts: 1_500,
            endTs: nil,
            tsISO: "1970-01-01T00:00:01Z",
            app: .init(bundleId: "gg.test", name: "Test"),
            windowTitle: nil,
            browserUrl: nil,
            snippet: "retained",
            media: .init(frameUrl: "/v1/frame/image?id=9")
        )
        let coverage = CaptureCoverageDisclosure(
            availability: .available,
            intervals: [Self.gap]
        )
        let payload = APIDTO.SearchResponse(
            query: "test",
            total: 1,
            limit: 25,
            offset: 0,
            semanticMode: "hybrid",
            semanticFallbackReason: nil,
            results: [hit],
            coverage: coverage
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
                as? [String: Any]
        )
        let results = try XCTUnwrap(object["results"] as? [[String: Any]])

        XCTAssertEqual((object["total"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(
            results.compactMap { ($0["id"] as? NSNumber)?.intValue },
            [9]
        )
        XCTAssertNotNil(object["coverage"])
    }

    func testFrameMetadataCarriesCoverageAtItsRequestedMoment() throws {
        let coverage = CaptureCoverageDisclosure(
            availability: .available,
            intervals: [Self.gap]
        )
        let payload = APIDTO.Frame(
            id: 9,
            ts: 1_500,
            tsISO: "1970-01-01T00:00:01Z",
            app: .init(bundleId: "gg.test", name: "Test"),
            windowTitle: nil,
            browserUrl: nil,
            axQuality: "good",
            text: "retained",
            media: .init(frameUrl: "/v1/frame/image?id=9"),
            coverage: coverage
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
                as? [String: Any]
        )
        let encodedCoverage = try XCTUnwrap(object["coverage"] as? [String: Any])
        let intervals = try XCTUnwrap(encodedCoverage["intervals"] as? [[String: Any]])

        XCTAssertEqual(encodedCoverage["availability"] as? String, "available")
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals.first?["episodeID"] as? String, Self.gap.episodeID)
    }

    func testLegacyClientsIgnoreAdditiveHealthAndSearchFields() throws {
        struct LegacyHealth: Decodable, Equatable {
            let status: String
            let version: String
            let capturing: Bool
            let proof: String?
        }
        struct LegacySearchHit: Decodable, Equatable {
            let id: Int64
            let snippet: String
        }
        struct LegacySearchResponse: Decodable, Equatable {
            let query: String
            let total: Int
            let results: [LegacySearchHit]
        }

        let health = APIDTO.Health(
            status: "ok",
            version: "0.4.2",
            capturing: true,
            proof: "proof",
            captureState: CaptureAggregateState.recovering.rawValue
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                LegacyHealth.self,
                from: JSONEncoder().encode(health)
            ),
            LegacyHealth(
                status: "ok",
                version: "0.4.2",
                capturing: true,
                proof: "proof"
            )
        )

        let hit = APIDTO.SearchHit(
            id: 9,
            kind: "screen",
            ts: 1_500,
            endTs: nil,
            tsISO: "1970-01-01T00:00:01Z",
            app: .init(bundleId: "gg.test", name: "Test"),
            windowTitle: nil,
            browserUrl: nil,
            snippet: "retained",
            media: .init(frameUrl: "/v1/frame/image?id=9")
        )
        let search = APIDTO.SearchResponse(
            query: "test",
            total: 1,
            limit: 25,
            offset: 0,
            semanticMode: "hybrid",
            semanticFallbackReason: nil,
            results: [hit],
            coverage: .metadataUnavailable
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                LegacySearchResponse.self,
                from: JSONEncoder().encode(search)
            ),
            LegacySearchResponse(
                query: "test",
                total: 1,
                results: [.init(id: 9, snippet: "retained")]
            )
        )
    }

    private static let gap = CaptureCoverageInterval(
        id: 4,
        leg: .screen,
        reason: .screenRequestFailed,
        episodeID: "synthetic",
        generation: 3,
        startMs: 1_000,
        endMs: 2_000,
        closeCause: .verifiedProgress
    )

    private static func snapshot(state: CaptureLegState) -> CaptureHealthSnapshot {
        let health = CaptureLegHealth(
            state: state,
            reason: .screenRequestFailed,
            generation: 3,
            attempt: 2,
            stateSinceMs: 1_000,
            lastCycleAtMs: 1_500,
            lastVerifiedProgressAtMs: 900
        )
        return CaptureHealthSnapshot(
            intent: .init(screenEnabled: true, systemAudioEnabled: true),
            permissions: [.screen: .granted, .systemAudio: .granted],
            suspension: nil,
            legs: [.screen: health, .systemAudio: health],
            aggregate: .recovering
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
