import Darwin
import Foundation
import XCTest

/// Opt-in physical smoke of the exact shipping built-in path.
///
/// The supplied directory is verified against the product manifest and is
/// never interpreted as a Hub ID. When it is not already laid out as a real
/// `installed/<uuid>/payload`, APFS clones place the exact verified bytes in a
/// temporary production-shaped installation without linking or downloading.
final class MLXRuntimeSmokeTests: XCTestCase {
    private enum SmokeError: Error, LocalizedError {
        case invalidOfflineGuards
        case cloneFailed(path: String, code: Int32)
        case generationDidNotBecomeActive
        case generationCompletedBeforeCancellation

        var errorDescription: String? {
            switch self {
            case .invalidOfflineGuards:
                "Runtime smoke requires HF_HUB_OFFLINE=1, TRANSFORMERS_OFFLINE=1, and downloads disabled"
            case .cloneFailed(let path, let code):
                "Could not create an APFS clone for \(path) (errno \(code))"
            case .generationDidNotBecomeActive:
                "Shipping local generation did not reach its active state"
            case .generationCompletedBeforeCancellation:
                "Shipping local generation completed before cancellation was observed"
            }
        }
    }

    private struct SmokeInstallation {
        let payload: URL
        let cleanupRoot: URL?

        func remove() {
            guard let cleanupRoot else { return }
            try? FileManager.default.removeItem(at: cleanupRoot)
        }
    }

    func testShippingAskGenerationCancellationDrainAndUnload() async throws {
        let bundle = Bundle(for: MLXRuntimeSmokeTests.self)
        let configuredPath = configuredValue(
            environment: "ZBS_EYE_MODEL_DIR",
            bundle: bundle,
            plist: "ZBSEyeModelDirectory"
        )
        guard let configuredPath else {
            throw XCTSkip(
                "Use verify-local-ai.sh --runtime-smoke with an explicit verified model directory"
            )
        }
        guard configuredValue(
            environment: "HF_HUB_OFFLINE",
            bundle: bundle,
            plist: "ZBSEyeHFHubOffline"
        ) == "1",
            configuredValue(
                environment: "TRANSFORMERS_OFFLINE",
                bundle: bundle,
                plist: "ZBSEyeTransformersOffline"
            ) == "1",
            configuredValue(
                environment: "ZBS_EYE_ALLOW_MODEL_DOWNLOADS",
                bundle: bundle,
                plist: "ZBSEyeAllowModelDownloads"
            ) == "0"
        else {
            throw SmokeError.invalidOfflineGuards
        }

        let manifest = BuiltInModelManifest.regular
        let environment = try LocalAIPhysicalGateEvidenceCapture.capture(
            bundle: bundle,
            manifest: manifest,
            hfHubOffline: configuredValue(
                environment: "HF_HUB_OFFLINE",
                bundle: bundle,
                plist: "ZBSEyeHFHubOffline"
            ),
            transformersOffline: configuredValue(
                environment: "TRANSFORMERS_OFFLINE",
                bundle: bundle,
                plist: "ZBSEyeTransformersOffline"
            ),
            allowModelDownloads: configuredValue(
                environment: "ZBS_EYE_ALLOW_MODEL_DOWNLOADS",
                bundle: bundle,
                plist: "ZBSEyeAllowModelDownloads"
            )
        )
        try LocalAIPhysicalGateValidator.validate(environment, manifest: manifest)
        let source = URL(
            fileURLWithPath: NSString(string: configuredPath).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
        let sourceVerification = try BuiltInModelVerifier.verify(
            directory: source,
            manifest: manifest
        )
        let installation = try makeShippingInstallation(
            from: source,
            manifest: manifest
        )
        defer { installation.remove() }

        let driver = MLXLocalRuntimeDriver()
        let service = LocalInferenceService(
            driver: driver,
            computeCoordinator: AIComputeCoordinator(vectorBackfill: .noop),
            idleUnloadDelay: .seconds(120)
        )
        try await service.loadVerified(
            directory: installation.payload,
            manifest: manifest
        )

        let selection = ProviderSelectionSnapshot(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: manifest.id,
            selectionRevision: .init(rawValue: 1),
            authorizationEpoch: .init(rawValue: 1)
        )
        let execution = AskExecutionContext(
            selection: selection,
            contextTokenCeiling: manifest.generation.contextTokenCeiling,
            executedLocally: true,
            recipientDisclosure: nil
        )
        let router = ShippingAskRouter(service: service)
        let ask = AskService(
            retrieval: SmokeRetrieval(evidence: [Self.architectureReviewEvidence()]),
            router: router
        )

        // This is the production Ask prompt builder, shipping driver, service
        // parser, renderer, and provenance path—not a copied smoke prompt.
        let response = try await ask.answer(
            question: "When is the architecture review, and who leads it?",
            execution: execution,
            requestID: UUID(),
            limits: AskGenerationLimits(
                retrievalLimit: 1,
                maximumSampleCharacters: 360,
                maximumOutputTokens: 160,
                requestTimeout: .seconds(120)
            )
        )
        let capturedRequest = await router.capturedRequest()
        let captured = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(captured.consumer, .ask)
        XCTAssertEqual(captured.localOutputContract?.purpose, .ask)
        XCTAssertEqual(captured.localOutputContract?.allowedSources, ["[1]"])
        XCTAssertFalse(response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(response.text.contains("[1]"))
        XCTAssertEqual(response.sources.count, 1)
        XCTAssertEqual(response.provenance?.providerID, selection.providerID)
        XCTAssertEqual(response.provenance?.modelID, selection.modelID)
        XCTAssertEqual(response.provenance?.executedLocally, true)
        XCTAssertNil(response.provenance?.brokerUpstream)
        XCTAssertEqual(sourceVerification.manifestID, manifest.id)
        XCTAssertEqual(sourceVerification.verifiedBytes, manifest.expectedDownloadBytes)

        // A long production Ask request leaves enough prefill/decode work to
        // assert that caller cancellation reaches the real MLX producer and
        // that LocalInferenceService does not return before it is drained.
        let cancellationRouter = ShippingAskRouter(service: service)
        let cancellationAsk = AskService(
            retrieval: SmokeRetrieval(evidence: Self.longCancellationEvidence()),
            router: cancellationRouter
        )
        let cancellationTask = Task {
            try await cancellationAsk.answer(
                question: "Summarize every architecture decision and owner in this history.",
                execution: execution,
                requestID: UUID(),
                limits: AskGenerationLimits(
                    retrievalLimit: 10,
                    maximumSampleCharacters: 360,
                    maximumOutputTokens: 800,
                    requestTimeout: .seconds(120)
                )
            )
        }
        try await waitUntilGenerating(service: service)
        let cancellationStarted = ContinuousClock().now
        cancellationTask.cancel()
        do {
            _ = try await cancellationTask.value
            throw SmokeError.generationCompletedBeforeCancellation
        } catch is CancellationError {
            // Required: LocalInferenceService observed caller cancellation.
        }
        XCTAssertLessThan(
            cancellationStarted.duration(to: ContinuousClock().now),
            .seconds(2),
            "Cancellation must drain the shipping MLX producer promptly"
        )
        let afterCancellation = await service.snapshot()
        XCTAssertNil(afterCancellation.activeRequestID)

        try await service.runtimeDrainer()(nil)
        let unloaded = await service.snapshot()
        XCTAssertEqual(unloaded.state, .unloaded)
        XCTAssertNil(unloaded.loadedModelID)
        XCTAssertNil(unloaded.loadedDirectory)
        XCTAssertNil(unloaded.activeRequestID)
    }

    private func makeShippingInstallation(
        from source: URL,
        manifest: BuiltInModelManifest
    ) throws -> SmokeInstallation {
        if source.lastPathComponent == "payload",
           source.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            == "installed",
           UUID(uuidString: source.deletingLastPathComponent().lastPathComponent) != nil {
            return SmokeInstallation(payload: source, cleanupRoot: nil)
        }

        // Keep the clone root beside the source so clonefile stays on the same
        // APFS volume. Clone extents are copy-on-write and every file keeps
        // st_nlink == 1, satisfying the production verifier's hard-link ban.
        let cleanupRoot = source.deletingLastPathComponent().appendingPathComponent(
            ".zbseye-runtime-smoke-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        let installationID = UUID()
        let payload = cleanupRoot
            .appendingPathComponent("installed", isDirectory: true)
            .appendingPathComponent(installationID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("payload", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: payload,
                withIntermediateDirectories: true
            )
            for file in manifest.files {
                let sourceFile = source.appendingPathComponent(file.relativePath)
                let destination = payload.appendingPathComponent(file.relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let result = sourceFile.withUnsafeFileSystemRepresentation { sourcePath in
                    destination.withUnsafeFileSystemRepresentation { destinationPath in
                        guard let sourcePath, let destinationPath else { return Int32(-1) }
                        return Darwin.clonefile(sourcePath, destinationPath, 0)
                    }
                }
                guard result == 0 else {
                    throw SmokeError.cloneFailed(path: file.relativePath, code: errno)
                }
            }
            return SmokeInstallation(payload: payload, cleanupRoot: cleanupRoot)
        } catch {
            try? FileManager.default.removeItem(at: cleanupRoot)
            throw error
        }
    }

    private func waitUntilGenerating(service: LocalInferenceService) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            if case .generating = await service.snapshot().state { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw SmokeError.generationDidNotBecomeActive
    }

    private func configuredValue(
        environment: String,
        bundle: Bundle,
        plist: String
    ) -> String? {
        let raw = ProcessInfo.processInfo.environment[environment]
            ?? bundle.object(forInfoDictionaryKey: plist) as? String
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func architectureReviewEvidence() -> AskRetrievedEvidence {
        AskRetrievedEvidence(
            source: SearchResult(
                id: 1,
                kind: .screen,
                ts: Date(timeIntervalSince1970: 1),
                bundleId: "gg.zbs.synthetic",
                appName: "Calendar",
                windowTitle: "Architecture review",
                browserURL: nil,
                snippet: "The architecture review is Monday at 10:30. Lena leads it.",
                relativePath: nil
            ),
            text: "The architecture review is Monday at 10:30. Lena leads it."
        )
    }

    private static func longCancellationEvidence() -> [AskRetrievedEvidence] {
        (1...10).map { index in
            let text = String(
                repeating:
                    "Decision \(index): the architecture owner is Lena; review state remains pending. ",
                count: 8
            )
            return AskRetrievedEvidence(
                source: SearchResult(
                    id: Int64(index),
                    kind: .screen,
                    ts: Date(timeIntervalSince1970: Double(index)),
                    bundleId: "gg.zbs.synthetic",
                    appName: "Decision log",
                    windowTitle: "Architecture decision \(index)",
                    browserURL: nil,
                    snippet: text,
                    relativePath: nil
                ),
                text: text
            )
        }
    }
}

private actor ShippingAskRouter: AskLLMRouting {
    let service: LocalInferenceService
    private var request: LLMRequest?

    init(service: LocalInferenceService) {
        self.service = service
    }

    func generate(
        _ request: LLMRequest,
        expectedSelection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        self.request = request
        return try await service.generate(
            request: request,
            selection: expectedSelection
        )
    }

    func capturedRequest() -> LLMRequest? { request }
}

private struct SmokeRetrieval: AskRetrievalProviding {
    let evidence: [AskRetrievedEvidence]

    func retrieve(question: String, limit: Int) async throws -> [AskRetrievedEvidence] {
        Array(evidence.prefix(limit))
    }
}
