import Foundation
import Observation

protocol AIProviderCatalogLoading: Sendable {
    func load(
        provider: AIProvider,
        baseURL: URL,
        timeout: Duration
    ) async throws -> ProviderCatalogState
}

extension ProviderHTTPCatalogClient: AIProviderCatalogLoading {}

protocol AIProviderCredentialStoring {
    func get(_ account: String) -> String?
    @discardableResult func set(_ value: String, account: String) -> Bool
    @discardableResult func delete(_ account: String) -> Bool
}

struct KeychainAIProviderCredentialStore: AIProviderCredentialStoring {
    func get(_ account: String) -> String? { KeychainStore.get(account) }
    func set(_ value: String, account: String) -> Bool {
        KeychainStore.set(value, account: account)
    }
    func delete(_ account: String) -> Bool { KeychainStore.delete(account) }
}

/// State of the "AI Models" section: one card per provider, exactly ONE active processing model across
/// all of them. @MainActor @Observable — the UI binds straight to it; the network probes go through the
/// process-wide LLMRouter. Persistence: UserDefaults "zbseye.ai.provider" (JSON, no secrets) with a one-time
/// migration from the legacy "zbseye.connections.llm" {baseURL, model} — an existing local setup keeps
/// working without the user touching anything. API keys are ONLY in the Keychain (never in defaults,
/// never in this observable state, never logged).
@MainActor
@Observable
final class AIProviderStore {
    enum CardStatus: Sendable, Equatable {
        case notConfigured
        case probing
        case connected(Int)     // model count
        case error(String)
    }

    /// State of the OpenRouter "Sign in" (OAuth + PKCE) flow. `running` = browser opened, waiting for the
    /// callback / exchanging the code; `failed` carries a user-facing message. On success we fall back to
    /// `idle` after the key is saved and the normal connect()/probe runs.
    enum OAuthPhase: Sendable, Equatable {
        case idle
        case running
        case failed(String)
    }

    /// Presence of the `claude` CLI for the Claude Code provider. `unknown` = not yet probed;
    /// `found` carries the resolved absolute path; `notFound` = the card shows an install hint and
    /// can't be activated. The path is never shown in the UI — only whether it exists.
    enum ClaudeCodeState: Sendable, Equatable {
        case unknown
        case checking
        case found(String)
        case notFound
        case unavailable(String)
    }

    private struct CodexProbeBaseline {
        let connection: CodexConnectionState
        let catalog: ProviderCatalogState?
        let status: CardStatus?
    }

    private struct CodexProbeOperation {
        let attempt: Int
        let task: Task<Void, Never>
    }

    private struct ClaudeCodeProbeBaseline {
        let connection: ClaudeCodeState
        let catalog: ProviderCatalogState?
        let status: CardStatus?
    }

    private struct AutomaticLocalProbe: Sendable {
        let provider: AIProvider
        let baseURL: URL
        let connectionAttempt: Int
    }

    private struct AutomaticLocalProbeResult: Sendable {
        enum Outcome: Sendable {
            case catalog(ProviderCatalogState)
            case unavailable
            case cancelled
        }

        let probe: AutomaticLocalProbe
        let outcome: Outcome
    }

    var settings: AIProviderSettings {
        didSet {
            guard settings != oldValue else { return }
            if !settingsAlreadyPersisted {
                persist()
            }
            if settings.selectionRevision != oldValue.selectionRevision
                || settings.authorizationEpoch != oldValue.authorizationEpoch {
                notifyRouterOfRoutingChange()
            }
        }
    }
    /// Per-provider reachability/auth state. This is deliberately independent from both the user's
    /// persisted model preference and the global committed active pair.
    private(set) var statuses: [String: CardStatus] = [:]
    /// Authority of the latest model catalog observed this session. A catalog may become unavailable or
    /// omit the preferred/active model without mutating either persisted identity.
    private(set) var catalogs: [String: ProviderCatalogState] = [:]
    /// Whether a Keychain key exists per cloud provider (the key itself never enters observable state).
    private(set) var keyPresent: [String: Bool] = [:]
    /// OpenRouter one-click sign-in progress (nothing else here observes the key material).
    private(set) var openRouterOAuthPhase: OAuthPhase = .idle
    /// Whether the user's Claude Code CLI is installed (drives the Claude Code card's dot + activation).
    private(set) var claudeCode: ClaudeCodeState = .unknown
    /// Prompt-free Codex App Server setup/auth/catalog state. Only `.authenticated`
    /// is eligible for activation and overlay registration.
    private(set) var codexConnection: CodexConnectionState = .unknown
    /// A totally unreadable current payload is preserved in UserDefaults rather
    /// than overwritten with empty state during launch. Field-level corruption
    /// is recovered by AIProviderSettings' lossy decoder before reaching here.
    private(set) var persistenceWarning: String?

    @ObservationIgnored private var oauthTask: Task<Void, Never>?
    /// Monotonically-increasing token that identifies the current OAuth attempt. A completion (or a late
    /// cancel) only mutates state if it still matches — so a superseded flow can't clobber a newer one.
    @ObservationIgnored private var oauthAttempt = 0
    @ObservationIgnored private var connectionAttempts: [String: Int] = [:]
    @ObservationIgnored private var codexAttempt = 0
    @ObservationIgnored private var claudeCodeAttempt = 0
    @ObservationIgnored private var codexProbeOperation: CodexProbeOperation?
    @ObservationIgnored private var codexProbeBaseline: CodexProbeBaseline?
    @ObservationIgnored private var claudeCodeProbeBaseline: ClaudeCodeProbeBaseline?
    @ObservationIgnored private var codexProvider: (any CodexProviderConnecting)?
    @ObservationIgnored private var claudeCodeProvider: (any ClaudeCodeProviderConnecting)?
    @ObservationIgnored private var processOverlay: LLMAdapterRegistry?
    @ObservationIgnored private var routerChangeNotification: (@Sendable () async -> Void)?
    @ObservationIgnored private let catalogClient: any AIProviderCatalogLoading
    @ObservationIgnored private let credentialStore: any AIProviderCredentialStoring
    @ObservationIgnored private let defaults: UserDefaults
    /// Best-effort acknowledgement/fault-injection seam. UserDefaults does not
    /// provide a transactional fsync boundary; the built-in model journal's
    /// next-process recovery receipt owns crash safety instead.
    @ObservationIgnored private let persistenceSynchronizer: () -> Bool
    @ObservationIgnored private var settingsAlreadyPersisted = false
    private static let key = "zbseye.ai.provider"
    private static let lastKnownGoodKey = "zbseye.ai.provider.lastKnownGood"
    private static let unreadableRecoveryKey = "zbseye.ai.provider.unreadableRecovery"
    private static let legacyKey = "zbseye.connections.llm"

    init(
        defaults persistedDefaults: UserDefaults = .standard,
        storedKeyExists: ((AIProvider) -> Bool)? = nil,
        catalogClient injectedCatalogClient: (any AIProviderCatalogLoading)? = nil,
        credentialStore injectedCredentialStore: (any AIProviderCredentialStoring)? = nil,
        persistenceSynchronizer injectedPersistenceSynchronizer: (() -> Bool)? = nil
    ) {
        defaults = persistedDefaults
        persistenceSynchronizer = injectedPersistenceSynchronizer
            ?? { persistedDefaults.synchronize() }
        catalogClient = injectedCatalogClient ?? ProviderHTTPCatalogClient(
            credentials: KeychainProviderHTTPCredentials()
        )
        let resolvedCredentialStore = injectedCredentialStore
            ?? KeychainAIProviderCredentialStore()
        credentialStore = resolvedCredentialStore
        if let data = persistedDefaults.data(forKey: Self.key) {
            let resolution = AIProviderSettingsArchive.resolve(
                currentData: data,
                lastKnownGoodData: persistedDefaults.data(forKey: Self.lastKnownGoodKey)
            )
            settings = resolution.settings

            switch resolution.source {
            case .current:
                // Any decodable current payload becomes the recovery point for
                // a later launch whose primary value is totally unreadable.
                persistedDefaults.set(data, forKey: Self.lastKnownGoodKey)
            case .lastKnownGood:
                persistenceWarning = String(localized: "AI model settings were recovered from the last known good copy. The unreadable payload was preserved.")
            case .defaults:
                persistenceWarning = String(localized: "AI model settings could not be read. The unreadable payload was preserved for recovery.")
            }

            if let unreadable = resolution.unreadableCurrentData {
                persistedDefaults.set(unreadable, forKey: Self.unreadableRecoveryKey)
            }
        } else {
            // One-time migration: the legacy config was always a LOCAL OpenAI-compatible endpoint.
            settings = Self.migrateLegacy(from: persistedDefaults) ?? AIProviderSettings()
            persist()
        }
        let keyLookup = storedKeyExists ?? { provider in
            guard let account = provider.keychainAccount else { return false }
            return !(resolvedCredentialStore.get(account) ?? "").isEmpty
        }
        for p in AIProvider.allCases where p.isCloud {
            keyPresent[p.rawValue] = keyLookup(p)
        }
    }

    /// Installs the process-provider control plane after AppEnvironment has
    /// resolved the real generative data root. A persisted process provider is
    /// reconnected only when it is still the active choice and owns at least
    /// one valid scoped consent grant. Inactive or unconsented providers stay
    /// completely quiet until the user presses their explicit Check button.
    func configureProcessProviders(
        codex: any CodexProviderConnecting,
        claudeCode: any ClaudeCodeProviderConnecting,
        overlay: LLMAdapterRegistry
    ) {
        codexProvider = codex
        claudeCodeProvider = claudeCode
        processOverlay = overlay
        guard let active = settings.activeProvider,
              active.isSubprocess,
              AIConsumer.allCases.contains(where: {
                  settings.isAuthorized(providerID: active.rawValue, consumer: $0)
              }) else { return }
        Task { [weak self] in await self?.connect(active) }
    }

    /// Wires the app-lifetime router after bootstrap constructs it. Routing
    /// revisions are observed centrally in `settings.didSet`, so every commit
    /// path gets prompt queued/active cancellation without bespoke callbacks.
    func configureRouterChangeNotification(
        _ notification: @escaping @Sendable () async -> Void
    ) {
        routerChangeNotification = notification
    }

    private func notifyRouterOfRoutingChange() {
        guard let routerChangeNotification else { return }
        Task { await routerChangeNotification() }
    }

    // MARK: derived state

    var activeProvider: AIProvider? { settings.activeProvider }
    var activeModelID: String? { settings.activeModelID }
    var selectionSnapshot: ProviderSelectionSnapshot? { settings.selectionSnapshot }
    /// The revision exists independently of an active pair. In particular, an
    /// explicit "None" selection still owns its advanced revision and must not
    /// be mistaken for a fresh revision zero by delayed provisioning work.
    var currentSelectionRevision: SelectionRevision { settings.selectionRevision }

    func model(for p: AIProvider) -> String { settings.models[p.rawValue] ?? "" }
    /// A card edit is only an inactive preference. The global active pair changes exclusively through
    /// `activate`, so editing the active provider's card cannot redirect work that is already configured.
    func setModel(_ m: String, for p: AIProvider) {
        settings.setPreferredModel(m, providerID: p.rawValue)
    }

    /// Cloud endpoints are pinned; local ones take the user override (custom has no default at all).
    func endpoint(for p: AIProvider) -> String {
        if p.isCloud { return p.defaultBaseURL }
        if let o = settings.endpoints[p.rawValue], !o.trimmingCharacters(in: .whitespaces).isEmpty { return o }
        return p.defaultBaseURL
    }
    func setEndpoint(_ s: String, for p: AIProvider) {
        guard p.allowsEndpointOverride else { return }
        guard settings.endpoints[p.rawValue] != s else { return }
        connectionAttempts[p.rawValue, default: 0] &+= 1
        settings.endpoints[p.rawValue] = s
        // Reachability/catalog belonged to the old server. Preserve the preference and committed pair,
        // but invalidate authorization for work that may have snapshotted the old endpoint.
        statuses[p.rawValue] = .notConfigured
        catalogs[p.rawValue] = .notLoaded
        if isActive(p) { settings.authorizationEpoch.advance() }
    }

    func status(_ p: AIProvider) -> CardStatus { statuses[p.rawValue] ?? .notConfigured }

    func catalogState(_ p: AIProvider) -> ProviderCatalogState {
        if let catalog = catalogs[p.rawValue] { return catalog }
        // Built-in provisioning and Codex App Server own separate authoritative
        // lifecycles; neither may fall through to an HTTP model-list probe.
        switch p.catalogDialect {
        case .bundledManifest, .codexAppServer:
            return .unsupported
        case .openAIModels, .anthropicModels, .documentedSuggestions, .curatedClaudeCode:
            return .notLoaded
        }
    }

    func selectionAvailability(_ p: AIProvider) -> ModelSelectionAvailability {
        catalogState(p).selectionAvailability(for: model(for: p))
    }

    /// Models from a live authoritative catalog only. Curated CLI/static suggestions intentionally do not
    /// appear here, so the UI cannot accidentally label them as server-verified.
    func fetchedModels(_ p: AIProvider) -> [String] { catalogState(p).models }

    /// Choices the provider card may show right now: an authoritative live catalog, or explicitly curated
    /// CLI/static choices after authentication was proven. The persisted preference is NEVER folded into
    /// this list; a missing choice remains visibly missing instead of becoming fake catalog authority.
    func availableModels(for p: AIProvider) -> [String] {
        switch p.catalogDialect {
        case .bundledManifest, .codexAppServer:
            return catalogState(p).models
        case .curatedClaudeCode:
            if case .found = claudeCode { return AIProvider.claudeCodeModels }
            return []
        case .documentedSuggestions:
            guard hasKey(p) else { return [] }
            return p.documentedSuggestedModels
        case .anthropicModels:
            guard hasKey(p) else { return [] }
            return catalogState(p).models
        case .openAIModels:
            if p.usesAPIKey {
                guard hasKey(p) else { return [] }
            } else {
                guard !endpoint(for: p).trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
            }
            return catalogState(p).models
        }
    }

    /// True once the USER has configured or activated any provider by hand — a saved API key, a saved
    /// local endpoint override, or an active selection. Merely auto-detected presence (e.g. the Claude
    /// Code CLI, or a probed local server) does NOT count, so first-run onboarding still auto-expands for
    /// someone who just happens to have `claude` installed.
    var userHasConfiguredProvider: Bool {
        if settings.active != nil { return true }
        if keyPresent.values.contains(true) { return true }
        return settings.endpoints.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func hasKey(_ p: AIProvider) -> Bool { keyPresent[p.rawValue] ?? false }

    func consentGrant(_ p: AIProvider) -> ScopedAIConsentGrant? {
        settings.consentGrant(forProviderID: p.rawValue)
    }

    /// The default keeps the existing UI and previously shipped manual Ask path compatible with a
    /// `legacy-manual-v1` grant. New consumers must always name their own scope explicitly.
    func hasConsent(_ p: AIProvider, for consumer: AIConsumer = .ask) -> Bool {
        settings.isAuthorized(providerID: p.rawValue, consumer: consumer)
    }

    func hasConsent(_ p: AIProvider, for consumers: Set<AIConsumer>) -> Bool {
        consumers.allSatisfy { settings.isAuthorized(providerID: p.rawValue, consumer: $0) }
    }

    func revokeConsent(_ p: AIProvider) {
        settings.revokeConsent(providerID: p.rawValue)
    }

    func isActive(_ p: AIProvider) -> Bool { activeProvider == p }

    /// Captures an immutable user choice against the current selection revision.
    /// Discovery may change around it, but confirmation can only commit while
    /// both the choice and its provider are still valid.
    func activationIntent(for p: AIProvider, modelID: String) -> ActivationIntent? {
        let cleanModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanModel.isEmpty, canActivate(p, modelID: cleanModel) else { return nil }
        return ActivationIntent(
            providerID: p.rawValue,
            modelID: cleanModel,
            expectedSelectionRevision: settings.selectionRevision
        )
    }

    /// Captures the user's one-click built-in provisioning choice before the
    /// multi-gigabyte artifact is available. This does not make the model
    /// selectable or active; the manager still has to verify and load the exact
    /// product manifest before the normal commitActivation boundary can pass.
    func builtInProvisioningIntent(modelID: String) -> ActivationIntent? {
        let cleanModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BuiltInModelManifest.all.contains(where: { $0.id == cleanModel }) else {
            return nil
        }
        return ActivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: cleanModel,
            expectedSelectionRevision: settings.selectionRevision
        )
    }

    /// Publishes process-local runtime truth into the provider catalog. Only a
    /// verified, loadable installation is authoritative. Removal or runtime
    /// failure immediately makes the provider unavailable without fabricating
    /// a model from a persisted preference.
    @discardableResult
    func publishBuiltInRuntimeAvailability(modelID: String?) -> Bool {
        let provider = AIProvider.zbsEyeLocal
        let nextCatalog: ProviderCatalogState
        let nextStatus: CardStatus
        if let modelID,
           BuiltInModelManifest.all.contains(where: { $0.id == modelID }) {
            nextCatalog = .authoritative([modelID])
            nextStatus = .connected(1)
        } else {
            nextCatalog = .unavailable
            nextStatus = .notConfigured
        }

        let previousCatalog = catalogState(provider)
        let previousStatus = status(provider)
        guard previousCatalog != nextCatalog || previousStatus != nextStatus else {
            return false
        }
        catalogs[provider.rawValue] = nextCatalog
        statuses[provider.rawValue] = nextStatus
        if isActive(provider), previousCatalog != nextCatalog {
            // The router's immutable snapshot must change when an active local
            // runtime disappears or becomes usable after bootstrap.
            settings.authorizationEpoch.advance()
        }
        return true
    }

    /// The only store-level activation commit boundary. When cloud consent is
    /// confirmed, its fully-scoped grant and the provider/model pair are written
    /// in the same settings mutation. A stale intent or newly-unavailable
    /// provider returns false and leaves all persisted state untouched.
    @discardableResult
    func commitActivation(
        _ intent: ActivationIntent,
        grantCloudConsent: Bool = false
    ) -> Bool {
        guard let p = AIProvider(rawValue: intent.providerID),
              canActivate(p, modelID: intent.modelID) else { return false }

        let consentDraft: ScopedAIConsentGrant?
        if grantCloudConsent {
            guard p.isCloud, let recipient = p.egressDestination else { return false }
            consentDraft = ScopedAIConsentGrant(
                providerID: p.rawValue,
                recipientDisclosure: recipient,
                consumers: Set(AIConsumer.allCases),
                policyRevision: ScopedAIConsentGrant.currentPolicyRevision
            )
        } else {
            consentDraft = nil
        }

        return settings.commitActivation(intent, consentDraft: consentDraft)
    }

    /// Captures ownership for an asynchronous remove/disconnect flow. The
    /// returned intent is safe to commit after draining because its revision
    /// and exact pair are rechecked atomically.
    func deactivationIntent(for provider: AIProvider) -> DeactivationIntent? {
        guard let snapshot = settings.selectionSnapshot,
              snapshot.providerID == provider.rawValue else { return nil }
        return DeactivationIntent(
            providerID: snapshot.providerID,
            modelID: snapshot.modelID,
            expectedSelectionRevision: snapshot.selectionRevision
        )
    }

    @discardableResult
    func commitDeactivation(_ intent: DeactivationIntent) -> Bool {
        settings.commitDeactivation(intent)
    }

    /// Best-effort provider persistence step used by the built-in model
    /// outbox. The proposed selection is queued before it is published into
    /// this in-memory store. The model journal retains either the pending
    /// effect or a next-process recovery receipt because UserDefaults cannot
    /// itself supply the crash-safe commit boundary.
    func commitBuiltInActivation(
        _ intent: ActivationIntent
    ) -> BuiltInModelProviderEffectResult {
        guard intent.providerID == AIProvider.zbsEyeLocal.rawValue,
              canActivate(.zbsEyeLocal, modelID: intent.modelID) else {
            return .stale
        }
        var candidate = settings
        guard candidate.commitActivation(intent) else { return .stale }
        return commitProviderSettingsWithAcknowledgement(candidate)
            ? .applied
            : .retryablePersistenceFailure
    }

    func commitBuiltInDeactivation(
        _ intent: DeactivationIntent
    ) -> BuiltInModelProviderEffectResult {
        guard intent.providerID == AIProvider.zbsEyeLocal.rawValue else {
            return .stale
        }
        var candidate = settings
        guard candidate.commitDeactivation(intent) else { return .stale }
        return commitProviderSettingsWithAcknowledgement(candidate)
            ? .applied
            : .retryablePersistenceFailure
    }

    private func canActivate(_ p: AIProvider, modelID: String) -> Bool {
        switch catalogState(p).selectionAvailability(for: modelID) {
        case .missingFromAuthoritativeCatalog, .providerUnavailable, .unsupported:
            return false
        case .notSelected, .unknownUntilAuthoritative, .available:
            break
        }
        if p.isCloud {
            if p.usesAPIKey, !hasKey(p) { return false }
            if p == .codex {
                guard case .authenticated = codexConnection else { return false }
            }
            if p == .claudeCode {
                guard case .found = claudeCode else { return false }
            }
        }
        return true
    }

    /// Turn Ask & Insights off — no model processes history until one is picked again. The per-provider
    /// selections, keys and consent are untouched, so re-activating later is a single tap. Records the
    /// deliberate "off" so a connected local server can't silently re-activate on the next AI Models visit.
    func deactivate() {
        settings.deactivate()
    }

    /// The request config consumers use. nil = nothing usable is active → Ask/Insights degrade honestly.
    var activeConfig: LLMConfig? {
        activeConfig(for: .ask)
    }

    /// Scoped configuration snapshot for a concrete consumer. The committed active model is used here,
    /// never the mutable provider-card preference.
    func activeConfig(for consumer: AIConsumer) -> LLMConfig? {
        guard let snapshot = settings.selectionSnapshot,
              let p = AIProvider(rawValue: snapshot.providerID) else { return nil }
        switch catalogState(p).selectionAvailability(for: snapshot.modelID) {
        case .missingFromAuthoritativeCatalog, .providerUnavailable, .unsupported:
            return nil
        case .notSelected, .unknownUntilAuthoritative, .available:
            break
        }
        let consented = settings.isAuthorized(providerID: p.rawValue, consumer: consumer)
        let cfg = LLMConfig(provider: p, baseURL: endpoint(for: p), model: snapshot.modelID,
                            cloudConsented: consented)
        guard cfg.isConfigured, cfg.isEndpointAllowed else { return nil }
        if p.isCloud {
            guard consented else { return nil }
            if p.usesAPIKey { guard hasKey(p) else { return nil } }
            if p == .codex {
                guard case .authenticated = codexConnection else { return nil }
            }
            // CLI identity is fail-closed. A persisted pair stays visible while
            // checking, but it cannot dispatch until the exact signed/hash-pinned
            // native executable has passed the current release policy.
            if p == .claudeCode {
                guard case .found = claudeCode else { return nil }
            }
        }
        return cfg
    }

    // MARK: probing

    /// Probe model authority without ever writing a preference or active pair. Built-in and subprocess
    /// providers have dedicated lifecycles and must not fall through to an empty HTTP endpoint.
    func connect(_ p: AIProvider) async {
        switch p.catalogDialect {
        case .bundledManifest:
            catalogs[p.rawValue] = .unsupported
            statuses[p.rawValue] = .error(
                String(localized: "Use the ZBS Eye Local controls above to manage the built-in model.")
            )
            return
        case .codexAppServer:
            await probeCodex(force: true)
            return
        case .curatedClaudeCode:
            await probeClaudeCode(force: true)
            return
        case .documentedSuggestions:
            guard hasKey(p) else {
                catalogs[p.rawValue] = .unavailable
                statuses[p.rawValue] = .error(
                    String(localized: "API key required — paste it above.")
                )
                return
            }
            catalogs[p.rawValue] = .notLoaded
            statuses[p.rawValue] = .connected(p.documentedSuggestedModels.count)
            return
        case .openAIModels, .anthropicModels:
            break
        }

        connectionAttempts[p.rawValue, default: 0] &+= 1
        let connectionAttempt = connectionAttempts[p.rawValue, default: 0]

        if p.usesAPIKey, !hasKey(p) {
            statuses[p.rawValue] = .error(String(localized: "API key required — paste it above."))
            catalogs[p.rawValue] = .unavailable
            return
        }
        let previousStatus = status(p)
        statuses[p.rawValue] = .probing
        guard let baseURL = URL(string: LLMConfig(
            provider: p,
            baseURL: endpoint(for: p),
            model: model(for: p)
        ).normalizedBaseURL) else {
            catalogs[p.rawValue] = .unavailable
            statuses[p.rawValue] = .error(String(localized: "The provider endpoint is invalid."))
            return
        }
        do {
            let catalog = try await catalogClient.load(
                provider: p,
                baseURL: baseURL,
                timeout: .seconds(10)
            )
            guard connectionAttempt == connectionAttempts[p.rawValue] else {
                return
            }
            guard !Task.isCancelled else {
                statuses[p.rawValue] = previousStatus
                return
            }
            guard case .authoritative(let list) = catalog else {
                catalogs[p.rawValue] = .unavailable
                statuses[p.rawValue] = .error(String(localized: "The provider returned an invalid model catalog."))
                return
            }
            catalogs[p.rawValue] = catalog
            statuses[p.rawValue] = .connected(list.count)
        } catch {
            guard connectionAttempt == connectionAttempts[p.rawValue] else {
                return
            }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                statuses[p.rawValue] = previousStatus
                return
            }
            catalogs[p.rawValue] = .unavailable
            statuses[p.rawValue] = .error(
                (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "The provider catalog is unavailable.")
            )
        }
    }

    /// Quiet local discovery fills only reachability/catalog state. It never chooses the first model and
    /// never activates a running server, including on a user's explicit `none` state.
    func autoProbeLocal() async {
        var probes: [AutomaticLocalProbe] = []
        for p in [AIProvider.lmstudio, .ollama, .custom] {
            guard !endpoint(for: p).isEmpty else { continue }
            connectionAttempts[p.rawValue, default: 0] &+= 1
            let connectionAttempt = connectionAttempts[p.rawValue, default: 0]
            let config = LLMConfig(provider: p, baseURL: endpoint(for: p), model: model(for: p))
            guard let baseURL = URL(string: config.normalizedBaseURL) else { continue }
            probes.append(AutomaticLocalProbe(
                provider: p,
                baseURL: baseURL,
                connectionAttempt: connectionAttempt
            ))
        }

        let catalogClient = catalogClient
        await withTaskGroup(of: AutomaticLocalProbeResult.self) { group in
            for probe in probes {
                group.addTask {
                    do {
                        let catalog = try await catalogClient.load(
                            provider: probe.provider,
                            baseURL: probe.baseURL,
                            timeout: .seconds(2)
                        )
                        return AutomaticLocalProbeResult(
                            probe: probe,
                            outcome: .catalog(catalog)
                        )
                    } catch {
                        let cancelled = Task.isCancelled
                            || error is CancellationError
                            || (error as? URLError)?.code == .cancelled
                        return AutomaticLocalProbeResult(
                            probe: probe,
                            outcome: cancelled ? .cancelled : .unavailable
                        )
                    }
                }
            }

            for await result in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                let p = result.probe.provider
                guard result.probe.connectionAttempt == connectionAttempts[p.rawValue] else {
                    continue
                }

                switch result.outcome {
                case .catalog(let catalog):
                    guard case .authoritative(let list) = catalog else {
                        catalogs[p.rawValue] = .unavailable
                        statuses[p.rawValue] = .error(String(localized: "The provider returned an invalid model catalog."))
                        continue
                    }
                    catalogs[p.rawValue] = catalog
                    statuses[p.rawValue] = .connected(list.count)
                case .unavailable:
                    catalogs[p.rawValue] = .unavailable
                    statuses[p.rawValue] = .notConfigured
                case .cancelled:
                    continue
                }
            }
        }
    }

    /// Prompt-free Codex discovery. It can initialize App Server, read account
    /// state, and read the current model catalog; it never starts a thread/turn
    /// and never writes a preferred or active model.
    func probeCodex(force: Bool = false) async {
        // CodexProviderConnection intentionally rejects overlapping control
        // operations. Share a normal discovery; a forced refresh cancels and
        // fully drains the current probe before starting its replacement.
        while let current = codexProbeOperation {
            if !force {
                await current.task.value
                return
            }
            current.task.cancel()
            await current.task.value
            if codexProbeOperation?.attempt == current.attempt {
                codexProbeOperation = nil
            }
            guard !Task.isCancelled else { return }
        }

        if !force, case .authenticated = codexConnection { return }
        guard let codexProvider, let processOverlay else {
            codexConnection = .error(String(localized: "Codex runtime is not ready."))
            catalogs[AIProvider.codex.rawValue] = .unavailable
            statuses[AIProvider.codex.rawValue] = .notConfigured
            return
        }
        let providerID = AIProvider.codex.rawValue
        let baseline = codexProbeBaseline ?? CodexProbeBaseline(
            connection: codexConnection,
            catalog: catalogs[providerID],
            status: statuses[providerID]
        )
        codexProbeBaseline = baseline
        codexAttempt &+= 1
        let attempt = codexAttempt
        if case .authenticated = baseline.connection {
            // A refresh keeps the exact last-known-good runtime usable until a
            // newer authoritative result commits.
        } else {
            codexConnection = .checking
            catalogs[providerID] = .unavailable
        }
        statuses[providerID] = .probing

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCodexProbe(
                attempt: attempt,
                baseline: baseline,
                provider: codexProvider,
                overlay: processOverlay
            )
        }
        codexProbeOperation = CodexProbeOperation(attempt: attempt, task: task)
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if codexProbeOperation?.attempt == attempt {
            codexProbeOperation = nil
        }
    }

    private func performCodexProbe(
        attempt: Int,
        baseline: CodexProbeBaseline,
        provider: any CodexProviderConnecting,
        overlay: LLMAdapterRegistry
    ) async {
        guard !Task.isCancelled else {
            restoreCodexProbe(
                connection: baseline.connection,
                catalog: baseline.catalog,
                status: baseline.status
            )
            codexProbeBaseline = nil
            return
        }
        let update = await provider.probe()
        guard attempt == codexAttempt else { return }
        guard !Task.isCancelled || update.runtimeDisposition == .committed else {
            restoreCodexProbe(
                connection: baseline.connection,
                catalog: baseline.catalog,
                status: baseline.status
            )
            codexProbeBaseline = nil
            return
        }
        codexProbeBaseline = nil
        await applyCodex(update, overlay: overlay)
    }

    private func restoreCodexProbe(
        connection: CodexConnectionState,
        catalog: ProviderCatalogState?,
        status: CardStatus?
    ) {
        let providerID = AIProvider.codex.rawValue
        codexConnection = connection
        if let catalog {
            catalogs[providerID] = catalog
        } else {
            catalogs.removeValue(forKey: providerID)
        }
        if let status {
            statuses[providerID] = status
        } else {
            statuses.removeValue(forKey: providerID)
        }
    }

    @discardableResult
    func startCodexLogin() async -> CodexLoginChallenge? {
        guard let codexProvider, let processOverlay else { return nil }
        codexProbeBaseline = nil
        codexAttempt &+= 1
        let attempt = codexAttempt
        statuses[AIProvider.codex.rawValue] = .probing
        await processOverlay.unregister(providerID: AIProvider.codex.rawValue)
        let update = await codexProvider.startLogin()
        guard attempt == codexAttempt else { return nil }
        await applyCodex(update, overlay: processOverlay)
        guard case .loginPending(let loginID, let authorizationURL) = update.state else {
            return nil
        }
        return CodexLoginChallenge(loginID: loginID, authorizationURL: authorizationURL)
    }

    func cancelCodexLogin() async {
        guard case .loginPending(let loginID, _) = codexConnection,
              let codexProvider, let processOverlay else { return }
        codexProbeBaseline = nil
        codexAttempt &+= 1
        let attempt = codexAttempt
        let update = await codexProvider.cancelLogin(loginID: loginID)
        guard attempt == codexAttempt else { return }
        await applyCodex(update, overlay: processOverlay)
    }

    func completeCodexLogin() async {
        guard case .loginPending(let loginID, _) = codexConnection,
              let codexProvider, let processOverlay else { return }
        codexProbeBaseline = nil
        codexAttempt &+= 1
        let attempt = codexAttempt
        let update = await codexProvider.completeLogin(loginID: loginID)
        guard attempt == codexAttempt else { return }
        await applyCodex(update, overlay: processOverlay)
    }

    private func applyCodex(
        _ update: CodexConnectionUpdate,
        overlay: LLMAdapterRegistry
    ) async {
        codexConnection = update.state
        switch update.state {
        case .authenticated(_, let models):
            catalogs[AIProvider.codex.rawValue] = .authoritative(models)
            statuses[AIProvider.codex.rawValue] = .connected(models.count)
        case .loginPending:
            catalogs[AIProvider.codex.rawValue] = .unavailable
            statuses[AIProvider.codex.rawValue] = .probing
        case .ready:
            catalogs[AIProvider.codex.rawValue] = .unavailable
            statuses[AIProvider.codex.rawValue] = .notConfigured
        case .missing:
            catalogs[AIProvider.codex.rawValue] = .unavailable
            statuses[AIProvider.codex.rawValue] = .notConfigured
        case .untrusted:
            catalogs[AIProvider.codex.rawValue] = .unavailable
            statuses[AIProvider.codex.rawValue] = .error(
                String(localized: "Upgrade Codex to the version supported by this ZBS Eye release.")
            )
        case .error(let message):
            catalogs[AIProvider.codex.rawValue] = .unavailable
            statuses[AIProvider.codex.rawValue] = .error(message)
        case .unknown, .checking:
            catalogs[AIProvider.codex.rawValue] = .unavailable
            statuses[AIProvider.codex.rawValue] = .probing
        }
        await overlay.unregister(providerID: AIProvider.codex.rawValue)
        if let registration = update.registration,
           case .authenticated = update.state {
            await overlay.register(registration)
        }
        // Process-provider authorization lives outside persisted settings.
        // Notify only after the overlay commit so new routing sees the same
        // registration state that the UI just published.
        notifyRouterOfRoutingChange()
    }

    /// Claude Code choices remain an exact curated release list. The adapter
    /// overlay appears only after signed identity and first-party auth pass.
    func probeClaudeCode(force: Bool = false) async {
        if case .checking = claudeCode { return }
        if !force, case .found = claudeCode { return }
        guard let claudeCodeProvider, let processOverlay else {
            claudeCode = .unavailable(String(localized: "Claude Code runtime is not ready."))
            catalogs[AIProvider.claudeCode.rawValue] = .unavailable
            statuses[AIProvider.claudeCode.rawValue] = .notConfigured
            return
        }
        let providerID = AIProvider.claudeCode.rawValue
        let baseline = claudeCodeProbeBaseline ?? ClaudeCodeProbeBaseline(
            connection: claudeCode,
            catalog: catalogs[providerID],
            status: statuses[providerID]
        )
        claudeCodeProbeBaseline = baseline
        claudeCodeAttempt &+= 1
        let attempt = claudeCodeAttempt
        if case .found = baseline.connection {
            // Keep the signed last-known-good adapter and identity available
            // while a user-initiated refresh is in flight.
        } else {
            claudeCode = .checking
        }
        statuses[providerID] = .probing
        guard !Task.isCancelled else {
            restoreClaudeCodeProbe(
                connection: baseline.connection,
                catalog: baseline.catalog,
                status: baseline.status
            )
            claudeCodeProbeBaseline = nil
            return
        }
        let update = await claudeCodeProvider.probe()
        guard attempt == claudeCodeAttempt else { return }
        guard !Task.isCancelled else {
            restoreClaudeCodeProbe(
                connection: baseline.connection,
                catalog: baseline.catalog,
                status: baseline.status
            )
            claudeCodeProbeBaseline = nil
            return
        }
        claudeCodeProbeBaseline = nil

        switch update.state {
        case .authenticated(_, let executablePath):
            claudeCode = .found(executablePath)
            catalogs[AIProvider.claudeCode.rawValue] = .notLoaded
            statuses[AIProvider.claudeCode.rawValue] = .connected(AIProvider.claudeCodeModels.count)
        case .missing:
            claudeCode = .notFound
            catalogs[AIProvider.claudeCode.rawValue] = .unavailable
            statuses[AIProvider.claudeCode.rawValue] = .notConfigured
        case .untrusted:
            claudeCode = .unavailable(String(localized: "Installed Claude Code is not an approved signed version."))
            catalogs[AIProvider.claudeCode.rawValue] = .unavailable
            statuses[AIProvider.claudeCode.rawValue] = .error(
                String(localized: "Upgrade Claude Code to the version supported by this ZBS Eye release.")
            )
        case .notAuthenticated:
            claudeCode = .unavailable(String(localized: "Sign in to Claude Code first."))
            catalogs[AIProvider.claudeCode.rawValue] = .unavailable
            statuses[AIProvider.claudeCode.rawValue] = .notConfigured
        case .unsupportedAccount:
            claudeCode = .unavailable(String(localized: "Claude Code must use a first-party Anthropic account."))
            catalogs[AIProvider.claudeCode.rawValue] = .unavailable
            statuses[AIProvider.claudeCode.rawValue] = .error(
                String(localized: "This routed Claude Code account is not supported.")
            )
        case .error(let message):
            claudeCode = .unavailable(message)
            catalogs[AIProvider.claudeCode.rawValue] = .unavailable
            statuses[AIProvider.claudeCode.rawValue] = .error(message)
        }
        await processOverlay.unregister(providerID: AIProvider.claudeCode.rawValue)
        if let registration = update.registration,
           case .authenticated = update.state {
            await processOverlay.register(registration)
        }
        notifyRouterOfRoutingChange()
    }

    private func restoreClaudeCodeProbe(
        connection: ClaudeCodeState,
        catalog: ProviderCatalogState?,
        status: CardStatus?
    ) {
        let providerID = AIProvider.claudeCode.rawValue
        claudeCode = connection
        if let catalog {
            catalogs[providerID] = catalog
        } else {
            catalogs.removeValue(forKey: providerID)
        }
        if let status {
            statuses[providerID] = status
        } else {
            statuses.removeValue(forKey: providerID)
        }
    }

    // MARK: API keys (Keychain only)

    func saveKey(
        _ raw: String,
        for p: AIProvider,
        connectAfterSave: Bool = true
    ) {
        guard let account = p.keychainAccount else { return }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let previousKey = credentialStore.get(account)
        // Any manual credential write invalidates work that already crossed
        // the old Keychain boundary. Advance synchronously, before another
        // MainActor task can publish a response authenticated with that key.
        connectionAttempts[p.rawValue, default: 0] &+= 1
        // A MANUAL key save must win over any in-flight OpenRouter OAuth: cancel it first so a late
        // OAuth success can't overwrite the pasted key and the "Cancel" row can't linger. (When this is
        // called by finishOpenRouterOAuth() on OAuth success, oauthTask is already nil → no-op.)
        if p == .openrouter, oauthTask != nil { cancelOpenRouterOAuth() }
        let retainedCredential = previousKey.map { !$0.isEmpty } ?? false
        let failedReplacementWouldRetainOldKey = retainedCredential && previousKey != key
        guard credentialStore.set(key, account: account) else {
            catalogs[p.rawValue] = .unavailable
            keyPresent[p.rawValue] = retainedCredential
            guard failedReplacementWouldRetainOldKey else {
                statuses[p.rawValue] = .error(String(localized: "Couldn't save the API key to the Keychain. Try again."))
                return
            }

            // Update-first Keychain writes leave the old credential intact on
            // failure. Revoke its authorization durably so a restart cannot
            // resurrect the previous key as an active cloud route.
            var revokedSettings = settings
            let previousEpoch = revokedSettings.authorizationEpoch
            revokedSettings.revokeConsent(providerID: p.rawValue)
            if revokedSettings.authorizationEpoch == previousEpoch {
                revokedSettings.authorizationEpoch.advance()
            }
            guard commitProviderSettingsWithAcknowledgement(revokedSettings) else {
                publishSettingsWithoutPersistence(revokedSettings)
                statuses[p.rawValue] = .error(String(localized: "Couldn't save the access revocation. The previous API key was kept; processing is paused. Try again."))
                return
            }
            statuses[p.rawValue] = .error(String(localized: "Couldn't replace the API key in the Keychain. The previous key was kept, and access was revoked. Try again."))
            return
        }
        keyPresent[p.rawValue] = true
        catalogs[p.rawValue] = .notLoaded
        statuses[p.rawValue] = .notConfigured
        if previousKey != key { settings.authorizationEpoch.advance() }
        if connectAfterSave {
            Task { await connect(p) }
        }
    }

    func removeKey(for p: AIProvider) {
        guard let account = p.keychainAccount else { return }
        connectionAttempts[p.rawValue, default: 0] &+= 1
        // Prevent an in-flight OAuth completion from restoring the credential
        // after this explicit revocation.
        if p == .openrouter { cancelOpenRouterOAuth() }

        // Revoke and persist authorization before touching the Keychain. If
        // deletion fails or the process dies at that boundary, a retained
        // credential still cannot authorize prompt egress after restart.
        var revokedSettings = settings
        let previousEpoch = revokedSettings.authorizationEpoch
        revokedSettings.revokeConsent(providerID: p.rawValue)
        if revokedSettings.authorizationEpoch == previousEpoch {
            revokedSettings.authorizationEpoch.advance()
        }
        catalogs[p.rawValue] = .unavailable
        guard commitProviderSettingsWithAcknowledgement(revokedSettings) else {
            // The durable write failed, so do not risk deleting the only copy
            // of the credential. Still publish the revoked snapshot in this
            // process: no prompt may cross the old authorization boundary
            // while the user retries the operation.
            publishSettingsWithoutPersistence(revokedSettings)
            keyPresent[p.rawValue] = true
            statuses[p.rawValue] = .error(String(localized: "Couldn't save the access revocation. The API key was not deleted; processing is paused. Try again."))
            return
        }
        guard credentialStore.delete(account) else {
            // A Keychain error does not prove absence. Keep the removal action
            // available, but never restore consent or routing authorization.
            keyPresent[p.rawValue] = true
            statuses[p.rawValue] = .error(String(localized: "Couldn't remove the API key from the Keychain. Access was revoked; try again."))
            return
        }
        keyPresent[p.rawValue] = false
        statuses[p.rawValue] = .notConfigured
    }

    // MARK: OpenRouter one-click sign-in (OAuth + PKCE)

    /// Kick off the real OpenRouter OAuth flow: opens the system browser, waits for the loopback
    /// callback, exchanges the code for an `sk-or-…` key and stores it in the SAME Keychain slot the
    /// manual key field uses — so the existing "key saved → connect()" path loads the model list and
    /// flips the card to connected. The async flow runs off this @MainActor store (OpenRouterOAuth is an
    /// actor); only the final Sendable outcome hops back here to mutate observable state.
    func connectOpenRouterOAuth() {
        guard oauthTask == nil else { return }   // already running — ignore a double-tap
        oauthAttempt &+= 1
        let attempt = oauthAttempt               // this flow's identity — checked when it completes
        openRouterOAuthPhase = .running          // a fresh attempt also clears any stale .failed banner
        let service = OpenRouterOAuth()
        oauthTask = Task { [weak self] in   // inherits @MainActor; only the actor call below awaits
            let outcome: Result<String, Error>
            do { outcome = .success(try await service.authorize()) }
            catch { outcome = .failure(error) }
            self?.finishOpenRouterOAuth(attempt, outcome)
        }
    }

    /// User closed the browser / clicked Cancel — tear the flow down and go quiet. Bumping the attempt
    /// token invalidates any completion still in flight, so it can't reset a newer attempt's state.
    func cancelOpenRouterOAuth() {
        oauthAttempt &+= 1
        oauthTask?.cancel()
        oauthTask = nil
        openRouterOAuthPhase = .idle
    }

    /// Clear a leftover `.failed` banner when the OpenRouter card next appears — the store is an
    /// app-lifetime singleton, so without this a past failure would stick across view revisits.
    func resetOpenRouterOAuthPhaseIfStale() {
        if oauthTask == nil, case .failed = openRouterOAuthPhase { openRouterOAuthPhase = .idle }
    }

    private func finishOpenRouterOAuth(_ attempt: Int, _ outcome: Result<String, Error>) {
        // Only the CURRENT attempt may mutate state — a superseded/cancelled flow completing late is a no-op.
        guard attempt == oauthAttempt else { return }
        oauthTask = nil
        switch outcome {
        case .success(let key):
            openRouterOAuthPhase = .idle
            saveKey(key, for: .openrouter)   // Keychain write + keyPresent + connect()/probe (green + models)
        case .failure(let error):
            // A user-initiated cancel is not an error to shout about.
            if (error as? OpenRouterOAuth.OAuthError)?.isCancellation == true || error is CancellationError {
                openRouterOAuthPhase = .idle
            } else {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                openRouterOAuthPhase = .failed(msg)
            }
        }
    }

    // MARK: persistence + migration

    @discardableResult
    private func persist(
        _ snapshot: AIProviderSettings? = nil,
        requireAcknowledgement: Bool = false
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot ?? settings) else {
            return false
        }
        defaults.set(data, forKey: Self.key)
        defaults.set(data, forKey: Self.lastKnownGoodKey)
        return !requireAcknowledgement || persistenceSynchronizer()
    }

    private func commitProviderSettingsWithAcknowledgement(
        _ candidate: AIProviderSettings
    ) -> Bool {
        guard persist(candidate, requireAcknowledgement: true) else {
            return false
        }
        settingsAlreadyPersisted = true
        settings = candidate
        settingsAlreadyPersisted = false
        return true
    }

    /// Publishes a fail-closed runtime snapshot after its durable
    /// acknowledgement failed. `persist(candidate, requireAcknowledgement:)`
    /// has already queued the same bytes; suppressing the observer here avoids
    /// pretending that a second, unacknowledged write fixed the failure.
    private func publishSettingsWithoutPersistence(
        _ candidate: AIProviderSettings
    ) {
        settingsAlreadyPersisted = true
        settings = candidate
        settingsAlreadyPersisted = false
    }

    /// Legacy {baseURL, model} (pre-"AI Models") — always local. Default ports map to their named cards
    /// (1234 → LM Studio, 11434 → Ollama); anything else becomes the "custom localhost" card as-is.
    /// The legacy defaults value stays untouched (harmless, and downgrade-safe).
    private static func migrateLegacy(from defaults: UserDefaults) -> AIProviderSettings? {
        struct Legacy: Decodable { let baseURL: String; let model: String }
        guard let data = defaults.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode(Legacy.self, from: data) else { return nil }
        let base = legacy.baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return nil }

        func normalized(_ s: String) -> String {
            var b = s.contains("://") ? s : "http://" + s
            while b.hasSuffix("/") { b.removeLast() }
            return b.lowercased()
        }
        let provider: AIProvider
        switch normalized(base) {
        case normalized(AIProvider.lmstudio.defaultBaseURL): provider = .lmstudio
        case normalized(AIProvider.ollama.defaultBaseURL):   provider = .ollama
        default:                                             provider = .custom
        }
        let cleanModel = legacy.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = cleanModel.isEmpty ? [:] : [provider.rawValue: cleanModel]
        let endpoints = provider == .custom ? [provider.rawValue: base] : [:]
        // Migration reconstructs the already-committed legacy pair without pretending the user just made
        // a new selection (so its revision/authorization epoch correctly begin at zero).
        return AIProviderSettings(
            active: cleanModel.isEmpty ? nil : provider.rawValue,
            activeModelID: cleanModel.isEmpty ? nil : cleanModel,
            models: models,
            endpoints: endpoints
        )
    }
}

extension AIProviderStore: BuiltInModelProviderControlling {}
