import Foundation

enum LocalAIPerformanceProtocolError: Error, LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

enum LocalAIPerformanceLanguage: String, Codable, Sendable {
    case english = "en"
    case russian = "ru"
}

enum LocalAIPerformanceCapability: Sendable, Equatable {
    case supported
    case unsupported(reason: String)
}

struct LocalAIPerformanceProtocol: Codable, Sendable, Equatable {
    struct Execution: Codable, Sendable, Equatable {
        var offline: Bool
        var serial: Bool
        var retryCount: Int
    }

    struct Hardware: Codable, Sendable, Equatable {
        var machineIdentifier: String
        var physicalMemoryBytes: UInt64
        var architecture: String
    }

    struct Generation: Codable, Sendable, Equatable {
        var temperature: Double
        var topP: Double
        var prefillStepSize: Int
        var thinkingMode: String
        var maximumOutputTokens: Int
        var safetyTokens: Int
        var seed: UInt64
    }

    struct Context: Codable, Sendable, Equatable {
        var id: String
        var preparedInputTokens: Int
    }

    struct Sampling: Codable, Sendable, Equatable {
        var coldPerContext: Int
        var warmPerContext: Int
        var retainedMemoryGenerations: Int
        var retainedMemoryContextID: String
        var languages: [LocalAIPerformanceLanguage]
        var warmupPerContext: Int
        var noRetries: Bool
    }

    struct PromptMaterial: Codable, Sendable, Equatable {
        var system: String
        var englishPrefix: String
        var englishFiller: String
        var russianPrefix: String
        var russianFiller: String

        func prefix(for language: LocalAIPerformanceLanguage) -> String {
            switch language {
            case .english: englishPrefix
            case .russian: russianPrefix
            }
        }

        func filler(for language: LocalAIPerformanceLanguage) -> String {
            switch language {
            case .english: englishFiller
            case .russian: russianFiller
            }
        }
    }

    struct Aggregation: Codable, Sendable, Equatable {
        var percentileMethod: String
        var reportPercentiles: [Double]
    }

    struct Thresholds: Codable, Sendable, Equatable {
        var twoKColdTTFTP95Seconds: Double
        var twoKWarmTTFTP95Seconds: Double
        var fullColdTTFTP95Seconds: Double
        var fullWarmTTFTP95Seconds: Double
        var minimumDecodeTokensPerSecond: Double
        var maximumCancellationSeconds: Double
        var maximumIncrementalPeakBytes: Double
        var maximumRetainedGrowthBytes: Double
        var minimumUnloadReleaseFraction: Double
        var maximumUnloadSeconds: Double
    }

    var protocolID: String
    var artifactID: String
    var artifactRevision: String
    var qualityProtocolID: String
    var buildConfiguration: String
    var execution: Execution
    var hardware: Hardware
    var generation: Generation
    var contexts: [Context]
    var sampling: Sampling
    var promptMaterial: PromptMaterial
    var coldDefinition: String
    var warmDefinition: String
    var wiredTicketDefinition: String
    var aggregation: Aggregation
    var thresholds: Thresholds
    var limitations: [String]

    static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func validate(against manifest: BuiltInModelManifest) throws {
        let gib = UInt64(1_024 * 1_024 * 1_024)
        let expectedFullInput = manifest.generation.contextTokenCeiling
            - generation.maximumOutputTokens
            - generation.safetyTokens
        let invalidReason: String?

        if protocolID != "local-ai-performance-v1" {
            invalidReason = "Unexpected protocol id"
        } else if artifactID != manifest.id || artifactRevision != manifest.revision {
            invalidReason = "Benchmark artifact does not match the manifest"
        } else if qualityProtocolID != manifest.generation.benchmarkProtocol {
            invalidReason = "Quality protocol does not match the manifest"
        } else if buildConfiguration != "Release" || !execution.offline
            || !execution.serial || execution.retryCount != 0
        {
            invalidReason = "Benchmark execution must be offline Release, serial, and no-retry"
        } else if hardware.machineIdentifier != "Mac16,5"
            || hardware.physicalMemoryBytes != 64 * gib || hardware.architecture != "arm64"
        {
            invalidReason = "Only the exact Mac16,5 / 64 GiB / arm64 envelope is qualified"
        } else if generation.temperature != manifest.generation.temperature
            || generation.topP != manifest.generation.topP
            || generation.prefillStepSize != 256
            || generation.thinkingMode != manifest.generation.thinkingMode.rawValue
            || generation.maximumOutputTokens != 256
            || generation.safetyTokens != 64
        {
            invalidReason = "Generation settings differ from the production profile"
        } else if contexts.map(\.preparedInputTokens) != [2_048, expectedFullInput]
            || expectedFullInput != 7_872
        {
            invalidReason = "Prepared input sizes must be exactly 2048 and 7872 tokens"
        } else if sampling.coldPerContext != 20 || sampling.warmPerContext != 30
            || sampling.retainedMemoryGenerations != 50
            || sampling.retainedMemoryContextID != "prepared-full"
            || sampling.languages != [.english, .russian]
            || sampling.warmupPerContext != 1 || !sampling.noRetries
        {
            invalidReason = "Sampling does not match the locked balanced no-retry protocol"
        } else if aggregation.percentileMethod != "nearest-rank"
            || aggregation.reportPercentiles != [0.5, 0.95]
        {
            invalidReason = "Only nearest-rank p50/p95 aggregation is accepted"
        } else if coldDefinition.isEmpty || warmDefinition.isEmpty
            || wiredTicketDefinition.isEmpty || promptMaterial.system.isEmpty
        {
            invalidReason = "Benchmark definitions and prompt material must be explicit"
        } else {
            invalidReason = nil
        }

        if let invalidReason {
            throw LocalAIPerformanceProtocolError.invalid(invalidReason)
        }
    }
}

enum LocalAIPerformanceMath {
    static func nearestRank(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty, percentile > 0, percentile <= 1 else { return nil }
        let sorted = values.sorted()
        let rank = Int(ceil(percentile * Double(sorted.count)))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    static func balancedLanguages(count: Int) -> [LocalAIPerformanceLanguage] {
        guard count > 0 else { return [] }
        return (0..<count).map { $0.isMultiple(of: 2) ? .english : .russian }
    }

    static func capabilityFailures(
        protocol benchmark: LocalAIPerformanceProtocol,
        coldSemantics: LocalAIPerformanceCapability,
        wiredTicket: LocalAIPerformanceCapability
    ) -> [String] {
        var failures: [String] = []
        switch coldSemantics {
        case .supported:
            if benchmark.coldDefinition.isEmpty { failures.append("cold semantics undefined") }
        case .unsupported(let reason):
            failures.append("cold semantics unsupported: \(reason)")
        }
        switch wiredTicket {
        case .supported:
            if benchmark.wiredTicketDefinition.isEmpty { failures.append("wired ticket undefined") }
        case .unsupported(let reason):
            failures.append("wired ticket unsupported: \(reason)")
        }
        return failures
    }
}
