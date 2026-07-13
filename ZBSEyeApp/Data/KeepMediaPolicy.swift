import Foundation

/// The complete user-facing captured-media retention policy. Indexes and model
/// assets are reported separately and never consume this budget.
enum KeepMediaPolicy: String, Codable, CaseIterable, Sendable, Equatable {
    case fiveGB = "5-gb"
    case tenGB = "10-gb"
    case twentyGB = "20-gb"
    case fiftyGB = "50-gb"
    case forever

    static let bytesPerGB: Int64 = 1_024 * 1_024 * 1_024

    var gigabytes: Int? {
        switch self {
        case .fiveGB: 5
        case .tenGB: 10
        case .twentyGB: 20
        case .fiftyGB: 50
        case .forever: nil
        }
    }

    var maxCapturedMediaBytes: Int64? {
        gigabytes.map { Int64($0) * Self.bytesPerGB }
    }

    var settingsLabel: String {
        gigabytes.map { "\($0) GB" } ?? String(localized: "Forever")
    }

    static func normalizedLegacyCap(_ gigabytes: Int) -> KeepMediaPolicy {
        switch gigabytes {
        case ...0: .forever
        case ...5: .fiveGB
        case ...10: .tenGB
        case ...20: .twentyGB
        case ...50: .fiftyGB
        default: .forever
        }
    }

}

/// A lossless-enough representation of the legacy defaults. Invalid values are
/// retained as descriptions in the migration receipt instead of being coerced.
enum LegacyKeepMediaValue: Codable, Sendable, Equatable {
    case missing
    case integer(Int)
    case invalid(String)
}

struct LegacyKeepMediaSnapshot: Codable, Sendable, Equatable {
    let days: LegacyKeepMediaValue
    let maxGB: LegacyKeepMediaValue
    /// nil means that no onboarding marker existed, which is distinct from an
    /// explicit false value left by an existing or interrupted profile.
    let onboardingCompleted: Bool?
}

enum KeepMediaInventoryUncertainty: String, Codable, Sendable, Equatable, Error {
    case configuredRootUnavailable
    case databaseReadFailed
    case filesystemReadFailed
    case byteMetadataMismatch
    case referencedFileMissing
    case orphanCapturedMedia
    case changedDuringReconciliation
    case unsafeRelativePath
    case migrationReceiptUnreadable
    case policyPreferenceUnreadable
    case existingProfileNeedsReconciliation
}

enum KeepMediaInventoryEvidence: Codable, Sendable, Equatable {
    /// Database and media directory were both positively observed empty.
    case positivelyEmpty
    /// Every referenced captured-media file and byte value reconciled exactly.
    case reconciled(capturedMediaBytes: Int64)
    case uncertain(KeepMediaInventoryUncertainty)

    var isAuthoritative: Bool {
        switch self {
        case .positivelyEmpty, .reconciled: true
        case .uncertain: false
        }
    }

    var capturedMediaBytes: Int64? {
        switch self {
        case .positivelyEmpty: 0
        case .reconciled(let bytes): bytes
        case .uncertain: nil
        }
    }
}

enum KeepMediaMigrationReason: String, Codable, Sendable, Equatable {
    case freshEmptyProfile
    case recognizedFiniteLegacyCap
    case promotedToAvoidImmediateDeletion
    case legacyUnlimited
    case legacyDaysPolicy
    case ambiguousOrCorruptLegacyState
    case uncertainInventory
}

struct KeepMediaMigrationResolution: Codable, Sendable, Equatable {
    let policy: KeepMediaPolicy
    let automaticDeletionAdmitted: Bool
    /// Indicates whether normalization changed the semantic legacy policy. The
    /// new versioned key may still be persisted when this is false.
    let shouldWritePolicy: Bool
    /// Deliberately always false: migration persists a decision, never performs
    /// or schedules a first-pass prune itself.
    let shouldRunRetention: Bool
    let reason: KeepMediaMigrationReason
}

enum KeepMediaMigration {
    static func resolve(
        snapshot: LegacyKeepMediaSnapshot,
        inventory: KeepMediaInventoryEvidence
    ) -> KeepMediaMigrationResolution {
        if snapshot.days == .missing,
           snapshot.maxGB == .missing,
           snapshot.onboardingCompleted == nil,
           inventory == .positivelyEmpty {
            return KeepMediaMigrationResolution(
                policy: .fiveGB,
                automaticDeletionAdmitted: true,
                shouldWritePolicy: true,
                shouldRunRetention: false,
                reason: .freshEmptyProfile
            )
        }

        guard case .integer(let legacyGB) = snapshot.maxGB else {
            if case .integer(let days) = snapshot.days, days > 0 {
                return failClosed(reason: .legacyDaysPolicy)
            }
            return failClosed(reason: .ambiguousOrCorruptLegacyState)
        }

        switch snapshot.days {
        case .integer(let days) where days != 0:
            return failClosed(
                reason: days > 0 ? .legacyDaysPolicy : .ambiguousOrCorruptLegacyState
            )
        case .invalid:
            return failClosed(reason: .ambiguousOrCorruptLegacyState)
        case .missing, .integer:
            break
        }

        guard legacyGB > 0 else {
            return failClosed(reason: .legacyUnlimited)
        }

        let normalized = KeepMediaPolicy.normalizedLegacyCap(legacyGB)
        guard normalized != .forever else {
            return failClosed(
                reason: legacyGB > 50 ? .promotedToAvoidImmediateDeletion : .legacyUnlimited
            )
        }
        let promoted = promotedPolicy(normalized, for: inventory)
        return KeepMediaMigrationResolution(
            policy: promoted,
            automaticDeletionAdmitted: false,
            shouldWritePolicy: promoted.gigabytes != legacyGB,
            shouldRunRetention: false,
            reason: promoted == normalized
                ? .recognizedFiniteLegacyCap
                : .promotedToAvoidImmediateDeletion
        )
    }

    /// Migration may only retain at least as much history as the legacy
    /// promise. Exact current usage can therefore move a finite legacy cap only
    /// upward; use beyond 50 GB becomes Forever instead of an immediate prune.
    static func promotedPolicy(
        _ policy: KeepMediaPolicy,
        for inventory: KeepMediaInventoryEvidence
    ) -> KeepMediaPolicy {
        guard let currentBytes = inventory.capturedMediaBytes,
              let legacyBytes = policy.maxCapturedMediaBytes else { return policy }
        let requiredBytes = max(currentBytes, legacyBytes)
        return KeepMediaPolicy.allCases.first { candidate in
            guard let maxBytes = candidate.maxCapturedMediaBytes else { return true }
            return maxBytes >= requiredBytes
        } ?? .forever
    }

    private static func failClosed(
        reason: KeepMediaMigrationReason
    ) -> KeepMediaMigrationResolution {
        KeepMediaMigrationResolution(
            policy: .forever,
            automaticDeletionAdmitted: false,
            shouldWritePolicy: true,
            shouldRunRetention: false,
            reason: reason
        )
    }
}

struct KeepMediaMigrationReceipt: Codable, Sendable, Equatable {
    static let currentVersion = 1

    let version: Int
    let legacySnapshot: LegacyKeepMediaSnapshot
    let inventory: KeepMediaInventoryEvidence
    let resolution: KeepMediaMigrationResolution

    init(
        legacySnapshot: LegacyKeepMediaSnapshot,
        inventory: KeepMediaInventoryEvidence,
        resolution: KeepMediaMigrationResolution
    ) {
        self.version = Self.currentVersion
        self.legacySnapshot = legacySnapshot
        self.inventory = inventory
        self.resolution = resolution
    }
}
