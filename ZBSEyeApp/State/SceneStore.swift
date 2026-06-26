import Foundation
import Observation

/// Стор «День в активностях»: сегментированные сцены для текущего дня.
/// @MainActor @Observable — паттерн TimelineStore/AskStore.
@MainActor
@Observable
final class SceneStore {
    @ObservationIgnored private let service: SceneService
    @ObservationIgnored private let timeline: TimelineService

    var scenes: [ActivityScene] = []
    var isLoading = false
    var error: String?

    /// День, за который показываем активности (nil = сегодня/хвост истории).
    var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    /// Поколение загрузки: последний вызов load() выигрывает. Защищает от гонки, когда быстрый
    /// повторный load() (смена дня / повторный appear) даёт двум запросам перезаписать друг друга
    /// не по порядку — старый результат не должен затереть новый день.
    @ObservationIgnored private var loadGeneration = 0

    init(service: SceneService, timeline: TimelineService) {
        self.service = service
        self.timeline = timeline
    }

    /// Загружает сцены за `selectedDay`. Вызывается при смене дня и при появлении вью.
    func load() async {
        loadGeneration += 1
        let gen = loadGeneration
        let day = selectedDay
        isLoading = true
        error = nil
        do {
            let result = try await service.scenes(forDay: day)
            guard gen == loadGeneration else { return }   // устарел — пришёл более новый load()
            scenes = result
        } catch {
            guard gen == loadGeneration else { return }
            self.error = String(describing: error)
            scenes = []
        }
        if gen == loadGeneration { isLoading = false }
    }

    /// Сцена, содержащая указанный момент времени (для правой панели таймлайна).
    func scene(for time: Date) async -> ActivityScene? {
        try? await service.scene(containing: time)
    }
}
