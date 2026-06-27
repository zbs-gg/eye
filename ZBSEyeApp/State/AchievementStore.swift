import Foundation
import Observation

/// Achievement state: catalog + set of unlocked ones (persist) + statistics. On refresh it recomputes
/// the statistics and unlocks new achievements (once, forever). A new unlock → pendingUnlock for the animation.
@MainActor
@Observable
final class AchievementStore {
    private(set) var stats = AchievementStats()
    private(set) var unlocked: Set<String> = []
    /// Queue of just-unlocked ones — for the pop-up reward (we show them one at a time).
    private(set) var pendingUnlock: Achievement?

    @ObservationIgnored private let service: AchievementStatsService
    @ObservationIgnored private var unlockDates: [String: Double] = [:]
    @ObservationIgnored private var queue: [Achievement] = []
    @ObservationIgnored private static let unlockedKey = "zbseye.ach.unlocked"
    @ObservationIgnored private static let datesKey = "zbseye.ach.dates"

    init(service: AchievementStatsService) {
        self.service = service
        if let ids = UserDefaults.standard.array(forKey: Self.unlockedKey) as? [String] {
            unlocked = Set(ids)
        }
        if let d = UserDefaults.standard.dictionary(forKey: Self.datesKey) as? [String: Double] {
            unlockDates = d
        }
    }

    var catalog: [Achievement] { AchievementCatalog.all }
    var unlockedCount: Int { unlocked.count }
    var totalCount: Int { catalog.count }

    func isUnlocked(_ a: Achievement) -> Bool { unlocked.contains(a.id) }
    func unlockedDate(_ id: String) -> Date? {
        unlockDates[id].map { Date(timeIntervalSince1970: $0) }
    }

    /// Recompute the statistics and unlock new achievements. Called after an ingest tick / on appear.
    func refresh() async {
        let s = await service.compute()
        stats = s
        var newly: [Achievement] = []
        for a in catalog where !unlocked.contains(a.id) && a.condition.isMet(s) {
            unlocked.insert(a.id)
            unlockDates[a.id] = Date().timeIntervalSince1970
            newly.append(a)
        }
        guard !newly.isEmpty else { return }
        persist()
        queue.append(contentsOf: newly)
        if pendingUnlock == nil { advanceQueue() }
    }

    /// The reward animation has been shown — take the next one from the queue.
    func clearPendingUnlock() {
        pendingUnlock = nil
        advanceQueue()
    }

    private func advanceQueue() {
        guard pendingUnlock == nil, !queue.isEmpty else { return }
        pendingUnlock = queue.removeFirst()
    }

    private func persist() {
        UserDefaults.standard.set(Array(unlocked), forKey: Self.unlockedKey)
        UserDefaults.standard.set(unlockDates, forKey: Self.datesKey)
    }
}
