import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import XCTest

final class LocalAIQualityGateV7Tests: XCTestCase {
    private struct FixtureFile: Decodable {
        let protocolID: String
        let language: String
        let caseCount: Int
        let cases: [EvalCase]

        enum CodingKeys: String, CodingKey {
            case language, cases
            case protocolID = "protocol_id"
            case caseCount = "case_count"
        }
    }

    private struct EvalCase: Decodable {
        let id: String
        let consumer: String
        let category: String
        let promptContract: String
        let input: EvalInput
        let expect: Expectation

        enum CodingKeys: String, CodingKey {
            case id, consumer, category, input, expect
            case promptContract = "prompt_contract"
        }
    }

    private struct QualityCase {
        let language: String
        let testCase: EvalCase
    }

    private struct EvalInput: Codable {
        let question: String?
        let evidence: [Evidence]?
        let activity: Activity?
        let summary: SummaryInput?
        let label: LabelInput?
    }

    private struct Evidence: Codable {
        let id: String
        let source: String
        let text: String
    }

    private struct Activity: Codable {
        let date: String
        let totalCaptures: Int
        let contextSwitches: Int
        let topApps: [TopApp]
        let textSamples: [String]

        enum CodingKeys: String, CodingKey {
            case date
            case totalCaptures = "total_captures"
            case contextSwitches = "context_switches"
            case topApps = "top_apps"
            case textSamples = "text_samples"
        }
    }

    private struct TopApp: Codable {
        let app: String
        let minutes: Int
        let captures: Int
    }

    private struct SummaryInput: Codable {
        let dateLine: String
        let countLine: String
        let fragments: [FixtureFragment]

        enum CodingKeys: String, CodingKey {
            case fragments
            case dateLine = "date_line"
            case countLine = "count_line"
        }
    }

    private struct FixtureFragment: Codable {
        let sourceID: String
        let text: String

        enum CodingKeys: String, CodingKey {
            case text
            case sourceID = "source_id"
        }
    }

    private struct LabelInput: Codable {
        let serializedBlock: String
        let signals: [String]

        enum CodingKeys: String, CodingKey {
            case signals
            case serializedBlock = "serialized_block"
        }
    }

    private struct Expectation: Decodable {
        let answerability: String
        let mustRefuse: Bool
        let requiredConcepts: [Concept]
        let requiredSources: [String]
        let allowedSources: [String]
        let requiredExactQuotes: [String]
        let forbiddenSubstrings: [String]
        let allowedNumbers: [String]
        let maxWords: Int
        let maxLines: Int
        let outputLanguage: String

        enum CodingKeys: String, CodingKey {
            case answerability
            case mustRefuse = "must_refuse"
            case requiredConcepts = "required_concepts"
            case requiredSources = "required_sources"
            case allowedSources = "allowed_sources"
            case requiredExactQuotes = "required_exact_quotes"
            case forbiddenSubstrings = "forbidden_substrings"
            case allowedNumbers = "allowed_numbers"
            case maxWords = "max_words"
            case maxLines = "max_lines"
            case outputLanguage = "output_language"
        }
    }

    private struct Concept: Decodable {
        let id: String
        let anyOf: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case anyOf = "any_of"
        }
    }

    private struct GeneratedOutput: Sendable {
        let chunks: String
        let calls: [ToolCall]
        let rawOutput: String
    }

    private struct CaseResult: Codable {
        let id: String
        let language: String
        let consumer: String
        let category: String
        let mustRefuse: Bool
        let variant: String
        let seed: UInt64
        let passed: Bool
        let failures: [String]
        let status: String?
        let rawOutput: String
        let output: String
        let elapsedSeconds: Double
    }

    private struct QualityReport: Codable {
        let protocolID: String
        let artifactID: String
        let modelRevision: String
        let generatedAt: Date
        let operatingSystem: String
        let physicalMemoryBytes: UInt64
        let stableCaseCount: Int
        let stablePassedCount: Int
        let stableOverallPassRate: Double
        let stableLanguagePassRates: [String: Double]
        let stableConsumerPassRates: [String: Double]
        let parserAcceptanceRate: Double
        let unsupportedRefusalRate: Double
        let attemptCount: Int
        let results: [CaseResult]
    }

    private struct QualityProbeReport: Codable {
        let protocolID: String
        let reportKind: String
        let releaseQualification: Bool
        let releaseGateCaseCount: Int
        let fixedCaseIDs: [String]
        let artifactID: String
        let modelRevision: String
        let generatedAt: Date
        let operatingSystem: String
        let physicalMemoryBytes: UInt64
        let stableCaseCount: Int
        let stablePassedCount: Int
        let parserAcceptanceRate: Double
        let attemptCount: Int
        let results: [CaseResult]
    }

    private struct StableCase {
        let language: String
        let consumer: String
        let passed: Bool
    }

    func testReleaseEnglishRussianFourConsumerQuality() async throws {
        guard configuredValue(
            environment: "ZBS_EYE_LOCAL_AI_QUALITY_GATE",
            plist: "ZBSEyeLocalAIQualityGate"
        ) == "1" else {
            throw XCTSkip("Set ZBS_EYE_LOCAL_AI_QUALITY_GATE=1 to run the physical v7 quality gate")
        }
        guard let path = configuredValue(
            environment: "ZBS_EYE_MODEL_DIR",
            plist: "ZBSEyeModelDirectory"
        ) else {
            XCTFail("V7 quality gate requires ZBS_EYE_MODEL_DIR")
            return
        }

        let modelDirectory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let manifest = BuiltInModelManifest.regular
        _ = try BuiltInModelVerifier.verify(directory: modelDirectory, manifest: manifest)
        XCTAssertEqual(manifest.generation.benchmarkProtocol, LocalAIV7ProtocolSupport.protocolID)
        let fixtures = try loadFixtures()
        XCTAssertEqual(fixtures.map(\.caseCount), [32, 32])
        XCTAssertEqual(fixtures.flatMap(\.cases).count, 64)

        let container = try await LocalModelTestSupport.loadContainer(from: modelDirectory)
        let results = try await runQualityCases(
            allQualityCases(in: fixtures),
            container: container,
            manifest: manifest
        )

        let report = makeReport(results: results, manifest: manifest)
        try write(report: report)
        Memory.clearCache()

        XCTAssertEqual(report.stableCaseCount, 64)
        XCTAssertEqual(report.attemptCount, 192)
        XCTAssertEqual(report.results.filter(\.mustRefuse).count, 24)
        XCTAssertGreaterThanOrEqual(report.stableOverallPassRate, 0.90)
        XCTAssertEqual(Set(report.stableLanguagePassRates.keys), ["en", "ru"])
        for (language, rate) in report.stableLanguagePassRates {
            XCTAssertGreaterThanOrEqual(rate, 0.85, "\(language) release quality")
        }
        XCTAssertEqual(
            Set(report.stableConsumerPassRates.keys),
            ["ask", "insights", "summary", "label"]
        )
        for (consumer, rate) in report.stableConsumerPassRates {
            XCTAssertGreaterThanOrEqual(rate, 0.85, "\(consumer) release quality")
        }
        XCTAssertGreaterThanOrEqual(report.parserAcceptanceRate, 0.95)
        XCTAssertEqual(report.unsupportedRefusalRate, 1.0)
    }

    func testBoundedEnglishRussianFourConsumerProbe() async throws {
        guard configuredValue(
            environment: "ZBS_EYE_LOCAL_AI_QUALITY_PROBE",
            plist: "ZBSEyeLocalAIQualityProbe"
        ) == "1" else {
            throw XCTSkip(
                "Set ZBS_EYE_LOCAL_AI_QUALITY_PROBE=1 to run the bounded physical v7 probe"
            )
        }
        guard let path = configuredValue(
            environment: "ZBS_EYE_MODEL_DIR",
            plist: "ZBSEyeModelDirectory"
        ) else {
            XCTFail("V7 quality probe requires ZBS_EYE_MODEL_DIR")
            return
        }

        let modelDirectory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let manifest = BuiltInModelManifest.regular
        _ = try BuiltInModelVerifier.verify(directory: modelDirectory, manifest: manifest)
        XCTAssertEqual(manifest.generation.benchmarkProtocol, LocalAIV7ProtocolSupport.protocolID)
        let fixtures = try loadFixtures()
        let byID = Dictionary(
            uniqueKeysWithValues: allQualityCases(in: fixtures).map {
                ($0.testCase.id, $0)
            }
        )
        let probeCases = try LocalAIV7ProbeSupport.caseIDs.map { id in
            guard let qualityCase = byID[id] else { throw V7QualityError.invalidFixture }
            return qualityCase
        }
        XCTAssertEqual(probeCases.count, 8)
        XCTAssertEqual(Set(probeCases.map { $0.testCase.id }), LocalAIV7ProbeSupport.caseIDSet)

        let container = try await LocalModelTestSupport.loadContainer(from: modelDirectory)
        let results = try await runQualityCases(
            probeCases,
            container: container,
            manifest: manifest
        )
        let stable = stableCases(from: results)
        let generatedAt = Date()
        let report = QualityProbeReport(
            protocolID: LocalAIV7ProtocolSupport.protocolID,
            reportKind: "bounded-preflight-probe",
            releaseQualification: false,
            releaseGateCaseCount: 64,
            fixedCaseIDs: LocalAIV7ProbeSupport.caseIDs,
            artifactID: manifest.id,
            modelRevision: manifest.revision,
            generatedAt: generatedAt,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            stableCaseCount: 8,
            stablePassedCount: stable.filter(\.passed).count,
            parserAcceptanceRate: Double(results.filter { $0.status != nil }.count)
                / Double(results.count),
            attemptCount: 24,
            results: results
        )
        try write(probeReport: report)
        Memory.clearCache()

        XCTAssertEqual(results.count, report.attemptCount)
        XCTAssertEqual(stable.count, report.stableCaseCount)
        XCTAssertEqual(report.stablePassedCount, 8)
        XCTAssertEqual(report.parserAcceptanceRate, 1.0)
    }

    private func loadFixtures() throws -> [FixtureFile] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/evals/fixtures", isDirectory: true)
        return try ["local-ai-v7-en", "local-ai-v7-ru"].map { name in
            let data = try Data(
                contentsOf: root.appendingPathComponent(name).appendingPathExtension("json")
            )
            let fixture = try JSONDecoder().decode(FixtureFile.self, from: data)
            guard fixture.protocolID == LocalAIV7ProtocolSupport.protocolID,
                  fixture.caseCount == fixture.cases.count else {
                throw V7QualityError.invalidFixture
            }
            return fixture
        }
    }

    private func allQualityCases(in fixtures: [FixtureFile]) -> [QualityCase] {
        fixtures.flatMap { fixture in
            fixture.cases.map {
                QualityCase(language: fixture.language, testCase: $0)
            }
        }
    }

    /// Both the bounded probe and the 64-case release gate enter through this
    /// exact production-request, generation, parser, renderer, and scorer path.
    private func runQualityCases(
        _ qualityCases: [QualityCase],
        container: ModelContainer,
        manifest: BuiltInModelManifest
    ) async throws -> [CaseResult] {
        let clock = ContinuousClock()
        var results: [CaseResult] = []
        for qualityCase in qualityCases {
            let testCase = qualityCase.testCase
            let request = try await productionRequest(
                for: testCase,
                language: qualityCase.language,
                manifest: manifest
            )
            let seeds = try LocalAIV7ProtocolSupport.evaluationSeeds(
                promptContract: testCase.promptContract,
                caseID: testCase.id,
                input: testCase.input
            )
            XCTAssertEqual(seeds.count, 3)
            for (variant, seed) in seeds {
                let started = clock.now
                let generated = try await generate(
                    container: container,
                    request: request,
                    seed: seed
                )
                let elapsed = started.duration(to: clock.now).seconds
                let scored = parseAndScore(
                    generated: generated,
                    request: request,
                    testCase: testCase,
                    language: qualityCase.language
                )
                results.append(CaseResult(
                    id: testCase.id,
                    language: qualityCase.language,
                    consumer: testCase.consumer,
                    category: testCase.category,
                    mustRefuse: testCase.expect.mustRefuse,
                    variant: variant,
                    seed: seed,
                    passed: scored.failures.isEmpty,
                    failures: scored.failures,
                    status: scored.status,
                    rawOutput: generated.rawOutput,
                    output: scored.output,
                    elapsedSeconds: elapsed
                ))
                print(
                    "QUALITY-V7 \(testCase.id)/\(variant) "
                        + "\(scored.failures.isEmpty ? "PASS" : "FAIL") "
                        + "\(elapsed)s: \(scored.failures.joined(separator: ", "))"
                )
            }
        }
        return results
    }

    private func productionRequest(
        for testCase: EvalCase,
        language: String,
        manifest: BuiltInModelManifest
    ) async throws -> LLMRequest {
        let selection = ProviderSelectionSnapshot(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: manifest.id,
            selectionRevision: .init(rawValue: 1),
            authorizationEpoch: .init(rawValue: 1)
        )
        let execution = AIConsumerExecutionContext(
            selection: selection,
            contextTokenCeiling: manifest.generation.contextTokenCeiling,
            executedLocally: true,
            recipientDisclosure: nil
        )
        let capture = V7RequestCaptureRouter()

        if testCase.consumer == "ask" {
            let evidence = (testCase.input.evidence ?? []).enumerated().map { index, item in
                AskRetrievedEvidence(
                    source: SearchResult(
                        id: Int64(index + 1),
                        kind: .screen,
                        ts: Date(timeIntervalSince1970: Double(index + 1)),
                        bundleId: "gg.zbs.synthetic",
                        appName: "Synthetic fixture",
                        windowTitle: item.source,
                        browserURL: nil,
                        snippet: item.text,
                        relativePath: nil
                    ),
                    text: item.text
                )
            }
            let service = AskService(
                retrieval: V7AskRetrieval(evidence: evidence),
                router: capture
            )
            _ = try? await service.answer(
                question: testCase.input.question ?? "",
                execution: AskExecutionContext(
                    selection: selection,
                    contextTokenCeiling: manifest.generation.contextTokenCeiling,
                    executedLocally: true,
                    recipientDisclosure: nil
                ),
                requestID: UUID()
            )
            return try await capturedRequest(from: capture)
        }

        let outputLanguage: LocalAIOutputLanguage = language == "ru" ? .ru : .en
        let plan: AIConsumerGenerationPlan
        switch testCase.consumer {
        case "insights":
            guard let activity = testCase.input.activity else {
                throw V7QualityError.invalidFixture
            }
            let hints = LocalAIContextPolicy.insightsHints(
                totalCaptures: activity.totalCaptures,
                contextSwitches: activity.contextSwitches,
                apps: activity.topApps.map {
                    LocalAIActivityApp(
                        name: $0.app,
                        minutes: $0.minutes,
                        captures: $0.captures
                    )
                },
                textSamples: activity.textSamples
            )
            plan = AIConsumerPromptFactory.dailyInsights(
                hints: hints,
                language: outputLanguage,
                maximumSampleCharacters: 360,
                timeout: .seconds(300)
            )
        case "summary":
            guard let summary = testCase.input.summary else {
                throw V7QualityError.invalidFixture
            }
            plan = AIConsumerPromptFactory.dailySummary(
                consumer: .manualSummary,
                language: outputLanguage,
                dateLine: summary.dateLine,
                countLine: summary.countLine,
                fragments: summary.fragments.map {
                    AIConsumerPromptFragment(sourceID: $0.sourceID, text: $0.text)
                },
                maximumFragmentCharacters: 960,
                maximumOutputTokens: 800,
                timeout: .seconds(300)
            )
        case "label":
            guard let label = testCase.input.label else {
                throw V7QualityError.invalidFixture
            }
            let detected = LocalAIContextPolicy.outputLanguage(for: label.signals)
            guard detected == outputLanguage else { throw V7QualityError.invalidFixture }
            plan = AIConsumerPromptFactory.generatedLabel(
                serializedBlock: label.serializedBlock,
                language: detected,
                maximumFragmentCharacters: 1_080,
                timeout: .seconds(300)
            )
        default:
            throw V7QualityError.invalidFixture
        }

        _ = try? await RoutedAIConsumerGenerator(router: capture).generate(
            plan: plan,
            execution: execution,
            requestID: UUID()
        )
        return try await capturedRequest(from: capture)
    }

    private func capturedRequest(from capture: V7RequestCaptureRouter) async throws -> LLMRequest {
        guard let request = await capture.request() else {
            throw V7QualityError.requestWasNotCaptured
        }
        return request
    }

    private func generate(
        container: ModelContainer,
        request: LLMRequest,
        seed: UInt64
    ) async throws -> GeneratedOutput {
        let session = ChatSession(
            container,
            instructions: request.systemPrompt,
            generateParameters: GenerateParameters(
                maxTokens: request.maximumOutputTokens,
                temperature: 0.2,
                topP: 0.95,
                prefillStepSize: 256,
                seed: seed
            ),
            additionalContext: ["enable_thinking": false],
            tools: [LocalAIAnswerToolContract.schema]
        )
        var chunks = ""
        var calls: [ToolCall] = []
        for try await event in session.streamDetails(to: request.userPrompt) {
            switch event {
            case .chunk(let chunk): chunks += chunk
            case .toolCall(let call): calls.append(call)
            case .info: break
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedCalls = try calls.map { call in
            String(decoding: try encoder.encode(call.function.arguments), as: UTF8.self)
        }
        return GeneratedOutput(
            chunks: chunks,
            calls: calls,
            rawOutput: ([chunks].filter { !$0.isEmpty } + encodedCalls).joined(separator: "\n")
        )
    }

    private func parseAndScore(
        generated: GeneratedOutput,
        request: LLMRequest,
        testCase: EvalCase,
        language: String
    ) -> (status: String?, output: String, failures: [String]) {
        guard let contract = request.localOutputContract else {
            return (nil, generated.rawOutput, ["missing-production-contract"])
        }
        let envelope: LocalAIOutputEnvelope
        do {
            guard generated.chunks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  generated.calls.count == 1 else {
                throw LocalAIAnswerToolContractError.invalidArguments
            }
            envelope = try LocalAIAnswerToolContract.parse(
                generated.calls[0],
                purpose: contract.purpose,
                allowedSources: contract.allowedSources
            )
        } catch {
            return (nil, generated.rawOutput, ["parser"])
        }

        let output = LocalAIOutputRenderer.render(
            envelope,
            purpose: contract.purpose,
            language: contract.language
        )
        var failures = score(output: output, envelope: envelope, testCase: testCase)
        guard let expectedStatus = expectedStatus(for: testCase) else {
            failures.append("fixture-status")
            return (envelope.status.rawValue, output, failures)
        }
        if envelope.status != expectedStatus { failures.append("status") }
        if contract.language.rawValue != language { failures.append("language-contract") }
        if !Set(contract.allowedSources).isSubset(of: Set(testCase.expect.allowedSources)) {
            failures.append("fixture-production-source-drift")
        }
        return (envelope.status.rawValue, output, Array(Set(failures)).sorted())
    }

    private func expectedStatus(for testCase: EvalCase) -> LocalAIOutputStatus? {
        switch (testCase.consumer, testCase.expect.answerability) {
        case ("ask", "supported"), ("insights", "supported"),
             ("summary", "supported"), ("label", "supported"):
            return .supported
        case ("ask", "partial"):
            return .uncertain
        case ("insights", "partial"):
            return .conflict
        case ("ask", "unsupported"):
            return .notFound
        case ("insights", "unsupported"):
            return .insufficient
        default:
            return nil
        }
    }

    private func score(
        output: String,
        envelope: LocalAIOutputEnvelope,
        testCase: EvalCase
    ) -> [String] {
        var failures: [String] = []
        let normalized = normalize(output)
        if output.isEmpty || output.contains("\0") { failures.append("empty-output") }
        for concept in testCase.expect.requiredConcepts
        where !concept.anyOf.contains(where: { conceptMatches($0, output: normalized) }) {
            failures.append("concept:\(concept.id)")
        }
        for quote in testCase.expect.requiredExactQuotes where !output.contains(quote) {
            failures.append("required-quote")
        }
        for forbidden in testCase.expect.forbiddenSubstrings
        where normalized.contains(normalize(forbidden)) {
            failures.append("forbidden")
        }

        let usedSources = Set(envelope.items.flatMap(\.sources))
        if !Set(testCase.expect.requiredSources).isSubset(of: usedSources) {
            failures.append("required-source")
        }
        if !usedSources.isSubset(of: Set(testCase.expect.allowedSources)) {
            failures.append("invented-source")
        }

        let withoutCitations = output.replacingOccurrences(
            of: #"\[\d+\]"#,
            with: "",
            options: .regularExpression
        )
        let numbers = Set(matches(
            #"(?<![\p{L}])\d+(?::\d{2})?(?![\p{L}])"#,
            in: withoutCitations
        ))
        if !numbers.isSubset(of: Set(testCase.expect.allowedNumbers)) {
            failures.append("invented-number")
        }
        if withoutCitations.split(whereSeparator: \Character.isWhitespace).count
            > testCase.expect.maxWords {
            failures.append("word-limit")
        }
        if output.split(whereSeparator: \Character.isNewline).count
            > testCase.expect.maxLines {
            failures.append("line-limit")
        }
        if !languagePasses(output, expected: testCase.expect.outputLanguage) {
            failures.append("language")
        }
        return failures
    }

    private func makeReport(
        results: [CaseResult],
        manifest: BuiltInModelManifest
    ) -> QualityReport {
        let stable = stableCases(from: results)
        func rates(key: (StableCase) -> String) -> [String: Double] {
            Dictionary(grouping: stable, by: key).mapValues { group in
                Double(group.filter(\.passed).count) / Double(group.count)
            }
        }
        let unsupported = results.filter(\.mustRefuse)
        let correctRefusals = unsupported.filter { result in
            result.status == (result.consumer == "ask" ? "not_found" : "insufficient")
        }
        return QualityReport(
            protocolID: LocalAIV7ProtocolSupport.protocolID,
            artifactID: manifest.id,
            modelRevision: manifest.revision,
            generatedAt: Date(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            stableCaseCount: stable.count,
            stablePassedCount: stable.filter(\.passed).count,
            stableOverallPassRate: Double(stable.filter(\.passed).count) / Double(stable.count),
            stableLanguagePassRates: rates(key: \.language),
            stableConsumerPassRates: rates(key: \.consumer),
            parserAcceptanceRate: Double(results.filter { $0.status != nil }.count)
                / Double(results.count),
            unsupportedRefusalRate: Double(correctRefusals.count) / Double(unsupported.count),
            attemptCount: results.count,
            results: results
        )
    }

    private func stableCases(from results: [CaseResult]) -> [StableCase] {
        Dictionary(grouping: results, by: \.id).values.map { attempts in
            StableCase(
                language: attempts[0].language,
                consumer: attempts[0].consumer,
                passed: attempts.count == 3 && attempts.allSatisfy(\.passed)
            )
        }
    }

    private func write(report: QualityReport) throws {
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
        let destination = root.appendingPathComponent("local-ai-v7-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: destination, options: .atomic)
        print("QUALITY-V7 report: \(destination.path)")
    }

    private func write(probeReport: QualityProbeReport) throws {
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
        let stamp = ISO8601DateFormatter().string(from: probeReport.generatedAt)
            .replacingOccurrences(of: ":", with: "-")
        let destination = root.appendingPathComponent("local-ai-v7-probe-\(stamp).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(probeReport).write(to: destination, options: .atomic)
        print("QUALITY-V7 probe report: \(destination.path)")
    }

    private func configuredValue(environment: String, plist: String) -> String? {
        let raw = ProcessInfo.processInfo.environment[environment]
            ?? Bundle(for: LocalAIQualityGateV7Tests.self)
                .object(forInfoDictionaryKey: plist) as? String
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func normalize(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private func conceptMatches(_ candidate: String, output: String) -> Bool {
        let candidate = normalize(candidate)
        if output.contains(candidate) { return true }
        let expectedTokens = semanticTokens(candidate)
        let outputTokens = Set(semanticTokens(output))
        return !expectedTokens.isEmpty && expectedTokens.allSatisfy(outputTokens.contains)
    }

    private func semanticTokens(_ value: String) -> [String] {
        let stop: Set<String> = [
            "a", "an", "the", "is", "are", "at", "on", "in", "of", "to", "and", "or",
            "в", "во", "на", "и", "или", "это", "по", "с", "со", "из",
        ]
        return matches(#"[\p{L}\p{N}:#-]+"#, in: value).compactMap { raw in
            let token = raw.lowercased()
            guard !stop.contains(token) else { return nil }
            if token.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }),
               token.count >= 6 {
                return String(token.prefix(5))
            }
            if token.count > 5, token.hasSuffix("ing") { return String(token.dropLast(3)) }
            if token.count > 4, token.hasSuffix("ed") { return String(token.dropLast(2)) }
            if token.count > 4, token.hasSuffix("s") { return String(token.dropLast()) }
            return token
        }
    }

    private func languagePasses(_ output: String, expected: String) -> Bool {
        let scalars = output.unicodeScalars
        let latin = scalars.filter {
            (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
        }.count
        let cyrillic = scalars.filter { (0x0400...0x04FF).contains($0.value) }.count
        let total = latin + cyrillic
        guard total > 0 else { return false }
        if expected == "ru" {
            return cyrillic >= 5 && Double(cyrillic) / Double(total) >= 0.35
        }
        return latin >= 5 && Double(cyrillic) / Double(total) <= 0.05
    }

    private func matches(_ pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        }
    }
}

private enum V7QualityError: Error {
    case invalidFixture
    case requestWasNotCaptured
    case captured
}

private actor V7RequestCaptureRouter: AskLLMRouting, AIConsumerLLMRouting {
    private var captured: LLMRequest?

    func generate(
        _ request: LLMRequest,
        expectedSelection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        captured = request
        throw V7QualityError.captured
    }

    func request() -> LLMRequest? { captured }
}

private struct V7AskRetrieval: AskRetrievalProviding {
    let evidence: [AskRetrievedEvidence]

    func retrieve(question: String, limit: Int) async throws -> [AskRetrievedEvidence] {
        Array(evidence.prefix(limit))
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds)
            + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
