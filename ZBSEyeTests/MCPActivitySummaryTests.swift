import Foundation
import XCTest

final class MCPActivitySummaryTests: XCTestCase {
    func testRequestParsesTimezoneAwareISOAndEpochWithBoundedLimits() throws {
        let iso = try MCPActivitySummaryRequest.parse(
            from: "2026-07-15T08:00:00+07:00",
            to: "2026-07-15T09:30:00.250+07:00",
            limit: nil,
            cursor: nil
        )
        XCTAssertEqual(iso.fromMs, 1_784_077_200_000)
        XCTAssertEqual(iso.toMs, 1_784_082_600_250)
        XCTAssertEqual(iso.limit, 12)

        let epoch = try MCPActivitySummaryRequest.parse(
            from: "1784077200000",
            to: "1784082600250",
            limit: 999,
            cursor: nil
        )
        XCTAssertEqual(epoch.fromMs, iso.fromMs)
        XCTAssertEqual(epoch.toMs, iso.toMs)
        XCTAssertEqual(epoch.limit, 24)
    }

    func testRequestRejectsMissingTimezoneInvalidRangeAndNonpositiveLimit() {
        XCTAssertThrowsError(try MCPActivitySummaryRequest.parse(
            from: "2026-07-15T08:00:00",
            to: "2026-07-15T09:00:00+07:00",
            limit: nil,
            cursor: nil
        ))
        XCTAssertThrowsError(try MCPActivitySummaryRequest.parse(
            from: "2000",
            to: "1000",
            limit: nil,
            cursor: nil
        ))
        XCTAssertThrowsError(try MCPActivitySummaryRequest.parse(
            from: "1000",
            to: "2000",
            limit: 0,
            cursor: nil
        ))
    }

    func testActivityLabelsRedactPathsSecretsEmailsAndFullURLs() {
        let titles = [
            "/Users/example/private.swift",
            "src/private/private.swift",
            #"C:\Users\example\private.swift"#,
            "file:///Users/example/private.swift",
            "Проекты/Глаз/секретный файл.md",
            "设计/私密 文件.md",
            "📁 work/secret file.md",
            "Deploy token=super-secret",
            "Deploy refresh_token=refresh-secret",
            "Deploy client_secret=client-secret",
            "Deploy ID_TOKEN=id-secret",
            "Contact nik@example.com",
            "Visit https://github.com/zbs-gg/eye?token=secret",
        ]
        let rendered = titles.compactMap {
            MCPActivitySummaryLabel.safeTopic(
                appName: "Xcode",
                bundleID: "com.apple.dt.Xcode",
                windowTitle: $0,
                browserURL: nil
            )
        }.joined(separator: " ")

        for forbidden in [
            "/Users/", "src/private", #"C:\Users"#, "file://",
            "секретный файл", "私密 文件", "secret file",
            "super-secret", "refresh-secret", "client-secret", "id-secret",
            "nik@example.com", "https://", "token=secret",
        ] {
            XCTAssertFalse(rendered.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
        XCTAssertTrue(rendered.contains("[path]"))
        XCTAssertTrue(rendered.contains("[secret]"))
        XCTAssertTrue(rendered.contains("[private]"))
        XCTAssertTrue(rendered.contains("github.com"))
    }

    func testEmptyHistoryIsAWellFormedSuccessfulEnvelope() async throws {
        let provider = ActivitySummaryCaptureFixture([])
        let service = makeService(provider: provider)

        let json = try await service.render(request(from: 1_000, to: 2_000))
        let object = try jsonObject(json)

        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["capture_count"] as? Int, 0)
        XCTAssertEqual(object["truncated"] as? Bool, false)
        XCTAssertTrue(object["observed_range"] is NSNull)
        XCTAssertTrue(object["newest_capture_at"] is NSNull)
        XCTAssertTrue(object["next_cursor"] is NSNull)
        XCTAssertEqual((object["sessions"] as? [Any])?.count, 0)
        XCTAssertEqual((object["top_apps"] as? [Any])?.count, 0)
    }

    func testEnvelopeIsVersionedSystemFilteredOrderedAndPrivacyBounded() async throws {
        let provider = ActivitySummaryCaptureFixture(Self.captures)
        let service = makeService(provider: provider)

        let json = try await service.render(request(from: 0, to: 2_000_000, limit: 12))
        let object = try jsonObject(json)
        let server = try XCTUnwrap(object["server"] as? [String: Any])
        XCTAssertEqual(server["name"] as? String, "zbseye")
        XCTAssertEqual(server["version"] as? String, "0.6.0")
        XCTAssertEqual(server["profile"] as? String, "memoryReadOnly")
        XCTAssertEqual(object["capture_count"] as? Int, 5)

        let requested = try XCTUnwrap(object["requested_range"] as? [String: Any])
        XCTAssertEqual(requested["from_ms"] as? Int, 0)
        XCTAssertEqual(requested["to_ms"] as? Int, 2_000_000)
        XCTAssertEqual(requested["from_iso"] as? String, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(requested["to_iso"] as? String, "1970-01-01T00:33:20.000Z")

        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.map { $0["representative_frame_id"] as? Int }, [2, 6])
        XCTAssertEqual(sessions.map { $0["frame_count"] as? Int }, [3, 2])
        XCTAssertEqual(sessions.map { $0["top_apps"] as? [String] }, [["Xcode"], ["Safari"]])
        XCTAssertTrue((sessions[0]["label"] as? String)?.hasPrefix("Xcode") == true)
        XCTAssertEqual(sessions[1]["label"] as? String, "Safari · github.com")

        let topApps = try XCTUnwrap(object["top_apps"] as? [[String: Any]])
        XCTAssertEqual(topApps.map { $0["name"] as? String }, ["Xcode", "Safari"])
        XCTAssertEqual(topApps.map { $0["frame_count"] as? Int }, [3, 2])

        for forbidden in [
            "loginwindow", "Screen Saver", "https://", "token=secret",
            "/Users/example/private.swift", "transcript-canary", "relativePath",
        ] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
    }

    func testTopAppsAreIndependentlyBoundedAndDeterministicallyRanked() async throws {
        var captures: [CaptureLite] = []
        for index in 0..<30 {
            captures.append(CaptureLite(
                id: Int64(index + 1),
                ts: Int64(index * 1_000),
                appId: Int64(index + 1),
                appName: String(format: "App%02d", index),
                bundleId: String(format: "com.example.app%02d", index),
                windowTitle: nil,
                browserUrl: nil
            ))
        }
        let service = makeService(provider: ActivitySummaryCaptureFixture(captures))

        let object = try jsonObject(await service.render(
            request(from: 0, to: 1_000_000, limit: 24)
        ))
        let topApps = try XCTUnwrap(object["top_apps"] as? [[String: Any]])

        XCTAssertEqual(topApps.count, 12)
        XCTAssertEqual(
            topApps.compactMap { $0["name"] as? String },
            (0..<12).map { String(format: "App%02d", $0) }
        )
    }

    func testCursorPinsSnapshotAndRejectsTamperingOrCrossQueryReuse() async throws {
        let provider = ActivitySummaryCaptureFixture(Self.captures)
        let service = makeService(provider: provider)
        let firstRequest = request(from: 0, to: 2_000_000, limit: 1)

        let first = try jsonObject(await service.render(firstRequest))
        XCTAssertEqual(first["truncated"] as? Bool, true)
        let firstSessions = try XCTUnwrap(first["sessions"] as? [[String: Any]])
        XCTAssertEqual(firstSessions.first?["representative_frame_id"] as? Int, 2)
        let cursor = try XCTUnwrap(first["next_cursor"] as? String)

        await provider.append(CaptureLite(
            id: 99,
            ts: 1_500_000,
            appId: 99,
            appName: "Injected Later",
            bundleId: "com.example.injected",
            windowTitle: "Late backfill",
            browserUrl: nil
        ))

        let second = try jsonObject(await service.render(
            request(from: 0, to: 2_000_000, cursor: cursor)
        ))
        let secondSessions = try XCTUnwrap(second["sessions"] as? [[String: Any]])
        XCTAssertEqual(secondSessions.first?["representative_frame_id"] as? Int, 6)
        XCTAssertEqual(second["truncated"] as? Bool, false)
        let secondJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: second),
            as: UTF8.self
        )
        XCTAssertFalse(secondJSON.contains("Injected Later"))

        await provider.remove(id: 1)
        let retentionError = await XCTCaptureErrorAsync {
            _ = try await service.render(
                self.request(from: 0, to: 2_000_000, limit: 1, cursor: cursor)
            )
        }
        XCTAssertEqual(retentionError as? MCPActivitySummaryError, .invalidCursor)

        let tamperIndex = cursor.index(cursor.startIndex, offsetBy: cursor.count / 3)
        let replacement: Character = cursor[tamperIndex] == "A" ? "B" : "A"
        var forged = cursor
        forged.replaceSubrange(tamperIndex...tamperIndex, with: String(replacement))
        let readsBeforeInvalidCursors = await provider.readCount()
        let forgedCursorError = await XCTCaptureErrorAsync {
            _ = try await service.render(
                self.request(from: 0, to: 2_000_000, limit: 1, cursor: forged)
            )
        }
        XCTAssertEqual(forgedCursorError as? MCPActivitySummaryError, .invalidCursor)
        let crossQueryCursorError = await XCTCaptureErrorAsync {
            _ = try await service.render(
                self.request(from: 0, to: 2_000_001, limit: 1, cursor: cursor)
            )
        }
        XCTAssertEqual(crossQueryCursorError as? MCPActivitySummaryError, .invalidCursor)
        let readsAfterInvalidCursors = await provider.readCount()
        XCTAssertEqual(readsAfterInvalidCursors, readsBeforeInvalidCursors)
    }

    func testBroadRangeFailsBeforeMaterializingBeyondCaptureCap() async {
        let provider = ActivitySummaryCaptureFixture(Array(Self.captures.prefix(3)))
        let service = makeService(provider: provider, maximumCaptures: 2)

        let error = await XCTCaptureErrorAsync {
            _ = try await service.render(self.request(from: 0, to: 2_000_000))
        }
        XCTAssertEqual(error as? MCPActivitySummaryError, .captureLimitExceeded)
        let requestedLimit = await provider.lastRequestedLimit()
        XCTAssertEqual(requestedLimit, 3)
    }

    func testProviderReadFailureIsThrownInsteadOfRenderedAsEmptyHistory() async {
        let service = makeService(provider: FailingActivitySummaryCaptureProvider())

        let error = await XCTCaptureErrorAsync {
            _ = try await service.render(self.request(from: 1_000, to: 2_000))
        }
        XCTAssertEqual(
            error as? FailingActivitySummaryCaptureProvider.FixtureError,
            .readFailed
        )
    }

    private func makeService(
        provider: any MCPActivitySummaryCaptureProviding,
        maximumCaptures: Int = 50_000
    ) -> MCPActivitySummaryService {
        MCPActivitySummaryService(
            provider: provider,
            profile: .memoryReadOnly,
            serverVersion: "0.6.0",
            cursorSecret: Data(repeating: 0x5A, count: 32),
            maximumCaptures: maximumCaptures
        )
    }

    private func request(
        from: Int64,
        to: Int64,
        limit: Int? = nil,
        cursor: String? = nil
    ) -> MCPActivitySummaryRequest {
        try! MCPActivitySummaryRequest.parse(
            from: String(from),
            to: String(to),
            limit: limit,
            cursor: cursor
        )
    }

    private func jsonObject(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
    }

    private static let captures: [CaptureLite] = [
        CaptureLite(
            id: 1, ts: 1_000, appId: 1, appName: "Xcode",
            bundleId: "com.apple.dt.Xcode", windowTitle: "/Users/example/private.swift",
            browserUrl: nil
        ),
        CaptureLite(
            id: 2, ts: 2_000, appId: 1, appName: "Xcode",
            bundleId: "com.apple.dt.Xcode", windowTitle: "/Users/example/private.swift",
            browserUrl: nil
        ),
        CaptureLite(
            id: 3, ts: 3_000, appId: 1, appName: "Xcode",
            bundleId: "com.apple.dt.Xcode", windowTitle: "transcript-canary",
            browserUrl: nil
        ),
        CaptureLite(
            id: 4, ts: 4_000, appId: 4, appName: "Screen Saver",
            bundleId: "com.apple.loginwindow", windowTitle: "loginwindow",
            browserUrl: nil
        ),
        CaptureLite(
            id: 5, ts: 1_000_000, appId: 2, appName: "Safari",
            bundleId: "com.apple.Safari", windowTitle: "GitHub",
            browserUrl: "https://github.com/zbs-gg/eye?token=secret"
        ),
        CaptureLite(
            id: 6, ts: 1_001_000, appId: 2, appName: "Safari",
            bundleId: "com.apple.Safari", windowTitle: "GitHub",
            browserUrl: "https://github.com/zbs-gg/eye?token=secret"
        ),
    ]
}

private actor ActivitySummaryCaptureFixture: MCPActivitySummaryCaptureProviding {
    private var values: [CaptureLite]
    private var rangeReadCount = 0
    private var requestedLimit: Int?

    init(_ values: [CaptureLite]) {
        self.values = values
    }

    func captures(
        fromMs: Int64,
        toMs: Int64,
        snapshotMaxCaptureID: Int64,
        limit: Int
    ) async throws -> [CaptureLite] {
        rangeReadCount += 1
        requestedLimit = limit
        return Array(values
            .filter {
                $0.ts >= fromMs && $0.ts <= toMs && $0.id <= snapshotMaxCaptureID
            }
            .sorted { ($0.ts, $0.id) < ($1.ts, $1.id) }
            .prefix(limit))
    }

    func append(_ capture: CaptureLite) {
        values.append(capture)
    }

    func remove(id: Int64) {
        values.removeAll { $0.id == id }
    }

    func readCount() -> Int { rangeReadCount }

    func lastRequestedLimit() -> Int? { requestedLimit }
}

private struct FailingActivitySummaryCaptureProvider: MCPActivitySummaryCaptureProviding {
    enum FixtureError: Error, Equatable { case readFailed }

    func captures(
        fromMs: Int64,
        toMs: Int64,
        snapshotMaxCaptureID: Int64,
        limit: Int
    ) async throws -> [CaptureLite] {
        throw FixtureError.readFailed
    }
}

private func XCTCaptureErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async -> (any Error)? {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
        return nil
    } catch {
        return error
    }
}
