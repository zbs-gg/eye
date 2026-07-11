import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

enum MLXLocalRuntimeDriverError: Error, Sendable, Equatable {
    case notLoaded
    case generationAlreadyActive
    case invalidMemoryEnvelope
    case unsupportedToolCallFormat
    case prefixRoundTripFailed
    case insufficientOutputTokenBudget
    case incompatibleKVQuantization
    case runtimeDrainUnconfirmed
}

enum MLXProducerDrain {
    nonisolated static func wait(
        for producer: Task<Void, Never>,
        timeout: Duration
    ) async -> LocalRuntimeDrainOutcome {
        switch await LocalRuntimeTaskDeadline.wait(for: producer, timeout: timeout) {
        case .completed:
            return .stopped
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .unhealthy("producer drain acknowledgement was cancelled")
        }
    }

    nonisolated static func cancelAndWait(
        for producer: Task<Void, Never>,
        timeout: Duration
    ) async -> LocalRuntimeDrainOutcome {
        producer.cancel()
        return await wait(for: producer, timeout: timeout)
    }
}

struct MLXLocalGenerationStream: Sendable {
    let stream: AsyncStream<Generation>
    let producer: Task<Void, Never>
}

/// Qwen 3.5's native XML-function opening. The function body remains model
/// generated and is still accepted only through MLX's native ToolCall parser
/// plus LocalAIAnswerToolContract's strict validation.
struct MLXForcedNativeToolPrefix: Sendable, Equatable {
    static let text = "<tool_call>\n<function=\(LocalAIAnswerToolContract.functionName)>\n"

    let tokenIDs: [Int]

    static func make(
        tokenizer: any MLXLMCommon.Tokenizer,
        configuration: ModelConfiguration,
        parameters: GenerateParameters
    ) throws -> Self {
        guard configuration.toolCallFormat == .xmlFunction else {
            throw MLXLocalRuntimeDriverError.unsupportedToolCallFormat
        }
        guard parameters.kvBits == nil, parameters.kvScheme == nil else {
            // TokenIterator's public custom-processor initializer does not
            // perform dynamic KV-cache quantization. Never silently drop a
            // future memory policy while forcing the native prefix.
            throw MLXLocalRuntimeDriverError.incompatibleKVQuantization
        }

        let tokenIDs = tokenizer.encode(text: text, addSpecialTokens: false)
        guard !tokenIDs.isEmpty,
              tokenizer.decode(tokenIds: tokenIDs, skipSpecialTokens: false) == text else {
            throw MLXLocalRuntimeDriverError.prefixRoundTripFailed
        }
        guard let maxTokens = parameters.maxTokens,
              maxTokens > tokenIDs.count else {
            // Leave at least one model-selected token after the forced opener;
            // otherwise only a syntactically incomplete function can result.
            throw MLXLocalRuntimeDriverError.insufficientOutputTokenBudget
        }
        return Self(tokenIDs: tokenIDs)
    }
}

/// Forces a finite token prefix, then delegates unchanged. `TokenIterator`
/// calls `prompt` once per generation and `didSample` for every emitted token,
/// so the cursor resets between generations and the prefix consumes the normal
/// output budget instead of being injected after decoding.
struct MLXForcedTokenSequenceProcessor: LogitProcessor {
    let tokenIDs: [Int]
    private var cursor = 0
    private var downstream: (any LogitProcessor)?

    init(tokenIDs: [Int], downstream: (any LogitProcessor)? = nil) {
        self.tokenIDs = tokenIDs
        self.downstream = downstream
    }

    mutating func prompt(_ prompt: MLXArray) {
        cursor = 0
        downstream?.prompt(prompt)
    }

    func process(logits: MLXArray) -> MLXArray {
        guard cursor < tokenIDs.count else {
            return downstream?.process(logits: logits) ?? logits
        }
        let vocabulary = MLXArray.arange(logits.dim(-1))
        let selected = vocabulary .== Int32(tokenIDs[cursor])
        return MLX.where(
            selected,
            MLXArray.zeros(like: logits),
            MLXArray.full(
                logits.shape,
                values: MLXArray(-Float.infinity),
                dtype: logits.dtype
            )
        )
    }

    mutating func didSample(token: MLXArray) {
        downstream?.didSample(token: token)
        if cursor < tokenIDs.count {
            cursor += 1
        }
    }
}

/// Exact structured-generation seam shared by production and the bounded V9
/// qualification harness. It has no repository lookup, download, or retry
/// path: callers must supply an already loaded local ModelContainer.
enum MLXLocalStructuredGeneration {
    private struct Values: Sendable {
        let systemPrompt: String
        let userPrompt: String
        let tools: [ToolSpec]
        let parameters: GenerateParameters
        let wiredMemoryTicket: MLX.WiredMemoryTicket
        let qualificationSeed: UInt64?
    }

    static func start(
        container: ModelContainer,
        systemPrompt: String,
        userPrompt: String,
        tools: [ToolSpec],
        parameters: GenerateParameters,
        wiredMemoryTicket: MLX.WiredMemoryTicket,
        qualificationSeed: UInt64? = nil
    ) async throws -> MLXLocalGenerationStream {
        try await container.perform(
            values: Values(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                tools: tools,
                parameters: parameters,
                wiredMemoryTicket: wiredMemoryTicket,
                qualificationSeed: qualificationSeed
            )
        ) { context, values in
            var parameters = values.parameters
            if let qualificationSeed = values.qualificationSeed {
                parameters.seed = qualificationSeed
            }
            let prefix = try MLXForcedNativeToolPrefix.make(
                tokenizer: context.tokenizer,
                configuration: context.configuration,
                parameters: parameters
            )
            let input = try await context.processor.prepare(
                input: userInput(
                    systemPrompt: values.systemPrompt,
                    userPrompt: values.userPrompt,
                    tools: values.tools
                )
            )
            let processor = MLXForcedTokenSequenceProcessor(
                tokenIDs: prefix.tokenIDs,
                downstream: parameters.processor()
            )
            // Preserve rotating-cache configuration by constructing the cache
            // with the full parameters. Dynamic KV quantization is rejected
            // above because the public custom-processor iterator cannot apply
            // it after construction.
            let cache = context.model.newCache(parameters: parameters)
            let iterator = try TokenIterator(
                input: input,
                model: context.model,
                cache: cache,
                processor: processor,
                sampler: parameters.sampler(),
                prefillStepSize: parameters.prefillStepSize,
                maxTokens: parameters.maxTokens
            )
            let (stream, producer) = generateTask(
                promptTokenCount: input.text.tokens.size,
                modelConfiguration: context.configuration,
                tokenizer: context.tokenizer,
                iterator: iterator,
                wiredMemoryTicket: values.wiredMemoryTicket,
                tools: values.tools
            )
            return MLXLocalGenerationStream(stream: stream, producer: producer)
        }
    }

    static func userInput(
        systemPrompt: String,
        userPrompt: String,
        tools: [ToolSpec]
    ) -> UserInput {
        UserInput(
            chat: [
                .system(systemPrompt),
                .user(userPrompt),
            ],
            tools: tools,
            additionalContext: ["enable_thinking": false]
        )
    }
}

/// Real offline MLX Swift LM driver. Loading deliberately duplicates the
/// qualification harness's exact local-directory resolution: model and
/// tokenizer both resolve to the verified directory and Qwen's `<|im_end|>`
/// remains an additional EOS token. There is no downloader or repository-ID
/// code path in this type.
actor MLXLocalRuntimeDriver: LocalInferenceRuntimeDriving {
    typealias ContainerLoader = @Sendable (URL) async throws -> ModelContainer

    private struct GenerationHandle: Sendable {
        let id: UUID
        let stream: AsyncStream<Generation>
        let producer: Task<Void, Never>
    }

    private struct InputSpec: Sendable {
        let systemPrompt: String
        let userPrompt: String
        let maximumOutputTokens: Int
        let temperature: Float
        let topP: Float
        let tools: [ToolSpec]?
        let wiredMemoryTicket: MLX.WiredMemoryTicket
    }

    private let wiredPolicy = MLX.WiredSumPolicy(id: UUID())
    private var container: ModelContainer?
    private var wiredGenerationBytes = 0
    private var active: GenerationHandle?
    private let drainAcknowledgementTimeout: Duration
    private let containerLoader: ContainerLoader
    private var loadPublicationEpoch: UInt64 = 0

    init(
        drainAcknowledgementTimeout: Duration = .seconds(5),
        containerLoader: @escaping ContainerLoader = MLXLocalRuntimeDriver.loadContainer
    ) {
        self.drainAcknowledgementTimeout = max(.milliseconds(1), drainAcknowledgementTimeout)
        self.containerLoader = containerLoader
    }

    func load(directory: URL, manifest: BuiltInModelManifest) async throws {
        loadPublicationEpoch &+= 1
        let publicationEpoch = loadPublicationEpoch
        guard await cancelAndDrain(timeout: drainAcknowledgementTimeout).isConfirmedStopped else {
            throw MLXLocalRuntimeDriverError.runtimeDrainUnconfirmed
        }
        guard publicationEpoch == loadPublicationEpoch else {
            throw CancellationError()
        }
        container = nil
        Memory.clearCache()

        let directory = directory.standardizedFileURL
        guard directory.isFileURL,
              FileManager.default.fileExists(atPath: directory.path),
              manifest.hardware.maximumIncrementalMemoryBytes <= UInt64(Int.max) else {
            throw MLXLocalRuntimeDriverError.invalidMemoryEnvelope
        }
        var loadedContainer: ModelContainer? = try await containerLoader(directory)
        guard publicationEpoch == loadPublicationEpoch else {
            // `unload` may have returned while MLX's non-cooperative loader was
            // still constructing this container. Drop the candidate before
            // clearing unowned allocator pages and never publish stale weights.
            loadedContainer = nil
            Memory.clearCache()
            throw CancellationError()
        }
        container = loadedContainer
        wiredGenerationBytes = Int(manifest.hardware.maximumIncrementalMemoryBytes)
    }

    func warmUp() async throws {
        let handle = try await start(
            InputSpec(
                systemPrompt: "You are ZBS Eye Local.",
                userPrompt: "Ready.",
                maximumOutputTokens: 1,
                temperature: 0,
                topP: 1,
                tools: nil,
                wiredMemoryTicket: wiredPolicy.ticket(
                    size: wiredGenerationBytes,
                    kind: MLX.WiredMemoryTicketKind.active
                )
            )
        )
        for await _ in handle.stream {
            if Task.isCancelled {
                handle.producer.cancel()
                break
            }
        }
        if Task.isCancelled { handle.producer.cancel() }
        let drain = await MLXProducerDrain.wait(
            for: handle.producer,
            timeout: drainAcknowledgementTimeout
        )
        guard drain.isConfirmedStopped else {
            if Task.isCancelled { throw CancellationError() }
            throw MLXLocalRuntimeDriverError.runtimeDrainUnconfirmed
        }
        clearActive(handle.id)
        try Task.checkCancellation()
    }

    func preparedInputTokenCount(
        for request: LocalRuntimeGenerationRequest
    ) async throws -> Int {
        guard let container else { throw MLXLocalRuntimeDriverError.notLoaded }
        let input = try await container.prepare(
            input: Self.userInput(for: request)
        )
        return input.text.tokens.size
    }

    func generate(
        _ request: LocalRuntimeGenerationRequest
    ) async throws -> LocalRuntimeGenerationOutput {
        let tools = Self.structuredTools(for: request.outputContract.purpose)
        let handle = try await start(
            InputSpec(
                systemPrompt: request.systemPrompt,
                userPrompt: request.userPrompt,
                maximumOutputTokens: request.maximumOutputTokens,
                temperature: Float(request.temperature),
                topP: Float(request.topP),
                tools: tools,
                wiredMemoryTicket: wiredPolicy.ticket(
                    size: wiredGenerationBytes,
                    kind: MLX.WiredMemoryTicketKind.active
                )
            )
        )

        var chunks: [String] = []
        var toolCalls: [ToolCall] = []
        var generatedTokenCount = 0
        var reachedTokenLimit = false
        for await event in handle.stream {
            if Task.isCancelled {
                handle.producer.cancel()
                break
            }
            switch event {
            case .chunk(let text):
                chunks.append(text)
            case .toolCall(let call):
                toolCalls.append(call)
            case .info(let info):
                generatedTokenCount = info.generationTokenCount
                if case .length = info.stopReason {
                    reachedTokenLimit = true
                }
            }
        }
        if Task.isCancelled { handle.producer.cancel() }
        let drain = await MLXProducerDrain.wait(
            for: handle.producer,
            timeout: drainAcknowledgementTimeout
        )
        guard drain.isConfirmedStopped else {
            if Task.isCancelled { throw CancellationError() }
            throw MLXLocalRuntimeDriverError.runtimeDrainUnconfirmed
        }
        clearActive(handle.id)
        try Task.checkCancellation()
        return LocalRuntimeGenerationOutput(
            textChunks: chunks,
            toolCalls: toolCalls,
            generatedTokenCount: generatedTokenCount,
            reachedTokenLimit: reachedTokenLimit
        )
    }

    func cancelAndDrain(timeout: Duration) async -> LocalRuntimeDrainOutcome {
        guard let handle = active else { return .stopped }
        let outcome = await MLXProducerDrain.cancelAndWait(for: handle.producer, timeout: timeout)
        if outcome.isConfirmedStopped {
            clearActive(handle.id)
        }
        return outcome
    }

    func unload(timeout: Duration) async -> LocalRuntimeDrainOutcome {
        // Invalidate pending `_load` ownership before the first suspension.
        // A loader that outlives this barrier can finish constructing locally,
        // but it can no longer publish a process-owned container afterward.
        loadPublicationEpoch &+= 1
        let outcome = await cancelAndDrain(timeout: timeout)
        guard outcome.isConfirmedStopped else { return outcome }
        // Drop the final strong ModelContainer reference before clearing MLX's
        // allocator cache; otherwise an apparently successful unload retains
        // the weights through the container.
        container = nil
        wiredGenerationBytes = 0
        Memory.clearCache()
        return .stopped
    }

    private func start(_ spec: InputSpec) async throws -> GenerationHandle {
        guard active == nil else {
            throw MLXLocalRuntimeDriverError.generationAlreadyActive
        }
        guard let container else { throw MLXLocalRuntimeDriverError.notLoaded }
        let id = UUID()
        let parameters = GenerateParameters(
            maxTokens: spec.maximumOutputTokens,
            temperature: spec.temperature,
            topP: spec.topP,
            prefillStepSize: 256
        )
        if let tools = spec.tools {
            let generation = try await MLXLocalStructuredGeneration.start(
                container: container,
                systemPrompt: spec.systemPrompt,
                userPrompt: spec.userPrompt,
                tools: tools,
                parameters: parameters,
                wiredMemoryTicket: spec.wiredMemoryTicket,
                qualificationSeed: nil
            )
            let handle = GenerationHandle(
                id: id,
                stream: generation.stream,
                producer: generation.producer
            )
            active = handle
            return handle
        }

        // Warm-up intentionally remains unconstrained: it exercises model
        // readiness without a structured-output contract or forced prefix.
        let handle = try await container.perform(values: spec) { context, spec in
            let input = try await context.processor.prepare(
                input: UserInput(
                    chat: [
                        .system(spec.systemPrompt),
                        .user(spec.userPrompt),
                    ],
                    tools: spec.tools,
                    additionalContext: ["enable_thinking": false]
                )
            )
            let iterator = try TokenIterator(
                input: input,
                model: context.model,
                parameters: parameters
            )
            let (stream, producer) = generateTask(
                promptTokenCount: input.text.tokens.size,
                modelConfiguration: context.configuration,
                tokenizer: context.tokenizer,
                iterator: iterator,
                wiredMemoryTicket: spec.wiredMemoryTicket,
                tools: spec.tools
            )
            return GenerationHandle(id: id, stream: stream, producer: producer)
        }
        active = handle
        return handle
    }

    private func clearActive(_ id: UUID) {
        guard active?.id == id else { return }
        active = nil
    }

    private nonisolated static func loadContainer(directory: URL) async throws -> ModelContainer {
        let configuration = ModelConfiguration(
            directory: directory,
            extraEOSTokens: ["<|im_end|>"]
        )
        let resolved = configuration.resolved(
            modelDirectory: directory,
            tokenizerDirectory: directory
        )
        let context = try await LLMModelFactory.shared._load(
            configuration: resolved,
            tokenizerLoader: LocalTokenizerLoader()
        )
        return LLMModelFactory.shared._wrap(context)
    }

    nonisolated static func structuredTools(
        for purpose: LocalAIOutputPurpose
    ) -> [ToolSpec] {
        [LocalAIAnswerToolContract.schema(for: purpose)]
    }

    nonisolated static func userInput(
        for request: LocalRuntimeGenerationRequest
    ) -> UserInput {
        MLXLocalStructuredGeneration.userInput(
            systemPrompt: request.systemPrompt,
            userPrompt: request.userPrompt,
            tools: structuredTools(for: request.outputContract.purpose)
        )
    }
}
