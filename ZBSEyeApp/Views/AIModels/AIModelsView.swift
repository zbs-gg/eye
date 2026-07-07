import SwiftUI

/// "AI Models": choose WHICH model processes history excerpts (Ask / Daily Insights / day summary).
///
/// The screen answers ONE question — "which model runs?" — with ONE authoritative line and ONE switcher:
///   (1) ACTIVE MODEL — a single row "Active model  ⋯" whose value is the friendly "Provider · Model" that
///       is running right now (the ONLY green statement on the screen), or "None". The switcher lists every
///       AVAILABLE model grouped by connected provider; picking a local model activates immediately, a cloud
///       model routes through the existing consent alert, and "None" turns Ask & Insights off.
///   (2) MANAGE PROVIDERS — a DisclosureGroup (collapsed once anything is connected, expanded for a fresh
///       user) holding the setup-only provider cards: status, key/OAuth/endpoint, one Connect / Load-models
///       button, and a neutral "N models available" line. The cards no longer activate anything — activation
///       lives only in the switcher above.
/// Cloud providers stay an explicit opt-in behind the unchanged consent alert; recording, index and storage
/// always stay on-device regardless of the choice made here.
struct AIModelsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var consentTarget: AIProvider?
    /// The model chosen in the switcher that is waiting behind the cloud consent alert. It is persisted +
    /// activated ONLY on grant — cancelling consent must leave the previously-active model untouched.
    @State private var consentPendingModel: String?
    @State private var showConsent = false
    @State private var advancedExpanded = false
    /// Set ONCE at first appear (expanded iff the user hasn't configured any provider yet) and thereafter
    /// only by hand — the manual toggle or the "Add a provider…" affordance. It must NOT track a live
    /// computed value, or the group would snap open/shut under the user as probes land.
    @State private var manageExpanded = false
    @State private var didInitManageExpansion = false

    private var ai: AIProviderStore { env.ai }

    var body: some View {
        let connected = connectedProviders   // one scan of the 7 providers per render (finding 6)
        return Form {
            activeSection(connected)
            manageSection(connected)
        }
        .formStyle(.grouped)
        .navigationTitle("AI Models")
        .task {
            await env.ai.autoProbeLocal()   // fill the switcher if LM Studio/Ollama are already running
            await env.ai.probeClaudeCode()  // detect the `claude` CLI (a GUI app doesn't inherit $PATH)
        }
        .onAppear {
            env.ai.resetOpenRouterOAuthPhaseIfStale()   // don't resurface a past OAuth error
            if !didInitManageExpansion {
                // Onboarding auto-expand keys on USER-configured providers only — never on a merely
                // auto-detected Claude Code CLI or a stale probed local model.
                manageExpanded = !env.ai.userHasConfiguredProvider
                didInitManageExpansion = true
            }
        }
        .alert("Enable cloud processing?", isPresented: $showConsent, presenting: consentTarget) { p in
            Button("Cancel", role: .cancel) {}
            Button(Self.consentConfirmTitle(p)) {
                // Consent is the gate: only NOW do we persist + activate the chosen cloud model, so
                // cancelling above left the previously-active model unchanged.
                env.ai.grantConsent(p)
                if let m = consentPendingModel { env.ai.setModel(m, for: p) }
                env.ai.activate(p)
            }
        } message: { p in
            Text(Self.consentMessage(p))
        }
    }

    // MARK: — (1) active-model switcher: the one authoritative line

    private func activeSection(_ connected: Set<AIProvider>) -> some View {
        Section {
            LabeledContent {
                activeModelMenu(connected)
            } label: {
                Text("Active model")
            }
        } footer: {
            activeCaption(connected)
        }
    }

    /// The single green statement on the screen: the friendly "Provider · Model" that is running, or "None".
    private func activeModelMenu(_ connected: Set<AIProvider>) -> some View {
        Menu {
            ForEach(Self.switcherGroups) { menuSection($0) }
            Divider()
            Button {
                ai.deactivate()
            } label: {
                menuLabel(String(localized: "None (turn Ask & Insights off)"),
                          selected: ai.activeConfig == nil)
            }
            if connected.count < AIProvider.allCases.count {
                Divider()
                Button { manageExpanded = true } label: {
                    Label("Add a provider…", systemImage: "plus")
                }
            }
        } label: {
            activeValueLabel
        }
    }

    @ViewBuilder
    private var activeValueLabel: some View {
        if let p = ai.activeProvider, ai.activeConfig != nil {
            // Friendly short name in the row; the full model id lives in the tooltip.
            Text(verbatim: "\(p.displayName) · \(friendlyModelName(ai.model(for: p), provider: p))")
                .foregroundStyle(.green)
                .help("\(p.displayName) · \(ai.model(for: p))")
        } else {
            Text("None — Ask & Insights off")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func menuSection(_ group: ProviderGroup) -> some View {
        let entries = group.providers.flatMap { p in
            ai.availableModels(for: p).map { ModelEntry(provider: p, model: $0) }
        }
        if !entries.isEmpty {
            Section(group.title) {
                ForEach(entries) { e in
                    Button {
                        select(e.provider, e.model)
                    } label: {
                        menuLabel(friendlyModelName(e.model, provider: e.provider),
                                  selected: isActiveModel(e.provider, e.model))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func menuLabel(_ text: String, selected: Bool) -> some View {
        if selected {
            Label(text, systemImage: "checkmark")
        } else {
            Text(verbatim: text)
        }
    }

    @ViewBuilder
    private func activeCaption(_ connected: Set<AIProvider>) -> some View {
        if ai.activeConfig == nil, !connected.isEmpty {
            // A model is set up but nothing runs — nudge the user to flip it on.
            Text("A model is ready — pick it above to turn on Ask & Insights.")
        } else {
            Text("This model reads history excerpts for Ask and Daily Insights. Local models never leave your Mac.")
        }
    }

    // MARK: — (2) manage providers: setup only, no activation here

    private func manageSection(_ connected: Set<AIProvider>) -> some View {
        Section {
            DisclosureGroup(isExpanded: $manageExpanded) {
                if connected.isEmpty {
                    Text("Ask and Daily Insights need a model to read your history. Pick one below — a free local model runs entirely on your Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                manageSubgroup("On this Mac", [.lmstudio, .ollama])
                Divider()
                manageSubgroup("Use your Claude Code", [.claudeCode])
                Divider()
                manageSubgroup("Cloud", [.openrouter])
                Divider()
                DisclosureGroup(isExpanded: $advancedExpanded) {
                    ProviderCard(provider: .custom, requestCloudConsent: requestConsent)
                    Divider()
                    ProviderCard(provider: .openai, requestCloudConsent: requestConsent)
                    Divider()
                    ProviderCard(provider: .anthropic, requestCloudConsent: requestConsent)
                } label: {
                    Label("Advanced — API keys & custom server", systemImage: "slider.horizontal.3")
                }
            } label: {
                Label("Manage providers", systemImage: "gearshape.2")
            }
        }
    }

    @ViewBuilder
    private func manageSubgroup(_ title: LocalizedStringKey, _ providers: [AIProvider]) -> some View {
        Text(title)
            .font(.caption).textCase(.uppercase).foregroundStyle(.secondary)
        ForEach(Array(providers.enumerated()), id: \.element) { idx, p in
            if idx > 0 { Divider() }
            if p == .claudeCode {
                ClaudeCodeCard()
            } else {
                ProviderCard(provider: p, requestCloudConsent: requestConsent)
            }
        }
    }

    // MARK: — switcher model catalog

    /// The groups the switcher presents (custom localhost lives under "On this Mac"; the key-based cloud
    /// providers share the "Cloud" group). A provider only appears if it currently exposes a model.
    private static let switcherGroups: [ProviderGroup] = [
        ProviderGroup(id: "local",  title: "On this Mac",         providers: [.lmstudio, .ollama, .custom]),
        ProviderGroup(id: "claude", title: "Use your Claude Code", providers: [.claudeCode]),
        ProviderGroup(id: "cloud",  title: "Cloud",                providers: [.openrouter, .anthropic, .openai]),
    ]

    /// The providers that currently expose at least one selectable model. Computed ONCE per render in
    /// `body` and threaded down — the manage-group's first-run expansion, the caption and the "add a
    /// provider" affordance all derive from this single scan instead of each rescanning the 7 providers.
    private var connectedProviders: Set<AIProvider> {
        Set(AIProvider.allCases.filter { !ai.availableModels(for: $0).isEmpty })
    }

    /// Short, human name: last path component (or the Claude Code "Default" sentinel). Full id in the tooltip.
    private func friendlyModelName(_ id: String, provider: AIProvider) -> String {
        if provider == .claudeCode, id == AIProvider.claudeCodeDefaultModel {
            return String(localized: "Default")
        }
        let slug = id.split(separator: "/").last.map(String.init) ?? id
        return slug.isEmpty ? id : slug
    }

    private func isActiveModel(_ p: AIProvider, _ m: String) -> Bool {
        ai.activeConfig != nil && ai.activeProvider == p && ai.model(for: p) == m
    }

    /// The one place activation happens. Local flips on immediately. A cloud model is NOT persisted or
    /// activated until consent is granted: an already-consented provider activates now; otherwise the
    /// chosen model is parked in `consentPendingModel` behind the alert, so cancelling leaves the
    /// previously-active model unchanged.
    private func select(_ p: AIProvider, _ m: String) {
        if p.isCloud {
            if ai.hasConsent(p) {
                ai.setModel(m, for: p)
                ai.activate(p)
            } else {
                consentTarget = p
                consentPendingModel = m
                showConsent = true
            }
        } else {
            ai.setModel(m, for: p)
            ai.activate(p)
        }
    }

    /// Consent path used by the setup cards (no specific switcher model to park — activate whatever the
    /// provider already has selected once consent is granted).
    private func requestConsent(_ p: AIProvider) {
        consentTarget = p
        consentPendingModel = nil
        showConsent = true
    }

    // MARK: consent copy (Claude Code is worded honestly — excerpts reach Anthropic via the CLI login)

    private static func consentConfirmTitle(_ p: AIProvider) -> LocalizedStringKey {
        p == .claudeCode ? "Send excerpts via Claude Code" : "Send excerpts to \(p.displayName)"
    }

    private static func consentMessage(_ p: AIProvider) -> LocalizedStringKey {
        p == .claudeCode
        ? "Claude Code sends excerpts of your screen history to Anthropic through your signed-in Claude Code login. Your recordings and index stay local."
        : "Cloud processing sends excerpts of your screen history to \(p.displayName). Your recordings and index stay local."
    }
}

/// A group heading in the switcher (its providers are folded in only when they expose a model).
private struct ProviderGroup: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let providers: [AIProvider]
}

/// One selectable "Provider · Model" pair in the switcher.
private struct ModelEntry: Identifiable {
    let provider: AIProvider
    let model: String
    var id: String { provider.rawValue + "\u{1}" + model }
}

// MARK: — Claude Code card (setup only: presence + install hint; the switcher does the activating)

private struct ClaudeCodeCard: View {
    @Environment(AppEnvironment.self) private var env
    private var ai: AIProviderStore { env.ai }
    private let provider = AIProvider.claudeCode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text("Uses the Claude Code you're already signed into — no API key to paste. Excerpts are sent to Anthropic through your Claude Code login, so it needs the same cloud opt-in.")
                .font(.footnote).foregroundStyle(.secondary)

            switch ai.claudeCode {
            case .unknown, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Claude Code…").foregroundStyle(.secondary)
                }
            case .notFound:
                notFoundRows
            case .found:
                Text("Ready — choose it in the switcher above")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(spacing: 8) {
            statusDot
            Text(verbatim: provider.displayName)
            CloudBadge()
        }
    }

    private var statusDot: some View {
        let color: Color = switch ai.claudeCode {
        case .found:              .green
        case .checking, .unknown: .yellow
        case .notFound:           .red
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private var notFoundRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Claude Code not found", systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
            Text("Install the Claude Code CLI and run `claude` once to sign in, then re-check.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Re-check") { Task { await ai.probeClaudeCode(force: true) } }
                .buttonStyle(.borderless)
        }
    }
}

// MARK: — generic provider card (setup only: status + credentials + Connect; no picker, no activation)

private struct ProviderCard: View {
    let provider: AIProvider
    let requestCloudConsent: (AIProvider) -> Void
    @Environment(AppEnvironment.self) private var env
    @State private var keyDraft = ""

    private var ai: AIProviderStore { env.ai }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if provider == .custom { endpointField }
            // OpenRouter: one-click "Connect" (real OAuth + PKCE) ABOVE the manual key field.
            if provider == .openrouter && !ai.hasKey(provider) { openRouterOAuthRow }
            if provider.usesAPIKey { keyRow }
            connectRow
            // No server-provided list yet (empty /v1/models, JIT loading, or not probed) → let any LOCAL
            // provider's model be typed in by hand; this FEEDS the switcher list, it does not activate.
            if ai.fetchedModels(provider).isEmpty && !provider.isCloud { manualModelField }
            footer
        }
        .padding(.vertical, 2)
    }

    // MARK: header (status dot + name + CLOUD badge)

    private var header: some View {
        HStack(spacing: 8) {
            statusDot
            Text(verbatim: provider.displayName)
            if provider.isCloud { CloudBadge() }
        }
    }

    private var statusDot: some View {
        let color: Color = switch ai.status(provider) {
        case .connected:    .green
        case .probing:      .yellow
        case .error:        .red
        case .notConfigured: .secondary.opacity(0.5)
        }
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    // MARK: rows

    private var endpointField: some View {
        TextField("Endpoint", text: Binding(
            get: { ai.endpoint(for: provider) },
            set: { ai.setEndpoint($0, for: provider) }),
            prompt: Text(verbatim: "http://127.0.0.1:8080/v1"))
            .textContentType(.URL)
            .autocorrectionDisabled()
    }

    private var keyRow: some View {
        HStack(spacing: 8) {
            if ai.hasKey(provider) {
                Label("API key in Keychain", systemImage: "key.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Remove key") { ai.removeKey(for: provider) }
                    .buttonStyle(.borderless).foregroundStyle(.red)
            } else {
                // For OpenRouter the OAuth button above is the primary path; the key field is a fallback.
                SecureField(provider == .openrouter ? "…or paste a key" : "API key",
                            text: $keyDraft, prompt: Text(verbatim: "sk-…"))
                    .onSubmit { saveKey() }
                Button("Save") { saveKey() }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let url = provider.keyConsoleURL {
                    Link("Get a key…", destination: url)
                }
            }
        }
    }

    // MARK: OpenRouter one-click sign-in (OAuth + PKCE)

    @ViewBuilder
    private var openRouterOAuthRow: some View {
        switch ai.openRouterOAuthPhase {
        case .running:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for your browser…").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { ai.cancelOpenRouterOAuth() }
                    .buttonStyle(.borderless)
            }
        case .idle, .failed:
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    ai.connectOpenRouterOAuth()
                } label: {
                    Label("Connect OpenRouter", systemImage: "person.badge.key.fill")
                }
                .buttonStyle(.borderedProminent)
                if case .failed(let msg) = ai.openRouterOAuthPhase {
                    Label(msg, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(3).help(msg)
                }
            }
        }
    }

    private func saveKey() {
        ai.saveKey(keyDraft, for: provider)
        keyDraft = ""
    }

    private var connectRow: some View {
        HStack(spacing: 10) {
            Button {
                Task { await ai.connect(provider) }
            } label: {
                Label(provider.isCloud ? "Load models" : "Connect", systemImage: "bolt.horizontal")
            }
            .disabled(isProbing || (provider.usesAPIKey && !ai.hasKey(provider))
                      || (provider == .custom && ai.endpoint(for: provider).isEmpty))

            if isProbing { ProgressView().controlSize(.small) }
            Spacer()
            statusText
        }
    }

    private var isProbing: Bool { ai.status(provider) == .probing }

    /// Setup-only status: a NEUTRAL model count (no green "Active" claim — that lives in the switcher).
    @ViewBuilder
    private var statusText: some View {
        switch ai.status(provider) {
        case .notConfigured:
            EmptyView()
        case .probing:
            Text("connecting…").foregroundStyle(.secondary)
        case .connected(let n):
            Text("\(n) models available").foregroundStyle(.secondary)
        case .error(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).lineLimit(2).help(msg)
        }
    }

    /// A local server may not implement /v1/models (or return an empty list while a model JIT-loads) —
    /// manual model entry as a fallback so LM Studio / Ollama / custom always have a model for the switcher.
    private var manualModelField: some View {
        TextField("Model", text: Binding(
            get: { ai.model(for: provider) },
            set: { ai.setModel($0, for: provider) }),
            prompt: Text(verbatim: "llama3.2 / qwen2.5 / …"))
            .autocorrectionDisabled()
    }

    // MARK: footer (one-line "what this is")

    @ViewBuilder
    private var footer: some View {
        switch provider {
        case .lmstudio:
            caption("Runs on this Mac (port 1234). Free and private — start the LM Studio server, then Connect.")
        case .ollama:
            caption("Runs on this Mac (port 11434). Free and private — `ollama serve`, then Connect.")
        case .custom:
            caption("Any OpenAI-compatible server on localhost: mlx_lm.server, llama.cpp server, …")
        case .claudeCode:
            EmptyView()   // handled by ClaudeCodeCard
        case .openrouter, .anthropic, .openai:
            caption("Cloud: excerpts of your screen history are sent to this provider — only after your explicit opt-in. The API key is stored in the Keychain.")
        }
    }

    private func caption(_ key: LocalizedStringKey) -> some View {
        Text(key).font(.footnote).foregroundStyle(.secondary)
    }
}

/// The small orange "CLOUD" tag shared by every provider whose excerpts may leave the Mac.
private struct CloudBadge: View {
    var body: some View {
        Text(verbatim: "CLOUD")
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(.orange)
    }
}
