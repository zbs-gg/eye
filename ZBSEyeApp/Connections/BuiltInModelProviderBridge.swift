import Foundation

/// Durable acknowledgement for the provider-selection side of the model
/// lifecycle outbox. Only terminal outcomes may remove the journaled effect;
/// an unacknowledged preferences write remains replayable after restart.
enum BuiltInModelProviderEffectResult: Sendable, Equatable {
    case applied
    case stale
    case retryablePersistenceFailure
}

/// Narrow provider-selection boundary used by the built-in model lifecycle.
/// Provisioning may begin before a model is available, but activation still
/// crosses the ordinary revision-checked provider commit boundary only after
/// the verified runtime has become authoritative.
@MainActor
protocol BuiltInModelProviderControlling: AnyObject {
    var currentSelectionRevision: SelectionRevision { get }

    func builtInProvisioningIntent(modelID: String) -> ActivationIntent?
    @discardableResult
    func publishBuiltInRuntimeAvailability(modelID: String?) -> Bool
    @discardableResult
    func commitBuiltInActivation(
        _ intent: ActivationIntent
    ) -> BuiltInModelProviderEffectResult
    func commitBuiltInDeactivation(
        _ intent: DeactivationIntent
    ) -> BuiltInModelProviderEffectResult
    func deactivationIntent(for provider: AIProvider) -> DeactivationIntent?
}

/// Orders lifecycle truth and persisted selection correctly. A successful
/// local candidate first publishes an authoritative catalog entry, then tries
/// the stale-safe activation commit. A removed/failed runtime is unpublished
/// even when a late deactivation intent has lost ownership to another model.
@MainActor
final class BuiltInModelProviderBridge {
    private let providers: any BuiltInModelProviderControlling

    init(providers: any BuiltInModelProviderControlling) {
        self.providers = providers
    }

    func handle(
        _ effect: BuiltInModelLifecycleEffect
    ) -> BuiltInModelProviderEffectResult {
        switch effect {
        case .requestActivation(let intent):
            _ = providers.publishBuiltInRuntimeAvailability(modelID: intent.modelID)
            return providers.commitBuiltInActivation(intent)

        case .requestDeactivation(let intent):
            let result = providers.commitBuiltInDeactivation(intent)
            _ = providers.publishBuiltInRuntimeAvailability(modelID: nil)
            return result
        }
    }

    @discardableResult
    func reconcile(_ snapshot: BuiltInModelManagerSnapshot) -> Bool {
        let modelID = snapshot.projection.isUsable
            ? snapshot.state.inventory.lastKnownGood?.artifact.modelID
            : nil
        return providers.publishBuiltInRuntimeAvailability(modelID: modelID)
    }
}
