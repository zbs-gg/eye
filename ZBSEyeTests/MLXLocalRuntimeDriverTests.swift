import Foundation
import MLX
import MLXLMCommon
import MLXNN
import XCTest

final class MLXLocalRuntimeDriverTests: XCTestCase {
    func testProducerDrainTimesOutWithoutPretendingNonCooperativeTaskStopped() async {
        let gate = NonCooperativeProducerGate()
        let producer = Task {
            await gate.enter()
        }
        await gate.waitUntilEntered()

        let started = ContinuousClock().now
        let outcome = await MLXProducerDrain.cancelAndWait(
            for: producer,
            timeout: .milliseconds(20)
        )

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(started.duration(to: ContinuousClock().now), .milliseconds(500))
        let exitedBeforeRelease = await gate.hasExited
        XCTAssertFalse(exitedBeforeRelease)

        await gate.release()
        await producer.value
        let exitedAfterRelease = await gate.hasExited
        XCTAssertTrue(exitedAfterRelease)
    }

    func testUnloadInvalidatesBlockedLoadBeforeLateContainerPublication() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mlx-runtime-load-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = NonCooperativeProducerGate()
        let driver = MLXLocalRuntimeDriver(
            drainAcknowledgementTimeout: .milliseconds(20),
            containerLoader: { _ in
                await gate.enter()
                return makeStubModelContainer()
            }
        )
        let loadTask = Task {
            try await driver.load(
                directory: directory,
                manifest: BuiltInModelManifest.regular
            )
        }
        await gate.waitUntilEntered()

        let unload = await driver.unload(timeout: .milliseconds(20))
        XCTAssertEqual(unload, .stopped)
        let pendingLoad = await LocalRuntimeTaskDeadline.wait(
            for: loadTask,
            timeout: .milliseconds(20)
        )
        XCTAssertEqual(
            pendingLoad,
            .timedOut
        )

        await gate.release()
        do {
            try await loadTask.value
            XCTFail("load published a container after unload invalidated its ownership")
        } catch is CancellationError {
            // Expected: a stale load may finish constructing, but never publish.
        } catch {
            XCTFail("unexpected stale-load error: \(error)")
        }
        let finalUnload = await driver.unload(timeout: .milliseconds(20))
        XCTAssertEqual(finalUnload, .stopped)
    }

    func testForcedProcessorEmitsTheConfiguredSequenceThenPassesLogitsThrough() {
        var processor = MLXForcedTokenSequenceProcessor(tokenIDs: [2, 0])
        let logits = MLXArray([0.1, 0.2, 0.3, 0.4] as [Float]).reshaped(1, 4)

        processor.prompt(MLXArray([9] as [Int32]))
        let first = processor.process(logits: logits)
        XCTAssertEqual(first.shape, logits.shape)
        XCTAssertEqual(sampledToken(from: first), 2)
        processor.didSample(token: MLXArray(Int32(2)))
        XCTAssertEqual(sampledToken(from: processor.process(logits: logits)), 0)
        processor.didSample(token: MLXArray(Int32(0)))

        XCTAssertEqual(
            processor.process(logits: logits).asArray(Float.self),
            logits.asArray(Float.self)
        )
    }

    func testForcedProcessorResetsAtTheNextPrompt() {
        var processor = MLXForcedTokenSequenceProcessor(tokenIDs: [3, 1])
        let logits = MLXArray([0.4, 0.3, 0.2, 0.1] as [Float])

        processor.prompt(MLXArray([8] as [Int32]))
        processor.didSample(token: MLXArray(Int32(3)))
        XCTAssertEqual(sampledToken(from: processor.process(logits: logits)), 1)

        processor.prompt(MLXArray([7] as [Int32]))
        XCTAssertEqual(sampledToken(from: processor.process(logits: logits)), 3)
    }

    func testNativePrefixPlanUsesExactXMLFunctionPrefixWithoutSpecialTokens() throws {
        let tokenizer = StubTokenizer(
            encodedTokenIDs: [11, 12, 13],
            decodedText: MLXForcedNativeToolPrefix.text
        )
        let parameters = GenerateParameters(
            maxTokens: 4,
            temperature: 0.2,
            topP: 0.95,
            prefillStepSize: 256
        )

        let plan = try MLXForcedNativeToolPrefix.make(
            tokenizer: tokenizer,
            configuration: configuration(format: .xmlFunction),
            parameters: parameters
        )

        XCTAssertEqual(
            MLXForcedNativeToolPrefix.text,
            "<tool_call>\n<function=emit_zbs_eye_answer>\n"
        )
        XCTAssertEqual(plan.tokenIDs, [11, 12, 13])
    }

    func testNativePrefixPlanFailsClosedForFormatRoundTripBudgetAndKVQuantization() {
        let exact = StubTokenizer(
            encodedTokenIDs: [11, 12, 13],
            decodedText: MLXForcedNativeToolPrefix.text
        )
        let mismatched = StubTokenizer(
            encodedTokenIDs: [11, 12, 13],
            decodedText: "not-the-prefix"
        )

        assertPrefixError(.unsupportedToolCallFormat) {
            _ = try MLXForcedNativeToolPrefix.make(
                tokenizer: exact,
                configuration: configuration(format: .json),
                parameters: GenerateParameters(maxTokens: 4)
            )
        }
        assertPrefixError(.prefixRoundTripFailed) {
            _ = try MLXForcedNativeToolPrefix.make(
                tokenizer: mismatched,
                configuration: configuration(format: .xmlFunction),
                parameters: GenerateParameters(maxTokens: 4)
            )
        }
        assertPrefixError(.insufficientOutputTokenBudget) {
            _ = try MLXForcedNativeToolPrefix.make(
                tokenizer: exact,
                configuration: configuration(format: .xmlFunction),
                parameters: GenerateParameters(maxTokens: 3)
            )
        }
        assertPrefixError(.incompatibleKVQuantization) {
            _ = try MLXForcedNativeToolPrefix.make(
                tokenizer: exact,
                configuration: configuration(format: .xmlFunction),
                parameters: GenerateParameters(maxTokens: 4, kvBits: 4)
            )
        }
        assertPrefixError(.incompatibleKVQuantization) {
            _ = try MLXForcedNativeToolPrefix.make(
                tokenizer: exact,
                configuration: configuration(format: .xmlFunction),
                parameters: GenerateParameters(maxTokens: 4, kvScheme: "affine4")
            )
        }
    }

    func testDriverSuppliesThePurposeSpecificSchemaToBothStructuredPaths() throws {
        let summaryProperties = try properties(
            in: XCTUnwrap(MLXLocalRuntimeDriver.structuredTools(for: .summary).first)
        )
        let askProperties = try properties(
            in: XCTUnwrap(MLXLocalRuntimeDriver.structuredTools(for: .ask).first)
        )

        XCTAssertEqual(Set(summaryProperties.keys), [
            "status", "item1_text", "item1_sources",
        ])
        XCTAssertTrue(Set([
            "status", "item1_text", "item1_sources", "item2_text",
            "item2_sources", "next_search",
        ]).isSubset(of: Set(askProperties.keys)))
    }

    private func sampledToken(from logits: MLXArray) -> Int {
        ArgMaxSampler().sample(logits: logits).item(Int.self)
    }

    private func configuration(format: ToolCallFormat) -> ModelConfiguration {
        ModelConfiguration(
            directory: URL(fileURLWithPath: "/tmp/zbseye-prefix-test", isDirectory: true),
            toolCallFormat: format
        )
    }

    private func properties(in tool: ToolSpec) throws -> [String: any Sendable] {
        let function = try XCTUnwrap(tool["function"] as? [String: any Sendable])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: any Sendable])
        return try XCTUnwrap(parameters["properties"] as? [String: any Sendable])
    }

    private func assertPrefixError(
        _ expected: MLXLocalRuntimeDriverError,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let actual = error as? MLXLocalRuntimeDriverError,
                  actual == expected else {
                XCTFail("Expected \(expected), got \(error)", file: file, line: line)
                return
            }
        }
    }
}

private func makeStubModelContainer() -> ModelContainer {
    let tokenizer = StubTokenizer(encodedTokenIDs: [], decodedText: "")
    return ModelContainer(
        context: ModelContext(
            configuration: ModelConfiguration(id: "stale-load-test"),
            model: StubLanguageModel(),
            processor: StandInUserInputProcessor(),
            tokenizer: tokenizer
        )
    )
}

private final class StubLanguageModel: Module, LanguageModel {
    func prepare(
        _ input: LMInput,
        cache: [KVCache],
        windowSize: Int?
    ) throws -> PrepareResult {
        .tokens(input.text)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        MLXArray.zeros([1, 1, 1])
    }

    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private actor NonCooperativeProducerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var hasExited = false

    func enter() async {
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
        hasExited = true
    }

    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct StubTokenizer: MLXLMCommon.Tokenizer {
    let encodedTokenIDs: [Int]
    let decodedText: String

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        guard text == MLXForcedNativeToolPrefix.text, !addSpecialTokens else { return [] }
        return encodedTokenIDs
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        guard tokenIds == encodedTokenIDs, !skipSpecialTokens else { return "" }
        return decodedText
    }

    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }

    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        []
    }
}
