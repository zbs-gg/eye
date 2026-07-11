import Foundation
import Observation

/// Actor-shaped manager seam. The UI store owns operation Tasks and observes
/// immutable snapshots; tests can provide a deterministic fake without model
/// bytes, network, or a live application.
protocol BuiltInModelManaging: Actor {
    func snapshot() -> BuiltInModelManagerSnapshot
    func storageSnapshot() throws -> BuiltInModelStorageSnapshot
    func install(
        manifestID: String,
        activationIntent: ActivationIntent?,
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult
    func pause() async throws -> BuiltInModelManagerSnapshot
    func resume(
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult
    func cancel() async throws -> BuiltInModelManagerSnapshot
    func retry(
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult
    func retryRuntimeLoad(
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerSnapshot
    func remove(
        deactivationIntent: DeactivationIntent?,
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult
    func reinstall(
        manifestID: String,
        activationIntent: ActivationIntent?,
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult
}

extension BuiltInModelManager: BuiltInModelManaging {}

enum BuiltInModelHardwareSupport: Sendable, Equatable {
    case checking
    case supported
    case unsupported(reason: String)
    case unavailable(reason: String)

    var reason: String? {
        switch self {
        case .checking:
            return "Checking whether this Mac supports the built-in model…"
        case .supported:
            return nil
        case .unsupported(let reason), .unavailable(let reason):
            return reason
        }
    }
}

/// UI-facing seam for the built-in model lifecycle. Views receive immutable
/// value snapshots and intents; they never reach into the manager actor or its
/// journal/filesystem directly. Long operations are store-owned and polled, so
/// progress remains visible while pause/cancel stay independently actionable.
@MainActor
@Observable
final class BuiltInModelStore {
    typealias CapacityReader = @Sendable (URL) throws -> Int64

    private(set) var snapshot: BuiltInModelManagerSnapshot?
    private(set) var storageSnapshot: BuiltInModelStorageSnapshot?
    private(set) var availableCapacityBytes: Int64?
    private(set) var isBusy = false
    private(set) var operationError: String?
    private(set) var hardwareSupport: BuiltInModelHardwareSupport = .checking
    var supportReason: String? { hardwareSupport.reason }

    @ObservationIgnored private var manager: (any BuiltInModelManaging)?
    @ObservationIgnored private var providers: (any BuiltInModelProviderControlling)?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var operationID: UUID?
    @ObservationIgnored private var capacityRefreshGeneration: UInt64 = 0
    @ObservationIgnored private let pollingInterval: Duration
    @ObservationIgnored private let capacityReader: CapacityReader

    init(
        pollingInterval: Duration = .milliseconds(150),
        capacityReader: @escaping CapacityReader = {
            try BuiltInModelRuntimeSupport.availableCapacity(at: $0)
        }
    ) {
        self.pollingInterval = max(.milliseconds(10), pollingInterval)
        self.capacityReader = capacityReader
    }

    func attach(
        manager: any BuiltInModelManaging,
        providers: any BuiltInModelProviderControlling
    ) async {
        self.manager = manager
        self.providers = providers
        accept(await manager.snapshot())
        storageSnapshot = try? await manager.storageSnapshot()
        await refreshAvailableCapacity()
    }

    func refresh() async {
        guard let manager else { return }
        accept(await manager.snapshot())
        storageSnapshot = try? await manager.storageSnapshot()
        await refreshAvailableCapacity()
    }

    func setHardwareSupport(_ support: BuiltInModelHardwareSupport) {
        hardwareSupport = support
        if case .supported = support {
            operationError = nil
        }
    }

    /// Cancels store-owned UI work and waits for it to leave the manager
    /// before the process-level model/runtime shutdown barrier runs.
    func shutdown() async {
        let operation = operationTask
        operationTask = nil
        operationID = nil
        pollingTask?.cancel()
        pollingTask = nil
        manager = nil
        providers = nil
        operation?.cancel()
        await operation?.value
        isBusy = false
    }

    func install() {
        guard requireSupportedHardware() else { return }
        guard let providers else { return }
        let modelID = BuiltInModelManifest.regular.id
        let intent = providers.builtInProvisioningIntent(modelID: modelID)
        let revision = providers.currentSelectionRevision
        startOperation { manager in
            try await manager.install(
                manifestID: modelID,
                activationIntent: intent,
                currentSelectionRevision: revision
            ).snapshot
        }
    }

    /// Control intents deliberately bypass the long-operation busy guard.
    /// Manager barriers make them safe while an install Task is suspended in
    /// streaming I/O.
    func pause() async {
        await performControl { try await $0.pause() }
    }

    func resume() {
        guard let providers else { return }
        let revision = providers.currentSelectionRevision
        startOperation { manager in
            try await manager.resume(currentSelectionRevision: revision).snapshot
        }
    }

    func cancel() async {
        await performControl { try await $0.cancel() }
    }

    func retry() {
        // A persisted removal failure has no provisioning candidate. The same
        // visible Retry action must re-enter the removal transaction instead
        // of calling candidate-only manager.retry(), which is a truthful no-op.
        if case .failed(let failure) = snapshot?.state.provisioningJob,
           failure.stage == .removal {
            remove()
            return
        }
        guard let providers else { return }
        let revision = providers.currentSelectionRevision
        startOperation { manager in
            try await manager.retry(currentSelectionRevision: revision).snapshot
        }
    }

    func retryRuntimeLoad() {
        guard let providers else { return }
        let revision = providers.currentSelectionRevision
        startOperation {
            try await $0.retryRuntimeLoad(currentSelectionRevision: revision)
        }
    }

    func remove() {
        guard let providers else { return }
        let intent = providers.deactivationIntent(for: .zbsEyeLocal)
        let revision = providers.currentSelectionRevision
        startOperation { manager in
            try await manager.remove(
                deactivationIntent: intent,
                currentSelectionRevision: revision
            ).snapshot
        }
    }

    func reinstall() {
        guard requireSupportedHardware() else { return }
        guard let providers else { return }
        let modelID = BuiltInModelManifest.regular.id
        // Reinstall repairs the local artifact; it is not a global provider
        // switch. Preserve activation only when ZBS Eye Local already owns the
        // active pair. A cloud/local-server choice must survive the repair.
        let intent = providers.deactivationIntent(for: .zbsEyeLocal) == nil
            ? nil
            : providers.builtInProvisioningIntent(modelID: modelID)
        let revision = providers.currentSelectionRevision
        startOperation { manager in
            try await manager.reinstall(
                manifestID: modelID,
                activationIntent: intent,
                currentSelectionRevision: revision
            ).snapshot
        }
    }

    private func startOperation(
        _ operation: @escaping @Sendable (
            any BuiltInModelManaging
        ) async throws -> BuiltInModelManagerSnapshot
    ) {
        guard operationTask == nil, let manager else { return }
        let id = UUID()
        operationID = id
        isBusy = true
        operationError = nil
        startPolling(manager: manager, operationID: id)

        operationTask = Task { @MainActor [weak self] in
            defer { self?.finishOperation(id) }
            do {
                let result = try await operation(manager)
                guard !Task.isCancelled else { return }
                self?.accept(result)
            } catch is CancellationError {
                // A user cancel is represented by the manager snapshot, not a
                // stale generic error banner.
                if let self { self.accept(await manager.snapshot()) }
            } catch {
                guard let self else { return }
                self.operationError = BuiltInModelFailureMessage.userFacing(
                    error,
                    context: .operation
                )
                self.accept(await manager.snapshot())
            }
            if let storage = try? await manager.storageSnapshot() {
                self?.storageSnapshot = storage
            }
            await self?.refreshAvailableCapacity()
        }
    }

    private func startPolling(
        manager: any BuiltInModelManaging,
        operationID: UUID
    ) {
        pollingTask?.cancel()
        let interval = pollingInterval
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let latest = await manager.snapshot()
                guard let self, self.operationID == operationID else { return }
                self.accept(latest)
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    private func performControl(
        _ operation: @escaping @Sendable (
            any BuiltInModelManaging
        ) async throws -> BuiltInModelManagerSnapshot
    ) async {
        guard let manager else { return }
        operationError = nil
        do {
            accept(try await operation(manager))
        } catch {
            operationError = BuiltInModelFailureMessage.userFacing(
                error,
                context: .operation
            )
            accept(await manager.snapshot())
        }
        storageSnapshot = try? await manager.storageSnapshot()
        await refreshAvailableCapacity()
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        pollingTask?.cancel()
        pollingTask = nil
        operationTask = nil
        operationID = nil
        isBusy = false
    }

    private func accept(_ snapshot: BuiltInModelManagerSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
        let modelID = snapshot.projection.isUsable
            ? snapshot.state.inventory.lastKnownGood?.artifact.modelID
            : nil
        _ = providers?.publishBuiltInRuntimeAvailability(modelID: modelID)
    }

    private func refreshAvailableCapacity() async {
        capacityRefreshGeneration &+= 1
        let generation = capacityRefreshGeneration
        guard let root = snapshot?.pinnedDataRoot else {
            setAvailableCapacity(nil)
            return
        }
        let reader = capacityReader
        let available = await Task.detached(priority: .utility) {
            try? reader(root)
        }.value
        guard capacityRefreshGeneration == generation,
              snapshot?.pinnedDataRoot == root else { return }
        setAvailableCapacity(available)
    }

    private func setAvailableCapacity(_ available: Int64?) {
        guard availableCapacityBytes != available else { return }
        availableCapacityBytes = available
    }

    private func requireSupportedHardware() -> Bool {
        guard case .supported = hardwareSupport else {
            operationError = supportReason
                ?? "The built-in model is unavailable on this Mac."
            return false
        }
        return true
    }
}
