import Foundation
import GRDB

enum CallAutomationRepositoryError: LocalizedError, Sendable, Equatable {
    case endpointChangeRequiresDiscard(Int)

    var errorDescription: String? {
        switch self {
        case .endpointChangeRequiresDiscard(let count):
            return "Changing the receiver would discard \(count) undelivered call event(s)."
        }
    }
}

struct CallAutomationDelivery: Sendable, Equatable {
    let event: CallAutomationOutboxRow
    let endpoint: URL
}

struct CallAutomationStatus: Sendable, Equatable {
    let enabled: Bool
    let pendingCount: Int
    let blockedCount: Int
}

/// Owns only durable outbox state. It never performs network I/O and is safe to call from the
/// dispatcher's actor without crossing into call-capture or transcription work.
actor CallAutomationRepository {
    private let database: ZBSEyeDatabase

    init(database: ZBSEyeDatabase) {
        self.database = database
    }

    func configuration() async throws -> CallAutomationConfigRow {
        try await database.pool.read { db in
            try CallAutomationConfigRow.fetchOne(db, key: 1) ?? CallAutomationConfigRow(
                id: 1,
                enabled: false,
                endpointURL: nil,
                endpointFingerprint: nil,
                updatedAtMs: 0
            )
        }
    }

    @discardableResult
    func saveConfiguration(
        enabled: Bool,
        endpoint: URL,
        discardUndeliveredOnEndpointChange: Bool,
        nowMs: Int64
    ) async throws -> Int {
        let canonicalEndpoint = try CallAutomationEndpoint.canonicalURL(endpoint)
        let endpointURL = canonicalEndpoint.absoluteString
        let endpointFingerprint = try CallAutomationEndpoint.fingerprint(canonicalEndpoint)
        return try await database.pool.write { db in
            let current = try CallAutomationConfigRow.fetchOne(db, key: 1)
            let endpointChanged = current?.endpointFingerprint != nil
                && current?.endpointFingerprint != endpointFingerprint
            var discarded = 0
            if endpointChanged {
                discarded = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_automation_outbox WHERE state != 'delivered'"
                ) ?? 0
                if discarded > 0 && !discardUndeliveredOnEndpointChange {
                    throw CallAutomationRepositoryError.endpointChangeRequiresDiscard(discarded)
                }
                if discarded > 0 {
                    try db.execute(
                        sql: "DELETE FROM call_automation_outbox WHERE state != 'delivered'"
                    )
                }
            }
            try db.execute(
                sql: """
                    UPDATE call_automation_config
                    SET enabled = ?, endpointURL = ?, endpointFingerprint = ?, updatedAtMs = ?
                    WHERE id = 1
                    """,
                arguments: [enabled, endpointURL, endpointFingerprint, nowMs]
            )
            return discarded
        }
    }

    func setEnabled(_ enabled: Bool, nowMs: Int64) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE call_automation_config SET enabled = ?, updatedAtMs = ? WHERE id = 1",
                arguments: [enabled, nowMs]
            )
        }
    }

    func claimNext(nowMs: Int64, leaseDurationMs: Int64) async throws -> CallAutomationDelivery? {
        try await database.pool.write { db in
            guard let config = try CallAutomationConfigRow.fetchOne(db, key: 1),
                  config.enabled,
                  let endpointString = config.endpointURL,
                  let fingerprint = config.endpointFingerprint,
                  let endpoint = URL(string: endpointString) else { return nil }

            guard let candidate = try CallAutomationOutboxRow.fetchOne(
                db,
                sql: """
                    SELECT o.*
                    FROM call_automation_outbox o
                    JOIN calls c ON c.id = o.callId
                    WHERE o.state = 'pending'
                      AND o.nextAttemptAtMs <= ?
                      AND o.endpointFingerprint = ?
                      AND (c.degradationReason IS NULL OR c.degradationReason != 'erase_pending')
                      AND NOT EXISTS (
                          SELECT 1
                          FROM call_automation_outbox earlier
                          WHERE earlier.callId = o.callId
                            AND earlier.sequence < o.sequence
                            AND earlier.state != 'delivered'
                      )
                    ORDER BY o.sequence
                    LIMIT 1
                    """,
                arguments: [nowMs, fingerprint]
            ) else { return nil }

            let leaseEnd = nowMs.addingReportingOverflow(max(1, leaseDurationMs))
            guard !leaseEnd.overflow else { return nil }
            try db.execute(
                sql: """
                    UPDATE call_automation_outbox
                    SET state = 'sending', attempts = attempts + 1,
                        leaseExpiresAtMs = ?, updatedAtMs = ?
                    WHERE eventID = ? AND state = 'pending'
                    """,
                arguments: [leaseEnd.partialValue, nowMs, candidate.eventID]
            )
            guard db.changesCount == 1,
                  let claimed = try CallAutomationOutboxRow.fetchOne(
                    db,
                    sql: "SELECT * FROM call_automation_outbox WHERE eventID = ?",
                    arguments: [candidate.eventID]
                  ) else { return nil }
            return CallAutomationDelivery(event: claimed, endpoint: endpoint)
        }
    }

    @discardableResult
    func recoverStaleLeases(nowMs: Int64) async throws -> Int {
        try await database.pool.write { db in
            try Self.recoverStaleLeases(db: db, nowMs: nowMs)
        }
    }

    private static func recoverStaleLeases(db: Database, nowMs: Int64) throws -> Int {
        try db.execute(
            sql: """
                UPDATE call_automation_outbox
                SET state = 'pending', leaseExpiresAtMs = NULL,
                    nextAttemptAtMs = MIN(nextAttemptAtMs, ?), updatedAtMs = ?
                WHERE state = 'sending' AND leaseExpiresAtMs <= ?
                """,
            arguments: [nowMs, nowMs, nowMs]
        )
        return db.changesCount
    }

    func markDelivered(eventID: String, statusCode: Int, nowMs: Int64) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE call_automation_outbox
                    SET state = 'delivered', leaseExpiresAtMs = NULL,
                        httpStatus = ?, lastErrorCode = NULL,
                        deliveredAtMs = ?, updatedAtMs = ?
                    WHERE eventID = ? AND state = 'sending'
                    """,
                arguments: [statusCode, nowMs, nowMs, eventID]
            )
        }
    }

    func markRetry(
        eventID: String,
        nextAttemptAtMs: Int64,
        errorCode: String,
        nowMs: Int64
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE call_automation_outbox
                    SET state = 'pending', leaseExpiresAtMs = NULL,
                        nextAttemptAtMs = ?, httpStatus = NULL,
                        lastErrorCode = ?, updatedAtMs = ?
                    WHERE eventID = ? AND state = 'sending'
                    """,
                arguments: [nextAttemptAtMs, errorCode, nowMs, eventID]
            )
        }
    }

    func markBlocked(
        eventID: String,
        statusCode: Int?,
        errorCode: String,
        nowMs: Int64
    ) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE call_automation_outbox
                    SET state = 'blocked', leaseExpiresAtMs = NULL,
                        httpStatus = ?, lastErrorCode = ?, updatedAtMs = ?
                    WHERE eventID = ? AND state = 'sending'
                    """,
                arguments: [statusCode, errorCode, nowMs, eventID]
            )
        }
    }

    @discardableResult
    func retryAllBlocked(nowMs: Int64) async throws -> Int {
        try await database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE call_automation_outbox
                    SET state = 'pending', nextAttemptAtMs = ?,
                        httpStatus = NULL, lastErrorCode = NULL, updatedAtMs = ?
                    WHERE state = 'blocked'
                    """,
                arguments: [nowMs, nowMs]
            )
            return db.changesCount
        }
    }

    func nextDispatchAtMs() async throws -> Int64? {
        try await database.pool.read { db in
            let pending = try Int64.fetchOne(
                db,
                sql: """
                    SELECT MIN(o.nextAttemptAtMs)
                    FROM call_automation_outbox o
                    JOIN call_automation_config c ON c.id = 1
                    JOIN calls call ON call.id = o.callId
                    WHERE c.enabled = 1 AND o.state = 'pending'
                      AND o.endpointFingerprint = c.endpointFingerprint
                      AND (call.degradationReason IS NULL OR call.degradationReason != 'erase_pending')
                      AND NOT EXISTS (
                          SELECT 1
                          FROM call_automation_outbox earlier
                          WHERE earlier.callId = o.callId
                            AND earlier.sequence < o.sequence
                            AND earlier.state != 'delivered'
                      )
                    """
            )
            let leaseExpiry = try Int64.fetchOne(
                db,
                sql: """
                    SELECT MIN(o.leaseExpiresAtMs)
                    FROM call_automation_outbox o
                    JOIN call_automation_config c ON c.id = 1
                    JOIN calls call ON call.id = o.callId
                    WHERE c.enabled = 1 AND o.state = 'sending'
                      AND o.endpointFingerprint = c.endpointFingerprint
                      AND (call.degradationReason IS NULL OR call.degradationReason != 'erase_pending')
                    """
            )
            return [pending, leaseExpiry].compactMap { $0 }.min()
        }
    }

    func status() async throws -> CallAutomationStatus {
        try await database.pool.read { db in
            let enabled = try Bool.fetchOne(
                db,
                sql: "SELECT enabled FROM call_automation_config WHERE id = 1"
            ) ?? false
            func count(_ state: CallAutomationDeliveryState) throws -> Int {
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_automation_outbox WHERE state = ?",
                    arguments: [state.rawValue]
                ) ?? 0
            }
            return try CallAutomationStatus(
                enabled: enabled,
                pendingCount: count(.pending) + count(.sending),
                blockedCount: count(.blocked)
            )
        }
    }

    @discardableResult
    func pruneDelivered(before cutoffMs: Int64) async throws -> Int {
        try await database.pool.write { db in
            try db.execute(
                sql: "DELETE FROM call_automation_outbox WHERE state = 'delivered' AND deliveredAtMs < ?",
                arguments: [cutoffMs]
            )
            return db.changesCount
        }
    }
}
