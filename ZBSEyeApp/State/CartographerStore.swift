import Foundation
import Observation

/// UI state for the "Cartographer" section: insights of the day + busy/error. @MainActor @Observable — following
/// the AskStore/DaySummaryStore pattern. Delegates generation to CartographerService (actor).
@MainActor
@Observable
final class CartographerStore {
    enum Phase: Sendable, Equatable {
        case idle
        case loading
        case done
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var insights: CartographerService.Insights?
    private(set) var errorText: String?

    /// Heuristic day summary (top apps / active time / context switches), computed on-device with NO LLM.
    /// Shown when no processing model is configured, so the screen is never blank.
    private(set) var heuristicActivity: CartographerService.DayActivity?

    /// Which day is selected for analysis (today by default).
    var selectedDay: Date = Calendar.current.startOfDay(for: Date()) {
        didSet {
            guard Calendar.current.startOfDay(for: selectedDay)
                    != Calendar.current.startOfDay(for: oldValue) else { return }
            // Day changed → reset the previous result (it was for a different day).
            insights = nil; errorText = nil; heuristicActivity = nil
            if phase != .loading { phase = .idle }
        }
    }

    var isBusy: Bool { phase == .loading }

    /// A processing model is active in "AI Models" — show the generate button, otherwise a hint.
    var llmReady: Bool { ai.activeConfig != nil }

    /// First-run consent (Pro #13): until explicit consent, daily screen fragments do NOT go to the local
    /// LLM. The UI shows a consent card; generation is blocked.
    private(set) var hasConsent: Bool = UserDefaults.standard.bool(forKey: "zbseye.cartographer.consent")

    /// The user consented — record it and start generation right away.
    func grantConsentAndGenerate() {
        UserDefaults.standard.set(true, forKey: "zbseye.cartographer.consent")
        hasConsent = true
        generate()
    }

    @ObservationIgnored private let service: CartographerService
    @ObservationIgnored private let ai: AIProviderStore
    @ObservationIgnored private var generateTask: Task<Void, Never>?

    init(service: CartographerService, ai: AIProviderStore) {
        self.service = service
        self.ai = ai
    }

    // MARK: — actions

    /// Called when the view appears (and when the day changes). With a model + prior consent, insights
    /// generate automatically (no manual "Get insights" click). Without a model, compute the heuristic
    /// summary so the screen is never empty.
    func autoRefresh() {
        if llmReady {
            heuristicActivity = nil
            if hasConsent, insights == nil, phase == .idle { generate() }
        } else {
            Task { await refreshHeuristic() }
        }
    }

    /// On-device day summary via CartographerService.collect (no LLM, no egress).
    func refreshHeuristic() async {
        let day = selectedDay
        let activity = try? await service.collect(day: day)
        // Guard against a day change while we were collecting.
        guard Calendar.current.startOfDay(for: selectedDay)
                == Calendar.current.startOfDay(for: day) else { return }
        heuristicActivity = activity
    }

    func generate() {
        guard hasConsent, !isBusy else { return }   // without explicit consent, fragments don't go to the LLM
        generateTask?.cancel()
        generateTask = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        generateTask?.cancel()
        generateTask = nil
        if phase == .loading { phase = .idle }
    }

    /// Privacy: reset the insights entirely — the history they were built on has been deleted.
    /// Called from AppEnvironment.deleteHistory.
    func reset() {
        generateTask?.cancel()
        generateTask = nil
        insights = nil
        errorText = nil
        heuristicActivity = nil
        phase = .idle
    }

    // MARK: — internal

    private func run() async {
        errorText = nil; insights = nil
        guard let llm = ai.activeConfig else {
            errorText = AutomationError.noLLM.errorDescription
            phase = .failed
            return
        }
        phase = .loading
        let day = selectedDay
        do {
            let result = try await service.generate(day: day, llm: llm)
            // Race: while we were generating, the selected day could have changed or a cancellation arrived.
            // Don't overwrite the result with another day's (otherwise yesterday's insights show under today).
            guard !Task.isCancelled,
                  Calendar.current.startOfDay(for: selectedDay)
                    == Calendar.current.startOfDay(for: day) else { phase = .idle; return }
            insights = result
            phase = .done
            AchievementCounters.bump(.cartographerRuns)   // Cartographer achievements
        } catch is CancellationError {
            phase = .idle
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            phase = .idle
        } catch {
            errorText = (error as? AutomationError)?.errorDescription ?? error.localizedDescription
            phase = .failed
        }
    }
}
