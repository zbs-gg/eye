import Foundation

/// Product hierarchy for the AI Models surface. Providers are the parent
/// objects; a model option can only exist inside one provider card.
enum AIModelsPresentation {
    static let primaryProviders: [AIProvider] = [
        .codex,
        .openrouter,
        .anthropic,
    ]

    static let localServerProviders: [AIProvider] = [
        .ollama,
        .lmstudio,
        .custom,
    ]

    static let moreProviders: [AIProvider] = [
        .moonshot,
        .zai,
        .xiaomi,
        .openai,
        .claudeCode,
    ]

    /// Opening AI Models may discover only resources that stay on this Mac.
    /// Process providers can initialize authenticated clients and reach their
    /// cloud backends, so their discovery remains behind explicit Check buttons.
    @MainActor
    static func prepareScreen(
        providers: AIProviderStore,
        refreshBuiltIn: @MainActor () async -> Void
    ) async {
        providers.resetOpenRouterOAuthPhaseIfStale()
        async let localProbe: Void = providers.autoProbeLocal()
        async let builtInRefresh: Void = refreshBuiltIn()
        _ = await (localProbe, builtInRefresh)
    }
}

struct AIModelsModelOptionPresentation: Identifiable, Equatable {
    let provider: AIProvider
    let id: String
    let shortName: String
    let isRecommended: Bool
}

struct AIModelsProviderCardPresentation: Identifiable, Equatable {
    let provider: AIProvider
    let models: [AIModelsModelOptionPresentation]

    var id: AIProvider { provider }
    var title: String { provider.displayName }

    init(provider: AIProvider, modelIDs: [String]) {
        self.provider = provider
        let recommendation = provider.recommendedModel(in: modelIDs)
        self.models = modelIDs.map { modelID in
            AIModelsModelOptionPresentation(
                provider: provider,
                id: modelID,
                shortName: Self.shortName(modelID, provider: provider),
                isRecommended: modelID == recommendation
            )
        }
    }

    static func shortName(_ modelID: String, provider: AIProvider) -> String {
        if provider == .zbsEyeLocal,
           modelID == BuiltInModelManifest.regular.id {
            return BuiltInModelManifest.regular.displayName
        }
        if provider == .claudeCode,
           modelID == AIProvider.claudeCodeDefaultModel {
            return String(localized: "Provider default")
        }
        let component = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return component.isEmpty ? modelID : component
    }
}
