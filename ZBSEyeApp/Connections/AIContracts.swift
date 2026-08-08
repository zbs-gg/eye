import Foundation

struct SelectionRevision: RawRepresentable, Codable, Sendable, Hashable, Comparable {
    var rawValue: UInt64

    static let zero = SelectionRevision(rawValue: 0)

    static func < (lhs: SelectionRevision, rhs: SelectionRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    mutating func advance() { rawValue &+= 1 }
}

struct AuthorizationEpoch: RawRepresentable, Codable, Sendable, Hashable, Comparable {
    var rawValue: UInt64

    static let zero = AuthorizationEpoch(rawValue: 0)

    static func < (lhs: AuthorizationEpoch, rhs: AuthorizationEpoch) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    mutating func advance() { rawValue &+= 1 }
}

enum AIConsumer: String, Codable, Sendable, CaseIterable, Hashable {
    case ask
    case dailyInsights
    case manualSummary
    case scheduledSummary
    case generatedLabels
    case activitySummary

    var isAutomatic: Bool {
        switch self {
        case .scheduledSummary, .generatedLabels, .activitySummary: true
        case .ask, .dailyInsights, .manualSummary: false
        }
    }
}

struct ScopedAIConsentGrant: Codable, Sendable, Equatable {
    static let legacyPolicyRevision = "legacy-manual-v1"
    static let currentPolicyRevision = "provider-egress-v2"
    static let legacyConsumers: Set<AIConsumer> = [
        .ask, .dailyInsights, .manualSummary, .scheduledSummary,
    ]

    var providerID: String
    var recipientDisclosure: String?
    var consumers: Set<AIConsumer>
    var policyRevision: String

    /// Consumer IDs introduced by a newer build are intentionally kept out of
    /// the current authorization set, but retained for a lossless round trip.
    /// This lets an older build preserve future state without granting access
    /// to a consumer whose behavior it cannot understand.
    private var unrecognizedConsumerIDs: Set<String>

    init(
        providerID: String,
        recipientDisclosure: String?,
        consumers: Set<AIConsumer>,
        policyRevision: String
    ) {
        self.providerID = providerID
        self.recipientDisclosure = recipientDisclosure
        self.consumers = consumers
        self.policyRevision = policyRevision
        self.unrecognizedConsumerIDs = []
    }

    static func legacy(providerID: String, recipientDisclosure: String?) -> Self {
        Self(
            providerID: providerID,
            recipientDisclosure: recipientDisclosure,
            consumers: legacyConsumers,
            policyRevision: legacyPolicyRevision
        )
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case recipientDisclosure
        case consumers
        case policyRevision
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try values.decode(String.self, forKey: .providerID)
        recipientDisclosure = try values.decodeIfPresent(String.self, forKey: .recipientDisclosure)
        policyRevision = try values.decode(String.self, forKey: .policyRevision)

        let consumerIDs = try values.decode([String].self, forKey: .consumers)
        consumers = Set(consumerIDs.compactMap(AIConsumer.init(rawValue:)))
        unrecognizedConsumerIDs = Set(
            consumerIDs.filter { AIConsumer(rawValue: $0) == nil }
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(providerID, forKey: .providerID)
        try values.encodeIfPresent(recipientDisclosure, forKey: .recipientDisclosure)
        try values.encode(policyRevision, forKey: .policyRevision)
        let consumerIDs = Set(consumers.map(\.rawValue)).union(unrecognizedConsumerIDs)
        try values.encode(consumerIDs.sorted(), forKey: .consumers)
    }
}

struct ProviderSelectionSnapshot: Codable, Sendable, Equatable, Hashable {
    let providerID: String
    let modelID: String
    let selectionRevision: SelectionRevision
    let authorizationEpoch: AuthorizationEpoch
}

enum ModelSelectionAvailability: Sendable, Equatable {
    case notSelected
    case unknownUntilAuthoritative
    case available
    case missingFromAuthoritativeCatalog
    case providerUnavailable
    case unsupported
}

enum ProviderCatalogState: Sendable, Equatable {
    case notLoaded
    case authoritative([String])
    case unavailable
    case unsupported

    func selectionAvailability(for selectedModelID: String) -> ModelSelectionAvailability {
        guard !selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notSelected
        }
        switch self {
        case .notLoaded:
            return .unknownUntilAuthoritative
        case .authoritative(let models):
            return models.contains(selectedModelID) ? .available : .missingFromAuthoritativeCatalog
        case .unavailable:
            return .providerUnavailable
        case .unsupported:
            return .unsupported
        }
    }

    /// Guidance only. The caller may display this candidate, but discovery must
    /// never write it into persisted selection.
    func recommendation(from candidates: [String]) -> String? {
        guard case .authoritative(let models) = self else { return nil }
        return candidates.first(where: models.contains)
    }

    var models: [String] {
        guard case .authoritative(let models) = self else { return [] }
        return models
    }

    /// A successful response is authoritative only when every advertised
    /// model has a usable identifier. An actually empty array is valid and
    /// remains distinguishable from a malformed payload whose entries collapse
    /// to nothing after validation.
    static func validatingSuccessfulPayload(_ rawModels: [String]) -> Self {
        var seen = Set<String>()
        var models: [String] = []
        models.reserveCapacity(rawModels.count)

        for rawModel in rawModels {
            let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { return .unavailable }
            if seen.insert(model).inserted { models.append(model) }
        }
        return .authoritative(models)
    }
}

/// Strict decoder for the model-list envelope shared by OpenAI-compatible and
/// Anthropic catalog endpoints. A 2xx response with another JSON shape is an
/// availability error, not an authoritative empty catalog.
enum ProviderCatalogPayload {
    private struct Envelope: Decodable {
        struct Model: Decodable {
            let id: String
        }

        let data: [Model]
    }

    static func modelIDs(from data: Data) throws -> [String] {
        try JSONDecoder().decode(Envelope.self, from: data).data.map(\.id)
    }
}

enum LLMRequestPriority: Int, Codable, Sendable, Comparable {
    case generatedLabels = 0
    case scheduledSummary = 1
    case explicitInsight = 2
    case ask = 3

    static func < (lhs: LLMRequestPriority, rhs: LLMRequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct LLMRequest: Sendable, Equatable {
    let id: UUID
    let consumer: AIConsumer
    let priority: LLMRequestPriority
    let systemPrompt: String
    let userPrompt: String
    let maximumOutputTokens: Int
    let timeout: Duration
    /// Local-only structured output metadata. Cloud/subprocess adapters ignore
    /// this value; the built-in runtime requires it so untrusted model output
    /// can be validated without scraping source identifiers out of prompts.
    let localOutputContract: LocalAIOutputContractRequest?

    init(
        id: UUID,
        consumer: AIConsumer,
        priority: LLMRequestPriority,
        systemPrompt: String,
        userPrompt: String,
        maximumOutputTokens: Int,
        timeout: Duration,
        localOutputContract: LocalAIOutputContractRequest? = nil
    ) {
        self.id = id
        self.consumer = consumer
        self.priority = priority
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.maximumOutputTokens = maximumOutputTokens
        self.timeout = timeout
        self.localOutputContract = localOutputContract
    }
}

struct AIExecutionProvenance: Codable, Sendable, Equatable {
    let providerID: String
    let modelID: String
    let executedLocally: Bool
    let generatedAt: Date
    let brokerUpstream: String?
}

struct LLMResponse: Sendable, Equatable {
    let content: String
    let truncated: Bool
    let provenance: AIExecutionProvenance
}

protocol LLMAdapter: Sendable {
    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse
}
