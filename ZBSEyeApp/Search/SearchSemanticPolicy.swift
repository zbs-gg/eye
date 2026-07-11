import Foundation

enum SearchSemanticPolicy: Sendable {
    /// GUI policy: query e5 participates in the process-wide compute barrier.
    case coordinated(AIComputeCoordinator)
    /// Compatibility for call sites that do not own in-process MLX.
    case uncoordinated
    /// Helper processes cannot share the GUI actor. They must stay FTS-only
    /// instead of loading a second e5 model while GUI MLX may be active.
    case ftsOnly(SemanticQueryFallbackReason)
}

enum SearchSemanticQueryOutcome: Sendable, Equatable {
    case vector([Float])
    case embeddingUnavailable
    case ftsOnly(SemanticQueryFallbackReason)
}

/// Small policy boundary kept independent of GRDB so denial/order behavior is
/// fixture-testable without loading e5 or opening the user's database.
struct SearchSemanticQueryRunner: Sendable {
    typealias Embed = @Sendable (String) async -> [Float]?

    private let policy: SearchSemanticPolicy
    private let embed: Embed

    init(policy: SearchSemanticPolicy, embed: @escaping Embed) {
        self.policy = policy
        self.embed = embed
    }

    func run(query: String) async -> SearchSemanticQueryOutcome {
        switch policy {
        case .ftsOnly(let reason):
            return .ftsOnly(reason)
        case .uncoordinated:
            guard let vector = await embed(query) else {
                return .embeddingUnavailable
            }
            return .vector(vector)
        case .coordinated(let coordinator):
            switch await coordinator.acquireSemanticQuery() {
            case .ftsOnly(let reason):
                return .ftsOnly(reason)
            case .granted(let lease):
                let vector = await embed(query)
                await lease.release()
                guard let vector else { return .embeddingUnavailable }
                return .vector(vector)
            }
        }
    }
}
