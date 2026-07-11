import SwiftUI

/// Provider-first AI setup. The only top-level model-like object is the
/// built-in local provider's hero; every other model stays inside its provider.
struct ProviderFirstAIModelsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var pendingActivation: ActivationIntent?
    @State private var moreExpanded = false
    @State private var activationError: String?

    private var ai: AIProviderStore { env.ai }
    private var consentIsPresented: Binding<Bool> {
        Binding(
            get: { pendingActivation != nil },
            set: { isPresented in
                if !isPresented { pendingActivation = nil }
            }
        )
    }

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 14, alignment: .top),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ActiveAISelectionCard(
                    activationError: activationError,
                    select: select
                )

                BuiltInLocalHero()

                providerSection(
                    title: "Cloud providers",
                    caption: "Connect a provider, then choose one of its models inside the card.",
                    providers: AIModelsPresentation.primaryProviders
                )

                providerSection(
                    title: "Local-server providers",
                    caption: "Separate connections for servers you already run. Their models remain inside each connection.",
                    providers: AIModelsPresentation.localServerProviders
                )

                DisclosureGroup(isExpanded: $moreExpanded) {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(AIModelsPresentation.moreProviders) { provider in
                            ProviderFirstCard(provider: provider)
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("More providers")
                            .font(.headline)
                        Text("Moonshot AI, Z.AI, Xiaomi, OpenAI, and Claude Code")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                privacyNote
            }
            .padding(24)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("AI Models")
        .task {
            await AIModelsPresentation.prepareScreen(providers: ai) {
                await env.builtInModels.refresh()
            }
        }
        .alert(
            "Enable cloud processing?",
            isPresented: consentIsPresented,
            presenting: pendingActivation
        ) { intent in
            Button("Cancel", role: .cancel) {
                pendingActivation = nil
            }
            if let provider = AIProvider(rawValue: intent.providerID) {
                Button("Enable \(provider.displayName)") {
                    let committed = ai.commitActivation(
                        intent,
                        grantCloudConsent: true
                    )
                    if !committed {
                        activationError = String(localized: "The available models changed. Choose the provider and model again.")
                    }
                    pendingActivation = nil
                }
            }
        } message: { intent in
            if let provider = AIProvider(rawValue: intent.providerID) {
                Text(consentMessage(for: provider))
            }
        }
    }

    private func providerSection(
        title: LocalizedStringKey,
        caption: LocalizedStringKey,
        providers: [AIProvider]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(providers) { provider in
                    ProviderFirstCard(provider: provider)
                }
            }
        }
    }

    private var privacyNote: some View {
        Label {
            Text("Cloud processing is always explicit. Before activation, ZBS Eye names the recipient and scopes. Recordings, the search index, and model preferences stay on this Mac.")
                .font(.footnote)
        } icon: {
            Image(systemName: "hand.raised.fill")
        }
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func select(_ provider: AIProvider, _ modelID: String) {
        activationError = nil
        guard let intent = ai.activationIntent(for: provider, modelID: modelID) else {
            activationError = String(localized: "That provider or model is not ready. Connect it and try again.")
            return
        }
        if provider.isCloud,
           !ai.hasConsent(provider, for: Set(AIConsumer.allCases)) {
            pendingActivation = intent
            return
        }
        if !ai.commitActivation(intent) {
            activationError = String(localized: "The available models changed. Choose the provider and model again.")
        }
    }

    private func consentMessage(for provider: AIProvider) -> String {
        let recipient = localizedRecipient(for: provider)
        return String(localized: "ZBS Eye will send only the excerpts needed for Ask, Daily Insights, manual and scheduled summaries, and automatic activity labels to \(recipient). Recordings and the search index stay on this Mac.")
    }

    private func localizedRecipient(for provider: AIProvider) -> String {
        switch provider {
        case .codex:
            return String(localized: "OpenAI through your Codex login")
        case .openrouter:
            return String(localized: "OpenRouter and the selected upstream model operator")
        case .anthropic, .claudeCode:
            return String(localized: "Anthropic")
        case .moonshot:
            return String(localized: "Moonshot AI")
        case .zai:
            return String(localized: "Z.AI")
        case .xiaomi:
            return String(localized: "Xiaomi")
        case .openai:
            return String(localized: "OpenAI")
        case .zbsEyeLocal, .ollama, .lmstudio, .custom:
            return provider.displayName
        }
    }
}

// MARK: - Global active pair

private struct ActiveAISelectionCard: View {
    @Environment(AppEnvironment.self) private var env
    let activationError: String?
    let select: (AIProvider, String) -> Void

    private var ai: AIProviderStore { env.ai }

    private var providerOrder: [AIProvider] {
        [.zbsEyeLocal]
            + AIModelsPresentation.primaryProviders
            + AIModelsPresentation.localServerProviders
            + AIModelsPresentation.moreProviders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    activeIdentity
                }
                Spacer(minLength: 12)
                activeMenu
            }

            activeCaption

            if let warning = ai.persistenceWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let activationError {
                Label(activationError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(15)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var activeIdentity: some View {
        if let provider = ai.activeProvider,
           let modelID = ai.activeModelID {
            let name = AIModelsProviderCardPresentation.shortName(
                modelID,
                provider: provider
            )
            HStack(spacing: 7) {
                Image(systemName: ai.activeConfig == nil
                      ? "exclamationmark.circle.fill"
                      : "checkmark.circle.fill")
                    .foregroundStyle(ai.activeConfig == nil ? .orange : .green)
                Text(verbatim: "\(provider.displayName) · \(name)")
                    .font(.title3.weight(.semibold))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                ai.activeConfig == nil
                    ? "Active model \(provider.displayName), \(name), attention required"
                    : "Active model \(provider.displayName), \(name), ready"
            )
        } else {
            HStack(spacing: 7) {
                Image(systemName: "pause.circle")
                    .foregroundStyle(.secondary)
                Text("None — AI features are off")
                    .font(.title3.weight(.semibold))
            }
        }
    }

    private var activeMenu: some View {
        Menu {
            ForEach(providerOrder) { provider in
                let models = ai.availableModels(for: provider)
                if !models.isEmpty {
                    Section {
                        ForEach(models, id: \.self) { modelID in
                            Button {
                                select(provider, modelID)
                            } label: {
                                let short = AIModelsProviderCardPresentation.shortName(
                                    modelID,
                                    provider: provider
                                )
                                if ai.activeProvider == provider,
                                   ai.activeModelID == modelID {
                                    Label(
                                        "\(provider.displayName) · \(short)",
                                        systemImage: "checkmark"
                                    )
                                } else {
                                    Text(verbatim: "\(provider.displayName) · \(short)")
                                }
                            }
                        }
                    } header: {
                        Text(verbatim: provider.displayName)
                    }
                }
            }
            Divider()
            Button {
                ai.deactivate()
            } label: {
                if ai.activeProvider == nil {
                    Label("None — turn AI features off", systemImage: "checkmark")
                } else {
                    Text("None — turn AI features off")
                }
            }
        } label: {
            Label("Switch provider or model", systemImage: "arrow.left.arrow.right")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var activeCaption: some View {
        if let provider = ai.activeProvider {
            if ai.activeConfig == nil {
                Text("The saved pair is still yours, but it needs a connection, model, or processing permission before it can run.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if provider.isCloud {
                Text("Ask, Daily Insights, summaries, and labels use this pair. History excerpts go only to the recipient you approved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Ask, Daily Insights, summaries, and labels use this one local pair.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if provider.isCloud,
               ai.consentGrant(provider) != nil,
               !ai.hasConsent(provider, for: Set(AIConsumer.allCases)) {
                Label("Consent update required for automatic activity labels", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Choose one provider and model. The same pair powers every AI feature.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Built-in provider hero

private struct BuiltInLocalHero: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmRemoval = false

    private var store: BuiltInModelStore { env.builtInModels }
    private var manifest: BuiltInModelManifest { .regular }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("DEFAULT · ON THIS MAC")
                        .font(.caption2.bold())
                        .tracking(0.7)
                        .foregroundStyle(.green)
                    Text("ZBS Eye Local")
                        .font(.title2.weight(.semibold))
                    Text("Download once. Ask, Daily Insights, summaries, and activity labels then work without another app, account, or API key.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Label("PRIVATE", systemImage: "lock.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(.green)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recommended model for this Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: manifest.displayName)
                        .font(.headline)
                }
                Spacer()
                Text(verbatim: "\(Self.bytes(displayedModelBytes)) · v\(manifest.artifactVersion)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(11)
            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))

            lifecycleStatus
            lifecycleActions

            if let operationError = store.operationError {
                Label(operationError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(19)
        .background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.green.opacity(0.34), lineWidth: 1)
        }
        .confirmationDialog(
            "Remove the built-in model?",
            isPresented: $confirmRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove model files", role: .destructive) {
                store.remove()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees the local model space. Your recordings, search index, provider preferences, and generated history are not removed.")
        }
    }

    @ViewBuilder
    private var lifecycleStatus: some View {
        switch store.hardwareSupport {
        case .checking:
            statusRow("Checking this Mac…", systemImage: "cpu", busy: true)
        case .unsupported(let reason):
            warningRow(verbatim: reason)
        case .unavailable(let reason):
            warningRow(verbatim: reason)
        case .supported:
            if let snapshot = store.snapshot {
                snapshotStatus(snapshot)
            } else {
                statusRow("Preparing local AI…", systemImage: "gearshape.2", busy: true)
            }
        }
    }

    @ViewBuilder
    private func snapshotStatus(_ snapshot: BuiltInModelManagerSnapshot) -> some View {
        if !snapshot.rootAvailable {
            warningRow("The configured model storage is unavailable. Connect the storage volume and restart ZBS Eye.")
        } else if snapshot.suspendedForRelocation {
            statusRow("Paused while storage is moving…", systemImage: "externaldrive.badge.timemachine", busy: true)
        } else if snapshot.state.inventory.lastKnownGood != nil,
                  snapshot.state.inventory.candidate != nil,
                  snapshot.projection.readiness == .usable {
            VStack(alignment: .leading, spacing: 9) {
                statusRow("Installed version remains ready", systemImage: "checkmark.circle.fill", color: .green)
                provisioningStatus(snapshot, candidateOnly: true)
            }
        } else {
            provisioningStatus(snapshot, candidateOnly: false)
        }
    }

    @ViewBuilder
    private func provisioningStatus(
        _ snapshot: BuiltInModelManagerSnapshot,
        candidateOnly: Bool
    ) -> some View {
        switch snapshot.state.provisioningJob {
        case .downloading(let progress):
            progressRow(candidateOnly ? "Downloading replacement" : "Downloading", progress: progress)
        case .paused(let progress):
            progressRow(candidateOnly ? "Replacement download paused" : "Download paused", progress: progress)
        case .pausedLowDisk(let progress, let required, let available):
            progressRow("Paused — more free space needed", progress: progress)
            Text("Needs \(Self.bytes(required)); \(Self.bytes(available)) available. ZBS Eye keeps 2 GB free for recording.")
                .font(.footnote)
                .foregroundStyle(.orange)
        case .preflightBlocked(let required, let available):
            warningRow("Not enough free space: needs \(Self.bytes(required)); \(Self.bytes(available)) available. Recording space is never reclaimed for a model.")
        case .verifying, .verificationPending:
            statusRow(candidateOnly ? "Verifying replacement files…" : "Verifying every downloaded file…", systemImage: "checkmark.shield", busy: true)
        case .failed(let failure):
            if candidateOnly {
                warningRow("Replacement failed: \(failure.message). The installed version is still ready.")
            } else {
                warningRow(verbatim: failure.message)
            }
        case .waitingForRuntimeDrain, .removing, .removalPending:
            statusRow("Removing local model files…", systemImage: "trash", busy: true)
        case .idle:
            if candidateOnly {
                statusRow("Replacement is staged", systemImage: "shippingbox")
            } else {
                readinessStatus(snapshot.projection.readiness, state: snapshot.state)
            }
        }
    }

    @ViewBuilder
    private func readinessStatus(
        _ readiness: BuiltInModelReadiness,
        state: BuiltInModelLifecycleState
    ) -> some View {
        switch readiness {
        case .unavailable:
            if state.inventory.candidate != nil {
                statusRow("Download interrupted — ready to resume", systemImage: "arrow.clockwise")
            } else {
                let free = store.availableCapacityBytes
                if let free {
                    statusRow("Ready to download · \(Self.bytes(free)) free", systemImage: "arrow.down.circle")
                } else {
                    statusRow("Ready to download", systemImage: "arrow.down.circle")
                }
            }
        case .loading:
            statusRow("Installed — loading the local runtime…", systemImage: "cpu", busy: true)
        case .usable:
            statusRow("Installed and ready", systemImage: "checkmark.circle.fill", color: .green)
        case .installedButRuntimeFailed:
            let reason: String = switch state.runtimeState {
            case .failed(_, let message): message
            default: String(localized: "The installed model could not load.")
            }
            warningRow(verbatim: reason)
        case .removing:
            statusRow("Removing local model files…", systemImage: "trash", busy: true)
        }
    }

    private func progressRow(
        _ title: LocalizedStringKey,
        progress: ProvisioningProgress
    ) -> some View {
        let total = max(1, progress.expectedBytes)
        let received = min(max(0, progress.receivedBytes), total)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(verbatim: "\(Self.bytes(received)) / \(Self.bytes(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(received), total: Double(total))
                .accessibilityLabel(title)
                .accessibilityValue("\(Self.bytes(received)) of \(Self.bytes(total))")
        }
    }

    private func statusRow(
        _ title: LocalizedStringKey,
        systemImage: String,
        color: Color = .secondary,
        busy: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
            Text(title)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private func warningRow(_ message: LocalizedStringKey) -> some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.footnote)
        .foregroundStyle(.orange)
    }

    private func warningRow(verbatim message: String) -> some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
            .font(.footnote)
            .foregroundStyle(.orange)
    }

    @ViewBuilder
    private var lifecycleActions: some View {
        if case .supported = store.hardwareSupport,
           let snapshot = store.snapshot,
           snapshot.rootAvailable,
           !snapshot.suspendedForRelocation {
            let actions = snapshot.projection.actions
            HStack(spacing: 9) {
                if actions.contains(.downloadAndEnable) {
                    Button {
                        store.install()
                    } label: {
                        Label("Download & enable", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                if actions.contains(.pause) {
                    Button("Pause") { Task { await store.pause() } }
                }
                if actions.contains(.resume) {
                    Button("Resume") { store.resume() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                if actions.contains(.retry) {
                    Button("Retry") { store.retry() }
                }
                if actions.contains(.retryLoad) {
                    Button("Retry load") { store.retryRuntimeLoad() }
                }
                if actions.contains(.reinstall) {
                    Button("Reinstall") { store.reinstall() }
                }
                if actions.contains(.cancel) || actions.contains(.discardCandidate) {
                    Button("Cancel download", role: .destructive) {
                        Task { await store.cancel() }
                    }
                }
                if actions.contains(.remove) {
                    Button("Remove…", role: .destructive) {
                        confirmRemoval = true
                    }
                }
                if store.isBusy,
                   !actions.contains(.pause),
                   !actions.contains(.cancel) {
                    ProgressView().controlSize(.small)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private static func bytes(_ value: Int64) -> String {
        StorageSettingsStore.format(max(0, value))
    }

    private var displayedModelBytes: Int64 {
        let verified = store.storageSnapshot?.activeVerifiedBytes ?? 0
        return verified > 0 ? verified : manifest.expectedDownloadBytes
    }
}

// MARK: - Provider cards

private struct ProviderFirstCard: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    let provider: AIProvider

    @State private var keyDraft = ""
    @State private var codexCompleting = false
    @State private var connectionTask: Task<Void, Never>?

    private var ai: AIProviderStore { env.ai }
    private var presentation: AIModelsProviderCardPresentation {
        AIModelsProviderCardPresentation(
            provider: provider,
            modelIDs: ai.availableModels(for: provider)
        )
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 11) {
                header
                providerStatusLine
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                connectionControls
                modelControls
                consentControls
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(provider.displayName)
        .onDisappear {
            connectionTask?.cancel()
            connectionTask = nil
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 7) {
            ProviderFirstStatus(provider: provider)
            Text(verbatim: provider.displayName)
                .font(.headline)
            if provider.isCloud { ProviderFirstCloudBadge() }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var providerStatusLine: some View {
        switch ai.status(provider) {
        case .notConfigured:
            Text("Not connected")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .probing:
            Text("Connecting…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .connected(let count):
            if provider.catalogDialect == .documentedSuggestions {
                Text("\(count) suggested models")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("Connected · \(count) models")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var description: LocalizedStringKey {
        switch provider {
        case .codex:
            "Use your signed-in OpenAI account through the approved Codex app server."
        case .openrouter:
            "One account with a broad live catalog. Claude Haiku is recommended when available."
        case .anthropic:
            "Connect directly to Anthropic. Claude Haiku is recommended when available."
        case .moonshot:
            "Moonshot AI is the provider; Kimi models stay inside this card."
        case .zai:
            "Z.AI is the provider; its documented GLM suggestions stay inside this card."
        case .xiaomi:
            "Xiaomi is the provider; its documented MiMo suggestions stay inside this card."
        case .openai:
            "Connect directly with an OpenAI API key and live model catalog."
        case .claudeCode:
            "Use the signed Claude Code installation already authenticated on this Mac."
        case .ollama:
            "Connect to Ollama on this Mac. Start the server first, then load its models."
        case .lmstudio:
            "Connect to LM Studio on this Mac. Start its local server first."
        case .custom:
            "An advanced OpenAI-compatible server on localhost only."
        case .zbsEyeLocal:
            "Built-in local AI is managed by the hero above."
        }
    }

    @ViewBuilder
    private var connectionControls: some View {
        switch provider {
        case .codex:
            codexControls
        case .claudeCode:
            claudeCodeControls
        default:
            genericControls
        }
    }

    @ViewBuilder
    private var genericControls: some View {
        if provider == .custom {
            TextField(
                "Endpoint",
                text: Binding(
                    get: { ai.endpoint(for: provider) },
                    set: { ai.setEndpoint($0, for: provider) }
                ),
                prompt: Text(verbatim: "http://127.0.0.1:8080/v1")
            )
            .textContentType(.URL)
            .autocorrectionDisabled()
        }

        if provider == .openrouter, !ai.hasKey(provider) {
            openRouterControls
        }

        if provider.usesAPIKey {
            apiKeyControls
        }

        HStack(spacing: 8) {
            Button {
                beginConnect()
            } label: {
                Label(connectTitle, systemImage: "arrow.clockwise")
            }
            .disabled(
                connectionTask != nil
                    || (provider.usesAPIKey && !ai.hasKey(provider))
                    || (provider == .custom && ai.endpoint(for: provider).isEmpty)
            )
            if connectionTask != nil {
                ProgressView().controlSize(.small)
                Button("Cancel") {
                    connectionTask?.cancel()
                    connectionTask = nil
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private var connectTitle: LocalizedStringKey {
        switch ai.status(provider) {
        case .connected:
            provider.catalogDialect == .documentedSuggestions
                ? "Refresh suggestions"
                : "Refresh models"
        case .notConfigured, .probing, .error:
            provider.isCloud ? "Load models" : "Connect"
        }
    }

    @ViewBuilder
    private var openRouterControls: some View {
        switch ai.openRouterOAuthPhase {
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for browser sign-in…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Cancel") { ai.cancelOpenRouterOAuth() }
            }
        case .idle, .failed:
            Button {
                ai.connectOpenRouterOAuth()
            } label: {
                Label("Connect OpenRouter", systemImage: "person.badge.key.fill")
            }
            .buttonStyle(.borderedProminent)
            if case .failed(let message) = ai.openRouterOAuthPhase {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var apiKeyControls: some View {
        if ai.hasKey(provider) {
            HStack(spacing: 7) {
                Label("API key saved in Keychain", systemImage: "key.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
                Spacer(minLength: 4)
                Button("Remove key", role: .destructive) {
                    ai.removeKey(for: provider)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                SecureField(
                    provider == .openrouter ? "…or paste an API key" : "API key",
                    text: $keyDraft,
                    prompt: Text(verbatim: "sk-…")
                )
                .onSubmit { saveKey() }
                HStack {
                    Button("Save key") { saveKey() }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let keyURL = provider.keyConsoleURL {
                        Link("Get a key…", destination: keyURL)
                    }
                }
            }
        }
    }

    private func saveKey() {
        ai.saveKey(keyDraft, for: provider, connectAfterSave: false)
        keyDraft = ""
        if ai.hasKey(provider) { beginConnect() }
    }

    private func beginConnect() {
        connectionTask?.cancel()
        connectionTask = Task { @MainActor in
            await ai.connect(provider)
            connectionTask = nil
        }
    }

    @ViewBuilder
    private var codexControls: some View {
        switch ai.codexConnection {
        case .unknown:
            Button("Check Codex") { Task { await ai.probeCodex(force: true) } }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking Codex and account…").font(.footnote)
            }
        case .missing:
            Label("Codex is not installed", systemImage: "xmark.circle")
                .font(.footnote)
            Button("Re-check") { Task { await ai.probeCodex(force: true) } }
        case .untrusted:
            Label("Upgrade required — this Codex build is not approved", systemImage: "exclamationmark.shield")
                .font(.footnote)
                .foregroundStyle(.orange)
            Button("Re-check") { Task { await ai.probeCodex(force: true) } }
        case .ready:
            Button {
                Task {
                    if let challenge = await ai.startCodexLogin() {
                        openURL(challenge.authorizationURL)
                    }
                }
            } label: {
                Label("Sign in with ChatGPT", systemImage: "person.crop.circle.badge.checkmark")
            }
            .buttonStyle(.borderedProminent)
        case .loginPending(_, let authorizationURL):
            VStack(alignment: .leading, spacing: 8) {
                Link("Open ChatGPT sign-in", destination: authorizationURL)
                HStack {
                    Button("I’ve finished signing in") {
                        codexCompleting = true
                        Task {
                            await ai.completeCodexLogin()
                            codexCompleting = false
                        }
                    }
                    .disabled(codexCompleting)
                    Button("Cancel") { Task { await ai.cancelCodexLogin() } }
                    if codexCompleting { ProgressView().controlSize(.small) }
                }
            }
        case .authenticated(let version, _):
            Label("Connected · Codex \(version)", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
            Button("Refresh models") { Task { await ai.probeCodex(force: true) } }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
            Button("Retry") { Task { await ai.probeCodex(force: true) } }
        }
    }

    @ViewBuilder
    private var claudeCodeControls: some View {
        switch ai.claudeCode {
        case .unknown:
            Button("Check Claude Code") { Task { await ai.probeClaudeCode(force: true) } }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking Claude Code and account…").font(.footnote)
            }
        case .found:
            Label("Signed and authenticated", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
            Button("Re-check") { Task { await ai.probeClaudeCode(force: true) } }
        case .notFound:
            Label("Claude Code is not installed", systemImage: "xmark.circle")
                .font(.footnote)
            Button("Re-check") { Task { await ai.probeClaudeCode(force: true) } }
        case .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.shield")
                .font(.footnote)
                .foregroundStyle(.orange)
            Button("Re-check") { Task { await ai.probeClaudeCode(force: true) } }
        }
    }

    @ViewBuilder
    private var modelControls: some View {
        if !presentation.models.isEmpty {
            Divider()
            Picker(
                "Model",
                selection: Binding(
                    get: {
                        presentation.models.contains(where: { $0.id == ai.model(for: provider) })
                            ? ai.model(for: provider)
                            : ""
                    },
                    set: { value in
                        if !value.isEmpty { ai.setModel(value, for: provider) }
                    }
                )
            ) {
                Text("Choose a model…").tag("")
                ForEach(presentation.models) { model in
                    let recommendation = provider.catalogDialect == .documentedSuggestions
                        ? String(localized: "Suggested")
                        : String(localized: "Recommended")
                    Text(verbatim: model.isRecommended
                         ? "\(model.shortName) — \(recommendation)"
                         : model.shortName)
                        .tag(model.id)
                }
            }

            if provider.catalogDialect == .documentedSuggestions {
                Label("Suggested from provider documentation — not verified by a live model-list endpoint", systemImage: "doc.text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let recommended = presentation.models.first(where: \.isRecommended) {
                Label {
                    Text("Recommended: \(recommended.shortName)")
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(.caption)
                .foregroundStyle(.green)
            }

            Text("This saves a preference inside \(provider.displayName). Use Active above to switch the global pair.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let saved = missingSavedModel {
                Label("Saved model unavailable: \(saved)", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else if let family = recommendedFamily {
            Divider()
            Label("Recommended after connection: \(family)", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let saved = missingSavedModel {
                Label("Saved model unavailable: \(saved)", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } else if let saved = missingSavedModel {
            Divider()
            Label("Saved model unavailable: \(saved)", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var missingSavedModel: String? {
        let saved = ai.model(for: provider)
        guard !saved.isEmpty,
              !presentation.models.contains(where: { $0.id == saved }) else {
            return nil
        }
        return saved
    }

    private var recommendedFamily: String? {
        switch provider {
        case .openrouter, .anthropic: "Claude Haiku"
        case .moonshot: "Kimi"
        case .zai: "GLM"
        case .xiaomi: "MiMo"
        default: nil
        }
    }

    @ViewBuilder
    private var consentControls: some View {
        if provider.isCloud, ai.consentGrant(provider) != nil {
            Divider()
            if !ai.hasConsent(provider, for: Set(AIConsumer.allCases)) {
                Label("Consent update required for automatic activity labels", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("Revoke processing consent", role: .destructive) {
                ai.revokeConsent(provider)
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct ProviderFirstStatus: View {
    @Environment(AppEnvironment.self) private var env
    let provider: AIProvider

    var body: some View {
        let status = env.ai.status(provider)
        Circle()
            .fill(color(for: status))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
            .help(text(for: status))
    }

    private func color(for status: AIProviderStore.CardStatus) -> Color {
        switch status {
        case .notConfigured: .secondary.opacity(0.45)
        case .probing: .yellow
        case .connected: .green
        case .error: .red
        }
    }

    private func text(for status: AIProviderStore.CardStatus) -> String {
        switch status {
        case .notConfigured: String(localized: "Not connected")
        case .probing: String(localized: "Connecting")
        case .connected(let count): String(localized: "Connected, \(count) models")
        case .error(let message): message
        }
    }
}

private struct ProviderFirstCloudBadge: View {
    var body: some View {
        Text("CLOUD")
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.16), in: Capsule())
            .foregroundStyle(.orange)
            .accessibilityLabel("Cloud provider")
    }
}
