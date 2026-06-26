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

    init(service: SceneService, timeline: TimelineService) {
        self.service = service
        self.timeline = timeline
    }

    /// Загружает сцены за `selectedDay`. Вызывается при смене дня и при появлении вью.
    func load() async {
        isLoading = true
        error = nil
        do {
            scenes = try await service.scenes(forDay: selectedDay)
        } catch {
            self.error = String(describing: error)
            scenes = []
        }
        isLoading = false
    }

    /// Сцена, содержащая указанный момент времени (для правой панели таймлайна).
    func scene(for time: Date) async -> ActivityScene? {
        try? await service.scene(containing: time)
    }
}
