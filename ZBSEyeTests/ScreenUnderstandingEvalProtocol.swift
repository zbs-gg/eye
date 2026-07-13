import Foundation

enum ScreenUnderstandingProtocolError: Error, LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

enum ScreenUnderstandingLane: String, Codable, Sendable, Hashable {
    case officialCheckpointQuality = "official-checkpoint-quality"
    case productFootprint = "product-footprint"
}

enum ScreenUnderstandingInputCapability: String, Codable, Sendable, Hashable {
    case singleImage = "single-image"
    case temporalPair = "temporal-pair"
}

enum ScreenUnderstandingOutputCapability: String, Codable, Sendable, Hashable {
    case summary
    case atomicFacts = "atomic-facts"
    case visibleText = "visible-text"
    case labels
    case regions
    case changeFacts = "change-facts"
    case confidence
    case abstention
    case errors
    case runtimeMetadata = "runtime-metadata"
}

enum ScreenUnderstandingMethodDisposition: String, Codable, Sendable, Hashable {
    case baseline
    case candidate
    case researchOnly = "research-only"
}

enum ScreenUnderstandingMethodSizeClass: String, Codable, Sendable, Hashable {
    case builtin
    case micro
    case parser
    case large
}

enum ScreenUnderstandingSourceAccess: String, Codable, Sendable, Hashable {
    case readOnly = "read-only"
    case readWrite = "read-write"
}

struct ScreenUnderstandingQualificationEvidence: Sendable, Equatable {
    var exactProductRuntimeScored: Bool
    var exactProductRuntimeArtifactSHA256: String
    var overallUsefulnessGainPoints: Double
    var weakStratumUsefulnessGainPoints: Double
    var criticalTextRecallDeltaPoints: Double
    var severityWeightedHallucinationDeltaPoints: Double
    var minimumDecisionCellCount: Int
    var duplicateLabelFraction: Double
    var factAgreement: Double
    var decisionAgreement: Double
}

struct ScreenUnderstandingEvalProtocol: Codable, Sendable, Equatable {
    struct Identity: Codable, Sendable, Equatable {
        var id: String
        var revision: Int
    }

    struct Execution: Codable, Sendable, Equatable {
        var offline: Bool
        var retryCount: Int
        var serial: Bool
    }

    struct Method: Codable, Sendable, Equatable {
        var id: String
        var disposition: ScreenUnderstandingMethodDisposition
        var remote: Bool
        var sizeClass: ScreenUnderstandingMethodSizeClass
        var artifactRevision: String
        var artifactSHA256: String
        var license: String
        var inputCapabilities: [ScreenUnderstandingInputCapability]
        var outputCapabilities: [ScreenUnderstandingOutputCapability]
    }

    struct Corpus: Codable, Sendable, Equatable {
        var lockedSingleFrameCount: Int
        var lockedTemporalPairCount: Int
        var minimumHeldOutSingleFrames: Int
        var minimumHeldOutTemporalPairs: Int
        var minimumDecisionCellCount: Int
        var duplicateLabelFraction: Double
        var minimumFactAgreement: Double
        var minimumDecisionAgreement: Double
        var liveSourceAccess: ScreenUnderstandingSourceAccess
        var splitsLockedBeforeOutputs: Bool
    }

    struct QualityThresholds: Codable, Sendable, Equatable {
        var minimumOverallUsefulnessGainPoints: Double
        var minimumWeakStratumUsefulnessGainPoints: Double
        var minimumCriticalTextRecallDeltaPoints: Double
        var maximumHallucinationDeltaPoints: Double
    }

    struct FootprintThresholds: Codable, Sendable, Equatable {
        var maximumColdP95Seconds: Double
        var maximumWarmP95Seconds: Double
        var maximumIncrementalPeakBytes: UInt64
        var maximumRetainedGrowthBytes: UInt64
        var minimumUnloadReleaseFraction: Double
        var maximumUnloadSeconds: Double
    }

    struct Reporting: Codable, Sendable, Equatable {
        var combinedQualityFootprintScoreAllowed: Bool
        var rawResultsPrivate: Bool
        var atomicWrites: Bool
    }

    struct Publication: Codable, Sendable, Equatable {
        var allowCaseMaterial: Bool
        var schema: String
        var allowedClasses: [String]
    }

    var identity: Identity
    var execution: Execution
    var lanes: [ScreenUnderstandingLane]
    var methods: [Method]
    var corpus: Corpus
    var qualityThresholds: QualityThresholds
    var footprintThresholds: FootprintThresholds
    var reporting: Reporting
    var publication: Publication

    static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func validate() throws {
        guard identity.id == "screen-understanding-v1", identity.revision == 1 else {
            throw ScreenUnderstandingProtocolError.invalid("Unexpected protocol identity")
        }
        guard execution.offline, execution.serial else {
            throw ScreenUnderstandingProtocolError.invalid("Execution must remain offline and serial")
        }
        guard execution.retryCount == 0 else {
            throw ScreenUnderstandingProtocolError.invalid("Benchmark retry count must be zero")
        }
        guard Set(lanes) == [.officialCheckpointQuality, .productFootprint] else {
            throw ScreenUnderstandingProtocolError.invalid("Quality and footprint lanes must be explicit")
        }
        guard !methods.isEmpty, Set(methods.map(\.id)).count == methods.count else {
            throw ScreenUnderstandingProtocolError.invalid("Method identifiers must be unique")
        }

        for method in methods {
            if method.remote {
                throw ScreenUnderstandingProtocolError.invalid("Remote adapters are forbidden")
            }
            if method.sizeClass == .large {
                throw ScreenUnderstandingProtocolError.invalid("Large models are forbidden")
            }
            if method.artifactRevision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ScreenUnderstandingProtocolError.invalid("Every artifact revision must be pinned")
            }
            if method.artifactSHA256.count != 64
                || method.artifactSHA256.contains(where: { !$0.isHexDigit })
            {
                throw ScreenUnderstandingProtocolError.invalid("Every artifact hash must be SHA-256")
            }
            if method.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ScreenUnderstandingProtocolError.invalid("Every method license must be recorded")
            }
            if method.outputCapabilities.contains(.changeFacts)
                && !method.inputCapabilities.contains(.temporalPair)
            {
                throw ScreenUnderstandingProtocolError.invalid(
                    "Temporal change facts require temporal-pair input"
                )
            }
        }

        guard corpus.liveSourceAccess == .readOnly else {
            throw ScreenUnderstandingProtocolError.invalid("Live source access must be read-only")
        }
        guard corpus.splitsLockedBeforeOutputs else {
            throw ScreenUnderstandingProtocolError.invalid("Corpus splits must be locked before outputs")
        }
        guard corpus.minimumHeldOutSingleFrames >= 60,
              corpus.minimumHeldOutTemporalPairs >= 30,
              corpus.minimumDecisionCellCount >= 15 else {
            throw ScreenUnderstandingProtocolError.invalid("Held-out split and decision cells are underpowered")
        }
        guard corpus.duplicateLabelFraction >= 0.15,
              corpus.minimumFactAgreement >= 0.90,
              corpus.minimumDecisionAgreement >= 0.80 else {
            throw ScreenUnderstandingProtocolError.invalid("Canonical annotation agreement gate is too weak")
        }
        guard !reporting.combinedQualityFootprintScoreAllowed else {
            throw ScreenUnderstandingProtocolError.invalid("Quality and footprint lane scores cannot merge")
        }
        guard reporting.rawResultsPrivate, reporting.atomicWrites else {
            throw ScreenUnderstandingProtocolError.invalid("Private raw reports must use atomic writes")
        }
        guard !publication.allowCaseMaterial,
              publication.schema == "public-aggregate.schema.json" else {
            throw ScreenUnderstandingProtocolError.invalid("Publication must reject case material")
        }
    }

    func qualificationFailures(
        for evidence: ScreenUnderstandingQualificationEvidence
    ) -> [String] {
        var failures: [String] = []
        if !evidence.exactProductRuntimeScored
            || evidence.exactProductRuntimeArtifactSHA256.count != 64
            || evidence.exactProductRuntimeArtifactSHA256.contains(where: { !$0.isHexDigit })
        {
            failures.append("exact product runtime was not independently scored")
        }
        if evidence.overallUsefulnessGainPoints
            < qualityThresholds.minimumOverallUsefulnessGainPoints
        {
            failures.append("overall usefulness gain missed R20")
        }
        if evidence.weakStratumUsefulnessGainPoints
            < qualityThresholds.minimumWeakStratumUsefulnessGainPoints
        {
            failures.append("weak-stratum usefulness gain missed R20")
        }
        if evidence.criticalTextRecallDeltaPoints
            < qualityThresholds.minimumCriticalTextRecallDeltaPoints
        {
            failures.append("critical-text recall regressed beyond R20")
        }
        if evidence.severityWeightedHallucinationDeltaPoints
            > qualityThresholds.maximumHallucinationDeltaPoints
        {
            failures.append("severity-weighted hallucination exceeded R20")
        }
        if evidence.minimumDecisionCellCount < corpus.minimumDecisionCellCount {
            failures.append("decision cell is underpowered")
        }
        if evidence.duplicateLabelFraction < corpus.duplicateLabelFraction
            || evidence.factAgreement < corpus.minimumFactAgreement
            || evidence.decisionAgreement < corpus.minimumDecisionAgreement
        {
            failures.append("canonical annotation agreement gate failed")
        }
        return failures
    }
}
