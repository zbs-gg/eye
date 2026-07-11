import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import XCTest

/// Long-running, opt-in physical qualification for the one product-downloadable
/// built-in artifact. Ordinary test and runtime-smoke paths never select this
/// suite, and this suite has no Hub identifier or downloader code path.
final class MLXRuntimeQualificationTests: XCTestCase {
    private enum QualificationError: Error, LocalizedError {
        case invalidInput(String)
        case missingCompletion
        case missingFirstToken
        case cancellationNotObserved

        var errorDescription: String? {
            switch self {
            case .invalidInput(let message): message
            case .missingCompletion: "Generation did not emit completion metadata"
            case .missingFirstToken: "Generation did not emit a token"
            case .cancellationNotObserved: "The MLX producer did not observe cancellation"
            }
        }
    }

    private enum Phase: String, Codable, Sendable {
        case cold
        case warm
        case retainedMemory
        case cancellation
    }

    private struct MemoryReading: Codable, Sendable {
        let activeBytes: Int
        let cacheBytes: Int
        let peakBytes: Int

        init(_ snapshot: Memory.Snapshot) {
            activeBytes = snapshot.activeMemory
            cacheBytes = snapshot.cacheMemory
            peakBytes = snapshot.peakMemory
        }

        var residentBytes: Int { activeBytes + cacheBytes }
    }

    private struct TicketBudget: Codable, Sendable {
        let contextID: String
        let preparedInputTokens: Int
        let weightBytes: Int
        let kvBytes: Int
        let workspaceBytes: Int
        let totalBytes: Int
        let admissionCapBytes: Int
    }

    private struct Sample: Codable, Sendable {
        let phase: Phase
        let contextID: String
        let language: LocalAIPerformanceLanguage
        let index: Int
        let preparedInputTokens: Int
        let maximumOutputTokens: Int
        let loadSeconds: Double
        let promptPreparationSeconds: Double
        let timeToFirstTokenSeconds: Double
        let generationSeconds: Double
        let generatedTokenCount: Int
        let decodeTokensPerSecond: Double
        let cancellationDrainSeconds: Double?
        let stopReason: String
        let memoryBefore: MemoryReading
        let memoryAfter: MemoryReading
        let incrementalPeakBytes: Int
        let wiredTicketBytes: Int
    }

    private struct Aggregate: Codable, Sendable {
        let phase: Phase
        let contextID: String
        let sampleCount: Int
        let englishCount: Int
        let russianCount: Int
        let timeToFirstTokenP50Seconds: Double?
        let timeToFirstTokenP95Seconds: Double?
        let minimumDecodeTokensPerSecond: Double?
        let maximumIncrementalPeakBytes: Int?
    }

    private struct RetainedMemoryResult: Codable, Sendable {
        let contextID: String
        let generationCount: Int
        let before: MemoryReading
        let after: MemoryReading
        let retainedGrowthBytes: Int
    }

    private struct UnloadResult: Codable, Sendable {
        let contextID: String
        let baseline: MemoryReading
        let loadedHighWaterBytes: Int
        let afterUnload: MemoryReading
        let modelAttributableBytes: Int
        let releasedFraction: Double
        let elapsedSeconds: Double
    }

    private struct CapabilityEvidence: Codable, Sendable {
        let coldSemantics: String
        let osDiskPageCachePurged: Bool
        let wiredTicket: String
        let productionRuntimeWiring: String
    }

    private struct Report: Codable, Sendable {
        let protocolID: String
        let artifactID: String
        let artifactRevision: String
        let generatedAt: Date
        var status: String
        let environment: LocalAIPhysicalGateEnvironment
        let capabilities: CapabilityEvidence
        let coldDefinition: String
        let warmDefinition: String
        let wiredTicketDefinition: String
        let limitations: [String]
        var ticketBudgets: [TicketBudget]
        var samples: [Sample]
        var aggregates: [Aggregate]
        var retainedMemory: RetainedMemoryResult?
        var unload: [UnloadResult]
        var failures: [String]
    }

    private struct GenerationMeasurement: Sendable {
        let timeToFirstTokenSeconds: Double
        let generationSeconds: Double
        let generatedTokenCount: Int
        let decodeTokensPerSecond: Double
        let cancellationDrainSeconds: Double?
        let stopReason: String
    }

    func testQualifiedModelMeetsLockedPerformanceEnvelope() async throws {
        guard configuredValue(
            environment: "ZBS_EYE_LOCAL_AI_PERFORMANCE_GATE",
            plist: "ZBSEyeLocalAIPerformanceGate"
        ) == "1" else {
            throw XCTSkip("Use verify-local-ai.sh --performance-gate with an explicit model directory")
        }

        let benchmark = try LocalAIPerformanceProtocol.load(from: protocolURL())
        try benchmark.validate(against: BuiltInModelManifest.regular)

        let environment = try LocalAIPhysicalGateEvidenceCapture.capture(
            bundle: Bundle(for: MLXRuntimeQualificationTests.self),
            manifest: BuiltInModelManifest.regular,
            hfHubOffline: configuredValue(
                environment: "HF_HUB_OFFLINE",
                plist: "ZBSEyeHFHubOffline"
            ),
            transformersOffline: configuredValue(
                environment: "TRANSFORMERS_OFFLINE",
                plist: "ZBSEyeTransformersOffline"
            ),
            allowModelDownloads: configuredValue(
                environment: "ZBS_EYE_ALLOW_MODEL_DOWNLOADS",
                plist: "ZBSEyeAllowModelDownloads"
            )
        )
        let capabilities = CapabilityEvidence(
            coldSemantics: "fresh verified ModelContainer per cold sample after prior scope return and MLX cache clear",
            osDiskPageCachePurged: false,
            wiredTicket: "real MLX WiredMemoryTicket passed to generateTokenTask",
            productionRuntimeWiring: "not claimed by this isolated U1 harness; required in U5/U9"
        )
        var report = Report(
            protocolID: benchmark.protocolID,
            artifactID: BuiltInModelManifest.regular.id,
            artifactRevision: BuiltInModelManifest.regular.revision,
            generatedAt: Date(),
            status: "running",
            environment: environment,
            capabilities: capabilities,
            coldDefinition: benchmark.coldDefinition,
            warmDefinition: benchmark.warmDefinition,
            wiredTicketDefinition: benchmark.wiredTicketDefinition,
            limitations: benchmark.limitations,
            ticketBudgets: [],
            samples: [],
            aggregates: [],
            retainedMemory: nil,
            unload: [],
            failures: []
        )

        do {
            try LocalAIPhysicalGateValidator.validate(
                environment,
                manifest: BuiltInModelManifest.regular
            )
            let modelDirectory = try configuredModelDirectory()
            _ = try BuiltInModelVerifier.verify(
                directory: modelDirectory,
                manifest: BuiltInModelManifest.regular
            )

            let budgets = try await tuneTicketBudgets(
                modelDirectory: modelDirectory,
                benchmark: benchmark
            )
            report.ticketBudgets = benchmark.contexts.compactMap { budgets[$0.id] }

            for context in benchmark.contexts {
                guard let budget = budgets[context.id] else {
                    throw QualificationError.invalidInput("Missing wired budget for \(context.id)")
                }
                for (index, language) in LocalAIPerformanceMath
                    .balancedLanguages(count: benchmark.sampling.coldPerContext).enumerated()
                {
                    report.samples.append(
                        try await coldSample(
                            modelDirectory: modelDirectory,
                            benchmark: benchmark,
                            context: context,
                            language: language,
                            index: index,
                            budget: budget
                        )
                    )
                    Memory.clearCache()
                }

                let warmResult = try await warmSamples(
                    modelDirectory: modelDirectory,
                    benchmark: benchmark,
                    context: context,
                    budget: budget,
                    includeRetainedMemorySoak:
                        context.id == benchmark.sampling.retainedMemoryContextID
                )
                report.samples.append(contentsOf: warmResult.samples)
                if let retained = warmResult.retainedMemory {
                    report.retainedMemory = retained
                }
                report.unload.append(warmResult.unload)
            }

            report.aggregates = makeAggregates(samples: report.samples)
            report.failures = evaluate(report: report, benchmark: benchmark)
            report.status = report.failures.isEmpty ? "passed" : "failed"
            let reportURL = try write(report: report)
            print("PERFORMANCE report: \(reportURL.path)")
            XCTAssertTrue(
                report.failures.isEmpty,
                "Performance qualification failed: \(report.failures.joined(separator: "; "))"
            )
        } catch {
            report.status = "failed"
            report.failures.append(error.localizedDescription)
            if let reportURL = try? write(report: report) {
                print("PERFORMANCE failed report: \(reportURL.path)")
            }
            XCTFail("Performance qualification aborted without retry: \(error.localizedDescription)")
        }
    }

    private func configuredModelDirectory() throws -> URL {
        guard let path = configuredValue(
            environment: "ZBS_EYE_MODEL_DIR",
            plist: "ZBSEyeModelDirectory"
        ) else {
            throw QualificationError.invalidInput("Performance gate requires ZBS_EYE_MODEL_DIR")
        }
        return URL(
            fileURLWithPath: NSString(string: path).expandingTildeInPath,
            isDirectory: true
        ).standardizedFileURL
    }

    private func tuneTicketBudgets(
        modelDirectory: URL,
        benchmark: LocalAIPerformanceProtocol
    ) async throws -> [String: TicketBudget] {
        Memory.clearCache()
        let container = try await LocalModelTestSupport.loadContainer(from: modelDirectory)
        var budgets: [String: TicketBudget] = [:]
        let headroom = 8 * 1_024 * 1_024 * 1_024
        let physicalCap = max(0, Int(benchmark.hardware.physicalMemoryBytes) - headroom)
        let admissionCap = min(GPU.maxRecommendedWorkingSetBytes() ?? physicalCap, physicalCap)

        for contextSpec in benchmark.contexts {
            let budget = try await container.perform { context in
                let input = try await Self.preparedInput(
                    context: context,
                    targetTokens: contextSpec.preparedInputTokens,
                    language: .english,
                    benchmark: benchmark
                )
                let measurement = try await WiredMemoryUtils.tune(
                    input: input,
                    context: context,
                    parameters: Self.generationParameters(benchmark),
                    resetPeakMemory: true
                )
                return TicketBudget(
                    contextID: contextSpec.id,
                    preparedInputTokens: measurement.tokenCount,
                    weightBytes: measurement.weightBytes,
                    kvBytes: measurement.kvBytes,
                    workspaceBytes: measurement.workspaceBytes,
                    totalBytes: measurement.totalBytes,
                    admissionCapBytes: admissionCap
                )
            }
            guard budget.preparedInputTokens == contextSpec.preparedInputTokens,
                budget.totalBytes > 0,
                budget.totalBytes <= budget.admissionCapBytes
            else {
                throw QualificationError.invalidInput(
                    "Wired ticket tuning could not admit \(contextSpec.id) truthfully"
                )
            }
            budgets[contextSpec.id] = budget
        }
        Memory.clearCache()
        return budgets
    }

    private func coldSample(
        modelDirectory: URL,
        benchmark: LocalAIPerformanceProtocol,
        context: LocalAIPerformanceProtocol.Context,
        language: LocalAIPerformanceLanguage,
        index: Int,
        budget: TicketBudget
    ) async throws -> Sample {
        Memory.clearCache()
        let memoryBefore = Memory.snapshot()
        Memory.peakMemory = 0
        let clock = ContinuousClock()
        let loadStartedAt = clock.now
        let container = try await LocalModelTestSupport.loadContainer(from: modelDirectory)
        let loadSeconds = loadStartedAt.duration(to: clock.now).seconds

        let measured = try await container.perform { modelContext in
            let preparationStartedAt = clock.now
            let input = try await Self.preparedInput(
                context: modelContext,
                targetTokens: context.preparedInputTokens,
                language: language,
                benchmark: benchmark
            )
            let preparationSeconds = preparationStartedAt.duration(to: clock.now).seconds
            let generation = try await Self.generate(
                input: input,
                context: modelContext,
                benchmark: benchmark,
                budget: budget,
                cancelAfterFirstToken: false
            )
            return (preparationSeconds, generation)
        }
        let memoryAfter = Memory.snapshot()
        let coldTTFT = loadSeconds + measured.0 + measured.1.timeToFirstTokenSeconds
        return Sample(
            phase: .cold,
            contextID: context.id,
            language: language,
            index: index,
            preparedInputTokens: context.preparedInputTokens,
            maximumOutputTokens: benchmark.generation.maximumOutputTokens,
            loadSeconds: loadSeconds,
            promptPreparationSeconds: measured.0,
            timeToFirstTokenSeconds: coldTTFT,
            generationSeconds: measured.1.generationSeconds,
            generatedTokenCount: measured.1.generatedTokenCount,
            decodeTokensPerSecond: measured.1.decodeTokensPerSecond,
            cancellationDrainSeconds: nil,
            stopReason: measured.1.stopReason,
            memoryBefore: MemoryReading(memoryBefore),
            memoryAfter: MemoryReading(memoryAfter),
            incrementalPeakBytes: max(0, memoryAfter.peakMemory - memoryBefore.activeMemory),
            wiredTicketBytes: budget.totalBytes
        )
    }

    private func warmSamples(
        modelDirectory: URL,
        benchmark: LocalAIPerformanceProtocol,
        context: LocalAIPerformanceProtocol.Context,
        budget: TicketBudget,
        includeRetainedMemorySoak: Bool
    ) async throws -> (samples: [Sample], retainedMemory: RetainedMemoryResult?, unload: UnloadResult) {
        Memory.clearCache()
        let baseline = Memory.snapshot()
        Memory.peakMemory = 0
        let clock = ContinuousClock()
        let batch = try await runLoadedWarmBatch(
            modelDirectory: modelDirectory,
            benchmark: benchmark,
            context: context,
            budget: budget,
            includeRetainedMemorySoak: includeRetainedMemorySoak
        )

        let unloadStartedAt = clock.now
        Memory.clearCache()
        let attributable = max(0, batch.loadedHighWaterBytes - baseline.activeMemory - baseline.cacheMemory)
        var afterUnload = Memory.snapshot()
        var released = releasedFraction(
            baselineBytes: baseline.activeMemory + baseline.cacheMemory,
            highWaterBytes: batch.loadedHighWaterBytes,
            currentBytes: afterUnload.activeMemory + afterUnload.cacheMemory
        )
        while released < benchmark.thresholds.minimumUnloadReleaseFraction,
            unloadStartedAt.duration(to: clock.now).seconds < benchmark.thresholds.maximumUnloadSeconds
        {
            try await Task.sleep(for: .milliseconds(100))
            Memory.clearCache()
            afterUnload = Memory.snapshot()
            released = releasedFraction(
                baselineBytes: baseline.activeMemory + baseline.cacheMemory,
                highWaterBytes: batch.loadedHighWaterBytes,
                currentBytes: afterUnload.activeMemory + afterUnload.cacheMemory
            )
        }
        let unload = UnloadResult(
            contextID: context.id,
            baseline: MemoryReading(baseline),
            loadedHighWaterBytes: batch.loadedHighWaterBytes,
            afterUnload: MemoryReading(afterUnload),
            modelAttributableBytes: attributable,
            releasedFraction: released,
            elapsedSeconds: unloadStartedAt.duration(to: clock.now).seconds
        )
        return (batch.samples, batch.retainedMemory, unload)
    }

    /// Returning from this helper is the explicit ownership boundary used by
    /// the unload measurement; no ModelContainer escapes in the result.
    private func runLoadedWarmBatch(
        modelDirectory: URL,
        benchmark: LocalAIPerformanceProtocol,
        context: LocalAIPerformanceProtocol.Context,
        budget: TicketBudget,
        includeRetainedMemorySoak: Bool
    ) async throws -> (
        samples: [Sample], retainedMemory: RetainedMemoryResult?, loadedHighWaterBytes: Int
    ) {
        let container = try await LocalModelTestSupport.loadContainer(from: modelDirectory)
        let clock = ContinuousClock()
        var samples: [Sample] = []
        var highWater = Memory.snapshot().activeMemory + Memory.snapshot().cacheMemory

        // Required unreported warm-up; it is never counted in the 30 samples.
        _ = try await container.perform { modelContext in
            let input = try await Self.preparedInput(
                context: modelContext,
                targetTokens: context.preparedInputTokens,
                language: .english,
                benchmark: benchmark
            )
            return try await Self.generate(
                input: input,
                context: modelContext,
                benchmark: benchmark,
                budget: budget,
                cancelAfterFirstToken: false
            )
        }

        for (index, language) in LocalAIPerformanceMath
            .balancedLanguages(count: benchmark.sampling.warmPerContext).enumerated()
        {
            let memoryBefore = Memory.snapshot()
            Memory.peakMemory = 0
            let measured = try await container.perform { modelContext in
                let preparationStartedAt = clock.now
                let input = try await Self.preparedInput(
                    context: modelContext,
                    targetTokens: context.preparedInputTokens,
                    language: language,
                    benchmark: benchmark
                )
                let preparationSeconds = preparationStartedAt.duration(to: clock.now).seconds
                let generation = try await Self.generate(
                    input: input,
                    context: modelContext,
                    benchmark: benchmark,
                    budget: budget,
                    cancelAfterFirstToken: false
                )
                let requestTTFT = preparationSeconds + generation.timeToFirstTokenSeconds
                return (preparationSeconds, requestTTFT, generation)
            }
            let memoryAfter = Memory.snapshot()
            highWater = max(highWater, memoryAfter.activeMemory + memoryAfter.cacheMemory)
            samples.append(
                Sample(
                    phase: .warm,
                    contextID: context.id,
                    language: language,
                    index: index,
                    preparedInputTokens: context.preparedInputTokens,
                    maximumOutputTokens: benchmark.generation.maximumOutputTokens,
                    loadSeconds: 0,
                    promptPreparationSeconds: measured.0,
                    timeToFirstTokenSeconds: measured.1,
                    generationSeconds: measured.2.generationSeconds,
                    generatedTokenCount: measured.2.generatedTokenCount,
                    decodeTokensPerSecond: measured.2.decodeTokensPerSecond,
                    cancellationDrainSeconds: nil,
                    stopReason: measured.2.stopReason,
                    memoryBefore: MemoryReading(memoryBefore),
                    memoryAfter: MemoryReading(memoryAfter),
                    incrementalPeakBytes: max(0, memoryAfter.peakMemory - memoryBefore.activeMemory),
                    wiredTicketBytes: budget.totalBytes
                )
            )
        }

        let cancellationMemoryBefore = Memory.snapshot()
        Memory.peakMemory = 0
        let cancellation = try await container.perform { modelContext in
            let input = try await Self.preparedInput(
                context: modelContext,
                targetTokens: context.preparedInputTokens,
                language: .english,
                benchmark: benchmark
            )
            return try await Self.generate(
                input: input,
                context: modelContext,
                benchmark: benchmark,
                budget: budget,
                cancelAfterFirstToken: true
            )
        }
        let cancellationMemoryAfter = Memory.snapshot()
        highWater = max(
            highWater,
            cancellationMemoryAfter.activeMemory + cancellationMemoryAfter.cacheMemory
        )
        samples.append(
            Sample(
                phase: .cancellation,
                contextID: context.id,
                language: .english,
                index: 0,
                preparedInputTokens: context.preparedInputTokens,
                maximumOutputTokens: benchmark.generation.maximumOutputTokens,
                loadSeconds: 0,
                promptPreparationSeconds: 0,
                timeToFirstTokenSeconds: cancellation.timeToFirstTokenSeconds,
                generationSeconds: cancellation.generationSeconds,
                generatedTokenCount: cancellation.generatedTokenCount,
                decodeTokensPerSecond: cancellation.decodeTokensPerSecond,
                cancellationDrainSeconds: cancellation.cancellationDrainSeconds,
                stopReason: cancellation.stopReason,
                memoryBefore: MemoryReading(cancellationMemoryBefore),
                memoryAfter: MemoryReading(cancellationMemoryAfter),
                incrementalPeakBytes: max(
                    0, cancellationMemoryAfter.peakMemory - cancellationMemoryBefore.activeMemory),
                wiredTicketBytes: budget.totalBytes
            )
        )

        var retained: RetainedMemoryResult?
        if includeRetainedMemorySoak {
            Memory.clearCache()
            let retainedBefore = Memory.snapshot()
            for (index, language) in LocalAIPerformanceMath
                .balancedLanguages(count: benchmark.sampling.retainedMemoryGenerations).enumerated()
            {
                let sampleMemoryBefore = Memory.snapshot()
                Memory.peakMemory = 0
                let measurement = try await container.perform { modelContext in
                    let input = try await Self.preparedInput(
                        context: modelContext,
                        targetTokens: context.preparedInputTokens,
                        language: language,
                        benchmark: benchmark
                    )
                    return try await Self.generate(
                        input: input,
                        context: modelContext,
                        benchmark: benchmark,
                        budget: budget,
                        cancelAfterFirstToken: false
                    )
                }
                let sampleMemoryAfter = Memory.snapshot()
                highWater = max(
                    highWater, sampleMemoryAfter.activeMemory + sampleMemoryAfter.cacheMemory)
                samples.append(
                    Sample(
                        phase: .retainedMemory,
                        contextID: context.id,
                        language: language,
                        index: index,
                        preparedInputTokens: context.preparedInputTokens,
                        maximumOutputTokens: benchmark.generation.maximumOutputTokens,
                        loadSeconds: 0,
                        promptPreparationSeconds: 0,
                        timeToFirstTokenSeconds: measurement.timeToFirstTokenSeconds,
                        generationSeconds: measurement.generationSeconds,
                        generatedTokenCount: measurement.generatedTokenCount,
                        decodeTokensPerSecond: measurement.decodeTokensPerSecond,
                        cancellationDrainSeconds: nil,
                        stopReason: measurement.stopReason,
                        memoryBefore: MemoryReading(sampleMemoryBefore),
                        memoryAfter: MemoryReading(sampleMemoryAfter),
                        incrementalPeakBytes: max(
                            0, sampleMemoryAfter.peakMemory - sampleMemoryBefore.activeMemory),
                        wiredTicketBytes: budget.totalBytes
                    )
                )
            }
            Memory.clearCache()
            let retainedAfter = Memory.snapshot()
            retained = RetainedMemoryResult(
                contextID: context.id,
                generationCount: benchmark.sampling.retainedMemoryGenerations,
                before: MemoryReading(retainedBefore),
                after: MemoryReading(retainedAfter),
                retainedGrowthBytes: max(
                    0,
                    (retainedAfter.activeMemory + retainedAfter.cacheMemory)
                        - (retainedBefore.activeMemory + retainedBefore.cacheMemory)
                )
            )
        }
        return (samples, retained, highWater)
    }

    private static func preparedInput(
        context: ModelContext,
        targetTokens: Int,
        language: LocalAIPerformanceLanguage,
        benchmark: LocalAIPerformanceProtocol
    ) async throws -> LMInput {
        let prefix = benchmark.promptMaterial.prefix(for: language)
        let filler = benchmark.promptMaterial.filler(for: language)
        let base = try await context.processor.prepare(
            input: UserInput(
                chat: [.system(benchmark.promptMaterial.system), .user(prefix)],
                tools: [LocalAIAnswerToolContract.schema],
                additionalContext: ["enable_thinking": false]
            )
        )
        let repeatCount = max(128, targetTokens / 8)
        let long = try await context.processor.prepare(
            input: UserInput(
                chat: [
                    .system(benchmark.promptMaterial.system),
                    .user(prefix + String(repeating: filler, count: repeatCount)),
                ],
                tools: [LocalAIAnswerToolContract.schema],
                additionalContext: ["enable_thinking": false]
            )
        )
        let baseTokens = base.text.tokens.asArray(Int.self)
        let longTokens = long.text.tokens.asArray(Int.self)
        let commonPrefix = Self.commonPrefixCount(baseTokens, longTokens)
        let commonSuffix = Self.commonSuffixCount(
            baseTokens,
            longTokens,
            excludingPrefix: commonPrefix
        )
        let fixedCount = commonPrefix + commonSuffix
        let middleCount = targetTokens - fixedCount
        let availableMiddle = longTokens.count - fixedCount
        guard middleCount >= 0, availableMiddle >= middleCount else {
            throw QualificationError.invalidInput(
                "Unable to prepare exactly \(targetTokens) templated \(language.rawValue) tokens"
            )
        }
        let exact = Array(longTokens.prefix(commonPrefix))
            + Array(longTokens.dropFirst(commonPrefix).prefix(middleCount))
            + Array(longTokens.suffix(commonSuffix))
        guard exact.count == targetTokens else {
            throw QualificationError.invalidInput("Prepared token count drifted from \(targetTokens)")
        }
        return LMInput(tokens: MLXArray(exact))
    }

    private static func generate(
        input: LMInput,
        context: ModelContext,
        benchmark: LocalAIPerformanceProtocol,
        budget: TicketBudget,
        cancelAfterFirstToken: Bool
    ) async throws -> GenerationMeasurement {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let iterator = try TokenIterator(
            input: input,
            model: context.model,
            parameters: Self.generationParameters(benchmark)
        )
        let policy = WiredBudgetPolicy(
            baseBytes: budget.weightBytes + budget.workspaceBytes,
            cap: budget.admissionCapBytes
        )
        guard policy.canAdmit(baseline: 0, activeSizes: [], newSize: budget.kvBytes) else {
            throw QualificationError.invalidInput("Wired ticket admission rejected the measured budget")
        }
        let ticket = policy.ticket(size: budget.kvBytes, kind: .active)
        let (stream, producer) = generateTokenTask(
            promptTokenCount: input.text.tokens.size,
            modelConfiguration: context.configuration,
            tokenizer: context.tokenizer,
            iterator: iterator,
            wiredMemoryTicket: ticket
        )

        var firstTokenAt: ContinuousClock.Instant?
        var cancellationRequestedAt: ContinuousClock.Instant?
        var completion: GenerateCompletionInfo?
        for await event in stream {
            switch event {
            case .token:
                if firstTokenAt == nil { firstTokenAt = clock.now }
                if cancelAfterFirstToken, cancellationRequestedAt == nil {
                    cancellationRequestedAt = clock.now
                    producer.cancel()
                }
            case .info(let info):
                completion = info
            @unknown default:
                continue
            }
        }
        await producer.value
        let endedAt = clock.now
        guard let firstTokenAt else { throw QualificationError.missingFirstToken }
        guard let completion else { throw QualificationError.missingCompletion }
        if cancelAfterFirstToken {
            let wasCancelled: Bool
            switch completion.stopReason {
            case .cancelled: wasCancelled = true
            case .stop, .length: wasCancelled = false
            @unknown default: wasCancelled = false
            }
            guard wasCancelled, let cancellationRequestedAt else {
                throw QualificationError.cancellationNotObserved
            }
            return GenerationMeasurement(
                timeToFirstTokenSeconds: startedAt.duration(to: firstTokenAt).seconds,
                generationSeconds: startedAt.duration(to: endedAt).seconds,
                generatedTokenCount: completion.generationTokenCount,
                decodeTokensPerSecond: completion.tokensPerSecond,
                cancellationDrainSeconds: cancellationRequestedAt.duration(to: endedAt).seconds,
                stopReason: "cancelled"
            )
        }
        return GenerationMeasurement(
            timeToFirstTokenSeconds: startedAt.duration(to: firstTokenAt).seconds,
            generationSeconds: startedAt.duration(to: endedAt).seconds,
            generatedTokenCount: completion.generationTokenCount,
            decodeTokensPerSecond: completion.tokensPerSecond,
            cancellationDrainSeconds: nil,
            stopReason: Self.stopReason(completion.stopReason)
        )
    }

    private static func generationParameters(
        _ benchmark: LocalAIPerformanceProtocol
    ) -> GenerateParameters {
        GenerateParameters(
            maxTokens: benchmark.generation.maximumOutputTokens,
            temperature: Float(benchmark.generation.temperature),
            topP: Float(benchmark.generation.topP),
            prefillStepSize: benchmark.generation.prefillStepSize,
            seed: benchmark.generation.seed
        )
    }

    private func makeAggregates(samples: [Sample]) -> [Aggregate] {
        let phases: [Phase] = [.cold, .warm]
        var aggregates: [Aggregate] = []
        for phase in phases {
            let phaseSamples = samples.filter { $0.phase == phase }
            let groups = Dictionary(grouping: phaseSamples, by: \.contextID)
            for (contextID, group) in groups {
                let ttft = group.map(\.timeToFirstTokenSeconds)
                let decode = group.map(\.decodeTokensPerSecond)
                let peak = group.map(\.incrementalPeakBytes)
                aggregates.append(
                    Aggregate(
                        phase: phase,
                        contextID: contextID,
                        sampleCount: group.count,
                        englishCount: group.filter { $0.language == .english }.count,
                        russianCount: group.filter { $0.language == .russian }.count,
                        timeToFirstTokenP50Seconds: LocalAIPerformanceMath.nearestRank(
                            ttft, percentile: 0.5),
                        timeToFirstTokenP95Seconds: LocalAIPerformanceMath.nearestRank(
                            ttft, percentile: 0.95),
                        minimumDecodeTokensPerSecond: decode.min(),
                        maximumIncrementalPeakBytes: peak.max()
                    )
                )
            }
        }
        return aggregates.sorted {
            ($0.contextID, $0.phase.rawValue) < ($1.contextID, $1.phase.rawValue)
        }
    }

    private func evaluate(
        report: Report,
        benchmark: LocalAIPerformanceProtocol
    ) -> [String] {
        var failures = LocalAIPerformanceMath.capabilityFailures(
            protocol: benchmark,
            coldSemantics: .supported,
            wiredTicket: .supported
        )
        for context in benchmark.contexts {
            for phase in [Phase.cold, .warm] {
                let expected = phase == .cold
                    ? benchmark.sampling.coldPerContext : benchmark.sampling.warmPerContext
                let group = report.samples.filter {
                    $0.phase == phase && $0.contextID == context.id
                }
                if group.count != expected
                    || group.filter({ $0.language == .english }).count != expected / 2
                    || group.filter({ $0.language == .russian }).count != expected / 2
                    || !group.allSatisfy({ $0.preparedInputTokens == context.preparedInputTokens })
                {
                    failures.append("\(context.id) \(phase.rawValue) sample matrix is incomplete")
                }
            }
        }

        func p95(_ phase: Phase, _ contextID: String) -> Double? {
            LocalAIPerformanceMath.nearestRank(
                report.samples.filter { $0.phase == phase && $0.contextID == contextID }
                    .map(\.timeToFirstTokenSeconds),
                percentile: 0.95
            )
        }
        if (p95(.cold, "prepared-2k") ?? .infinity)
            > benchmark.thresholds.twoKColdTTFTP95Seconds
        {
            failures.append("prepared-2k cold TTFT p95")
        }
        if (p95(.warm, "prepared-2k") ?? .infinity)
            > benchmark.thresholds.twoKWarmTTFTP95Seconds
        {
            failures.append("prepared-2k warm TTFT p95")
        }
        if (p95(.cold, "prepared-full") ?? .infinity)
            > benchmark.thresholds.fullColdTTFTP95Seconds
        {
            failures.append("prepared-full cold TTFT p95")
        }
        if (p95(.warm, "prepared-full") ?? .infinity)
            > benchmark.thresholds.fullWarmTTFTP95Seconds
        {
            failures.append("prepared-full warm TTFT p95")
        }

        let completed = report.samples.filter { $0.phase == .cold || $0.phase == .warm }
        if completed.map(\.decodeTokensPerSecond).min() ?? 0
            < benchmark.thresholds.minimumDecodeTokensPerSecond
        {
            failures.append("sustained decode below threshold")
        }
        let cancellations = report.samples.filter { $0.phase == .cancellation }
        if cancellations.count != benchmark.contexts.count
            || cancellations.contains(where: {
                ($0.cancellationDrainSeconds ?? .infinity)
                    > benchmark.thresholds.maximumCancellationSeconds
            })
        {
            failures.append("cancellation drain threshold")
        }
        let coldPeak = report.samples.filter { $0.phase == .cold }
            .map(\.incrementalPeakBytes).max() ?? .max
        if Double(coldPeak) > benchmark.thresholds.maximumIncrementalPeakBytes {
            failures.append("incremental peak memory threshold")
        }
        if report.retainedMemory?.contextID != benchmark.sampling.retainedMemoryContextID
            || report.retainedMemory?.generationCount
                != benchmark.sampling.retainedMemoryGenerations
            || Double(report.retainedMemory?.retainedGrowthBytes ?? .max)
                > benchmark.thresholds.maximumRetainedGrowthBytes
        {
            failures.append("50-generation retained memory threshold")
        }
        if report.unload.count != benchmark.contexts.count
            || report.unload.contains(where: {
                $0.releasedFraction < benchmark.thresholds.minimumUnloadReleaseFraction
                    || $0.elapsedSeconds > benchmark.thresholds.maximumUnloadSeconds
            })
        {
            failures.append("unload release threshold")
        }
        return failures
    }

    private func write(report: Report) throws -> URL {
        let configured = configuredValue(
            environment: "ZBS_EYE_LOCAL_AI_RESULTS_DIR",
            plist: "ZBSEyeLocalAIResultsDirectory"
        )
        let root = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("build/local-ai-results", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: report.generatedAt)
            .replacingOccurrences(of: ":", with: "-")
        let destination = root.appendingPathComponent(
            "local-ai-performance-v1-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: destination, options: .atomic)
        return destination
    }

    private func configuredValue(environment: String, plist: String) -> String? {
        let raw = ProcessInfo.processInfo.environment[environment]
            ?? Bundle(for: MLXRuntimeQualificationTests.self)
                .object(forInfoDictionaryKey: plist) as? String
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func protocolURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals/local-ai-performance-v1.json")
    }

    private static func commonPrefixCount(_ lhs: [Int], _ rhs: [Int]) -> Int {
        var count = 0
        while count < min(lhs.count, rhs.count), lhs[count] == rhs[count] { count += 1 }
        return count
    }

    private static func commonSuffixCount(
        _ lhs: [Int],
        _ rhs: [Int],
        excludingPrefix prefix: Int
    ) -> Int {
        var count = 0
        let maximum = min(lhs.count, rhs.count) - prefix
        while count < maximum,
            lhs[lhs.count - count - 1] == rhs[rhs.count - count - 1]
        {
            count += 1
        }
        return count
    }

    private static func stopReason(_ reason: GenerateStopReason) -> String {
        switch reason {
        case .stop: "stop"
        case .length: "length"
        case .cancelled: "cancelled"
        @unknown default: "unknown"
        }
    }

    private static func releasedFraction(
        baselineBytes: Int,
        highWaterBytes: Int,
        currentBytes: Int
    ) -> Double {
        let attributable = max(0, highWaterBytes - baselineBytes)
        guard attributable > 0 else { return 0 }
        let retained = max(0, currentBytes - baselineBytes)
        return max(0, min(1, Double(attributable - retained) / Double(attributable)))
    }

    private func releasedFraction(
        baselineBytes: Int,
        highWaterBytes: Int,
        currentBytes: Int
    ) -> Double {
        Self.releasedFraction(
            baselineBytes: baselineBytes,
            highWaterBytes: highWaterBytes,
            currentBytes: currentBytes
        )
    }

}

private extension Duration {
    var seconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
