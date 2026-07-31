import Foundation
import GRDB

/// Transaction-local maintenance for half-open capture uncertainty intervals.
/// The surviving right side keeps the original episode identity so an in-flight
/// controller can still close the same open interval after a concurrent privacy
/// deletion commits.
enum CaptureCoverageMaintenance {
    static func subtractDeletedRange(
        in database: Database,
        fromMs: Int64,
        toMs: Int64
    ) throws {
        guard toMs > fromMs,
              try database.tableExists("capture_coverage_intervals") else { return }
        if fromMs == 0, toMs == Int64.max {
            try database.execute(sql: "DELETE FROM capture_coverage_intervals")
            return
        }

        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, leg, reason, episode_id, generation,
                       start_ms, end_ms, close_cause
                FROM capture_coverage_intervals
                WHERE start_ms < ?
                  AND (end_ms IS NULL OR end_ms > ?)
                ORDER BY start_ms ASC, id ASC
                """,
            arguments: [toMs, fromMs]
        )
        for row in rows {
            let id: Int64 = row["id"]
            let startMs: Int64 = row["start_ms"]
            let endMs: Int64? = row["end_ms"]
            let keepsLeft = startMs < fromMs
            let keepsRight = toMs < Int64.max && (endMs == nil || endMs! > toMs)

            switch (keepsLeft, keepsRight) {
            case (false, false):
                try database.execute(
                    sql: "DELETE FROM capture_coverage_intervals WHERE id = ?",
                    arguments: [id]
                )

            case (true, false):
                try database.execute(
                    sql: """
                        UPDATE capture_coverage_intervals
                        SET end_ms = ?, close_cause = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        fromMs,
                        CaptureCoverageCloseCause.historyDeleted.rawValue,
                        id,
                    ]
                )

            case (false, true):
                try database.execute(
                    sql: "UPDATE capture_coverage_intervals SET start_ms = ? WHERE id = ?",
                    arguments: [toMs, id]
                )

            case (true, true):
                let episodeID: String = row["episode_id"]
                let leftEpisodeID = "\(episodeID)#before-\(fromMs)-\(toMs)"
                try database.execute(
                    sql: """
                        INSERT INTO capture_coverage_intervals(
                            leg, reason, episode_id, generation,
                            start_ms, end_ms, close_cause
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        row["leg"] as String,
                        row["reason"] as String,
                        leftEpisodeID,
                        row["generation"] as Int64,
                        startMs,
                        fromMs,
                        CaptureCoverageCloseCause.historyDeleted.rawValue,
                    ]
                )
                // Preserve the original identity on the right. If this row is
                // open, the runtime controller's later compare-and-set close
                // still targets the correct episode and generation.
                try database.execute(
                    sql: "UPDATE capture_coverage_intervals SET start_ms = ? WHERE id = ?",
                    arguments: [toMs, id]
                )
            }
        }
    }
}
