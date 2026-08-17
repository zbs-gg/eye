import Foundation
import GRDB

/// Read-only access to internally saved Reviews. Every mutation goes through
/// IngestService so relocation can close one writer admission boundary.
actor ReviewSummaryRepository {
    private let db: ZBSEyeDatabase

    init(db: ZBSEyeDatabase) {
        self.db = db
    }

    func summary(for period: ReviewPeriod) async throws -> ReviewSummary? {
        try await db.pool.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT * FROM review_summaries
                    WHERE period_kind = ? AND period_start_ms = ? AND period_end_ms = ?
                    """,
                arguments: [period.kind.rawValue, period.startMs, period.endMs]
            ) else { return nil }
            return try Self.decode(row)
        }
    }

    func mostRecent(limit: Int = 20) async throws -> [ReviewSummary] {
        try await db.pool.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT * FROM review_summaries ORDER BY generated_at_ms DESC LIMIT ?",
                arguments: [max(1, min(limit, 100))]
            ).map(Self.decode)
        }
    }

    private static func decode(_ row: Row) throws -> ReviewSummary {
        guard let kind = ReviewPeriodKind(rawValue: row["period_kind"]),
              let trigger = ReviewTrigger(rawValue: row["trigger_kind"]) else {
            throw DatabaseError(message: "invalid review summary stable value")
        }
        let providerID: String = row["provider_id"]
        let modelID: String = row["model_id"]
        let usage = LLMUsage(
            inputTokens: row["input_tokens"],
            cachedInputTokens: row["cached_input_tokens"],
            outputTokens: row["output_tokens"],
            reasoningOutputTokens: row["reasoning_output_tokens"]
        )
        let billing: ReviewBilling?
        if let amount: Double = row["billing_amount"],
           let unitRaw: String = row["billing_unit"],
           let unit = ReviewBilling.Unit(rawValue: unitRaw),
           let date: String = row["rate_card_date"] {
            billing = ReviewBilling(amount: amount, unit: unit, rateCardDate: date)
        } else {
            billing = nil
        }
        return ReviewSummary(
            id: row["id"],
            period: ReviewPeriod(
                kind: kind,
                start: dateFromMs(row["period_start_ms"]),
                end: dateFromMs(row["period_end_ms"])
            ),
            generatedAt: dateFromMs(row["generated_at_ms"]),
            markdown: row["markdown"],
            sessions: row["sessions"],
            totalCaptures: row["total_captures"],
            provenance: AIExecutionProvenance(
                providerID: providerID,
                modelID: modelID,
                executedLocally: row["executed_locally"],
                generatedAt: dateFromMs(row["generated_at_ms"]),
                brokerUpstream: row["broker_upstream"]
            ),
            promptVersion: row["prompt_version"],
            usage: usage.hasMeasurement ? usage : nil,
            billing: billing,
            sourceTruncated: row["source_truncated"],
            contextTruncated: row["context_truncated"],
            outputTruncated: row["output_truncated"],
            coverageIncomplete: row["coverage_incomplete"],
            trigger: trigger
        )
    }
}
