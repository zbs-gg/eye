import Foundation

struct KeepMediaPolicyConfirmation: Sendable, Equatable {
    let policy: KeepMediaPolicy
    let currentBytes: Int64
    let bytesToRemove: Int64
}

enum KeepMediaPolicyChangeResult: Sendable, Equatable {
    case applied
    case confirmationRequired(KeepMediaPolicyConfirmation)
    case unavailable(String)
}

@MainActor
final class KeepMediaPolicyCoordinator {
    typealias InventoryResolver = @Sendable (
        ZBSEyeDatabase,
        StorageManager
    ) async -> KeepMediaInventoryEvidence
    typealias StorageRefresher = @MainActor @Sendable (
        StorageSettingsStore,
        StorageManager
    ) async -> Void

    private let resolveInventory: InventoryResolver
    private let refreshStorage: StorageRefresher
    private var changeInProgress = false

    init(
        resolveInventory: @escaping InventoryResolver = { db, storage in
            await CapturedMediaReconciler.reconcile(db: db, storage: storage)
        },
        refreshStorage: @escaping StorageRefresher = { settings, storage in
            await settings.refresh(storage: storage)
        }
    ) {
        self.resolveInventory = resolveInventory
        self.refreshStorage = refreshStorage
    }

    func change(
        _ policy: KeepMediaPolicy,
        confirmedRemovalBytes: Int64? = nil,
        storageSettings: StorageSettingsStore,
        recording: RecordingStore,
        storage: StorageManager?,
        database: ZBSEyeDatabase?,
        admission: AutomaticRetentionAdmission?
    ) async -> KeepMediaPolicyChangeResult {
        guard !changeInProgress else {
            return .unavailable(
                String(localized: "Another Keep Media change is still finishing. Try again in a moment.")
            )
        }
        changeInProgress = true
        defer { changeInProgress = false }
        guard !storageSettings.relocationInProgress,
              let storage, let database, let admission else {
            return .unavailable(String(localized: "Storage is not ready yet."))
        }

        if policy == .forever {
            guard let pending = storageSettings.beginForeverRevocation() else {
                admission.revoke(to: storageSettings.automaticRetentionRecord.revision)
                return .unavailable(
                    String(localized: "Automatic cleanup is stopped for this run, but Eye could not save Forever. Try again before restarting.")
                )
            }
            await Task.detached(priority: .utility) {
                admission.revoke(to: pending.revision)
            }.value
            guard storageSettings.finishForeverRevocation() else {
                admission.revoke(to: storageSettings.automaticRetentionRecord.revision)
                return .unavailable(
                    String(localized: "Automatic cleanup is stopped, but Eye could not finish saving Forever. Try again.")
                )
            }
            return .applied
        }

        _ = await recording.pauseForMaintenanceAndDrain(waitForTranscription: false)
        let inventory = await resolveInventory(database, storage)
        recording.resumeAfterMaintenance()
        guard let currentBytes = inventory.capturedMediaBytes,
              let maximumBytes = policy.maxCapturedMediaBytes else {
            return .unavailable(
                String(localized: "Eye could not verify every media file. Nothing was deleted; try again when recording is idle.")
            )
        }

        let bytesToRemove = max(0, currentBytes - maximumBytes)
        if bytesToRemove > 0,
           confirmedRemovalBytes.map({ $0 < bytesToRemove }) ?? true {
            return .confirmationRequired(KeepMediaPolicyConfirmation(
                policy: policy,
                currentBytes: currentBytes,
                bytesToRemove: bytesToRemove
            ))
        }

        guard let pending = storageSettings.beginFiniteTransition(policy) else {
            admission.revoke(to: storageSettings.automaticRetentionRecord.revision)
            return .unavailable(
                String(localized: "Automatic cleanup is stopped for this run, but Eye could not save the new media limit. Try again before restarting.")
            )
        }
        let staged = await Task.detached(priority: .utility) {
            admission.revokeAndStage(pending)
        }.value
        guard staged else {
            storageSettings.failClosedAutomaticDeletionPreservingPolicy()
            admission.revoke(to: storageSettings.automaticRetentionRecord.revision)
            return .unavailable(
                String(localized: "The media limit was saved, but automatic cleanup stayed off. Restart Eye to verify it safely.")
            )
        }
        guard let record = storageSettings.finishFiniteTransition(pending, inventory: inventory),
              admission.activate(record) else {
            storageSettings.failClosedAutomaticDeletionPreservingPolicy()
            admission.revoke(to: storageSettings.automaticRetentionRecord.revision)
            return .unavailable(
                String(localized: "The media limit was saved, but automatic cleanup stayed off. Restart Eye to verify it safely.")
            )
        }
        await refreshStorage(storageSettings, storage)
        return .applied
    }
}
