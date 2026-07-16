import Foundation

/// Durable intent for automatic captured-media retention. The record is kept
/// outside the history database so opening or revoking retention never needs a
/// schema migration or touches the user's captured history.
struct AutomaticRetentionRecord: Codable, Sendable, Equatable {
    static let currentVersion = 1

    enum Phase: String, Codable, Sendable, Equatable {
        case closed
        case pendingFinite
        case finiteAdmitted
        case pendingForever
    }

    enum Source: String, Codable, Sendable, Equatable {
        case migration
        case explicitSelection
    }

    let version: Int
    let revision: UInt64
    let policy: KeepMediaPolicy
    let phase: Phase
    let source: Source

    init(
        revision: UInt64,
        policy: KeepMediaPolicy,
        phase: Phase,
        source: Source
    ) {
        self.version = Self.currentVersion
        self.revision = revision
        self.policy = policy
        self.phase = phase
        self.source = source
    }

    static let closedForever = AutomaticRetentionRecord(
        revision: 0,
        policy: .forever,
        phase: .closed,
        source: .migration
    )

    var recoveredForStartup: AutomaticRetentionRecord {
        switch phase {
        case .pendingForever:
            return AutomaticRetentionRecord(
                revision: revision,
                policy: .forever,
                phase: .closed,
                source: source
            )
        case .finiteAdmitted:
            // A persisted permit is never trusted across a process boundary.
            // Reopen it only after the current database/filesystem inventory
            // has reconciled successfully.
            return AutomaticRetentionRecord(
                revision: revision,
                policy: policy,
                phase: .pendingFinite,
                source: source
            )
        case .closed, .pendingFinite:
            return self
        }
    }

    var isValid: Bool {
        guard version == Self.currentVersion else { return false }
        switch phase {
        case .finiteAdmitted, .pendingFinite:
            return policy.maxCapturedMediaBytes != nil
        case .pendingForever:
            return policy == .forever
        case .closed:
            return policy == .forever || policy.maxCapturedMediaBytes != nil
        }
    }
}

struct AutomaticRetentionPermit: Sendable, Equatable {
    let revision: UInt64
    let policy: KeepMediaPolicy
    let maxBytes: Int64
}

enum AutomaticRetentionAdmissionError: Error, Sendable, Equatable {
    case stalePermit
}

/// Process-local lease for one automatic-retention database transaction. The
/// lock intentionally spans the synchronous transaction body: revocation can
/// wait for the already-admitted transaction, then prevents every later one.
final class AutomaticRetentionAdmission: @unchecked Sendable {
    private let condition = NSCondition()
    private var record: AutomaticRetentionRecord
    private var activeLeases = 0

    init(record: AutomaticRetentionRecord = .closedForever) {
        // Callers pass an already startup-resolved record. Keeping recovery in
        // StorageSettingsStore lets an in-process finite activation issue a
        // permit without immediately demoting itself back to pending.
        self.record = record.isValid ? record : .closedForever
    }

    func currentPermit() -> AutomaticRetentionPermit? {
        condition.lock()
        defer { condition.unlock() }
        return permitIfAdmitted()
    }

    @discardableResult
    func activate(_ admitted: AutomaticRetentionRecord) -> Bool {
        precondition(admitted.isValid && admitted.phase == .finiteAdmitted)
        condition.lock()
        defer { condition.unlock() }
        let mayCompletePendingFinite = admitted.revision == record.revision
            && record.phase == .pendingFinite
            && record.policy == admitted.policy
        guard admitted.revision > record.revision || mayCompletePendingFinite else {
            return false
        }
        record = admitted
        return true
    }

    /// Closes new admission. If a transaction already owns the lease, this
    /// call waits for that synchronous transaction to finish exactly once.
    func revoke(to revision: UInt64) {
        condition.lock()
        let nextRevision = max(revision, record.revision)
        record = AutomaticRetentionRecord(
            revision: nextRevision,
            policy: .forever,
            phase: .closed,
            source: record.source
        )
        while activeLeases > 0 { condition.wait() }
        condition.unlock()
    }

    /// Revoke the old permit and publish the new finite decision as inert.
    /// `activate` may then complete this exact revision after authoritative
    /// reconciliation, while any older or concurrent completion stays stale.
    @discardableResult
    func revokeAndStage(_ pending: AutomaticRetentionRecord) -> Bool {
        precondition(pending.isValid && pending.phase == .pendingFinite)
        condition.lock()
        defer { condition.unlock() }
        guard pending.revision > record.revision
                || (pending.revision == record.revision
                    && record.phase == .pendingFinite
                    && record.policy == pending.policy) else {
            return false
        }
        record = pending
        return true
    }

    func withLease<T>(
        _ permit: AutomaticRetentionPermit,
        _ body: () throws -> T
    ) throws -> T {
        try beginLease(permit)
        defer { endLease() }
        return try body()
    }

    func withAsyncLease<T: Sendable>(
        _ permit: AutomaticRetentionPermit,
        _ body: () async throws -> T
    ) async throws -> T {
        try beginLease(permit)
        defer { endLease() }
        return try await body()
    }

    private func beginLease(_ permit: AutomaticRetentionPermit) throws {
        condition.lock()
        guard permitIfAdmitted() == permit else {
            condition.unlock()
            throw AutomaticRetentionAdmissionError.stalePermit
        }
        activeLeases += 1
        condition.unlock()
    }

    private func endLease() {
        condition.lock()
        activeLeases -= 1
        if activeLeases == 0 { condition.broadcast() }
        condition.unlock()
    }

    private func permitIfAdmitted() -> AutomaticRetentionPermit? {
        guard record.phase == .finiteAdmitted,
              let maxBytes = record.policy.maxCapturedMediaBytes else { return nil }
        return AutomaticRetentionPermit(
            revision: record.revision,
            policy: record.policy,
            maxBytes: maxBytes
        )
    }
}
