import Foundation

/// Mutable process-wide adapter table owned by AppEnvironment. Registration is
/// explicit and exact: an unavailable provider is never replaced with another
/// provider or model behind the user's back.
actor LLMAdapterRegistry: LLMAdapterRegistering {
    private var registrations: [String: LLMAdapterRegistration] = [:]

    func registration(for providerID: String) async -> LLMAdapterRegistration? {
        registrations[providerID]
    }

    func register(_ registration: LLMAdapterRegistration) {
        registrations[registration.providerID] = registration
    }

    func unregister(providerID: String) {
        registrations.removeValue(forKey: providerID)
    }

    func removeAll() {
        registrations.removeAll()
    }
}

/// The router asks for an immutable, consumer-scoped authorization snapshot.
/// It never reads mutable observable state directly. Because AIProviderStore is
/// MainActor-isolated, this bridge also creates the concurrency boundary that
/// keeps provider/UI mutation out of the generation actor.
extension AIProviderStore: LLMSelectionSnapshotProviding {
    func currentSnapshot(for consumer: AIConsumer) async -> ProviderSelectionSnapshot? {
        guard activeConfig(for: consumer) != nil else { return nil }
        return selectionSnapshot
    }
}

extension AIProviderStore: AIConsumerReadinessProviding {
    func currentExecutionContext(for consumer: AIConsumer) -> AIConsumerExecutionContext? {
        guard activeConfig(for: consumer) != nil,
              let selection = selectionSnapshot,
              let provider = AIProvider(rawValue: selection.providerID) else {
            return nil
        }

        let ceiling: Int
        if provider == .zbsEyeLocal,
           let manifest = BuiltInModelManifest.all.first(where: {
               $0.id == selection.modelID
           }) {
            ceiling = manifest.generation.contextTokenCeiling
        } else {
            // External/local-server APIs do not expose a trustworthy tokenizer
            // ceiling in their catalog. Four thousand is the fail-closed
            // compatibility floor; provider-specific metadata can raise it.
            ceiling = 4_096
        }
        return AIConsumerExecutionContext(
            selection: selection,
            contextTokenCeiling: ceiling,
            executedLocally: !provider.isCloud,
            recipientDisclosure: recipientDisclosure(for: provider)
        )
    }
}

extension AIProviderStore: AskReadinessProviding {
    func currentAskExecutionContext() -> AskExecutionContext? {
        guard let context = currentExecutionContext(for: .ask) else { return nil }
        return AskExecutionContext(
            selection: context.selection,
            contextTokenCeiling: context.contextTokenCeiling,
            executedLocally: context.executedLocally,
            recipientDisclosure: context.recipientDisclosure
        )
    }
}

/// Production registry for the currently completed direct-HTTP boundary. It
/// resolves mutable localhost endpoints at lookup time, so changing an Ollama,
/// LM Studio, or custom endpoint cannot leave Ask dispatching to a stale URL.
/// Built-in, Codex, and Claude registrations are added by their own runtime
/// owners once those process boundaries are live.
@MainActor
final class ApplicationLLMAdapterRegistry: LLMAdapterRegistering {
    private let providers: AIProviderStore
    private let overlay: LLMAdapterRegistry
    private let credentials = KeychainProviderHTTPCredentials()

    init(providers: AIProviderStore, overlay: LLMAdapterRegistry) {
        self.providers = providers
        self.overlay = overlay
    }

    func registration(for providerID: String) async -> LLMAdapterRegistration? {
        // Process owners register built-in/subprocess adapters dynamically.
        // Overlay wins; HTTP remains a live fallback so localhost endpoint
        // edits cannot leave a stale adapter behind.
        if let registration = await overlay.registration(for: providerID) {
            return registration
        }
        guard let provider = AIProvider(rawValue: providerID) else { return nil }
        switch provider {
        case .openrouter, .anthropic, .moonshot, .zai, .xiaomi, .openai,
                .ollama, .lmstudio, .custom, .customAPI:
            let rawEndpoint = providers.endpoint(for: provider)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedEndpoint = provider.isCloud || rawEndpoint.contains("://")
                ? rawEndpoint
                : "http://\(rawEndpoint)"
            guard let baseURL = URL(string: normalizedEndpoint) else {
                return nil
            }
            let adapter = ProviderHTTPAdapter(
                provider: provider,
                baseURL: baseURL,
                credentials: credentials,
                authorization: providers
            )
            return LLMAdapterRegistration(
                providerID: provider.rawValue,
                executedLocally: !provider.isCloud,
                adapter: adapter
            )
        case .zbsEyeLocal, .codex, .claudeCode:
            return nil
        }
    }
}

extension AIProviderStore: ProviderHTTPAuthorizationProviding {
    func currentAuthorization() async -> ProviderHTTPAuthorizationState {
        guard let selection = selectionSnapshot else {
            return ProviderHTTPAuthorizationState(selection: nil, consentGrant: nil)
        }
        return ProviderHTTPAuthorizationState(
            selection: selection,
            consentGrant: settings.consentGrant(forProviderID: selection.providerID)
        )
    }
}

/// Reads only the provider-specific data-protection Keychain item, off the
/// cooperative executor. The adapter performs the authorization/host checks
/// again after this async boundary and before attaching the returned secret.
struct KeychainProviderHTTPCredentials: ProviderHTTPCredentialProviding {
    func credential(for provider: AIProvider) async throws -> String? {
        guard let account = provider.keychainAccount else { return nil }
        return await Task.detached(priority: .userInitiated) {
            KeychainStore.get(account)
        }.value
    }
}
