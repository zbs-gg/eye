import Foundation
import Observation

/// "Day in activities" store: segmented scenes for the current day, grouped into activity BLOCKS
/// (what the user was plausibly doing). System shells are kept separately for the debug toggle.
/// @MainActor @Observable — same pattern as TimelineStore/AskStore.
@MainActor
@Observable
final class SceneStore {
    @ObservationIgnored private let service: SceneService
    @ObservationIgnored private let timeline: TimelineService
    @ObservationIgnored private let labeler: BlockLabelService
    @ObservationIgnored private let connections: ConnectionStore

    var scenes: [ActivityScene] = []          // all scenes of the day (system ones flagged)
    var blocks: [ActivityBlock] = []          // merged user activity — the top-level UI unit
    var systemScenes: [ActivityScene] = []    // filtered entries, shown only by the debug toggle
    /// block.id → LLM one-liner; arrives asynchronously, UI falls back to the heuristic label.
    var llmLabels: [String: String] = [:]
    /// "Show system events" debug toggle (default OFF), persisted like other view prefs.
    var showSystemEvents = UserDefaults.standard.bool(forKey: "zbseye.activities.showSystem") {
        didSet { UserDefaults.standard.set(showSystemEvents, forKey: "zbseye.activities.showSystem") }
    }
    var isLoading = false
    var error: String?

    /// The day whose activities we show (nil = today / tail of history).
    var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    /// Load generation: the latest load() call wins. Guards against a race where a fast
    /// repeat load() (day change / repeat appear) lets two requests overwrite each other
    /// out of order — an old result must not clobber the new day.
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var labelTask: Task<Void, Never>?

    init(service: SceneService, timeline: TimelineService,
         labeler: BlockLabelService, connections: ConnectionStore) {
        self.service = service
        self.timeline = timeline
        self.labeler = labeler
        self.connections = connections
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
            systemScenes = result.filter(\.isSystem)
            blocks = ActivityBlockBuilder.blocks(from: result)
            llmLabels = [:]
            requestLLMLabels(day: day, blocks: blocks, gen: gen)
        } catch {
            guard gen == loadGeneration else { return }
            self.error = String(describing: error)
            scenes = []; blocks = []; systemScenes = []; llmLabels = [:]
        }
        if gen == loadGeneration { isLoading = false }
    }

    /// The scene containing the given moment in time (for the timeline's right panel).
    func scene(for time: Date) async -> ActivityScene? {
        try? await service.scene(containing: time)
    }

    // MARK: - LLM block labels (optional, heuristic fallback always shown)

    /// Kick off one-liner generation for the day's blocks. Only when a LOCAL model is configured
    /// AND the user already consented to screen fragments going to the local LLM (the Cartographer
    /// consent, Pro #13 — Activities must not start sending titles/phrases before that explicit yes).
    /// Sequential on purpose: don't hammer a local model with N parallel requests. Results are
    /// cached per (day, block-range) inside BlockLabelService — a re-render never re-asks.
    private func requestLLMLabels(day: Date, blocks: [ActivityBlock], gen: Int) {
        labelTask?.cancel()
        guard connections.llm.isConfigured, connections.llm.isLocalOnly,
              UserDefaults.standard.bool(forKey: "zbseye.cartographer.consent") else { return }
        let llm = connections.llm
        labelTask = Task { [weak self] in
            for block in blocks {
                guard let self, !Task.isCancelled, gen == self.loadGeneration else { return }
                guard let line = await self.labeler.label(day: day, block: block, llm: llm) else { continue }
                guard !Task.isCancelled, gen == self.loadGeneration else { return }
                self.llmLabels[block.id] = line
            }
        }
    }
}
