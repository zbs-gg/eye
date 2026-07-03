import Foundation
import Observation

/// State of the "AI Models" section: one card per provider, exactly ONE active processing model across
/// all of them. @MainActor @Observable — the UI binds straight to it; the network probes go through the
/// LLMClient actor. Persistence: UserDefaults "zbseye.ai.provider" (JSON, no secrets) with a one-time
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

    var settings: AIProviderSettings {
        didSet { if settings != oldValue { persist() } }
    }
    /// Per-provider probe status + models fetched this session (not persisted — servers/keys change).
    private(set) var statuses: [String: CardStatus] = [:]
    private(set) var models: [String: [String]] = [:]
    /// Whether a Keychain key exists per cloud provider (the key itself never enters observable state).
    private(set) var keyPresent: [String: Bool] = [:]

    @ObservationIgnored private let client = LLMClient()
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let key = "zbseye.ai.provider"
    private static let legacyKey = "zbseye.connections.llm"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(AIProviderSettings.self, from: data) {
            settings = s
        } else {
            // One-time migration: the legacy config was always a LOCAL OpenAI-compatible endpoint.
            settings = Self.migrateLegacy() ?? AIProviderSettings()
            persist()
        }
        for p in AIProvider.allCases where p.isCloud {
            keyPresent[p.rawValue] = Self.storedKeyExists(p)
        }
    }

    // MARK: derived state

    var activeProvider: AIProvider? { settings.activeProvider }

    func model(for p: AIProvider) -> String { settings.models[p.rawValue] ?? "" }
    func setModel(_ m: String, for p: AIProvider) { settings.models[p.rawValue] = m }

    /// Cloud endpoints are pinned; local ones take the user override (custom has no default at all).
    func endpoint(for p: AIProvider) -> String {
        if p.isCloud { return p.defaultBaseURL }
        if let o = settings.endpoints[p.rawValue], !o.trimmingCharacters(in: .whitespaces).isEmpty { return o }
        return p.defaultBaseURL
    }
    func setEndpoint(_ s: String, for p: AIProvider) {
        guard !p.isCloud else { return }
        settings.endpoints[p.rawValue] = s
    }

    func status(_ p: AIProvider) -> CardStatus { statuses[p.rawValue] ?? .notConfigured }

    /// Picker options: models from the server + the currently selected one (don't lose the choice).
    func modelOptions(_ p: AIProvider) -> [String] {
        var opts = models[p.rawValue] ?? []
        let sel = model(for: p)
        if !sel.isEmpty, !opts.contains(sel) { opts.insert(sel, at: 0) }
        return opts
    }

    func hasKey(_ p: AIProvider) -> Bool { keyPresent[p.rawValue] ?? false }
    func hasConsent(_ p: AIProvider) -> Bool { settings.cloudConsent[p.rawValue] ?? false }
    func grantConsent(_ p: AIProvider) { settings.cloudConsent[p.rawValue] = true }

    func isActive(_ p: AIProvider) -> Bool { activeProvider == p }

    /// Make this provider THE processing model. Cloud requires prior consent (the view shows the
    /// warning alert and calls grantConsent first) — refuse silently otherwise, never flip by accident.
    func activate(_ p: AIProvider) {
        guard !model(for: p).isEmpty else { return }
        if p.isCloud { guard hasConsent(p), hasKey(p) else { return } }
        settings.active = p.rawValue
    }

    /// The request config consumers use. nil = nothing usable is active → Ask/Insights degrade honestly.
    var activeConfig: LLMConfig? {
        guard let p = activeProvider else { return nil }
        let cfg = LLMConfig(provider: p, baseURL: endpoint(for: p), model: model(for: p),
                            cloudConsented: hasConsent(p))
        guard cfg.isConfigured, cfg.isEndpointAllowed else { return nil }
        if p.isCloud { guard hasConsent(p), hasKey(p) else { return nil } }
        return cfg
    }

    // MARK: probing

    /// Probe the provider: GET /models, fill the card's Picker. Local probes are fast (the server either
    /// answers instantly or isn't running); cloud gets a network-realistic timeout. Anthropic keeps a
    /// static fallback list — its /v1/models may fail while the key is perfectly fine for /v1/messages.
    func connect(_ p: AIProvider) async {
        if p.isCloud, !hasKey(p) {
            statuses[p.rawValue] = .error(String(localized: "API key required — paste it above."))
            return
        }
        statuses[p.rawValue] = .probing
        let cfg = LLMConfig(provider: p, baseURL: endpoint(for: p), model: model(for: p))
        let result = await client.listModels(cfg, timeout: p.isCloud ? 10 : 2)
        switch result {
        case .ok(let list):
            models[p.rawValue] = list
            statuses[p.rawValue] = .connected(list.count)
            autoSelect(p, from: list)
        case .failed(let msg):
            if p == .anthropic, hasKey(p) {
                models[p.rawValue] = AIProvider.anthropicFallbackModels
                statuses[p.rawValue] = .connected(AIProvider.anthropicFallbackModels.count)
                autoSelect(p, from: AIProvider.anthropicFallbackModels)
            } else {
                models[p.rawValue] = []
                statuses[p.rawValue] = .error(msg)
            }
        }
    }

    /// Quiet local probe when "AI Models" opens: fill pickers if LM Studio/Ollama are already running,
    /// stay silent (no error status) if not — the cards just show their Connect buttons.
    func autoProbeLocal() async {
        for p in [AIProvider.lmstudio, .ollama, .custom] {
            guard !endpoint(for: p).isEmpty else { continue }
            if case .ok(let list) = await client.listModels(
                LLMConfig(provider: p, baseURL: endpoint(for: p), model: model(for: p)), timeout: 2) {
                models[p.rawValue] = list
                statuses[p.rawValue] = .connected(list.count)
                autoSelect(p, from: list)
            }
        }
    }

    /// If nothing is selected OR the previous choice is gone from the server — take the first available,
    /// so "Use this model" works right away with a model that actually exists.
    private func autoSelect(_ p: AIProvider, from list: [String]) {
        if !list.isEmpty, !list.contains(model(for: p)) { setModel(list[0], for: p) }
    }

    // MARK: API keys (Keychain only)

    func saveKey(_ raw: String, for p: AIProvider) {
        guard let account = p.keychainAccount else { return }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        KeychainStore.set(key, account: account)
        keyPresent[p.rawValue] = true
        Task { await connect(p) }
    }

    func removeKey(for p: AIProvider) {
        guard let account = p.keychainAccount else { return }
        KeychainStore.delete(account)
        keyPresent[p.rawValue] = false
        models[p.rawValue] = []
        statuses[p.rawValue] = .notConfigured
        if isActive(p) { settings.active = nil }   // no key → the provider can't process anything
    }

    private static func storedKeyExists(_ p: AIProvider) -> Bool {
        guard let account = p.keychainAccount else { return false }
        return !(KeychainStore.get(account) ?? "").isEmpty
    }

    // MARK: persistence + migration

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }

    /// Legacy {baseURL, model} (pre-"AI Models") — always local. Default ports map to their named cards
    /// (1234 → LM Studio, 11434 → Ollama); anything else becomes the "custom localhost" card as-is.
    /// The legacy defaults value stays untouched (harmless, and downgrade-safe).
    private static func migrateLegacy() -> AIProviderSettings? {
        struct Legacy: Decodable { let baseURL: String; let model: String }
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
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
        var s = AIProviderSettings()
        s.models[provider.rawValue] = legacy.model
        if provider == .custom { s.endpoints[provider.rawValue] = base }
        if !legacy.model.trimmingCharacters(in: .whitespaces).isEmpty { s.active = provider.rawValue }
        return s
    }
}
