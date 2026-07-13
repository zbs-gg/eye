import AppKit
import SwiftUI

struct AISetupView: View {
    @Environment(AppEnvironment.self) private var env
    let sessionID: UUID
    var showsCloseButton = true

    private var setup: AISetupPresentation { env.aiSetup }

    var body: some View {
        @Bindable var setup = setup
        VStack(alignment: .leading, spacing: 18) {
            header
            activeSelection

            Picker("Connection type", selection: $setup.selectedPath) {
                ForEach(AISetupPath.allCases) { path in
                    Text(path.title).tag(path)
                }
            }
            .pickerStyle(.segmented)

            providerPicker

            if let provider = setup.selectedProvider {
                AISetupProviderView(provider: provider, sessionID: sessionID)
                    .id(provider)
            } else {
                ContentUnavailableView {
                    Label("Choose a provider", systemImage: "sparkles")
                } description: {
                    Text("Nothing connects, downloads, or activates until you choose.")
                }
                .frame(maxHeight: .infinity)
            }

            privacyNote
        }
        .padding(24)
        .frame(minWidth: 600, idealWidth: 680, minHeight: 520, idealHeight: 620)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add AI").font(.title2.bold())
                Text("Optional. Eye keeps recording, Timeline, and local search without it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if showsCloseButton {
                Button("Done") { setup.dismiss(sessionID: sessionID) }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var activeSelection: some View {
        HStack(spacing: 10) {
            Image(systemName: env.ai.activeProvider == nil ? "pause.circle" : "checkmark.circle.fill")
                .foregroundStyle(env.ai.activeProvider == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Active").font(.caption).foregroundStyle(.secondary)
                Text(activeLabel).font(.headline)
            }
            Spacer()
            if env.ai.activeProvider != nil {
                Button("Disconnect") { env.ai.deactivate() }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var activeLabel: String {
        AISetupPresentation.activeLabel(
            provider: env.ai.activeProvider,
            modelID: env.ai.activeModelID
        )
    }

    private var providerPicker: some View {
        HStack {
            Text("Provider")
            Spacer()
            Picker("Provider", selection: Binding(
                get: { setup.selectedProvider },
                set: { setup.selectedProvider = $0 }
            )) {
                Text("Choose…").tag(nil as AIProvider?)
                ForEach(AISetupPresentation.providers(for: setup.selectedPath)) { provider in
                    Text(provider.displayName).tag(provider as AIProvider?)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
        }
    }

    private var privacyNote: some View {
        Label(
            "Capture and storage stay local. Cloud processing happens only for the provider and text scope you explicitly approve.",
            systemImage: "hand.raised.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct AISetupProviderView: View {
    @Environment(AppEnvironment.self) private var env
    let provider: AIProvider
    let sessionID: UUID

    @State private var apiKey = ""
    @State private var pendingActivation: ActivationIntent?
    @State private var actionMessage: String?

    private var setup: AISetupPresentation { env.aiSetup }
    private var ai: AIProviderStore { env.ai }

    var body: some View {
        let models = ai.availableModels(for: provider)
        let recommendedModel = provider.recommendedModel(in: models)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                providerHeader
                if provider == .zbsEyeLocal {
                    builtInControls(models: models, recommendedModel: recommendedModel)
                } else {
                    if provider.allowsEndpointOverride { endpointField }
                    if provider.usesAPIKey { credentialControls }
                    connectionControls
                    modelControls(models: models, recommendedModel: recommendedModel)
                }
                if let actionMessage {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if ai.hasKey(provider) {
                    Button("Remove Credential", role: .destructive) {
                        ai.removeKey(for: provider)
                        actionMessage = nil
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert(
            "Allow this provider to answer from Eye?",
            isPresented: Binding(
                get: { pendingActivation != nil },
                set: { if !$0 { pendingActivation = nil } }
            ),
            presenting: pendingActivation
        ) { intent in
            Button("Cancel", role: .cancel) { pendingActivation = nil }
            Button("Allow and use") {
                commit(intent, grantCloudConsent: true)
                pendingActivation = nil
            }
        } message: { _ in
            Text(consentMessage)
        }
        .onDisappear {
            if provider == .codex,
               case .loginPending(let loginID, _) = ai.codexConnection {
                Task { await ai.cancelCodexLogin(expectedLoginID: loginID) }
            }
            if provider == .openrouter { ai.cancelOpenRouterOAuth() }
        }
    }

    private var providerHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(provider.displayName).font(.headline)
            Text(providerSummary).font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func builtInControls(models: [String], recommendedModel: String?) -> some View {
        if env.builtInModels.isBusy {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Downloading or preparing the local model…")
                    .foregroundStyle(.secondary)
                Button("Pause") { Task { await env.builtInModels.pause() } }
                Button("Cancel", role: .destructive) {
                    Task { await env.builtInModels.cancel() }
                }
            }
        } else if models.isEmpty {
            Button {
                env.builtInModels.install()
            } label: {
                Label("Download & enable", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            Text("One explicit download. The durable model job continues if this sheet closes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(models, id: \.self) { model in
                modelButton(model, recommendedModel: recommendedModel)
            }
        }
        if let error = env.builtInModels.operationError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private var endpointField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(provider == .customAPI ? "HTTPS base URL" : "Local endpoint")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(
                provider == .customAPI ? "https://inference.example/v1" : "http://127.0.0.1:8000/v1",
                text: Binding(
                    get: { ai.endpoint(for: provider) },
                    set: { ai.setEndpoint($0, for: provider) }
                )
            )
            .textFieldStyle(.roundedBorder)
        }
    }

    private var credentialControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField(ai.hasKey(provider) ? "Credential saved" : "API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            Button("Save Credential") {
                guard ai.saveKey(apiKey, for: provider, connectAfterSave: false) else {
                    actionMessage = String(localized: "The credential could not be saved to Keychain.")
                    return
                }
                apiKey = ""
                actionMessage = nil
            }
            .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if provider == .codex,
                   case .ready = ai.codexConnection {
                    Button("Sign in to Codex") { startCodexLogin() }
                        .disabled(setup.hasEphemeralWork)
                } else if provider == .codex,
                          case .loginPending = ai.codexConnection {
                    Button("Complete Sign-in") {
                        setup.runEphemeral(sessionID: sessionID) {
                            await ai.completeCodexLogin()
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        Task { await ai.cancelCodexLogin() }
                    }
                } else {
                    Button(connectionTitle) { connect() }
                        .disabled(setup.hasEphemeralWork)
                }
            switch ai.status(provider) {
            case .probing:
                ProgressView().controlSize(.small)
            case .connected(let count):
                Label("\(count) models", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            case .error(let message):
                Text(message).font(.caption).foregroundStyle(.red)
            case .notConfigured:
                EmptyView()
            }
            }
        }
    }

    @ViewBuilder
    private func modelControls(models: [String], recommendedModel: String?) -> some View {
        if !models.isEmpty {
            Divider()
            LazyVStack(alignment: .leading, spacing: 8) {
                Text("Models from \(provider.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(models, id: \.self) { model in
                    modelButton(model, recommendedModel: recommendedModel)
                }
            }
        }
    }

    private func modelButton(_ model: String, recommendedModel: String?) -> some View {
        let recommended = recommendedModel == model
        return Button {
            select(model)
        } label: {
            HStack {
                Text(AISetupPresentation.modelShortName(model, provider: provider))
                if recommended {
                    Text("Recommended").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if ai.isActive(provider), ai.activeModelID == model {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(9)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func connect() {
        guard !provider.usesAPIKey || ai.hasKey(provider) else {
            actionMessage = String(localized: "Save a credential first.")
            return
        }
        guard !provider.allowsEndpointOverride
                || !ai.endpoint(for: provider).trimmingCharacters(in: .whitespaces).isEmpty else {
            actionMessage = String(localized: "Enter an endpoint first.")
            return
        }
        setup.runEphemeral(sessionID: sessionID) {
            await ai.connect(provider)
        }
    }

    private func startCodexLogin() {
        setup.runEphemeral(sessionID: sessionID) {
            guard let challenge = await ai.startCodexLogin(),
                  setup.isPresented,
                  setup.sessionID == sessionID else { return }
            NSWorkspace.shared.open(challenge.authorizationURL)
        }
    }

    private func select(_ model: String) {
        actionMessage = nil
        ai.setModel(model, for: provider)
        guard let intent = ai.activationIntent(for: provider, modelID: model) else {
            actionMessage = String(localized: "Connect this provider and choose a current model.")
            return
        }
        let consumers = setup.origin?.consentConsumers ?? [.ask]
        if provider.isCloud, !ai.hasConsent(provider, for: consumers) {
            pendingActivation = intent
        } else {
            commit(intent, grantCloudConsent: false)
        }
    }

    private func commit(_ intent: ActivationIntent, grantCloudConsent: Bool) {
        let consumers = setup.origin?.consentConsumers ?? [.ask]
        guard ai.commitActivation(
            intent,
            grantCloudConsent: grantCloudConsent,
            consumers: consumers
        ) else {
            actionMessage = String(localized: "The provider changed. Connect it and choose the model again.")
            return
        }
        actionMessage = nil
    }

    private var consentMessage: String {
        let recipient = ai.recipientDisclosure(for: provider) ?? provider.displayName
        let scope = setup.origin == .ask
            ? String(localized: "Ask only")
            : String(localized: "the in-app AI features you explicitly run")
        return String(localized: "Eye will send only the text excerpts needed for \(scope) to \(recipient). Raw images, audio, and file paths are not sent.")
    }

    private var connectionTitle: String {
        switch provider {
        case .codex: return String(localized: "Check Codex")
        case .claudeCode: return String(localized: "Check Claude Code")
        case .ollama, .lmstudio, .custom: return String(localized: "Connect local server")
        default: return String(localized: "Load Models")
        }
    }

    private var providerSummary: String {
        switch provider {
        case .zbsEyeLocal: return String(localized: "Private one-click model managed by Eye on this Mac.")
        case .ollama, .lmstudio, .custom: return String(localized: "Uses a server you run on numeric loopback.")
        case .codex, .claudeCode: return String(localized: "Uses your existing signed-in coding-assistant account.")
        case .customAPI: return String(localized: "OpenAI-compatible HTTPS API with its own Keychain credential.")
        default: return String(localized: "Connect this provider, then choose one of its models.")
        }
    }
}

/// Separate presenter view avoids competing with onboarding and repair sheets.
struct AISetupSheetHost: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: Binding(
                get: { env.aiSetup.isPresented },
                set: { if !$0 { env.aiSetup.dismiss() } }
            )) {
                if let sessionID = env.aiSetup.sessionID {
                    AISetupView(sessionID: sessionID)
                        .environment(env)
                }
            }
    }
}
