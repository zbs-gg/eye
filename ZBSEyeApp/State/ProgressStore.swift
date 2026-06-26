import Foundation
import Observation
import GRDB

// MARK: — Shared milestone list (also used by AppEnvironment.celebrateMilestoneIfNeeded)

enum MemoryMilestones {
    static let frames: [Int] = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]
}

// MARK: — Progress snapshot (Sendable: computed on background, delivered to MainActor)

struct ProgressSnapshot: Sendable, Equatable {
    var totalFrames: Int = 0
    var totalDays: Int = 0          // distinct calendar days with at least one capture
    var streakDays: Int = 0         // consecutive days ending today (local time)
    var memoryAgeDays: Int = 0      // days since first capture
    var nextMilestone: Int? = nil   // nil when beyond last milestone
    var lastMilestone: Int? = nil   // last passed milestone

    var hoursOfMemory: Double { Double(totalFrames) / 3600.0 }   // rough: 1 frame/sec average

    var progressToNext: Double {
        guard let next = nextMilestone, next > 0 else { return 1.0 }
        let prev = lastMilestone ?? 0
        let span = next - prev
        let done = totalFrames - prev
        return max(0, min(1, Double(done) / Double(span)))
    }
}

// MARK: — ProgressStore

/// @MainActor @Observable хранилище прогресса: стрик, вехи, возраст памяти.
/// Читает БД через pool.read (background) — никакой блокировки MainActor.
@MainActor
@Observable
final class ProgressStore {
    private(set) var snapshot = ProgressSnapshot()

    /// Pending milestone for celebration overlay (set once per new milestone cross).
    private(set) var pendingCelebration: Int? = nil

    @ObservationIgnored private weak var db: ZBSEyeDatabase?

    init(db: ZBSEyeDatabase?) {
        self.db = db
    }

    /// Public refresh: called after ingest cycle / on appear.
    func refresh() async {
        guard let db else { return }
        let result = await Self.compute(db: db)
        snapshot = result
    }

    /// Called from AppEnvironment when milestone is crossed to trigger the overlay.
    func celebrateMilestone(_ frames: Int) {
        pendingCelebration = frames
    }

    /// Dismissed by the overlay after animation completes.
    func clearCelebration() {
        pendingCelebration = nil
    }

    // MARK: — Background computation

    nonisolated private static func compute(db: ZBSEyeDatabase) async -> ProgressSnapshot {
        guard let raw = try? await db.pool.read({ dbc -> RawStats? in
            // Single-pass aggregate: COUNT, MIN, MAX ts + distinct calendar days + streak
            guard let row = try Row.fetchOne(dbc, sql: """
                SELECT
                  COUNT(*) AS totalFrames,
                  MIN(ts)  AS minTs,
                  MAX(ts)  AS maxTs
                FROM screen_captures
                """) else { return nil }

            let totalFrames: Int = row["totalFrames"] ?? 0
            guard totalFrames > 0 else { return nil }
            let minTs: Int64 = row["minTs"] ?? 0
            let maxTs: Int64 = row["maxTs"] ?? 0

            // Distinct active day strings (DESC) — ОДИН скан дат: и для стрика, и для счётчика дней
            // (activeDays = их количество). Раньше был отдельный COUNT(DISTINCT date(...)) — лишний
            // полный скан истории (ревью Pro #8).
            let dayStrings = try String.fetchAll(dbc, sql: """
                SELECT DISTINCT date(ts / 1000, 'unixepoch', 'localtime') AS d
                FROM screen_captures
                ORDER BY d DESC
                """)
            let activeDays = dayStrings.count

            // Streak: consecutive calendar days ending today (local time), walking backwards.
            var streakDays = 0
            let cal = Calendar.current
            var expected = cal.startOfDay(for: Date())
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            for ds in dayStrings {
                guard let day = fmt.date(from: ds) else { break }
                if cal.startOfDay(for: day) == expected {
                    streakDays += 1
                    expected = cal.date(byAdding: .day, value: -1, to: expected)!
                } else {
                    break
                }
            }

            return RawStats(totalFrames: totalFrames, minTs: minTs, maxTs: maxTs,
                            activeDays: activeDays, streakDays: streakDays)
        }) else {
            return ProgressSnapshot()
        }

        var s = ProgressSnapshot()
        s.totalFrames = raw.totalFrames
        s.totalDays = raw.activeDays
        s.streakDays = raw.streakDays

        // Memory age: days from first frame to now
        let firstDate = Date(timeIntervalSince1970: Double(raw.minTs) / 1000.0)
        s.memoryAgeDays = max(0, Calendar.current.dateComponents([.day], from: firstDate, to: Date()).day ?? 0)

        // Milestones
        let milestones = MemoryMilestones.frames
        s.lastMilestone = milestones.filter { $0 <= raw.totalFrames }.max()
        s.nextMilestone = milestones.first { $0 > raw.totalFrames }

        return s
    }

    private struct RawStats {
        let totalFrames: Int
        let minTs: Int64
        let maxTs: Int64
        let activeDays: Int
        let streakDays: Int
    }
}
