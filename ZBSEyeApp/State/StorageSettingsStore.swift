import Foundation
import Observation
import CoreFoundation

/// Storage settings: one Keep Media policy plus how much is actually used.
/// Legacy day/size keys are read only by the one-time migration; automatic
/// deletion is governed exclusively by Keep Media admission.
@MainActor
@Observable
final class StorageSettingsStore {
    private(set) var keepMediaPolicy: KeepMediaPolicy
    /// A finite policy is inert until DB metadata and the captured-media tree
    /// reconcile. Persisted policy alone never authorizes automatic deletion.
    private(set) var automaticDeletionAdmitted = false
    private(set) var automaticRetentionRecord: AutomaticRetentionRecord

    private(set) var mediaBytes: Int64 = 0
    private(set) var databaseBytes: Int64 = 0
    private(set) var freeBytes: Int64 = 0
    var totalBytes: Int64 { mediaBytes + databaseBytes }

    // relocate (T1): storage relocation state
    var relocationInProgress = false
    var relocationProgress: Double = 0
    var relocationStatus = ""
    var relocationError: String?
    var dataRootDisplay: String { StorageLocation.displayPath() }
    var isRelocated: Bool { StorageLocation.isRelocated() }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored static let daysKey = "zbseye.retention.days"
    @ObservationIgnored static let gbKey = "zbseye.retention.maxGB"
    @ObservationIgnored static let onboardingKey = "zbseye.onboarding.done"
    @ObservationIgnored static let keepMediaPolicyKey = "zbseye.keepMedia.policy.v1"
    @ObservationIgnored static let keepMediaReceiptKey = "zbseye.keepMedia.migrationReceipt.v1"
    @ObservationIgnored static let admissionRecordKey = "zbseye.keepMedia.automaticRetention.v1"
    @ObservationIgnored private static let explicitPolicyKey = "zbseye.keepMedia.explicitSelection.v1"
    @ObservationIgnored private let admissionRecordWasPresentAtInitialization: Bool
    @ObservationIgnored private let admissionPersistenceGate: (AutomaticRetentionRecord) -> Bool

    init(
        defaults: UserDefaults = .standard,
        admissionPersistenceGate: @escaping (AutomaticRetentionRecord) -> Bool = { _ in true }
    ) {
        self.defaults = defaults
        self.admissionPersistenceGate = admissionPersistenceGate
        let persistedAdmissionData = defaults.data(forKey: Self.admissionRecordKey)
        admissionRecordWasPresentAtInitialization = persistedAdmissionData != nil
        let decodedAdmission = persistedAdmissionData.flatMap {
            try? JSONDecoder().decode(AutomaticRetentionRecord.self, from: $0)
        }
        let recoveredAdmission: AutomaticRetentionRecord
        if let decodedAdmission, decodedAdmission.isValid {
            recoveredAdmission = decodedAdmission.recoveredForStartup
        } else if persistedAdmissionData != nil {
            recoveredAdmission = .closedForever
        } else {
            recoveredAdmission = .closedForever
        }
        automaticRetentionRecord = recoveredAdmission
        if persistedAdmissionData != nil {
            keepMediaPolicy = recoveredAdmission.policy
            // Persisted finite admission is deliberately demoted to pending at
            // every process start. Current media reconciliation is required
            // before automatic deletion can reopen.
            automaticDeletionAdmitted = false
            _ = persistAdmissionRecord(recoveredAdmission)
            defaults.set(recoveredAdmission.policy.rawValue, forKey: Self.keepMediaPolicyKey)
        } else {
            keepMediaPolicy = defaults.string(forKey: Self.keepMediaPolicyKey)
                .flatMap(KeepMediaPolicy.init(rawValue:)) ?? .forever
        }
    }

    /// Resolve and persist the one-time legacy migration. The receipt is
    /// durably readable before the policy key is published, so an interruption
    /// can only retain longer. Legacy keys stay untouched until an explicit
    /// user selection.
    @discardableResult
    func initializeKeepMediaPolicy(
        inventory: KeepMediaInventoryEvidence
    ) -> KeepMediaMigrationResolution {
        if admissionRecordWasPresentAtInitialization {
            return resolveAutomaticRecord(inventory: inventory)
        }
        if let existingReceipt = decodedReceipt() {
            let rawPersistedPolicy = defaults.string(forKey: Self.keepMediaPolicyKey)
            let persistedPolicy = rawPersistedPolicy
                .flatMap(KeepMediaPolicy.init(rawValue:))
            if defaults.object(forKey: Self.keepMediaPolicyKey) != nil,
               persistedPolicy == nil {
                publish(policy: .forever, admitted: false)
                return KeepMediaMigration.resolve(
                    snapshot: legacySnapshot(),
                    inventory: .uncertain(.policyPreferenceUnreadable)
                )
            }
            let policy = persistedPolicy ?? existingReceipt.resolution.policy
            if persistedPolicy == nil {
                defaults.set(policy.rawValue, forKey: Self.keepMediaPolicyKey)
            }
            let promotedPolicy = KeepMediaMigration.promotedPolicy(policy, for: inventory)
            if promotedPolicy != policy {
                defaults.set(promotedPolicy.rawValue, forKey: Self.keepMediaPolicyKey)
            }
            return publishRecoveredPolicy(
                promotedPolicy,
                inventory: inventory,
                originalAdmission: existingReceipt.resolution.automaticDeletionAdmitted
            )
        }

        if defaults.object(forKey: Self.keepMediaReceiptKey) != nil {
            let resolution = KeepMediaMigration.resolve(
                snapshot: legacySnapshot(),
                inventory: .uncertain(.migrationReceiptUnreadable)
            )
            publish(policy: .forever, admitted: false)
            return resolution
        }

        let snapshot = legacySnapshot()
        let resolution = KeepMediaMigration.resolve(snapshot: snapshot, inventory: inventory)
        let receipt = KeepMediaMigrationReceipt(
            legacySnapshot: snapshot,
            inventory: inventory,
            resolution: resolution
        )

        guard let receiptData = try? JSONEncoder().encode(receipt) else {
            publish(policy: .forever, admitted: false)
            return KeepMediaMigration.resolve(
                snapshot: snapshot,
                inventory: .uncertain(.migrationReceiptUnreadable)
            )
        }
        defaults.set(receiptData, forKey: Self.keepMediaReceiptKey)
        guard decodedReceipt() == receipt else {
            publish(policy: .forever, admitted: false)
            return KeepMediaMigration.resolve(
                snapshot: snapshot,
                inventory: .uncertain(.migrationReceiptUnreadable)
            )
        }

        defaults.set(resolution.policy.rawValue, forKey: Self.keepMediaPolicyKey)
        guard defaults.string(forKey: Self.keepMediaPolicyKey) == resolution.policy.rawValue else {
            publish(policy: .forever, admitted: false)
            return KeepMediaMigration.resolve(
                snapshot: snapshot,
                inventory: .uncertain(.migrationReceiptUnreadable)
            )
        }
        guard persistMigrationAdmission(resolution) else {
            publish(policy: .forever, admitted: false)
            return KeepMediaMigration.resolve(
                snapshot: snapshot,
                inventory: .uncertain(.migrationReceiptUnreadable)
            )
        }
        publish(policy: resolution.policy, admitted: resolution.automaticDeletionAdmitted)
        return resolution
    }

    /// First half of a finite-policy transition. The new policy is persisted
    /// as deletion-inert before the caller revokes and drains the old permit.
    /// A crash can therefore retain longer, but can never resurrect the old
    /// smaller cap after the user selected a larger one successfully.
    @discardableResult
    func beginFiniteTransition(_ policy: KeepMediaPolicy) -> AutomaticRetentionRecord? {
        guard policy.maxCapturedMediaBytes != nil else { return nil }
        let pending = AutomaticRetentionRecord(
            revision: automaticRetentionRecord.revision &+ 1,
            policy: policy,
            phase: .pendingFinite,
            source: .explicitSelection
        )
        automaticDeletionAdmitted = false
        guard persistAdmissionRecord(pending) else { return nil }
        return pending
    }

    /// Completes a finite transition only after the old permit is revoked and
    /// the current media inventory is authoritative.
    @discardableResult
    func finishFiniteTransition(
        _ pending: AutomaticRetentionRecord,
        inventory: KeepMediaInventoryEvidence
    ) -> AutomaticRetentionRecord? {
        guard pending == automaticRetentionRecord,
              pending.phase == .pendingFinite,
              inventory.isAuthoritative else { return nil }
        let admitted = AutomaticRetentionRecord(
            revision: pending.revision,
            policy: pending.policy,
            phase: .finiteAdmitted,
            source: pending.source
        )
        guard persistAdmissionRecord(admitted) else { return nil }
        defaults.set(admitted.policy.rawValue, forKey: Self.keepMediaPolicyKey)
        defaults.set(true, forKey: Self.explicitPolicyKey)
        defaults.removeObject(forKey: Self.daysKey)
        defaults.removeObject(forKey: Self.gbKey)
        publish(policy: admitted.policy, admitted: true)
        return admitted
    }

    /// First half of the crash-safe Forever transition. The durable pending
    /// intent closes deletion before an async retention drain begins; the
    /// visible policy remains unchanged until the caller acknowledges the drain.
    @discardableResult
    func beginForeverRevocation() -> AutomaticRetentionRecord? {
        let pending = AutomaticRetentionRecord(
            revision: automaticRetentionRecord.revision &+ 1,
            policy: .forever,
            phase: .pendingForever,
            source: .explicitSelection
        )
        automaticDeletionAdmitted = false
        guard persistAdmissionRecord(pending) else { return nil }
        return pending
    }

    /// Completes a pending Forever transition after automatic work has drained.
    @discardableResult
    func finishForeverRevocation() -> Bool {
        guard automaticRetentionRecord.phase == .pendingForever else { return false }
        let closed = AutomaticRetentionRecord(
            revision: automaticRetentionRecord.revision,
            policy: .forever,
            phase: .closed,
            source: automaticRetentionRecord.source
        )
        guard persistAdmissionRecord(closed) else {
            publish(policy: .forever, admitted: false)
            return false
        }
        defaults.set(KeepMediaPolicy.forever.rawValue, forKey: Self.keepMediaPolicyKey)
        defaults.set(true, forKey: Self.explicitPolicyKey)
        defaults.removeObject(forKey: Self.daysKey)
        defaults.removeObject(forKey: Self.gbKey)
        publish(policy: .forever, admitted: false)
        return true
    }

    /// If the process-local permit cannot mirror a persisted finite decision,
    /// retain the user's visible cap but return deletion to a startup-
    /// reconcilable pending state. A UI error must never leave a phantom
    /// admitted policy behind.
    func failClosedAutomaticDeletionPreservingPolicy() {
        guard let _ = keepMediaPolicy.maxCapturedMediaBytes else { return }
        let pending = AutomaticRetentionRecord(
            revision: automaticRetentionRecord.revision &+ 1,
            policy: keepMediaPolicy,
            phase: .pendingFinite,
            source: .explicitSelection
        )
        guard persistAdmissionRecord(pending) else { return }
        publish(policy: keepMediaPolicy, admitted: false)
    }

    private func publishRecoveredPolicy(
        _ policy: KeepMediaPolicy,
        inventory: KeepMediaInventoryEvidence,
        originalAdmission: Bool
    ) -> KeepMediaMigrationResolution {
        let admitted = policy != .forever
            && originalAdmission
            && inventory.isAuthoritative
        let record = AutomaticRetentionRecord(
            revision: automaticRetentionRecord.revision &+ 1,
            policy: policy,
            phase: admitted ? .finiteAdmitted : (policy == .forever ? .closed : .pendingFinite),
            source: .migration
        )
        guard persistAdmissionRecord(record) else {
            publish(policy: .forever, admitted: false)
            return KeepMediaMigration.resolve(
                snapshot: legacySnapshot(),
                inventory: .uncertain(.migrationReceiptUnreadable)
            )
        }
        publish(policy: policy, admitted: admitted)
        return KeepMediaMigrationResolution(
            policy: policy,
            automaticDeletionAdmitted: admitted,
            shouldWritePolicy: false,
            shouldRunRetention: false,
            reason: policy == .forever ? .legacyUnlimited : .recognizedFiniteLegacyCap
        )
    }

    private func publish(policy: KeepMediaPolicy, admitted: Bool) {
        keepMediaPolicy = policy
        automaticDeletionAdmitted = admitted
    }

    @discardableResult
    private func persistMigrationAdmission(_ resolution: KeepMediaMigrationResolution) -> Bool {
        persistAdmissionRecord(AutomaticRetentionRecord(
            revision: automaticRetentionRecord.revision &+ 1,
            policy: resolution.policy,
            phase: resolution.automaticDeletionAdmitted
                ? .finiteAdmitted
                : (resolution.policy == .forever ? .closed : .pendingFinite),
            source: .migration
        ))
    }

    @discardableResult
    private func persistAdmissionRecord(_ record: AutomaticRetentionRecord) -> Bool {
        guard admissionPersistenceGate(record) else {
            failClosedInMemory()
            return false
        }
        guard let data = try? JSONEncoder().encode(record) else {
            failClosedInMemory()
            return false
        }
        defaults.set(data, forKey: Self.admissionRecordKey)
        guard let roundTrip = defaults.data(forKey: Self.admissionRecordKey),
              let decoded = try? JSONDecoder().decode(AutomaticRetentionRecord.self, from: roundTrip),
              decoded == record else {
            failClosedInMemory()
            return false
        }
        automaticRetentionRecord = record
        return true
    }

    private func failClosedInMemory() {
        automaticRetentionRecord = AutomaticRetentionRecord(
            revision: automaticRetentionRecord.revision,
            policy: .forever,
            phase: .closed,
            source: automaticRetentionRecord.source
        )
        keepMediaPolicy = .forever
        automaticDeletionAdmitted = false
    }

    private func resolveAutomaticRecord(
        inventory: KeepMediaInventoryEvidence
    ) -> KeepMediaMigrationResolution {
        let current = automaticRetentionRecord
        guard current.phase == .pendingFinite else {
            publish(policy: current.policy, admitted: false)
            return resolutionFromAutomaticRecord(admitted: false)
        }

        guard inventory.isAuthoritative else {
            let closed = AutomaticRetentionRecord(
                revision: current.revision &+ 1,
                policy: .forever,
                phase: .closed,
                source: current.source
            )
            _ = persistAdmissionRecord(closed)
            defaults.set(KeepMediaPolicy.forever.rawValue, forKey: Self.keepMediaPolicyKey)
            publish(policy: .forever, admitted: false)
            return resolutionFromAutomaticRecord(admitted: false)
        }

        let policy = KeepMediaMigration.promotedPolicy(current.policy, for: inventory)
        let admitted = policy != .forever
        let resolved = AutomaticRetentionRecord(
            revision: current.revision,
            policy: policy,
            phase: admitted ? .finiteAdmitted : .closed,
            source: current.source
        )
        guard persistAdmissionRecord(resolved) else {
            publish(policy: .forever, admitted: false)
            return resolutionFromAutomaticRecord(admitted: false)
        }
        defaults.set(policy.rawValue, forKey: Self.keepMediaPolicyKey)
        publish(policy: policy, admitted: admitted)
        return resolutionFromAutomaticRecord(admitted: admitted)
    }

    private func resolutionFromAutomaticRecord(admitted: Bool) -> KeepMediaMigrationResolution {
        return KeepMediaMigrationResolution(
            policy: automaticRetentionRecord.policy,
            automaticDeletionAdmitted: admitted,
            shouldWritePolicy: false,
            shouldRunRetention: false,
            reason: automaticRetentionRecord.policy == .forever
                ? .legacyUnlimited
                : .recognizedFiniteLegacyCap
        )
    }

    private func decodedReceipt() -> KeepMediaMigrationReceipt? {
        guard let data = defaults.data(forKey: Self.keepMediaReceiptKey),
              let receipt = try? JSONDecoder().decode(KeepMediaMigrationReceipt.self, from: data),
              receipt.version == KeepMediaMigrationReceipt.currentVersion else { return nil }
        return receipt
    }

    private func legacySnapshot() -> LegacyKeepMediaSnapshot {
        LegacyKeepMediaSnapshot(
            days: Self.legacyInteger(defaults.object(forKey: Self.daysKey)),
            maxGB: Self.legacyInteger(defaults.object(forKey: Self.gbKey)),
            onboardingCompleted: Self.legacyBool(defaults.object(forKey: Self.onboardingKey))
        )
    }

    nonisolated private static func legacyInteger(_ object: Any?) -> LegacyKeepMediaValue {
        guard let object else { return .missing }
        guard let number = object as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return .invalid(String(describing: object))
        }
        let value = number.doubleValue
        guard value.isFinite,
              value.rounded(.towardZero) == value,
              value >= Double(Int.min), value <= Double(Int.max) else {
            return .invalid(String(describing: object))
        }
        return .integer(Int(value))
    }

    nonisolated private static func legacyBool(_ object: Any?) -> Bool? {
        guard let object else { return nil }
        guard let number = object as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            // An invalid but present marker must never make a profile appear fresh.
            return false
        }
        return number.boolValue
    }

    /// Recompute used space (media folder, sqlite+WAL, and free space) away from MainActor.
    func refresh(storage: StorageManager?) async {
        guard let storage else { return }
        let computed = await Task.detached(priority: .utility) { () -> (Int64, Int64, Int64) in
            let media = storage.totalBytes()
            let free = storage.freeBytes()
            var dbBytes: Int64 = 0
            if let url = try? ZBSEyeDatabase.defaultURL() {
                for suffix in ["", "-wal", "-shm"] {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
                    dbBytes += (attrs?[.size] as? Int64) ?? 0
                }
            }
            return (media, dbBytes, free)
        }.value
        mediaBytes = computed.0
        databaseBytes = computed.1
        freeBytes = computed.2
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
