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
    }

    var settings: AIProviderSettings {
        didSet { if settings != oldValue { persist() } }
    }
    /// Per-provider probe status + models fetched this session (not persisted — servers/keys change).
    private(set) var statuses: [String: CardStatus] = [:]
    private(set) var models: [String: [String]] = [:]
    /// Whether a Keychain key exists per cloud provider (the key itself never enters observable state).
    private(set) var keyPresent: [String: Bool] = [:]
    /// OpenRouter one-click sign-in progress (nothing else here observes the key material).
    private(set) var openRouterOAuthPhase: OAuthPhase = .idle
    /// Whether the user's Claude Code CLI is installed (drives the Claude Code card's dot + activation).
    private(set) var claudeCode: ClaudeCodeState = .unknown

    @ObservationIgnored private var oauthTask: Task<Void, Never>?
    /// Monotonically-increasing token that identifies the current OAuth attempt. A completion (or a late
    /// cancel) only mutates state if it still matches — so a superseded flow can't clobber a newer one.
    @ObservationIgnored private var oauthAttempt = 0
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
        guard settings.endpoints[p.rawValue] != s else { return }
        settings.endpoints[p.rawValue] = s
        // The cached status/models belong to the OLD server. Invalidate them so a stale
        // "connected · N models" can't be activated against a now-different endpoint.
        statuses[p.rawValue] = .notConfigured
        models[p.rawValue] = []
    }

    func status(_ p: AIProvider) -> CardStatus { statuses[p.rawValue] ?? .notConfigured }

    /// Models actually fetched from the server this session (empty if none/failed). Distinct from
    /// `modelOptions`, which also folds in the currently-selected model — the view uses this to decide
    /// whether to offer manual model entry (no server list ⇒ let the user type an id).
    func fetchedModels(_ p: AIProvider) -> [String] { models[p.rawValue] ?? [] }

    /// Picker options: models from the server + the currently selected one (don't lose the choice).
    /// Claude Code has no live `/models` — it offers a fixed preset list for the `--model` flag.
    func modelOptions(_ p: AIProvider) -> [String] {
        var opts = p == .claudeCode ? AIProvider.claudeCodeModels : (models[p.rawValue] ?? [])
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
    /// A key-based cloud provider also needs its key; Claude Code (no key) only needs the CLI present.
    func activate(_ p: AIProvider) {
        guard !model(for: p).isEmpty else { return }
        if p.isCloud {
            guard hasConsent(p) else { return }
            if p.usesAPIKey { guard hasKey(p) else { return } }
            if p == .claudeCode { guard case .found = claudeCode else { return } }
        }
        settings.active = p.rawValue
    }

    /// The request config consumers use. nil = nothing usable is active → Ask/Insights degrade honestly.
    var activeConfig: LLMConfig? {
        guard let p = activeProvider else { return nil }
        let cfg = LLMConfig(provider: p, baseURL: endpoint(for: p), model: model(for: p),
                            cloudConsented: hasConsent(p))
        guard cfg.isConfigured, cfg.isEndpointAllowed else { return nil }
        if p.isCloud {
            guard hasConsent(p) else { return nil }
            if p.usesAPIKey { guard hasKey(p) else { return nil } }
            if p == .claudeCode { guard case .found = claudeCode else { return nil } }
        }
        return cfg
    }

    // MARK: probing

    /// Probe the provider: GET /models, fill the card's Picker. A cold-starting local server can take a
    /// few seconds to answer, so the probe gets a network-realistic timeout. Anthropic keeps a static
    /// fallback list ONLY when the probe SUCCEEDS (2xx = key proven good) but enumeration is unavailable —
    /// a real failure (401 / offline / DNS) is surfaced honestly, never masked as connected.
    func connect(_ p: AIProvider) async {
        if p.isCloud, !hasKey(p) {
            statuses[p.rawValue] = .error(String(localized: "API key required — paste it above."))
            return
        }
        statuses[p.rawValue] = .probing
        let cfg = LLMConfig(provider: p, baseURL: endpoint(for: p), model: model(for: p))
        let result = await client.listModels(cfg, timeout: 10)
        switch result {
        case .ok(let list) where !list.isEmpty:
            models[p.rawValue] = list
            statuses[p.rawValue] = .connected(list.count)
            autoSelect(p, from: list, fetched: true)
        case .ok:
            // 2xx but no enumerable models. Anthropic's /v1/models can be unavailable while the key is
            // valid for /v1/messages → fall back to a static list (auth proven good, enumeration isn't).
            if p == .anthropic {
                let fallback = AIProvider.anthropicFallbackModels
                models[p.rawValue] = fallback
                statuses[p.rawValue] = .connected(fallback.count)
                autoSelect(p, from: fallback, fetched: false)   // static list — never clobber a persisted choice
            } else {
                models[p.rawValue] = []
                statuses[p.rawValue] = .connected(0)
            }
        case .failed(let msg):
            // Non-2xx (e.g. 401 bad key) or transport error. Report honestly; do NOT show a green
            // connected state and do NOT touch the user's persisted model selection.
            models[p.rawValue] = []
            statuses[p.rawValue] = .error(msg)
        }
    }

    /// Quiet local probe when "AI Models" opens: fill pickers if LM Studio/Ollama are already running,
    /// stay silent (no error status) if not — the cards just show their Connect buttons.
    func autoProbeLocal() async {
        for p in [AIProvider.lmstudio, .ollama, .custom] {
            guard !endpoint(for: p).isEmpty else { continue }
            if case .ok(let list) = await client.listModels(
                LLMConfig(provider: p, baseURL: endpoint(for: p), model: model(for: p)), timeout: 2),
               !list.isEmpty {
                models[p.rawValue] = list
                statuses[p.rawValue] = .connected(list.count)
                autoSelect(p, from: list, fetched: true)
            }
        }
    }

    /// Detect the user's Claude Code CLI when "AI Models" opens (or on an explicit re-check). Found →
    /// seed a default `--model` preset so "Use this model" works immediately; not found → the card shows
    /// an install hint. `force` re-runs discovery even if it was already checked (user just installed it).
    func probeClaudeCode(force: Bool = false) async {
        if case .checking = claudeCode { return }
        if !force, case .found = claudeCode { return }
        claudeCode = .checking
        if force { await ClaudeCodeLocator.shared.refresh() }
        if let path = await ClaudeCodeLocator.shared.resolve() {
            claudeCode = .found(path)
            if model(for: .claudeCode).isEmpty {
                setModel(AIProvider.claudeCodeDefaultModel, for: .claudeCode)
            }
        } else {
            claudeCode = .notFound
            // A previously-active Claude Code provider is no longer usable without the CLI.
            if isActive(.claudeCode) { settings.active = nil }
        }
    }

    /// Fill the model selection so "Use this model" works right away — WITHOUT clobbering the user's
    /// persisted choice. When there is no stored model, take the first available. When `fetched` is true
    /// (a real, freshly-fetched server list) also replace a stored model that's genuinely gone from it;
    /// on a static fallback list (`fetched == false`) a non-empty stored choice is left untouched.
    private func autoSelect(_ p: AIProvider, from list: [String], fetched: Bool) {
        guard !list.isEmpty else { return }
        let current = model(for: p)
        if current.isEmpty {
            setModel(list[0], for: p)
        } else if fetched, !list.contains(current) {
            setModel(list[0], for: p)
        }
    }

    // MARK: API keys (Keychain only)

    func saveKey(_ raw: String, for p: AIProvider) {
        guard let account = p.keychainAccount else { return }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        // A MANUAL key save must win over any in-flight OpenRouter OAuth: cancel it first so a late
        // OAuth success can't overwrite the pasted key and the "Cancel" row can't linger. (When this is
        // called by finishOpenRouterOAuth() on OAuth success, oauthTask is already nil → no-op.)
        if p == .openrouter, oauthTask != nil { cancelOpenRouterOAuth() }
        // A failed Keychain write must NOT look saved: keep keyPresent=false so the SecureField stays
        // visible for re-entry, surface the error, and do not auto-connect with a key that isn't stored.
        guard KeychainStore.set(key, account: account) else {
            keyPresent[p.rawValue] = false
            statuses[p.rawValue] = .error(String(localized: "Couldn't save the API key to the Keychain. Try again."))
            return
        }
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
        // Removing the OpenRouter key also tears down any in-flight OAuth and clears a stale .failed
        // banner, so it can't resurface the next time the card is shown.
        if p == .openrouter { cancelOpenRouterOAuth() }
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
