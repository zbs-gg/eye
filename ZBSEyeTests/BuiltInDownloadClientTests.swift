import Darwin
import Foundation
import XCTest

final class BuiltInDownloadClientTests: XCTestCase {
    private let sourceURL = URL(string: "https://assets.example/model.bin")!

    func testFreshDownloadStreamsExactBytesWithHardenedRequestAndFileMode() async throws {
        let fixture = try Fixture(expectedBytes: 100)
        let transport = ScriptedDownloadTransport([
            .response(
                url: sourceURL,
                status: 200,
                headers: Self.fullHeaders(length: 100, etag: #""v1""#),
                chunks: [Self.bytes(30, value: 1), Self.bytes(70, value: 2)]
            ),
        ])
        let client = makeClient(transport: transport)

        let outcome = try await client.download(plan: fixture.plan(sourceURL: sourceURL))

        guard case .completed(let state) = outcome else {
            return XCTFail("expected completed, got \(outcome)")
        }
        XCTAssertEqual(state.receivedBytes, 100)
        XCTAssertEqual(state.strongETag, #""v1""#)
        XCTAssertEqual(try Self.fileSize(fixture.partialURL), 100)
        XCTAssertEqual(try Self.fileMode(fixture.partialURL), 0o600)

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].headers["Accept-Encoding"], "identity")
        XCTAssertNil(requests[0].headers["Range"])
        XCTAssertNil(requests[0].headers["If-Range"])
        Self.assertNoAmbientCredentials(requests[0])
    }

    func testResumeAtTenFiftyAndNinetyPercentUsesExactRangeAndIfRange() async throws {
        for offset in [Int64(10), 50, 90] {
            let fixture = try Fixture(expectedBytes: 100)
            try Self.bytes(Int(offset), value: 7).write(to: fixture.partialURL)
            let resume = fixture.resumeState(
                sourceURL: sourceURL,
                receivedBytes: offset,
                etag: #""stable""#
            )
            let transport = ScriptedDownloadTransport([
                .response(
                    url: sourceURL,
                    status: 206,
                    headers: Self.rangeHeaders(
                        start: offset,
                        end: 99,
                        total: 100,
                        etag: #""stable""#
                    ),
                    chunks: [Self.bytes(Int(100 - offset), value: 8)]
                ),
            ])
            let client = makeClient(transport: transport)

            let outcome = try await client.download(
                plan: fixture.plan(sourceURL: sourceURL),
                resumeState: resume
            )

            guard case .completed(let state) = outcome else {
                return XCTFail("offset \(offset): expected completion")
            }
            XCTAssertEqual(state.receivedBytes, 100)
            XCTAssertEqual(try Self.fileSize(fixture.partialURL), 100)
            let captured = await transport.capturedRequests()
            let request = try XCTUnwrap(captured.first)
            XCTAssertEqual(request.headers["Range"], "bytes=\(offset)-")
            XCTAssertEqual(request.headers["If-Range"], #""stable""#)
        }
    }

    func testMismatchedResponseETagDiscardsPartialAndRestartsFresh() async throws {
        let fixture = try Fixture(expectedBytes: 100)
        try Self.bytes(50, value: 3).write(to: fixture.partialURL)
        let transport = ScriptedDownloadTransport([
            .response(
                url: sourceURL,
                status: 206,
                headers: Self.rangeHeaders(start: 50, end: 99, total: 100, etag: #""changed""#),
                chunks: []
            ),
            .response(
                url: sourceURL,
                status: 200,
                headers: Self.fullHeaders(length: 100, etag: #""changed""#),
                chunks: [Self.bytes(100, value: 9)]
            ),
        ])
        let client = makeClient(transport: transport)

        let outcome = try await client.download(
            plan: fixture.plan(sourceURL: sourceURL),
            resumeState: fixture.resumeState(
                sourceURL: sourceURL,
                receivedBytes: 50,
                etag: #""old""#
            )
        )

        guard case .completed(let state) = outcome else { return XCTFail("expected completion") }
        XCTAssertEqual(state.strongETag, #""changed""#)
        XCTAssertEqual(try Data(contentsOf: fixture.partialURL), Self.bytes(100, value: 9))
        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map { $0.headers["Range"] }, ["bytes=50-", nil])
    }

    func testStaleResumeIdentityOrDiskLengthRestartsWithoutRange() async throws {
        enum Mutation: CaseIterable { case url, revision, fingerprint, expectedLength, diskLength }

        for mutation in Mutation.allCases {
            let fixture = try Fixture(expectedBytes: 100)
            try Self.bytes(mutation == .diskLength ? 49 : 50, value: 4).write(to: fixture.partialURL)
            var state = fixture.resumeState(
                sourceURL: sourceURL,
                receivedBytes: 50,
                etag: #""stable""#
            )
            switch mutation {
            case .url:
                state.sourceURL = URL(string: "https://assets.example/other.bin")!
            case .revision:
                state.revision = "other-revision"
            case .fingerprint:
                state.manifestFingerprintSHA256 = "other-fingerprint"
            case .expectedLength:
                state.expectedBytes = 101
            case .diskLength:
                break
            }
            let transport = ScriptedDownloadTransport([
                .response(
                    url: sourceURL,
                    status: 200,
                    headers: Self.fullHeaders(length: 100, etag: #""stable""#),
                    chunks: [Self.bytes(100, value: 5)]
                ),
            ])
            let client = makeClient(transport: transport)

            _ = try await client.download(
                plan: fixture.plan(sourceURL: sourceURL),
                resumeState: state
            )

            let captured = await transport.capturedRequests()
            let request = try XCTUnwrap(captured.first)
            XCTAssertNil(request.headers["Range"], "mutation \(mutation)")
            XCTAssertEqual(try Data(contentsOf: fixture.partialURL), Self.bytes(100, value: 5))
        }
    }

    func testIgnoredRangeRestartsUsingTheSameFullResponse() async throws {
        let fixture = try Fixture(expectedBytes: 100)
        try Self.bytes(50, value: 1).write(to: fixture.partialURL)
        let transport = ScriptedDownloadTransport([
            .response(
                url: sourceURL,
                status: 200,
                headers: Self.fullHeaders(length: 100, etag: #""v2""#),
                chunks: [Self.bytes(100, value: 6)]
            ),
        ])
        let client = makeClient(transport: transport)

        _ = try await client.download(
            plan: fixture.plan(sourceURL: sourceURL),
            resumeState: fixture.resumeState(
                sourceURL: sourceURL,
                receivedBytes: 50,
                etag: #""v1""#
            )
        )

        XCTAssertEqual(try Data(contentsOf: fixture.partialURL), Self.bytes(100, value: 6))
        let captured = await transport.capturedRequests()
        XCTAssertEqual(captured.count, 1)
    }

    func testOverlappingAndShortRangeResponsesFailBeforeAppending() async throws {
        for headers in [
            Self.rangeHeaders(start: 49, end: 99, total: 100, etag: #""v1""#),
            Self.rangeHeaders(start: 50, end: 89, total: 100, etag: #""v1""#),
        ] {
            let fixture = try Fixture(expectedBytes: 100)
            let original = Self.bytes(50, value: 7)
            try original.write(to: fixture.partialURL)
            let transport = ScriptedDownloadTransport([
                .response(url: sourceURL, status: 206, headers: headers, chunks: []),
            ])
            let client = makeClient(transport: transport)

            do {
                _ = try await client.download(
                    plan: fixture.plan(sourceURL: sourceURL),
                    resumeState: fixture.resumeState(
                        sourceURL: sourceURL,
                        receivedBytes: 50,
                        etag: #""v1""#
                    )
                )
                XCTFail("expected invalid range")
            } catch {
                XCTAssertEqual(error as? BuiltInDownloadError, .invalidContentRange)
            }
            XCTAssertEqual(try Data(contentsOf: fixture.partialURL), original)
        }
    }

    func testWrongLengthOverrunAndCompressedResponsesFailClosed() async throws {
        do {
            let fixture = try Fixture(expectedBytes: 100)
            let transport = ScriptedDownloadTransport([
                .response(
                    url: sourceURL,
                    status: 200,
                    headers: Self.fullHeaders(length: 99, etag: #""v1""#),
                    chunks: []
                ),
            ])
            let client = makeClient(transport: transport)
            _ = try await client.download(plan: fixture.plan(sourceURL: sourceURL))
            XCTFail("expected wrong length")
        } catch {
            guard case .invalidContentLength = error as? BuiltInDownloadError else {
                return XCTFail("unexpected \(error)")
            }
        }

        do {
            let fixture = try Fixture(expectedBytes: 100)
            let transport = ScriptedDownloadTransport([
                .response(
                    url: sourceURL,
                    status: 200,
                    headers: Self.fullHeaders(length: 100, etag: #""v1""#),
                    chunks: [Self.bytes(60, value: 1), Self.bytes(41, value: 2)]
                ),
            ])
            let client = makeClient(transport: transport)
            _ = try await client.download(plan: fixture.plan(sourceURL: sourceURL))
            XCTFail("expected overrun")
        } catch {
            XCTAssertEqual(error as? BuiltInDownloadError, .bodyOverrun)
        }

        do {
            let fixture = try Fixture(expectedBytes: 100)
            var headers = Self.fullHeaders(length: 100, etag: #""v1""#)
            headers["Content-Encoding"] = "gzip"
            let transport = ScriptedDownloadTransport([
                .response(url: sourceURL, status: 200, headers: headers, chunks: []),
            ])
            let client = makeClient(transport: transport)
            _ = try await client.download(plan: fixture.plan(sourceURL: sourceURL))
            XCTFail("expected encoding rejection")
        } catch {
            XCTAssertEqual(error as? BuiltInDownloadError, .compressedResponse)
        }
    }

    func testInvalidStatusWeakETagAndShortBodyReportTheirExactInvariant() async throws {
        do {
            let fixture = try Fixture(expectedBytes: 100)
            let transport = ScriptedDownloadTransport([
                .response(url: sourceURL, status: 403, headers: [:], chunks: []),
            ])
            let client = makeClient(transport: transport)
            _ = try await client.download(plan: fixture.plan(sourceURL: sourceURL))
            XCTFail("expected exact status rejection")
        } catch {
            XCTAssertEqual(error as? BuiltInDownloadError, .invalidStatus(403))
        }

        do {
            let fixture = try Fixture(expectedBytes: 100)
            let transport = ScriptedDownloadTransport([
                .response(
                    url: sourceURL,
                    status: 200,
                    headers: Self.fullHeaders(length: 100, etag: #"W/"weak""#),
                    chunks: []
                ),
            ])
            let client = makeClient(transport: transport)
            _ = try await client.download(plan: fixture.plan(sourceURL: sourceURL))
            XCTFail("expected weak ETag rejection")
        } catch {
            XCTAssertEqual(error as? BuiltInDownloadError, .missingOrInvalidETag)
        }

        do {
            let fixture = try Fixture(expectedBytes: 100)
            let transport = ScriptedDownloadTransport([
                .response(
                    url: sourceURL,
                    status: 200,
                    headers: Self.fullHeaders(length: 100, etag: #""v1""#),
                    chunks: [Self.bytes(99, value: 1)]
                ),
            ])
            let client = makeClient(transport: transport)
            _ = try await client.download(plan: fixture.plan(sourceURL: sourceURL))
            XCTFail("expected short-body rejection")
        } catch {
            XCTAssertEqual(
                error as? BuiltInDownloadError,
                .shortBody(expected: 100, actual: 99)
            )
        }
    }

    func testBlockedURLSessionRedirectPublishesOriginalThreeXXResponse() async throws {
        let state = BuiltInURLSessionStreamState()
        let delegate = BuiltInURLSessionDownloadDelegate(state: state)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        let original = URL(string: "https://assets.example/model.bin")!
        let destination = URL(string: "https://cdn.example/model.bin")!
        let task = session.dataTask(with: original)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: original,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": destination.absoluteString]
            )
        )
        let wait = Task { try await state.waitForResponse() }

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: destination),
            completionHandler: { redirectedRequest in
                XCTAssertNil(redirectedRequest)
            }
        )

        let published = try await wait.value
        XCTAssertEqual(published.statusCode, 302)
        XCTAssertEqual(published.url, original)
        XCTAssertEqual(published.value(forHeader: "Location"), destination.absoluteString)
        state.cancel()
        session.invalidateAndCancel()
    }

    func testURLSessionStreamStateNotifiesTerminalExactlyOnce() async {
        let state = BuiltInURLSessionStreamState()
        let counter = AsyncCounter()
        state.setTerminalObserver {
            Task { await counter.increment() }
        }

        state.complete(error: nil)
        state.cancel()

        for _ in 0..<100 {
            if await counter.value > 0 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        let terminalCount = await counter.value
        XCTAssertEqual(terminalCount, 1)
    }

    func testAllowedRedirectIsManualBoundedAndLeaksNoAmbientHeaders() async throws {
        let fixture = try Fixture(expectedBytes: 100)
        let redirected = URL(string: "https://cdn.example/signed/model.bin")!
        let transport = ScriptedDownloadTransport([
            .response(
                url: sourceURL,
                status: 302,
                headers: ["Location": redirected.absoluteString],
                chunks: []
            ),
            .response(
                url: redirected,
                status: 200,
                headers: Self.fullHeaders(length: 100, etag: #""v1""#),
                chunks: [Self.bytes(100, value: 3)]
            ),
        ])
        let client = BuiltInDownloadClient(
            transport: transport,
            allowedAssetHosts: ["assets.example", "cdn.example"]
        )

        _ = try await client.download(plan: fixture.plan(sourceURL: sourceURL))

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [sourceURL, redirected])
        for request in requests {
            XCTAssertEqual(request.headers["Accept-Encoding"], "identity")
            Self.assertNoAmbientCredentials(request)
        }
    }

    func testPinnedManifestRedirectToProductionHuggingFaceCDNIsAccepted() async throws {
        let fixture = try Fixture(expectedBytes: 100)
        let manifestSource = try XCTUnwrap(
            BuiltInModelManifest.regular.files.first(where: { $0.role == .weights })
        ).sourceURL
        let productionRedirect = URL(
            string: "https://us.aws.cdn.hf.co/repositories/manifest-pinned/model.safetensors"
        )!
        let transport = ScriptedDownloadTransport([
            .response(
                url: manifestSource,
                status: 302,
                headers: ["Location": productionRedirect.absoluteString],
                chunks: []
            ),
            .response(
                url: productionRedirect,
                status: 200,
                headers: Self.fullHeaders(length: 100, etag: #""production-etag""#),
                chunks: [Self.bytes(100, value: 4)]
            ),
        ])
        let client = BuiltInDownloadClient(
            transport: transport,
            allowedAssetHosts: BuiltInModelRuntimeSupport.allowedAssetHosts
        )

        _ = try await client.download(plan: fixture.plan(sourceURL: manifestSource))

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.map(\.url), [manifestSource, productionRedirect])
        XCTAssertTrue(requests.allSatisfy { $0.headers["Accept-Encoding"] == "identity" })
    }

    func testProductionCDNTrustDoesNotExtendToSiblingOrNestedHosts() async throws {
        let manifestSource = try XCTUnwrap(
            BuiltInModelManifest.regular.files.first(where: { $0.role == .weights })
        ).sourceURL
        for rawDestination in [
            "https://eu.aws.cdn.hf.co/model.bin",
            "https://attacker.us.aws.cdn.hf.co/model.bin",
        ] {
            let fixture = try Fixture(expectedBytes: 100)
            let destination = try XCTUnwrap(URL(string: rawDestination))
            let transport = ScriptedDownloadTransport([
                .response(
                    url: manifestSource,
                    status: 302,
                    headers: ["Location": destination.absoluteString],
                    chunks: []
                ),
            ])
            let client = BuiltInDownloadClient(
                transport: transport,
                allowedAssetHosts: BuiltInModelRuntimeSupport.allowedAssetHosts
            )

            do {
                _ = try await client.download(plan: fixture.plan(sourceURL: manifestSource))
                XCTFail("expected exact-authority rejection for \(rawDestination)")
            } catch {
                XCTAssertEqual(error as? BuiltInDownloadError, .disallowedURL)
            }
        }
    }

    func testRedirectRejectsHTTPAndEveryLiteralIPEvenWhenAllowlisted() async throws {
        let destinations = [
            "http://cdn.example/model.bin",
            "https://127.0.0.1/model.bin",
            "https://10.0.0.1/model.bin",
            "https://169.254.1.1/model.bin",
            "https://[::1]/model.bin",
        ]

        for rawDestination in destinations {
            let fixture = try Fixture(expectedBytes: 100)
            let destination = try XCTUnwrap(URL(string: rawDestination))
            let host = try XCTUnwrap(destination.host)
            let transport = ScriptedDownloadTransport([
                .response(
                    url: sourceURL,
                    status: 302,
                    headers: ["Location": destination.absoluteString],
                    chunks: []
                ),
            ])
            let client = BuiltInDownloadClient(
                transport: transport,
                allowedAssetHosts: ["assets.example", host]
            )

            do {
                _ = try await client.download(plan: fixture.plan(sourceURL: sourceURL))
                XCTFail("expected redirect rejection for \(rawDestination)")
            } catch {
                XCTAssertEqual(error as? BuiltInDownloadError, .disallowedURL)
            }
        }
    }

    func testCancelDeletesPartialWhileTransportInterruptionPreservesIt() async throws {
        do {
            let fixture = try Fixture(expectedBytes: 100)
            let transport = ScriptedDownloadTransport([
                .response(
                    url: sourceURL,
                    status: 200,
                    headers: Self.fullHeaders(length: 100, etag: #""v1""#),
                    chunks: [Self.bytes(40, value: 1)],
                    blockAfterChunks: true
                ),
            ])
            let client = makeClient(transport: transport)
            let plan = fixture.plan(sourceURL: sourceURL)
            let task = Task { try await client.download(plan: plan) }
            try await Self.waitForFileSize(fixture.partialURL, atLeast: 40)

            let acknowledgement = await client.cancelAndDrain()
            let outcome = try await task.value

            XCTAssertEqual(acknowledgement.activeDownloads, 0)
            XCTAssertEqual(outcome, .cancelled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.partialURL.path))
        }

        do {
            let fixture = try Fixture(expectedBytes: 100)
            let transport = ScriptedDownloadTransport([
                .response(
                    url: sourceURL,
                    status: 200,
                    headers: Self.fullHeaders(length: 100, etag: #""v1""#),
                    chunks: [Self.bytes(40, value: 2)],
                    terminalError: FixtureTransportError.interrupted
                ),
            ])
            let client = makeClient(transport: transport)

            let outcome = try await client.download(plan: fixture.plan(sourceURL: sourceURL))

            guard case .interrupted(let state) = outcome else {
                return XCTFail("expected interruption")
            }
            XCTAssertEqual(state?.receivedBytes, 40)
            XCTAssertEqual(try Self.fileSize(fixture.partialURL), 40)
        }
    }

    func testCapacityShrinkPausesLowDiskWithoutDeletingBytes() async throws {
        let fixture = try Fixture(expectedBytes: 100)
        let transport = ScriptedDownloadTransport([
            .response(
                url: sourceURL,
                status: 200,
                headers: Self.fullHeaders(length: 100, etag: #""v1""#),
                chunks: [Self.bytes(40, value: 1), Self.bytes(60, value: 2)]
            ),
        ])
        let client = BuiltInDownloadClient(
            transport: transport,
            allowedAssetHosts: ["assets.example"],
            capacityCheck: { progress in
                let reserve = BuiltInModelManager.captureReserveBytes
                    + BuiltInModelManager.capacitySafetyBytes
                let available = progress.receivedBytes >= 40
                    ? reserve + 59
                    : reserve + 100
                return BuiltInModelRuntimeSupport.downloadCapacityDecision(
                    progress,
                    availableBytes: available
                )
            }
        )

        let outcome = try await client.download(plan: fixture.plan(sourceURL: sourceURL))

        guard case .pausedLowDisk(let state, let required, let available) = outcome else {
            return XCTFail("expected pausedLowDisk")
        }
        XCTAssertEqual(state?.receivedBytes, 40)
        let reserve = BuiltInModelManager.captureReserveBytes
            + BuiltInModelManager.capacitySafetyBytes
        XCTAssertEqual(required, reserve + 60)
        XCTAssertEqual(available, reserve + 59)
        XCTAssertEqual(try Self.fileSize(fixture.partialURL), 40)
    }

    func testProgressObserverUsesDurableByteCheckpointsInsteadOfEveryChunk() async throws {
        let fixture = try Fixture(expectedBytes: 100)
        let transport = ScriptedDownloadTransport([
            .response(
                url: sourceURL,
                status: 200,
                headers: Self.fullHeaders(length: 100, etag: #""v1""#),
                chunks: [
                    Self.bytes(30, value: 1),
                    Self.bytes(30, value: 2),
                    Self.bytes(40, value: 3),
                ]
            ),
        ])
        let progress = ProgressRecorder()
        let client = BuiltInDownloadClient(
            transport: transport,
            allowedAssetHosts: ["assets.example"],
            progressCheckpointBytes: 50
        )

        _ = try await client.download(
            plan: fixture.plan(sourceURL: sourceURL),
            onProgress: { state in
                await progress.append(state.receivedBytes)
            }
        )

        let checkpoints = await progress.values
        XCTAssertEqual(checkpoints, [60, 100])
    }

    func testSuspendAndDrainAcknowledgesNoInflightWorkAndResumeCompletes() async throws {
        let fixture = try Fixture(expectedBytes: 100)
        let firstTransport = ScriptedDownloadTransport([
            .response(
                url: sourceURL,
                status: 200,
                headers: Self.fullHeaders(length: 100, etag: #""v1""#),
                chunks: [Self.bytes(40, value: 1)],
                blockAfterChunks: true
            ),
            .response(
                url: sourceURL,
                status: 206,
                headers: Self.rangeHeaders(start: 40, end: 99, total: 100, etag: #""v1""#),
                chunks: [Self.bytes(60, value: 2)]
            ),
        ])
        let client = makeClient(transport: firstTransport)
        let plan = fixture.plan(sourceURL: sourceURL)
        let task = Task { try await client.download(plan: plan) }
        try await Self.waitForFileSize(fixture.partialURL, atLeast: 40)

        let acknowledgement = await client.suspendAndDrain()
        let paused = try await task.value

        XCTAssertTrue(acknowledgement.hadActiveDownload)
        XCTAssertEqual(acknowledgement.activeDownloads, 0)
        guard case .paused(let state) = paused else { return XCTFail("expected paused") }
        XCTAssertEqual(state?.receivedBytes, 40)
        XCTAssertEqual(try Self.fileSize(fixture.partialURL), 40)

        do {
            _ = try await client.download(plan: fixture.plan(sourceURL: sourceURL), resumeState: state)
            XCTFail("suspended client accepted work")
        } catch {
            XCTAssertEqual(error as? BuiltInDownloadError, .suspended)
        }

        await client.resumeAfterDrain()
        let completed = try await client.download(plan: plan, resumeState: state)
        guard case .completed(let completedState) = completed else {
            return XCTFail("expected resumed completion")
        }
        XCTAssertEqual(completedState.receivedBytes, 100)
        XCTAssertEqual(try Self.fileSize(fixture.partialURL), 100)
    }

    func testSymlinkHardLinkAndSpecialPartialFilesAreRejected() async throws {
        let fixture = try Fixture(expectedBytes: 10)
        let victim = fixture.root.appendingPathComponent("victim")
        try Data("victim".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(
            at: fixture.partialURL,
            withDestinationURL: victim
        )
        let transport = ScriptedDownloadTransport([])
        let client = makeClient(transport: transport)

        do {
            _ = try await client.download(plan: fixture.plan(sourceURL: sourceURL))
            XCTFail("expected symlink rejection")
        } catch {
            XCTAssertEqual(error as? BuiltInDownloadError, .unsafePartialFile)
        }
        XCTAssertEqual(try Data(contentsOf: victim), Data("victim".utf8))

        let hardLinkFixture = try Fixture(expectedBytes: 10)
        let original = hardLinkFixture.root.appendingPathComponent("original")
        try Data("original".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: hardLinkFixture.partialURL)
        let hardLinkClient = makeClient(transport: ScriptedDownloadTransport([]))
        do {
            _ = try await hardLinkClient.download(plan: hardLinkFixture.plan(sourceURL: sourceURL))
            XCTFail("expected hard-link rejection")
        } catch {
            XCTAssertEqual(error as? BuiltInDownloadError, .unsafePartialFile)
        }

        let specialPlan = BuiltInDownloadPlan(
            sourceURL: sourceURL,
            revision: "revision-1",
            manifestFingerprintSHA256: "fingerprint-1",
            expectedBytes: 10,
            partialFileURL: URL(fileURLWithPath: "/dev/null")
        )
        let specialClient = makeClient(transport: ScriptedDownloadTransport([]))
        do {
            _ = try await specialClient.download(plan: specialPlan)
            XCTFail("expected special-file rejection")
        } catch {
            XCTAssertEqual(error as? BuiltInDownloadError, .unsafePartialFile)
        }
    }

    private func makeClient(
        transport: ScriptedDownloadTransport
    ) -> BuiltInDownloadClient {
        BuiltInDownloadClient(
            transport: transport,
            allowedAssetHosts: ["assets.example"]
        )
    }

    private static func fullHeaders(length: Int64, etag: String) -> [String: String] {
        ["Content-Length": String(length), "ETag": etag]
    }

    private static func rangeHeaders(
        start: Int64,
        end: Int64,
        total: Int64,
        etag: String
    ) -> [String: String] {
        [
            "Content-Length": String(end - start + 1),
            "Content-Range": "bytes \(start)-\(end)/\(total)",
            "ETag": etag,
        ]
    }

    private static func bytes(_ count: Int, value: UInt8) -> Data {
        Data(repeating: value, count: count)
    }

    private static func assertNoAmbientCredentials(
        _ request: BuiltInDownloadHTTPRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for header in ["Authorization", "Cookie", "Referer", "Referrer", "Origin"] {
            XCTAssertNil(request.headers[header], "unexpected \(header)", file: file, line: line)
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
        return info.st_size
    }

    private static func fileMode(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
        return info.st_mode & mode_t(0o777)
    }

    private static func waitForFileSize(
        _ url: URL,
        atLeast expected: Int64
    ) async throws {
        for _ in 0..<200 {
            if let size = try? fileSize(url), size >= expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("partial never reached \(expected) bytes")
    }
}

private struct Fixture {
    let root: URL
    let partialURL: URL
    let expectedBytes: Int64

    init(expectedBytes: Int64) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-download-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        partialURL = root.appendingPathComponent("asset.partial")
        self.expectedBytes = expectedBytes
    }

    func plan(sourceURL: URL) -> BuiltInDownloadPlan {
        BuiltInDownloadPlan(
            sourceURL: sourceURL,
            revision: "revision-1",
            manifestFingerprintSHA256: "fingerprint-1",
            expectedBytes: expectedBytes,
            partialFileURL: partialURL
        )
    }

    func resumeState(
        sourceURL: URL,
        receivedBytes: Int64,
        etag: String
    ) -> BuiltInDownloadResumeState {
        BuiltInDownloadResumeState(
            sourceURL: sourceURL,
            revision: "revision-1",
            manifestFingerprintSHA256: "fingerprint-1",
            expectedBytes: expectedBytes,
            strongETag: etag,
            receivedBytes: receivedBytes
        )
    }
}

private enum FixtureTransportError: Error {
    case interrupted
}

private actor ScriptedDownloadTransport: BuiltInDownloadTransport {
    struct Script: Sendable {
        let response: BuiltInDownloadHTTPResponse
        let chunks: [Data]
        let terminalError: (any Error & Sendable)?
        let blockAfterChunks: Bool

        static func response(
            url: URL,
            status: Int,
            headers: [String: String],
            chunks: [Data],
            terminalError: (any Error & Sendable)? = nil,
            blockAfterChunks: Bool = false
        ) -> Script {
            Script(
                response: BuiltInDownloadHTTPResponse(
                    url: url,
                    statusCode: status,
                    headers: headers
                ),
                chunks: chunks,
                terminalError: terminalError,
                blockAfterChunks: blockAfterChunks
            )
        }
    }

    private var scripts: [Script]
    private var requests: [BuiltInDownloadHTTPRequest] = []

    init(_ scripts: [Script]) {
        self.scripts = scripts
    }

    func open(_ request: BuiltInDownloadHTTPRequest) async throws -> BuiltInDownloadStream {
        requests.append(request)
        guard !scripts.isEmpty else { throw FixtureTransportError.interrupted }
        let script = scripts.removeFirst()
        let body = ScriptedBody(
            chunks: script.chunks,
            terminalError: script.terminalError,
            blockAfterChunks: script.blockAfterChunks
        )
        return BuiltInDownloadStream(
            response: script.response,
            nextChunk: { try await body.next() },
            cancel: { Task { await body.cancel() } }
        )
    }

    func capturedRequests() -> [BuiltInDownloadHTTPRequest] { requests }
}

private actor ScriptedBody {
    private var chunks: [Data]
    private let terminalError: (any Error & Sendable)?
    private let blockAfterChunks: Bool
    private var cancelled = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(
        chunks: [Data],
        terminalError: (any Error & Sendable)?,
        blockAfterChunks: Bool
    ) {
        self.chunks = chunks
        self.terminalError = terminalError
        self.blockAfterChunks = blockAfterChunks
    }

    func next() async throws -> Data? {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if blockAfterChunks, !cancelled {
            await withCheckedContinuation { waiter = $0 }
        }
        if cancelled { throw CancellationError() }
        if let terminalError { throw terminalError }
        return nil
    }

    func cancel() {
        cancelled = true
        waiter?.resume()
        waiter = nil
    }
}

private actor AsyncCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor ProgressRecorder {
    private(set) var values: [Int64] = []
    func append(_ value: Int64) { values.append(value) }
}
