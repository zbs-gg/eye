import Foundation
import GRDB

/// Personal usage analytics computed from Eye's own history — "how did I actually spend my screen
/// time?" Dogfoods the same site-aware attribution as Daily Insights (browsers split by site, not
/// lumped). Read-only actor; all fields Sendable so the snapshot crosses to the MainActor.
actor UsageStatsService {
    private let db: ZBSEyeDatabase
    private let repo: DayActivityRepository
    init(db: ZBSEyeDatabase, repo: DayActivityRepository) { self.db = db; self.repo = repo }

    struct TopItem: Sendable, Identifiable { let label: String; let minutes: Int; var id: String { label } }

    struct Snapshot: Sendable, Equatable {
        var days: Int = 7
        var topApps: [TopItem] = []            // site-aware (browsers per site)
        var totalActiveMinutes: Int = 0
        var avgMinutesPerActiveDay: Int = 0
        var activeDays: Int = 0
        var contextSwitchesPerDay: Int = 0
        var busiestHour: Int? = nil            // 0–23, local
        var hourHistogram: [Int] = Array(repeating: 0, count: 24)   // active-minutes per hour of day
        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.days == b.days && a.topApps.map(\.label) == b.topApps.map(\.label)
                && a.topApps.map(\.minutes) == b.topApps.map(\.minutes)
                && a.totalActiveMinutes == b.totalActiveMinutes && a.busiestHour == b.busiestHour
        }
    }

    /// Compute over the last `days` days (default 7).
    func compute(days: Int = 7) async -> Snapshot {
        var s = Snapshot(days: days)
        let cal = Calendar.current
        let now = Date()
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: now)) ?? now
        let fromMs = Int64(start.timeIntervalSince1970 * 1000)
        let toMs = Int64(now.timeIntervalSince1970 * 1000)

        guard let caps = try? await repo.captures(fromMs: fromMs, toMs: toMs), !caps.isEmpty else { return s }

        // Site-aware top apps (browsers split by site, real host recovered from browser history).
        let hosts = (try? await repo.browserHostOverrides(caps)) ?? [:]
        let usage = DayActivityRepository.appSiteActiveMs(caps, activeGapCapMs: 120 * 1000, hosts: hosts)
        s.topApps = usage.ms.sorted { $0.value > $1.value }.prefix(8).map {
            TopItem(label: usage.label[$0.key] ?? "—", minutes: max(1, Int($0.value / 60000)))
        }
        s.totalActiveMinutes = Int(usage.ms.values.reduce(0, +) / 60000)

        // Active days in the window + per-day averages.
        let dayKeys = Set(caps.map { cal.startOfDay(for: Date(timeIntervalSince1970: Double($0.ts) / 1000)) })
        s.activeDays = max(1, dayKeys.count)
        s.avgMinutesPerActiveDay = s.totalActiveMinutes / s.activeDays
        s.contextSwitchesPerDay = DayActivityRepository.contextSwitches(caps) / s.activeDays

        // Hour-of-day histogram (active-minutes credited to the previous frame's hour).
        var prev: CaptureLite? = nil
        for cap in caps {
            if let p = prev {
                let h = cal.component(.hour, from: Date(timeIntervalSince1970: Double(p.ts) / 1000))
                let deltaMs = min(cap.ts - p.ts, 120 * 1000)
                s.hourHistogram[h] += Int(deltaMs / 60000)
            }
            prev = cap
        }
        s.busiestHour = s.hourHistogram.enumerated().max(by: { $0.element < $1.element })?.offset
        if s.hourHistogram.allSatisfy({ $0 == 0 }) { s.busiestHour = nil }
        return s
    }
}
