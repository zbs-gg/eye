import Foundation
import GRDB

/// Read-only companion to capture search. Coverage SQL deliberately stays out
/// of FTS queries so disclosure cannot change ranking, pagination, or counts.
struct CaptureCoverageQuery: Sendable {
    private let database: ZBSEyeDatabase

    init(database: ZBSEyeDatabase) {
        self.database = database
    }

    func overlapping(startMs: Int64, endMs: Int64) async throws -> CaptureCoverageRead {
        guard endMs > startMs else { return .available([]) }
        return try await database.pool.read { db in
            guard try db.tableExists("capture_coverage_intervals") else {
                return .metadataUnavailable
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, leg, reason, episode_id, generation,
                           start_ms, end_ms, close_cause
                    FROM capture_coverage_intervals
                    WHERE start_ms < ?
                      AND (end_ms IS NULL OR end_ms > ?)
                    ORDER BY start_ms ASC, id ASC
                    """,
                arguments: [endMs, startMs]
            )
            return .available(try rows.map(Self.decode))
        }
    }

    func openIntervals() async throws -> CaptureCoverageRead {
        try await database.pool.read { db in
            guard try db.tableExists("capture_coverage_intervals") else {
                return .metadataUnavailable
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, leg, reason, episode_id, generation,
                           start_ms, end_ms, close_cause
                    FROM capture_coverage_intervals
                    WHERE end_ms IS NULL
                    ORDER BY start_ms ASC, id ASC
                    """
            )
            return .available(try rows.map(Self.decode))
        }
    }

    private static func decode(_ row: Row) throws -> CaptureCoverageInterval {
        guard let leg = CaptureLeg(rawValue: row["leg"]),
              let reason = CaptureHealthReason(rawValue: row["reason"]) else {
            throw CaptureCoverageQueryError.invalidStableValue
        }
        let closeRaw: String? = row["close_cause"]
        let closeCause: CaptureCoverageCloseCause?
        if let closeRaw {
            guard let decoded = CaptureCoverageCloseCause(rawValue: closeRaw) else {
                throw CaptureCoverageQueryError.invalidStableValue
            }
            closeCause = decoded
        } else {
            closeCause = nil
        }
        return CaptureCoverageInterval(
            id: row["id"],
            leg: leg,
            reason: reason,
            episodeID: row["episode_id"],
            generation: row["generation"],
            startMs: row["start_ms"],
            endMs: row["end_ms"],
            closeCause: closeCause
        )
    }
}

enum CaptureCoverageQueryError: Error, Sendable, Equatable {
    case invalidStableValue
}
