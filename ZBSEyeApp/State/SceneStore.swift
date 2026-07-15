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
    @ObservationIgnored private let readiness: any AIConsumerReadinessProviding

    var scenes: [ActivityScene] = []          // all scenes of the day (system ones flagged)
    var blocks: [ActivityBlock] = []          // merged user activity — the top-level UI unit
    var systemScenes: [ActivityScene] = []    // filtered entries, shown only by the debug toggle
    /// block.id → LLM one-liner; arrives asynchronously, UI falls back to the heuristic label.
    var llmLabels: [String: String] = [:]
    /// Identity stays next to every generated label even though labels are
    /// session-only UI data. This prevents local/cloud/model attribution from
    /// being lost when the active pair later changes.
    var llmLabelProvenance: [String: AIExecutionProvenance] = [:]
    var llmLabelPromptVersions: [String: String] = [:]
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
         labeler: BlockLabelService,
         readiness: any AIConsumerReadinessProviding) {
        self.service = service
        self.timeline = timeline
        self.labeler = labeler
        self.readiness = readiness
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
            llmLabelProvenance = [:]
            llmLabelPromptVersions = [:]
            requestLLMLabels(day: day, blocks: blocks, gen: gen)
        } catch {
            guard gen == loadGeneration else { return }
            self.error = String(describing: error)
            scenes = []; blocks = []; systemScenes = []; llmLabels = [:]
            llmLabelProvenance = [:]; llmLabelPromptVersions = [:]
        }
        if gen == loadGeneration { isLoading = false }
    }

    /// The scene containing the exact visible frame (for the timeline's right panel).
    func scene(for frame: FrameDetail) async -> ActivityScene? {
        try? await service.scene(containingCaptureID: frame.id, at: frame.ts)
    }

    // MARK: - LLM block labels (optional, heuristic fallback always shown)

    /// Kick off one-liner generation only when the generated-label consumer is
    /// explicitly authorized. A migrated legacy cloud grant excludes this
    /// automatic scope, so it produces zero background dispatch.
    /// Sequential on purpose: don't hammer a local model with N parallel requests. Results are
    /// cached per (day, block-range) inside BlockLabelService — a re-render never re-asks.
    private func requestLLMLabels(day: Date, blocks: [ActivityBlock], gen: Int) {
        labelTask?.cancel()
        guard UserDefaults.standard.bool(forKey: "zbseye.cartographer.consent"),
              let execution = readiness.currentExecutionContext(for: .generatedLabels) else { return }
        labelTask = Task { [weak self] in
            for block in blocks {
                guard let self, !Task.isCancelled, gen == self.loadGeneration,
                      self.readiness.currentExecutionContext(for: .generatedLabels) == execution else { return }
                let requestID = UUID()
                guard let generated = await self.labeler.label(
                    day: day,
                    block: block,
                    execution: execution,
                    requestID: requestID
                ) else { continue }
                guard !Task.isCancelled, gen == self.loadGeneration,
                      self.readiness.currentExecutionContext(for: .generatedLabels) == execution else { return }
                self.llmLabels[block.id] = generated.text
                self.llmLabelProvenance[block.id] = generated.provenance
                self.llmLabelPromptVersions[block.id] = generated.promptVersion
            }
        }
    }
}
