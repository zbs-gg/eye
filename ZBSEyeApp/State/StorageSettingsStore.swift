import Foundation
import Observation
import GRDB
import CoreFoundation

/// Breakdown of used space (Sendable — returned from a Task.detached into @MainActor). Attribution
/// import/live by monitorId='sp' (live capture writes monitorId=String(displayID): '0'/'1'…).
struct StorageBreakdown: Sendable, Equatable {
    var framesTotal = 0
    var framesImport = 0
    var framesLive = 0
    var audioTotal = 0
    var oldestTs: Int64?
    var newestTs: Int64?
    var liveFrameBytes: Int64 = 0       // import has bytes=NULL → this is the size of live frames in the DB only
    var topApps: [AppUsage] = []

    struct AppUsage: Sendable, Equatable, Identifiable {
        let name: String
        let frames: Int
        var id: String { name }
    }
}

/// Storage settings: one Keep Media policy plus how much is actually used.
/// The legacy day/size properties remain only until the compact Settings view
/// lands; automatic deletion is governed exclusively by Keep Media admission.
@MainActor
@Observable
final class StorageSettingsStore {
    /// 0 = keep forever. Default 0 ("memory forever" — we do NOT delete by default).
    var retentionDays: Int {
        didSet { if retentionDays != oldValue { defaults.set(retentionDays, forKey: Self.daysKey) } }
    }
    /// Limit in GB; 0 = no limit. Default 0.
    var maxGB: Int {
        didSet { if maxGB != oldValue { defaults.set(maxGB, forKey: Self.gbKey) } }
    }

    private(set) var keepMediaPolicy: KeepMediaPolicy
    /// A finite policy is inert until DB metadata and the captured-media tree
    /// reconcile. Persisted policy alone never authorizes automatic deletion.
    private(set) var automaticDeletionAdmitted = false
    private(set) var automaticRetentionRecord: AutomaticRetentionRecord

    private(set) var mediaBytes: Int64 = 0
    private(set) var databaseBytes: Int64 = 0
    private(set) var freeBytes: Int64 = 0
    private(set) var breakdown: StorageBreakdown?
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

    static let dayOptions = [0, 7, 14, 30, 90]   // 0 = "Forever" first: the default and the essence of the product
    static let gbOptions = [0, 10, 20, 50, 100]   // 0 = "No limit" first

    /// Time-based automatic retention is retired by the Keep Media contract.
    var effectiveDays: Int? { nil }
    var effectiveMaxBytes: Int64? {
        automaticDeletionAdmitted ? keepMediaPolicy.maxCapturedMediaBytes : nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        retentionDays = (defaults.object(forKey: Self.daysKey) == nil) ? 0
                                                                       : defaults.integer(forKey: Self.daysKey)
        maxGB = (defaults.object(forKey: Self.gbKey) == nil) ? 0 : defaults.integer(forKey: Self.gbKey)
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

    /// The only path that retires legacy keys. A finite choice may be saved
    /// while reconciliation is uncertain, but remains deletion-inert.
    func selectKeepMediaPolicy(
        _ policy: KeepMediaPolicy,
        inventory: KeepMediaInventoryEvidence
    ) {
        if policy == .forever {
            _ = beginForeverRevocation()
            finishForeverRevocation()
            return
        }
        defaults.set(policy.rawValue, forKey: Self.keepMediaPolicyKey)
        guard defaults.string(forKey: Self.keepMediaPolicyKey) == policy.rawValue else { return }
        defaults.set(true, forKey: Self.explicitPolicyKey)
        defaults.removeObject(forKey: Self.daysKey)
        defaults.removeObject(forKey: Self.gbKey)
        let admitted = policy != .forever && inventory.isAuthoritative
        let record = AutomaticRetentionRecord(
            revision: automaticRetentionRecord.revision &+ 1,
            policy: policy,
            phase: admitted ? .finiteAdmitted : (policy == .forever ? .closed : .pendingFinite),
            source: .explicitSelection
        )
        guard persistAdmissionRecord(record) else {
            publish(policy: .forever, admitted: false)
            return
        }
        publish(policy: policy, admitted: admitted)
    }

    /// First half of the crash-safe Forever transition. The durable pending
    /// intent closes deletion before an async retention drain begins; the
    /// visible policy remains unchanged until the caller acknowledges the drain.
    @discardableResult
    func beginForeverRevocation() -> AutomaticRetentionRecord {
        let pending = AutomaticRetentionRecord(
            revision: automaticRetentionRecord.revision &+ 1,
            policy: .forever,
            phase: .pendingForever,
            source: .explicitSelection
        )
        automaticDeletionAdmitted = false
        return persistAdmissionRecord(pending) ? pending : automaticRetentionRecord
    }

    /// Completes a pending Forever transition after automatic work has drained.
    func finishForeverRevocation() {
        guard automaticRetentionRecord.phase == .pendingForever else { return }
        let closed = AutomaticRetentionRecord(
            revision: automaticRetentionRecord.revision,
            policy: .forever,
            phase: .closed,
            source: automaticRetentionRecord.source
        )
        guard persistAdmissionRecord(closed) else {
            publish(policy: .forever, admitted: false)
            return
        }
        defaults.set(KeepMediaPolicy.forever.rawValue, forKey: Self.keepMediaPolicyKey)
        defaults.set(true, forKey: Self.explicitPolicyKey)
        defaults.removeObject(forKey: Self.daysKey)
        defaults.removeObject(forKey: Self.gbKey)
        publish(policy: .forever, admitted: false)
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
        automaticRetentionRecord = .closedForever
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

    /// Recompute used space (media — folder walk, DB — size of sqlite+wal, free on the volume) +
    /// the breakdown from the DB (import/live frames, audio, date range, top apps). Called when
    /// Settings opens; all on a utility-priority background with a single read transaction.
    func refresh(storage: StorageManager?, db: ZBSEyeDatabase?) async {
        guard let storage else { return }
        let computed = await Task.detached(priority: .utility) { () async -> (Int64, Int64, Int64, StorageBreakdown?) in
            let media = storage.totalBytes()
            let free = storage.freeBytes()
            var dbBytes: Int64 = 0
            if let url = try? ZBSEyeDatabase.defaultURL() {
                for suffix in ["", "-wal", "-shm"] {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
                    dbBytes += (attrs?[.size] as? Int64) ?? 0
                }
            }
            let bd: StorageBreakdown? = await Self.computeBreakdown(db: db)
            return (media, dbBytes, free, bd)
        }.value
        mediaBytes = computed.0
        databaseBytes = computed.1
        freeBytes = computed.2
        breakdown = computed.3
    }

    /// One aggregate read transaction: counters/attribution/range + top apps. nil when there's no DB.
    /// nonisolated: called from the Task.detached in refresh, must not hop onto MainActor.
    nonisolated private static func computeBreakdown(db: ZBSEyeDatabase?) async -> StorageBreakdown? {
        guard let db else { return nil }
        return try? await db.pool.read { dbc -> StorageBreakdown in
            var bd = StorageBreakdown()
            if let row = try Row.fetchOne(dbc, sql: """
                SELECT
                  (SELECT COUNT(*) FROM screen_captures) AS framesTotal,
                  (SELECT COUNT(*) FROM screen_captures WHERE monitorId = 'sp') AS framesImport,
                  (SELECT COUNT(*) FROM screen_captures WHERE monitorId <> 'sp') AS framesLive,
                  (SELECT COUNT(*) FROM audio_captures) AS audioTotal,
                  (SELECT MIN(ts) FROM screen_captures) AS oldestTs,
                  (SELECT MAX(ts) FROM screen_captures) AS newestTs,
                  (SELECT COALESCE(SUM(bytes), 0) FROM screen_captures WHERE bytes IS NOT NULL) AS liveFrameBytes
                """) {
                bd.framesTotal = row["framesTotal"] ?? 0
                bd.framesImport = row["framesImport"] ?? 0
                bd.framesLive = row["framesLive"] ?? 0
                bd.audioTotal = row["audioTotal"] ?? 0
                bd.oldestTs = row["oldestTs"]
                bd.newestTs = row["newestTs"]
                bd.liveFrameBytes = row["liveFrameBytes"] ?? 0
            }
            bd.topApps = try Row.fetchAll(dbc, sql: """
                SELECT COALESCE(a.name, '(?)') AS name, COUNT(*) AS frames
                FROM screen_captures c LEFT JOIN apps a ON a.id = c.appId
                GROUP BY c.appId ORDER BY frames DESC LIMIT 6
                """).map { StorageBreakdown.AppUsage(name: $0["name"], frames: $0["frames"]) }
            return bd
        }
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
