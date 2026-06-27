import Foundation
import Observation

/// "Day in activities" store: segmented scenes for the current day.
/// @MainActor @Observable — same pattern as TimelineStore/AskStore.
@MainActor
@Observable
final class SceneStore {
    @ObservationIgnored private let service: SceneService
    @ObservationIgnored private let timeline: TimelineService

    var scenes: [ActivityScene] = []
    var isLoading = false
    var error: String?

    /// The day whose activities we show (nil = today / tail of history).
    var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    /// Load generation: the latest load() call wins. Guards against a race where a fast
    /// repeat load() (day change / repeat appear) lets two requests overwrite each other
    /// out of order — an old result must not clobber the new day.
    @ObservationIgnored private var loadGeneration = 0

    init(service: SceneService, timeline: TimelineService) {
        self.service = service
        self.timeline = timeline
    }

    /// Loads scenes for `selectedDay`. Called on day change and on view appear.
    func load() async {
        loadGeneration += 1
        let gen = loadGeneration
        let day = selectedDay
        isLoading = true
        error = nil
        do {
            let result = try await service.scenes(forDay: day)
            guard gen == loadGeneration else { return }   // stale — a newer load() arrived
            scenes = result
        } catch {
            guard gen == loadGeneration else { return }
            self.error = String(describing: error)
            scenes = []
        }
        if gen == loadGeneration { isLoading = false }
    }

    /// The scene containing the given moment in time (for the timeline's right panel).
    func scene(for time: Date) async -> ActivityScene? {
        try? await service.scene(containing: time)
    }
}
