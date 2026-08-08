import Foundation

enum AIModelOutputChannel: Sendable, Equatable {
    case builtInNativeTool
    case visibleText
}

/// Stable provider identities. Models are deliberately not represented here:
/// the UI shows provider entities, and each provider owns its own catalog and
/// per-provider selection.
enum AIProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case zbsEyeLocal
    case codex
    case openrouter
    case anthropic
    case moonshot
    case zai
    case xiaomi
    case openai
    case claudeCode
    case ollama
    case lmstudio
    case custom
    case customAPI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zbsEyeLocal: return "ZBS Eye Local"
        case .codex:       return "Codex"
        case .openrouter:  return "OpenRouter"
        case .anthropic:   return "Anthropic"
        case .moonshot:    return "Moonshot AI"
        case .zai:         return "Z.AI"
        case .xiaomi:      return "Xiaomi"
        case .openai:      return "OpenAI"
        case .claudeCode:  return "Claude Code"
        case .ollama:      return "Ollama"
        case .lmstudio:    return "LM Studio"
        case .custom:      return "Local Compatible"
        case .customAPI:   return "Custom API"
        }
    }

    var isCloud: Bool {
        switch self {
        case .zbsEyeLocal, .ollama, .lmstudio, .custom:
            return false
        case .codex, .openrouter, .anthropic, .moonshot, .zai, .xiaomi,
                .openai, .claudeCode, .customAPI:
            return true
        }
    }

    /// The actual recipient named in the consent surface. Subprocess providers
    /// still count as cloud because their authenticated CLI sends the excerpt.
    var egressDestination: String? {
        switch self {
        case .zbsEyeLocal, .ollama, .lmstudio, .custom:
            return nil
        case .codex:
            return "OpenAI, via your Codex login"
        case .openrouter:
            return "OpenRouter and the selected upstream model operator"
        case .anthropic:
            return "Anthropic"
        case .moonshot:
            return "Moonshot AI (Kimi)"
        case .zai:
            return "Z.AI"
        case .xiaomi:
            return "Xiaomi MiMo"
        case .openai:
            return "OpenAI"
        case .claudeCode:
            return "Anthropic, via your Claude Code login"
        case .customAPI:
            return "the custom API endpoint you configured"
        }
    }

    /// Custom API consent names the concrete configured origin. Fixed
    /// providers retain their stable recipient disclosure.
    func egressDestination(for baseURL: String?) -> String? {
        guard self == .customAPI else { return egressDestination }
        guard let raw = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "Custom API at https://\(host.lowercased())\(port)"
    }

    func acceptsEgressDestination(_ disclosure: String?) -> Bool {
        if self != .customAPI { return disclosure == egressDestination }
        guard let disclosure else { return false }
        return disclosure.hasPrefix("Custom API at https://")
            && disclosure.utf8.count <= 1_024
            && !disclosure.contains("\n")
            && !disclosure.contains("\r")
    }

    var isSubprocess: Bool { self == .codex || self == .claudeCode }
    var outputChannel: AIModelOutputChannel {
        self == .zbsEyeLocal ? .builtInNativeTool : .visibleText
    }
    var usesAPIKey: Bool { keychainAccount != nil }

    /// Stable request dialect IDs. These values are part of the provider
    /// contract: transport routing must never be inferred from a display name,
    /// endpoint, or model identifier.
    enum Wire: String, Codable, Sendable, Equatable, Hashable {
        case builtInMLX = "mlx-in-process-v1"
        case openAICompatible = "openai-chat-completions-v1"
        case anthropicMessages = "anthropic-messages-v1"
        case codexAppServer = "codex-app-server-v1"
        case claudeCodeCLI = "claude-code-cli-v1"
    }

    /// Stable discovery dialect IDs. Catalog authority is independent from
    /// request transport: curated CLI choices are not a live HTTP catalog, and
    /// a bundled manifest is not an OpenAI `/models` response.
    enum CatalogDialect: String, Codable, Sendable, Equatable, Hashable {
        case bundledManifest = "bundled-manifest-v1"
        case openAIModels = "openai-models-v1"
        case anthropicModels = "anthropic-models-v1"
        case documentedSuggestions = "documented-suggestions-v1"
        case codexAppServer = "codex-app-server-v1"
        case curatedClaudeCode = "curated-claude-code-v1"
    }

    struct Descriptor: Codable, Sendable, Equatable, Hashable {
        let transport: Wire
        let catalog: CatalogDialect
    }

    var descriptor: Descriptor {
        switch self {
        case .zbsEyeLocal:
            return Descriptor(transport: .builtInMLX, catalog: .bundledManifest)
        case .codex:
            return Descriptor(transport: .codexAppServer, catalog: .codexAppServer)
        case .openrouter, .moonshot, .openai, .ollama, .lmstudio, .custom, .customAPI:
            return Descriptor(transport: .openAICompatible, catalog: .openAIModels)
        case .zai, .xiaomi:
            return Descriptor(
                transport: .openAICompatible,
                catalog: .documentedSuggestions
            )
        case .anthropic:
            return Descriptor(transport: .anthropicMessages, catalog: .anthropicModels)
        case .claudeCode:
            return Descriptor(transport: .claudeCodeCLI, catalog: .curatedClaudeCode)
        }
    }

    var wire: Wire { descriptor.transport }
    var catalogDialect: CatalogDialect { descriptor.catalog }

    /// Cloud endpoints are fixed. Only the three localhost server providers
    /// expose an endpoint override in the UI.
    var defaultBaseURL: String {
        switch self {
        case .zbsEyeLocal, .codex, .claudeCode:
            return ""
        case .openrouter:
            return "https://openrouter.ai/api/v1"
        case .anthropic:
            return "https://api.anthropic.com/v1"
        case .moonshot:
            return "https://api.moonshot.ai/v1"
        case .zai:
            return "https://api.z.ai/api/paas/v4"
        case .xiaomi:
            return "https://api.xiaomimimo.com/v1"
        case .openai:
            return "https://api.openai.com/v1"
        case .ollama:
            return "http://127.0.0.1:11434/v1"
        case .lmstudio:
            return "http://127.0.0.1:1234/v1"
        case .custom:
            return ""
        case .customAPI:
            return ""
        }
    }

    var apiHost: String? {
        switch self {
        case .zbsEyeLocal, .codex, .claudeCode, .ollama, .lmstudio, .custom, .customAPI:
            return nil
        case .openrouter: return "openrouter.ai"
        case .anthropic:  return "api.anthropic.com"
        case .moonshot:   return "api.moonshot.ai"
        case .zai:        return "api.z.ai"
        case .xiaomi:     return "api.xiaomimimo.com"
        case .openai:     return "api.openai.com"
        }
    }

    var keychainAccount: String? {
        switch self {
        case .zbsEyeLocal, .codex, .claudeCode, .ollama, .lmstudio, .custom:
            return nil
        case .openrouter: return "llm.openrouter"
        case .anthropic:  return "llm.anthropic"
        case .moonshot:   return "llm.moonshot"
        case .zai:        return "llm.zai"
        case .xiaomi:     return "llm.xiaomi"
        case .openai:     return "llm.openai"
        case .customAPI:  return "llm.custom-api"
        }
    }

    var keyConsoleURL: URL? {
        switch self {
        case .zbsEyeLocal, .codex, .claudeCode, .ollama, .lmstudio, .custom, .customAPI:
            return nil
        case .openrouter:
            return URL(string: "https://openrouter.ai/keys")
        case .anthropic:
            return URL(string: "https://console.anthropic.com/settings/keys")
        case .moonshot:
            return URL(string: "https://platform.kimi.ai")
        case .zai:
            return URL(string: "https://z.ai/manage-apikey/apikey-list")
        case .xiaomi:
            return URL(string: "https://platform.xiaomimimo.com")
        case .openai:
            return URL(string: "https://platform.openai.com/api-keys")
        }
    }

    var allowsEndpointOverride: Bool {
        self == .ollama || self == .lmstudio || self == .custom || self == .customAPI
    }

    static let claudeCodeDefaultModel = "default"
    static let claudeCodeModels = [
        "default", "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5-20251001",
    ]

    /// Provider-documented candidates for APIs that currently publish no
    /// authenticated model-list endpoint. These remain suggestions, never
    /// authoritative catalog entries.
    var documentedSuggestedModels: [String] {
        switch self {
        case .zai:
            return ["glm-5.1", "glm-5-turbo", "glm-5", "glm-4.7-flash"]
        case .xiaomi:
            return ["mimo-v2.5-pro", "mimo-v2.5"]
        default:
            return []
        }
    }

    /// Pure UI guidance inside this provider's own model list. A recommendation
    /// never creates catalog authority, persists a preference, or activates a
    /// pair. Live catalog order breaks ties so a provider can put its newest
    /// suitable model first without ZBS Eye inventing a cross-provider rank.
    func recommendedModel(in models: [String]) -> String? {
        let choices = models.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func first(containing fragments: [String]) -> String? {
            choices.first { model in
                let value = model.lowercased()
                return fragments.allSatisfy(value.contains)
            }
        }

        switch self {
        case .zbsEyeLocal:
            return choices.first { $0 == BuiltInModelManifest.regular.id }
        case .openrouter, .anthropic:
            return first(containing: ["claude", "haiku"])
        case .moonshot:
            return first(containing: ["kimi"])
        case .zai:
            return documentedSuggestedModels.first(where: choices.contains)
                ?? first(containing: ["glm"])
        case .xiaomi:
            return documentedSuggestedModels.first(where: choices.contains)
                ?? first(containing: ["mimo"])
        case .codex, .openai, .claudeCode, .ollama, .lmstudio, .custom, .customAPI:
            return nil
        }
    }

    static func isChatCapableOpenAIModel(_ id: String) -> Bool {
        if id.hasPrefix("gpt-") { return true }
        return id.range(of: #"^o\d"#, options: .regularExpression) != nil
    }
}

/// A user's pending global provider/model choice. The selection revision is
/// captured when the choice is made, so a delayed confirmation or provisioning
/// completion cannot overwrite a newer choice.
struct ActivationIntent: Codable, Sendable, Equatable, Hashable {
    let providerID: String
    let modelID: String
    let expectedSelectionRevision: SelectionRevision
}

/// Ownership token for an asynchronous remove/disconnect flow. It can commit
/// the deliberate-off state only while the exact provider/model pair still
/// owns the captured revision; a late completion must never turn off a newer
/// choice.
struct DeactivationIntent: Codable, Sendable, Equatable, Hashable {
    let providerID: String
    let modelID: String
    let expectedSelectionRevision: SelectionRevision
}

/// The one deliberately separate model route used by the Activities day
/// summary. It is not a general per-consumer routing table: Ask and every
/// existing consumer continue to use the global active pair.
struct ActivitySummaryRouteSettings: Codable, Sendable, Equatable {
    var providerID: String?
    var modelID: String?
    var enabled: Bool
    var revision: SelectionRevision

    static let disabled = Self(
        providerID: nil,
        modelID: nil,
        enabled: false,
        revision: .zero
    )

    mutating func enable(providerID: String, modelID: String) {
        let cleanModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty, !cleanModel.isEmpty else { return }
        guard self.providerID != providerID
                || self.modelID != cleanModel
                || !enabled else { return }
        self.providerID = providerID
        self.modelID = cleanModel
        enabled = true
        revision.advance()
    }

    mutating func disable() {
        guard enabled else { return }
        enabled = false
        revision.advance()
    }

    func selectionSnapshot(
        authorizationEpoch: AuthorizationEpoch
    ) -> ProviderSelectionSnapshot? {
        guard enabled,
              let providerID,
              let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.isEmpty else { return nil }
        return ProviderSelectionSnapshot(
            providerID: providerID,
            modelID: modelID,
            selectionRevision: revision,
            authorizationEpoch: authorizationEpoch
        )
    }
}

struct ActivitySummaryRouteCandidate: Sendable, Equatable, Identifiable {
    let provider: AIProvider
    let modelIDs: [String]

    var id: String { provider.rawValue }
}

/// Pure loading policy shared by the store and persistence tests. A corrupt
/// current payload is never mistaken for an intentional reset: the most recent
/// decodable snapshot is recovered when available, and the unreadable bytes are
/// returned so the store can retain a forensic/recovery copy before any write.
enum AIProviderSettingsArchive {
    enum Source: Sendable, Equatable {
        case current
        case lastKnownGood
        case defaults
    }

    struct Resolution: Sendable, Equatable {
        let settings: AIProviderSettings
        let source: Source
        let unreadableCurrentData: Data?
    }

    static func resolve(
        currentData: Data?,
        lastKnownGoodData: Data?
    ) -> Resolution {
        guard let currentData else {
            return Resolution(
                settings: AIProviderSettings(),
                source: .defaults,
                unreadableCurrentData: nil
            )
        }

        if let current = try? JSONDecoder().decode(AIProviderSettings.self, from: currentData) {
            return Resolution(
                settings: current,
                source: .current,
                unreadableCurrentData: nil
            )
        }

        if let lastKnownGoodData,
           let recovered = try? JSONDecoder().decode(
               AIProviderSettings.self,
               from: lastKnownGoodData
           ) {
            return Resolution(
                settings: recovered,
                source: .lastKnownGood,
                unreadableCurrentData: currentData
            )
        }

        return Resolution(
            settings: AIProviderSettings(),
            source: .defaults,
            unreadableCurrentData: currentData
        )
    }
}

/// Versioned provider state. Dictionary keys stay as raw strings so a newer
/// provider survives a round trip through an older build instead of being
/// erased merely because the enum does not know it yet.
struct AIProviderSettings: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var active: String?
    /// The committed model in the global active pair. This is intentionally
    /// separate from `models`, which stores an inactive card preference.
    var activeModelID: String?
    var models: [String: String]
    var endpoints: [String: String]
    /// Kept for downgrade compatibility and migration only. New authorization
    /// checks use `consentGrants` with an explicit consumer scope.
    var cloudConsent: [String: Bool]
    var processingDisabledByUser: Bool
    /// Durable product-wide kill switch. Unlike `processingDisabledByUser`,
    /// which remembers that the primary Ask model was disconnected, this also
    /// gates the separately persisted Activities summary route.
    var allProcessingDisabledByUser: Bool
    var selectionRevision: SelectionRevision
    var authorizationEpoch: AuthorizationEpoch
    var consentGrants: [String: ScopedAIConsentGrant]

    init(
        active: String? = nil,
        activeModelID: String? = nil,
        models: [String: String] = [:],
        endpoints: [String: String] = [:],
        cloudConsent: [String: Bool] = [:],
        processingDisabledByUser: Bool = false,
        allProcessingDisabledByUser: Bool = false,
        selectionRevision: SelectionRevision = .zero,
        authorizationEpoch: AuthorizationEpoch = .zero,
        consentGrants: [String: ScopedAIConsentGrant]? = nil,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.active = active
        self.activeModelID = active.flatMap { providerID in
            activeModelID ?? models[providerID]
        }
        self.models = models
        self.endpoints = endpoints
        self.cloudConsent = cloudConsent
        self.processingDisabledByUser = processingDisabledByUser
        self.allProcessingDisabledByUser = allProcessingDisabledByUser
        self.selectionRevision = selectionRevision
        self.authorizationEpoch = authorizationEpoch
        self.consentGrants = consentGrants ?? Self.migrateLegacyConsent(cloudConsent)
    }

    var activeProvider: AIProvider? { active.flatMap(AIProvider.init(rawValue:)) }

    var selectionSnapshot: ProviderSelectionSnapshot? {
        guard let providerID = active,
              let modelID = activeModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.isEmpty else { return nil }
        return ProviderSelectionSnapshot(
            providerID: providerID,
            modelID: modelID,
            selectionRevision: selectionRevision,
            authorizationEpoch: authorizationEpoch
        )
    }

    func consentGrant(forProviderID providerID: String) -> ScopedAIConsentGrant? {
        consentGrants[providerID]
    }

    func isAuthorized(providerID: String, consumer: AIConsumer) -> Bool {
        guard let provider = AIProvider(rawValue: providerID) else { return false }
        if !provider.isCloud { return true }
        guard let recipient = provider.egressDestination(
                  for: endpoints[providerID] ?? provider.defaultBaseURL
              ),
              let grant = consentGrants[providerID],
              grant.providerID == providerID,
              grant.recipientDisclosure == recipient,
              [ScopedAIConsentGrant.legacyPolicyRevision,
               ScopedAIConsentGrant.currentPolicyRevision].contains(grant.policyRevision)
        else { return false }
        return grant.consumers.contains(consumer)
    }

    mutating func setPreferredModel(_ modelID: String, providerID: String) {
        models[providerID] = modelID
    }

    /// Atomically commits the pending global pair and an optional scoped cloud
    /// consent draft. Stale intents and invalid/missing cloud consent fail
    /// closed without mutating preferences, consent, revisions, or the pair.
    @discardableResult
    mutating func commitActivation(
        _ intent: ActivationIntent,
        consentDraft: ScopedAIConsentGrant? = nil,
        requiredConsumers: Set<AIConsumer> = Set(
            AIConsumer.allCases.filter { $0 != .activitySummary }
        )
    ) -> Bool {
        guard intent.expectedSelectionRevision == selectionRevision else { return false }
        return commitCurrentActivation(
            providerID: intent.providerID,
            modelID: intent.modelID,
            consent: consentDraft,
            requiredConsumers: requiredConsumers
        )
    }

    private mutating func commitCurrentActivation(
        providerID: String,
        modelID: String,
        consent: ScopedAIConsentGrant? = nil,
        requiredConsumers: Set<AIConsumer>
    ) -> Bool {
        let cleanModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanModel.isEmpty,
              let provider = AIProvider(rawValue: providerID) else { return false }

        if provider.isCloud {
            let effectiveGrant = consent ?? consentGrants[providerID]
            let expectedRecipient = provider.egressDestination(
                for: endpoints[providerID] ?? provider.defaultBaseURL
            )
            guard !requiredConsumers.isEmpty,
                  let effectiveGrant,
                  effectiveGrant.providerID == providerID,
                  effectiveGrant.recipientDisclosure == expectedRecipient,
                  effectiveGrant.policyRevision == ScopedAIConsentGrant.currentPolicyRevision,
                  requiredConsumers.isSubset(of: effectiveGrant.consumers)
            else { return false }
        } else if consent != nil {
            return false
        }

        var consentChanged = false
        if let consent,
           consent.providerID == providerID,
           provider.isCloud,
           consent.recipientDisclosure == provider.egressDestination(
               for: endpoints[providerID] ?? provider.defaultBaseURL
           ),
           consentGrants[providerID] != consent {
            consentGrants[providerID] = consent
            cloudConsent[providerID] = true
            consentChanged = true
        }

        let pairChanged = active != providerID || activeModelID != cleanModel
        let productWideDisableChanged = allProcessingDisabledByUser
        models[providerID] = cleanModel
        active = providerID
        activeModelID = cleanModel
        processingDisabledByUser = false
        allProcessingDisabledByUser = false
        if pairChanged { selectionRevision.advance() }
        if pairChanged || consentChanged || productWideDisableChanged {
            authorizationEpoch.advance()
        }
        return true
    }

    mutating func disableAllProcessing() {
        guard !allProcessingDisabledByUser else { return }
        allProcessingDisabledByUser = true
        authorizationEpoch.advance()
    }

    mutating func enableAllProcessing() {
        guard allProcessingDisabledByUser else { return }
        allProcessingDisabledByUser = false
        authorizationEpoch.advance()
    }

    mutating func deactivate() {
        guard active != nil || !processingDisabledByUser else { return }
        active = nil
        activeModelID = nil
        processingDisabledByUser = true
        selectionRevision.advance()
        authorizationEpoch.advance()
    }

    @discardableResult
    mutating func commitDeactivation(_ intent: DeactivationIntent) -> Bool {
        guard
            intent.expectedSelectionRevision == selectionRevision,
            active == intent.providerID,
            activeModelID == intent.modelID
        else { return false }
        deactivate()
        return true
    }

    mutating func setConsent(_ grant: ScopedAIConsentGrant?) {
        guard let grant,
              let provider = AIProvider(rawValue: grant.providerID),
              provider.isCloud,
              grant.recipientDisclosure == provider.egressDestination(
                  for: endpoints[grant.providerID] ?? provider.defaultBaseURL
              ) else { return }
        if consentGrants[grant.providerID] != grant {
            consentGrants[grant.providerID] = grant
            cloudConsent[grant.providerID] = true
            authorizationEpoch.advance()
        }
    }

    mutating func revokeConsent(providerID: String) {
        let removedGrant = consentGrants.removeValue(forKey: providerID) != nil
        let removedLegacy = cloudConsent.removeValue(forKey: providerID) != nil
        let changed = removedGrant || removedLegacy
        if changed { authorizationEpoch.advance() }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case active
        case activeModelID
        case models
        case endpoints
        case cloudConsent
        case processingDisabledByUser
        case allProcessingDisabledByUser
        case selectionRevision
        case authorizationEpoch
        case consentGrants
    }

    private struct RawCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)

        func lossy<T: Decodable>(_ type: T.Type, _ key: CodingKeys, default fallback: T) -> T {
            (try? values.decodeIfPresent(type, forKey: key)) ?? fallback
        }

        schemaVersion = lossy(Int.self, .schemaVersion, default: Self.currentSchemaVersion)
        active = (try? values.decodeIfPresent(String.self, forKey: .active)) ?? nil
        let decodedModels = lossy([String: String].self, .models, default: [:])
        models = decodedModels
        let decodedActiveModel = (try? values.decodeIfPresent(String.self, forKey: .activeModelID))
            ?? nil
        activeModelID = active.flatMap { providerID in
            decodedActiveModel ?? decodedModels[providerID]
        }
        endpoints = lossy([String: String].self, .endpoints, default: [:])
        cloudConsent = lossy([String: Bool].self, .cloudConsent, default: [:])
        processingDisabledByUser = lossy(Bool.self, .processingDisabledByUser, default: false)
        allProcessingDisabledByUser = lossy(
            Bool.self,
            .allProcessingDisabledByUser,
            default: false
        )
        selectionRevision = lossy(SelectionRevision.self, .selectionRevision, default: .zero)
        authorizationEpoch = lossy(AuthorizationEpoch.self, .authorizationEpoch, default: .zero)
        if values.contains(.consentGrants) {
            // Present-but-empty means revoked. Present-but-malformed fails
            // closed. Decode entries independently so one malformed or future
            // grant cannot erase valid grants. Presence remains authoritative:
            // skipped entries must never resurrect a stale legacy boolean.
            var decodedGrants: [String: ScopedAIConsentGrant] = [:]
            if let grantValues = try? values.nestedContainer(
                keyedBy: RawCodingKey.self,
                forKey: .consentGrants
            ) {
                for key in grantValues.allKeys {
                    if let grant = try? grantValues.decode(
                        ScopedAIConsentGrant.self,
                        forKey: key
                    ) {
                        decodedGrants[key.stringValue] = grant
                    }
                }
            }
            consentGrants = decodedGrants
        } else {
            consentGrants = Self.migrateLegacyConsent(cloudConsent)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encodeIfPresent(active, forKey: .active)
        try values.encodeIfPresent(activeModelID, forKey: .activeModelID)
        try values.encode(models, forKey: .models)
        try values.encode(endpoints, forKey: .endpoints)
        try values.encode(cloudConsent, forKey: .cloudConsent)
        try values.encode(processingDisabledByUser, forKey: .processingDisabledByUser)
        try values.encode(allProcessingDisabledByUser, forKey: .allProcessingDisabledByUser)
        try values.encode(selectionRevision, forKey: .selectionRevision)
        try values.encode(authorizationEpoch, forKey: .authorizationEpoch)
        try values.encode(consentGrants, forKey: .consentGrants)
    }

    private static func migrateLegacyConsent(
        _ legacy: [String: Bool]
    ) -> [String: ScopedAIConsentGrant] {
        Dictionary(uniqueKeysWithValues: legacy.compactMap { providerID, allowed in
            guard allowed,
                  let provider = AIProvider(rawValue: providerID),
                  provider.isCloud,
                  let recipient = provider.egressDestination else { return nil }
            return (
                providerID,
                ScopedAIConsentGrant.legacy(
                    providerID: providerID,
                    recipientDisclosure: recipient
                )
            )
        })
    }
}
