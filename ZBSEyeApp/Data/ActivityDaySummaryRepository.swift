import Foundation
import GRDB

/// One durable, privacy-safe summary for a calendar day shown in Activities.
/// The source interval is half-open: `[sourceStartMs, sourceEndMs)`.
struct ActivityDaySummaryCacheEntry: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "activity_day_summaries"

    let dayKey: String
    let inputFingerprint: String
    let summary: String
    let providerID: String
    let modelID: String
    let executedLocally: Bool
    let brokerUpstream: String?
    let recipientDisclosure: String?
    /// Safe origin shown in provenance. Never contains credentials, path, query, or fragment.
    let endpointDisclosure: String?
    /// Opaque fingerprint of the canonical endpoint including its normalized path.
    let endpointIdentity: String?
    let promptVersion: String
    let generatedAtMs: Int64
    let sourceStartMs: Int64
    let sourceEndMs: Int64
    let sourceCount: Int
}

/// One consistent cache read plus the privacy epoch a later write must still match.
struct ActivityDaySummaryCacheSnapshot: Sendable, Equatable {
    let entry: ActivityDaySummaryCacheEntry?
    let invalidationEpoch: Int64
}

/// The single day-key formatter shared by collection, cache lookup, and presentation.
/// A caller must pass the timezone whose calendar day it is summarizing.
enum ActivityDaySummaryDayKey {
    static func make(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Narrow storage boundary for the one Activities day-summary cache.
actor ActivityDaySummaryRepository {
    private let database: ZBSEyeDatabase

    init(database: ZBSEyeDatabase) {
        self.database = database
    }

    func snapshot(dayKey: String) async throws -> ActivityDaySummaryCacheSnapshot {
        try await database.pool.read { db in
            guard let epoch = try Int64.fetchOne(
                db,
                sql: """
                    SELECT invalidationEpoch
                    FROM activity_day_summary_state
                    WHERE singleton = 1
                    """
            ) else {
                throw DatabaseError(message: "activity day-summary invalidation state is missing")
            }
            return ActivityDaySummaryCacheSnapshot(
                entry: try ActivityDaySummaryCacheEntry.fetchOne(db, key: dayKey),
                invalidationEpoch: epoch
            )
        }
    }

    /// A late model response is accepted only if privacy/retention has not
    /// invalidated Activities data since the caller's snapshot.
    @discardableResult
    func replace(
        _ entry: ActivityDaySummaryCacheEntry,
        expectedInvalidationEpoch: Int64
    ) async throws -> Bool {
        try await database.pool.write { db in
            guard try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM activity_day_summary_state WHERE singleton = 1"
            ) != nil else {
                throw DatabaseError(message: "activity day-summary invalidation state is missing")
            }
            try db.execute(
                sql: """
                    INSERT INTO activity_day_summaries(
                        dayKey, inputFingerprint, summary, providerID, modelID,
                        executedLocally, brokerUpstream, recipientDisclosure,
                        endpointDisclosure, endpointIdentity, promptVersion, generatedAtMs,
                        sourceStartMs, sourceEndMs, sourceCount
                    )
                    SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
                    FROM activity_day_summary_state
                    WHERE singleton = 1 AND invalidationEpoch = ?
                    ON CONFLICT(dayKey) DO UPDATE SET
                        inputFingerprint = excluded.inputFingerprint,
                        summary = excluded.summary,
                        providerID = excluded.providerID,
                        modelID = excluded.modelID,
                        executedLocally = excluded.executedLocally,
                        brokerUpstream = excluded.brokerUpstream,
                        recipientDisclosure = excluded.recipientDisclosure,
                        endpointDisclosure = excluded.endpointDisclosure,
                        endpointIdentity = excluded.endpointIdentity,
                        promptVersion = excluded.promptVersion,
                        generatedAtMs = excluded.generatedAtMs,
                        sourceStartMs = excluded.sourceStartMs,
                        sourceEndMs = excluded.sourceEndMs,
                        sourceCount = excluded.sourceCount
                    """,
                arguments: [
                    entry.dayKey,
                    entry.inputFingerprint,
                    entry.summary,
                    entry.providerID,
                    entry.modelID,
                    entry.executedLocally,
                    entry.brokerUpstream,
                    entry.recipientDisclosure,
                    entry.endpointDisclosure,
                    entry.endpointIdentity,
                    entry.promptVersion,
                    entry.generatedAtMs,
                    entry.sourceStartMs,
                    entry.sourceEndMs,
                    entry.sourceCount,
                    expectedInvalidationEpoch,
                ]
            )
            return db.changesCount == 1
        }
    }

    func delete(dayKey: String) async throws {
        try await database.pool.write { db in
            try Self.bumpInvalidationEpoch(in: db)
            try db.execute(
                sql: "DELETE FROM activity_day_summaries WHERE dayKey = ?",
                arguments: [dayKey]
            )
        }
    }

    /// Deletes cached summaries whose source interval intersects `[fromMs, toMs)`.
    func deleteOverlapping(fromMs: Int64, toMs: Int64) async throws {
        try await database.pool.write { db in
            try Self.deleteOverlapping(in: db, fromMs: fromMs, toMs: toMs)
        }
    }

    func deleteAll() async throws {
        try await database.pool.write { db in
            try Self.deleteAll(in: db)
        }
    }

    nonisolated static func deleteOverlapping(
        in db: Database,
        fromMs: Int64,
        toMs: Int64
    ) throws {
        try bumpInvalidationEpoch(in: db)
        try db.execute(
            sql: """
                DELETE FROM activity_day_summaries
                WHERE sourceStartMs < ? AND sourceEndMs > ?
                """,
            arguments: [toMs, fromMs]
        )
    }

    nonisolated static func deleteSummariesContainingSources(
        in db: Database,
        sourceTimestampsMs: [Int64]
    ) throws {
        guard !sourceTimestampsMs.isEmpty else { return }
        try bumpInvalidationEpoch(in: db)
        for timestamp in sourceTimestampsMs {
            try db.execute(
                sql: """
                    DELETE FROM activity_day_summaries
                    WHERE sourceStartMs <= ? AND sourceEndMs > ?
                    """,
                arguments: [timestamp, timestamp]
            )
        }
    }

    nonisolated static func deleteAll(in db: Database) throws {
        try bumpInvalidationEpoch(in: db)
        try db.execute(sql: "DELETE FROM activity_day_summaries")
    }

    /// `WHERE < max` makes overflow fail closed instead of wrapping back to an
    /// epoch that could authorize an ancient in-flight response.
    private nonisolated static func bumpInvalidationEpoch(in db: Database) throws {
        try db.execute(
            sql: """
                UPDATE activity_day_summary_state
                SET invalidationEpoch = invalidationEpoch + 1
                WHERE singleton = 1 AND invalidationEpoch < ?
                """,
            arguments: [Int64.max]
        )
        guard db.changesCount == 1 else {
            throw DatabaseError(message: "activity day-summary invalidation epoch is unavailable or exhausted")
        }
    }
}
