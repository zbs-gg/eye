import Darwin
import Foundation
import GRDB
import XCTest

/// Opt-in U9 coexistence gate for the production local-AI control plane and
/// the real GRDB/IngestService writer on an isolated data root. ScreenCaptureKit
/// and physical microphone/system-audio sessions remain a staging-app gate;
/// this test records that limitation and never labels itself full release
/// qualification.
final class LocalAIRecorderCoexistenceGateTests: XCTestCase {
    private struct Installation {
        let payload: URL
        let cleanupRoot: URL?

        func remove() {
            guard let cleanupRoot else { return }
            try? FileManager.default.removeItem(at: cleanupRoot)
        }
    }

    fileprivate struct RecorderMetrics: Encodable {
        let captureTriggers: Int
        let captureCompletions: Int
        let captureCoalesced: Int
        let captureFailures: Int
        let captureCycleP95Seconds: Double
        let ingestP95Seconds: Double
        let audioQueueHighWater: Int
        let audioAttempts: Int
        let audioCompletions: Int
        let audioDrops: Int
        let audioIngestP95Seconds: Double
        let dbErrors: Int
        let screenRows: Int
        let audioRows: Int
        let embedQueueGrowth: Int
        let maximumActiveGapSeconds: Double
        let processFootprintStartBytes: UInt64
        let processFootprintEndBytes: UInt64
    }

    private struct Thresholds: Encodable {
        let maximumCaptureIngestP95RegressionFraction = 0.10
        let maximumActiveGapSeconds = 6.0
        let maximumIncrementalFootprintBytes = 5_905_580_032
        let requiredSequentialGenerations = 50
        let requiredCaptureFailures = 0
        let requiredAudioDrops = 0
        let requiredDBErrors = 0
    }

    private struct Report: Encodable {
        let protocolID: String
        let generatedAt: Date
        let status: String
        let releaseQualification: Bool
        let scope: String
        let limitations: [String]
        let environment: LocalAIPhysicalGateEnvironment
        let baseline: RecorderMetrics
        let inference: RecorderMetrics
        let sequentialGenerations: Int
        let thresholds: Thresholds
        let failures: [String]
    }

    func testRecorderMetricsReconcileAudioRowsAndDrops() {
        let valid = RecorderMetrics(
            captureTriggers: 4,
            captureCompletions: 4,
            captureCoalesced: 0,
            captureFailures: 0,
            captureCycleP95Seconds: 0.01,
            ingestP95Seconds: 0.01,
            audioQueueHighWater: 1,
            audioAttempts: 3,
            audioCompletions: 2,
            audioDrops: 1,
            audioIngestP95Seconds: 0.01,
            dbErrors: 1,
            screenRows: 4,
            audioRows: 2,
            embedQueueGrowth: 4,
            maximumActiveGapSeconds: 0.05,
            processFootprintStartBytes: 1,
            processFootprintEndBytes: 1
        )
        XCTAssertTrue(
            LocalAIRecorderGatePolicy.reconciliationFailures(
                label: "probe",
                metrics: valid
            ).isEmpty
        )

        let invalid = RecorderMetrics(
            captureTriggers: valid.captureTriggers,
            captureCompletions: valid.captureCompletions,
            captureCoalesced: valid.captureCoalesced,
            captureFailures: valid.captureFailures,
            captureCycleP95Seconds: valid.captureCycleP95Seconds,
            ingestP95Seconds: valid.ingestP95Seconds,
            audioQueueHighWater: valid.audioQueueHighWater,
            audioAttempts: valid.audioAttempts,
            audioCompletions: valid.audioCompletions,
            audioDrops: valid.audioDrops,
            audioIngestP95Seconds: valid.audioIngestP95Seconds,
            dbErrors: valid.dbErrors,
            screenRows: valid.screenRows,
            audioRows: 1,
            embedQueueGrowth: valid.embedQueueGrowth,
            maximumActiveGapSeconds: valid.maximumActiveGapSeconds,
            processFootprintStartBytes: valid.processFootprintStartBytes,
            processFootprintEndBytes: valid.processFootprintEndBytes
        )
        XCTAssertEqual(
            LocalAIRecorderGatePolicy.reconciliationFailures(
                label: "probe",
                metrics: invalid
            ),
            ["probe audio DB rows do not reconcile"]
        )
    }

    func testGenerationFailureDrainsRecorderProbeBeforePropagating() async {
        let events = RecorderGateEventLog()

        do {
            _ = try await RecorderGateGenerationSequence.run(
                requiredGenerations: 1,
                generate: {
                    await events.append("generate-failed")
                    throw RecorderGateSequenceTestError.expected
                },
                stopAndDrainProbe: {
                    await events.append("probe-drained")
                    return "metrics"
                },
                cleanupRuntime: {
                    await events.append("runtime-drained")
                }
            )
            XCTFail("expected generation failure")
        } catch {
            XCTAssertEqual(error as? RecorderGateSequenceTestError, .expected)
        }
        let recordedEvents = await events.snapshot()
        XCTAssertEqual(
            recordedEvents,
            ["generate-failed", "probe-drained", "runtime-drained"]
        )
    }

    func testProductionRuntimeCoexistsWithRecorderWriterBaseline() async throws {
        let bundle = Bundle(for: LocalAIRecorderCoexistenceGateTests.self)
        guard LocalAIPhysicalGateEvidenceCapture.configuredValue(
            environment: "ZBS_EYE_LOCAL_AI_RECORDER_COEXISTENCE_GATE",
            bundle: bundle,
            plist: "ZBSEyeLocalAIRecorderCoexistenceGate"
        ) == "1" else {
            throw XCTSkip(
                "Use verify-local-ai.sh --recorder-coexistence-gate with an explicit model directory"
            )
        }

        let manifest = BuiltInModelManifest.regular
        let environment = try LocalAIPhysicalGateEvidenceCapture.capture(
            bundle: bundle,
            manifest: manifest,
            hfHubOffline: LocalAIPhysicalGateEvidenceCapture.configuredValue(
                environment: "HF_HUB_OFFLINE", bundle: bundle, plist: "ZBSEyeHFHubOffline"
            ),
            transformersOffline: LocalAIPhysicalGateEvidenceCapture.configuredValue(
                environment: "TRANSFORMERS_OFFLINE",
                bundle: bundle,
                plist: "ZBSEyeTransformersOffline"
            ),
            allowModelDownloads: LocalAIPhysicalGateEvidenceCapture.configuredValue(
                environment: "ZBS_EYE_ALLOW_MODEL_DOWNLOADS",
                bundle: bundle,
                plist: "ZBSEyeAllowModelDownloads"
            )
        )
        try LocalAIPhysicalGateValidator.validate(environment, manifest: manifest)
        let modelDirectory = try configuredModelDirectory(bundle: bundle)
        _ = try BuiltInModelVerifier.verify(directory: modelDirectory, manifest: manifest)
        let installation = try makeShippingInstallation(from: modelDirectory, manifest: manifest)
        defer { installation.remove() }

        let throwawayRoot = FileManager.default.temporaryDirectory.appending(
            path: "zbseye-recorder-coexistence-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: throwawayRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: throwawayRoot) }
        let database = try ZBSEyeDatabase(path: throwawayRoot.appending(path: "probe.sqlite").path)
        let storage = try StorageManager(
            mediaDirectory: throwawayRoot.appending(path: "media", directoryHint: .isDirectory)
        )
        let ingest = IngestService(db: database, storage: storage)

        let baselineProbe = RecorderWriterProbe(database: database, ingest: ingest)
        let baselineTask = Task { try await baselineProbe.run(minimumCycles: 60) }
        try await Task.sleep(for: .seconds(3))
        await baselineProbe.stop()
        let baseline = try await baselineTask.value

        let compute = AIComputeCoordinator(vectorBackfill: .noop)
        let service = LocalInferenceService(
            driver: MLXLocalRuntimeDriver(),
            computeCoordinator: compute,
            idleUnloadDelay: .seconds(120)
        )
        try await service.loadVerified(directory: installation.payload, manifest: manifest)
        let selection = ProviderSelectionSnapshot(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: manifest.id,
            selectionRevision: .init(rawValue: 1),
            authorizationEpoch: .init(rawValue: 1)
        )
        let snapshots = RecorderGateSnapshotProvider(selection)
        let registry = RecorderGateRegistry(
            registration: LLMAdapterRegistration(
                providerID: selection.providerID,
                executedLocally: true,
                adapter: service
            )
        )
        let router = LLMRouter(snapshotProvider: snapshots, adapterRegistry: registry)
        let generator = RoutedAIConsumerGenerator(router: router)
        let execution = AIConsumerExecutionContext(
            selection: selection,
            contextTokenCeiling: manifest.generation.contextTokenCeiling,
            executedLocally: true,
            recipientDisclosure: nil
        )
        let plan = generationPlan()

        let inferenceProbe = RecorderWriterProbe(database: database, ingest: ingest)
        let inferenceTask = Task { try await inferenceProbe.run(minimumCycles: 60) }
        let (completedGenerations, inference) = try await RecorderGateGenerationSequence.run(
            requiredGenerations: 50,
            generate: {
                let output = try await generator.generate(
                    plan: plan,
                    execution: execution,
                    requestID: UUID()
                )
                guard !output.content.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty else {
                    throw RecorderGateError.emptyGeneration
                }
            },
            stopAndDrainProbe: {
                await inferenceProbe.stop()
                return try await inferenceTask.value
            },
            cleanupRuntime: {
                guard await router.shutdown(timeout: .seconds(5)) else {
                    throw RecorderGateError.routerShutdownFailed
                }
                try await service.runtimeDrainer()(nil)
            }
        )

        let computeSnapshot = await compute.snapshot()
        XCTAssertFalse(computeSnapshot.generationPending)
        XCTAssertFalse(computeSnapshot.generationActive)

        let thresholds = Thresholds()
        let failures = gateFailures(
            baseline: baseline,
            inference: inference,
            generations: completedGenerations,
            thresholds: thresholds
        )
        let report = Report(
            protocolID: "local-ai-recorder-coexistence-v1",
            generatedAt: Date(),
            status: failures.isEmpty ? "passed-safe-writer-scope" : "failed",
            releaseQualification: false,
            scope: "production MLXLocalRuntimeDriver + LocalInferenceService + LLMRouter + AIComputeCoordinator concurrent with throwaway GRDB IngestService screen/audio rows",
            limitations: [
                "ScreenCaptureKit and AX/OCR capture are not exercised by this unhosted test bundle.",
                "Microphone, system-audio, VAD, and speech-recognition hardware queues are not exercised.",
                "This gate does not replace the staging-app hardware recorder run required by U9.",
            ],
            environment: environment,
            baseline: baseline,
            inference: inference,
            sequentialGenerations: completedGenerations,
            thresholds: thresholds,
            failures: failures
        )
        try write(report: report)

        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    private func generationPlan() -> AIConsumerGenerationPlan {
        AIConsumerGenerationPlan(
            consumer: .dailyInsights,
            priority: .explicitInsight,
            promptVersion: "recorder-coexistence-v1",
            language: .en,
            purpose: .insights,
            systemPrompt: "Summarize the supplied fact.",
            nativeToolSystemPrompt: LocalAINativeToolPrompt.system(
                taskInstructions: "Summarize the supplied fact without invention.",
                purposeInstructions: "Return one concise supported item and cite its allowed source ID."
            ),
            userPreamble: "Evidence:\n",
            fragments: [
                AIConsumerPromptFragment(
                    sourceID: "insight:1",
                    text: "The architecture review is Tuesday at 10:00 and Marina leads it."
                )
            ],
            userPostamble: "\nReturn one insight.",
            nativeToolUserPostamble: "\nUse only the evidence above.",
            maximumFragmentCharacters: 512,
            // The native answer tool needs enough room for the model's tool
            // envelope as well as content. The qualified performance protocol
            // uses the same 256-token ceiling; 64 deterministically truncates
            // Qwen before a valid tool call and tests the wrong failure mode.
            maximumOutputTokens: 256,
            timeout: .seconds(120)
        )
    }

    private func gateFailures(
        baseline: RecorderMetrics,
        inference: RecorderMetrics,
        generations: Int,
        thresholds: Thresholds
    ) -> [String] {
        var failures: [String] = []
        failures += LocalAIRecorderGatePolicy.reconciliationFailures(
            label: "baseline",
            metrics: baseline
        )
        failures += LocalAIRecorderGatePolicy.reconciliationFailures(
            label: "inference",
            metrics: inference
        )
        if generations != thresholds.requiredSequentialGenerations {
            failures.append(
                "expected \(thresholds.requiredSequentialGenerations) sequential generations, got \(generations)"
            )
        }
        if inference.captureFailures != thresholds.requiredCaptureFailures {
            failures.append(
                "capture failures must equal \(thresholds.requiredCaptureFailures)"
            )
        }
        if inference.audioDrops != thresholds.requiredAudioDrops {
            failures.append("audio drops must equal \(thresholds.requiredAudioDrops)")
        }
        if inference.dbErrors != thresholds.requiredDBErrors {
            failures.append("DB errors must equal \(thresholds.requiredDBErrors)")
        }
        if inference.maximumActiveGapSeconds > thresholds.maximumActiveGapSeconds {
            failures.append("active capture gap exceeded two 3-second ticks")
        }
        let allowedP95 = baseline.ingestP95Seconds
            * (1 + thresholds.maximumCaptureIngestP95RegressionFraction)
        if inference.ingestP95Seconds > allowedP95 {
            failures.append("capture/ingest p95 regressed by more than 10%")
        }
        let footprintGrowth = inference.processFootprintEndBytes
            > baseline.processFootprintEndBytes
            ? inference.processFootprintEndBytes - baseline.processFootprintEndBytes
            : 0
        if footprintGrowth > UInt64(thresholds.maximumIncrementalFootprintBytes) {
            failures.append("incremental process footprint exceeded 5.5 GiB")
        }
        return failures
    }

    private func configuredModelDirectory(bundle: Bundle) throws -> URL {
        guard let path = LocalAIPhysicalGateEvidenceCapture.configuredValue(
            environment: "ZBS_EYE_MODEL_DIR", bundle: bundle, plist: "ZBSEyeModelDirectory"
        ) else {
            throw RecorderGateError.missingModelDirectory
        }
        return URL(
            fileURLWithPath: NSString(string: path).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
    }

    private func makeShippingInstallation(
        from source: URL,
        manifest: BuiltInModelManifest
    ) throws -> Installation {
        if source.lastPathComponent == "payload",
           source.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            == "installed",
           UUID(uuidString: source.deletingLastPathComponent().lastPathComponent) != nil {
            return Installation(payload: source, cleanupRoot: nil)
        }
        let cleanupRoot = source.deletingLastPathComponent().appending(
            path: ".zbseye-recorder-gate-\(UUID().uuidString.lowercased())",
            directoryHint: .isDirectory
        )
        let payload = cleanupRoot
            .appending(path: "installed", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
            .appending(path: "payload", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            for file in manifest.files {
                let input = source.appending(path: file.relativePath)
                let output = payload.appending(path: file.relativePath)
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let result = input.withUnsafeFileSystemRepresentation { inputPath in
                    output.withUnsafeFileSystemRepresentation { outputPath in
                        guard let inputPath, let outputPath else { return Int32(-1) }
                        return Darwin.clonefile(inputPath, outputPath, 0)
                    }
                }
                guard result == 0 else {
                    throw RecorderGateError.cloneFailed(file.relativePath, errno)
                }
            }
            return Installation(payload: payload, cleanupRoot: cleanupRoot)
        } catch {
            try? FileManager.default.removeItem(at: cleanupRoot)
            throw error
        }
    }

    private func write(report: Report) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configured = ProcessInfo.processInfo.environment["ZBS_EYE_LOCAL_AI_RESULTS_DIR"]
        let directory = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.appending(path: "build/local-ai-results", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let filename = "local-ai-recorder-coexistence-\(formatter.string(from: report.generatedAt).replacingOccurrences(of: ":", with: "-")).json"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appending(path: filename), options: .atomic)
    }
}

private enum LocalAIRecorderGatePolicy {
    static func reconciliationFailures(
        label: String,
        metrics: LocalAIRecorderCoexistenceGateTests.RecorderMetrics
    ) -> [String] {
        var failures: [String] = []
        if metrics.captureTriggers != metrics.captureCompletions + metrics.captureFailures {
            failures.append("\(label) capture trigger/completion/failure counts do not reconcile")
        }
        if metrics.screenRows != metrics.captureCompletions {
            failures.append("\(label) screen DB rows do not reconcile")
        }
        if metrics.embedQueueGrowth != metrics.screenRows {
            failures.append("\(label) embed queue growth does not reconcile")
        }
        if metrics.audioAttempts != metrics.audioCompletions + metrics.audioDrops {
            failures.append("\(label) audio attempt/completion/drop counts do not reconcile")
        }
        if metrics.audioRows != metrics.audioCompletions {
            failures.append("\(label) audio DB rows do not reconcile")
        }
        return failures
    }
}

private enum RecorderGateGenerationSequence {
    static func run<Metrics: Sendable>(
        requiredGenerations: Int,
        generate: () async throws -> Void,
        stopAndDrainProbe: () async throws -> Metrics,
        cleanupRuntime: () async throws -> Void
    ) async throws -> (completedGenerations: Int, metrics: Metrics) {
        var completedGenerations = 0
        var generationFailure: (any Error)?
        do {
            for _ in 0..<requiredGenerations {
                try await generate()
                completedGenerations += 1
            }
        } catch {
            generationFailure = error
        }

        let metricsResult: Result<Metrics, any Error>
        do {
            metricsResult = .success(try await stopAndDrainProbe())
        } catch {
            metricsResult = .failure(error)
        }
        let runtimeCleanupResult: Result<Void, any Error>
        do {
            runtimeCleanupResult = .success(try await cleanupRuntime())
        } catch {
            runtimeCleanupResult = .failure(error)
        }

        if let generationFailure { throw generationFailure }
        let metrics = try metricsResult.get()
        try runtimeCleanupResult.get()
        return (completedGenerations, metrics)
    }
}

private actor RecorderGateEventLog {
    private var events: [String] = []
    func append(_ event: String) { events.append(event) }
    func snapshot() -> [String] { events }
}

private enum RecorderGateSequenceTestError: Error, Equatable {
    case expected
}

private enum RecorderGateError: Error {
    case missingModelDirectory
    case cloneFailed(String, Int32)
    case emptyGeneration
    case routerShutdownFailed
}

private actor RecorderGateSnapshotProvider: LLMSelectionSnapshotProviding {
    private let selection: ProviderSelectionSnapshot
    init(_ selection: ProviderSelectionSnapshot) { self.selection = selection }
    func currentSnapshot(for consumer: AIConsumer) -> ProviderSelectionSnapshot? { selection }
}

private actor RecorderGateRegistry: LLMAdapterRegistering {
    private let registration: LLMAdapterRegistration
    init(registration: LLMAdapterRegistration) { self.registration = registration }
    func registration(for providerID: String) -> LLMAdapterRegistration? {
        providerID == registration.providerID ? registration : nil
    }
}

private actor RecorderWriterProbe {
    private struct Counts {
        let screens: Int
        let audio: Int
        let embed: Int
    }

    private let database: ZBSEyeDatabase
    private let ingest: IngestService
    private var stopRequested = false

    init(database: ZBSEyeDatabase, ingest: IngestService) {
        self.database = database
        self.ingest = ingest
    }

    func stop() { stopRequested = true }

    func run(minimumCycles: Int) async throws -> LocalAIRecorderCoexistenceGateTests.RecorderMetrics {
        let before = try await counts()
        let footprintStart = Self.physicalFootprintBytes()
        var captureDurations: [Double] = []
        var audioDurations: [Double] = []
        var triggerCount = 0
        var completionCount = 0
        var captureFailures = 0
        var dbErrors = 0
        var audioAttempts = 0
        var audioCompletions = 0
        var audioDrops = 0
        var coalesced = 0
        var maximumGap = 0.0
        var previousTick: ContinuousClock.Instant?
        let clock = ContinuousClock()

        while triggerCount < minimumCycles || !stopRequested {
            let tick = clock.now
            if let previousTick {
                let gap = previousTick.duration(to: tick).seconds
                maximumGap = max(maximumGap, gap)
                coalesced += max(0, Int(gap / 0.05) - 1)
            }
            previousTick = tick
            triggerCount += 1
            let captureStart = clock.now
            do {
                _ = try await ingest.ingest(ScreenCaptureRecord(
                    timestamp: Date(),
                    bundleId: "gg.zbs.recorder-gate",
                    appName: "Recorder gate",
                    windowTitle: "cycle \(triggerCount)",
                    browserURL: nil,
                    monitorId: "synthetic-safe",
                    image: .none,
                    pixelWidth: 1,
                    pixelHeight: 1,
                    textBlocks: [
                        CapturedTextBlock(source: .ax, text: "capture \(triggerCount)")
                    ],
                    axQuality: .fullUseful
                ))
                completionCount += 1
            } catch {
                captureFailures += 1
                dbErrors += 1
            }
            captureDurations.append(captureStart.duration(to: clock.now).seconds)

            if triggerCount.isMultiple(of: 4) {
                audioAttempts += 1
                let audioStart = clock.now
                do {
                    _ = try await ingest.ingest(AudioCaptureRecord(
                        timestamp: Date(),
                        relativePath: "synthetic-safe/audio-\(triggerCount).m4a",
                        durationSec: 0.05,
                        channel: "synthetic-safe",
                        bytes: 0
                    ))
                    audioCompletions += 1
                } catch {
                    audioDrops += 1
                    dbErrors += 1
                }
                audioDurations.append(audioStart.duration(to: clock.now).seconds)
            }

            let elapsed = tick.duration(to: clock.now)
            if elapsed < .milliseconds(50) {
                try await Task.sleep(for: .milliseconds(50) - elapsed)
            }
        }

        let after = try await counts()
        return LocalAIRecorderCoexistenceGateTests.RecorderMetrics(
            captureTriggers: triggerCount,
            captureCompletions: completionCount,
            captureCoalesced: coalesced,
            captureFailures: captureFailures,
            captureCycleP95Seconds: Self.percentile95(captureDurations),
            ingestP95Seconds: Self.percentile95(captureDurations),
            audioQueueHighWater: audioDurations.isEmpty ? 0 : 1,
            audioAttempts: audioAttempts,
            audioCompletions: audioCompletions,
            audioDrops: audioDrops,
            audioIngestP95Seconds: Self.percentile95(audioDurations),
            dbErrors: dbErrors,
            screenRows: after.screens - before.screens,
            audioRows: after.audio - before.audio,
            embedQueueGrowth: after.embed - before.embed,
            maximumActiveGapSeconds: maximumGap,
            processFootprintStartBytes: footprintStart,
            processFootprintEndBytes: Self.physicalFootprintBytes()
        )
    }

    private func counts() async throws -> Counts {
        try await database.pool.read { db in
            Counts(
                screens: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screen_captures") ?? 0,
                audio: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audio_captures") ?? 0,
                embed: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embed_queue") ?? 0
            )
        }
    }

    private nonisolated static func percentile95(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }

    private nonisolated static func physicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
