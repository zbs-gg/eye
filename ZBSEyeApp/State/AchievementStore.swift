import Foundation
import Observation

/// Состояние достижений: каталог + множество открытых (persist) + статистика. На refresh пересчитывает
/// статистику и открывает новые ачивки (раз, навсегда). Новое открытие → pendingUnlock для анимации.
@MainActor
@Observable
final class AchievementStore {
    private(set) var stats = AchievementStats()
    private(set) var unlocked: Set<String> = []
    /// Очередь только что открытых — для всплывающей награды (показываем по одной).
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

    /// Пересчитать статистику и открыть новые достижения. Вызывается после ingest-тика / на appear.
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

    /// Анимация награды показана — берём следующую из очереди.
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
