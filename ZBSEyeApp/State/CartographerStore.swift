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
    var llmReady: Bool { readiness.currentExecutionContext(for: .dailyInsights) != nil }

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
    @ObservationIgnored private let readiness: any AIConsumerReadinessProviding
    @ObservationIgnored private var generateTask: Task<Void, Never>?
    @ObservationIgnored private var activeRequest: AIConsumerRequestOwnership?

    init(service: CartographerService, readiness: any AIConsumerReadinessProviding) {
        self.service = service
        self.readiness = readiness
    }

    // MARK: — actions

    /// Called when the view appears (and when the day changes). Opening the
    /// screen never starts generation, regardless of provider locality; Daily
    /// Insights always requires the explicit user action. Without a model,
    /// compute the on-device heuristic summary so the screen is never empty.
    func autoRefresh() {
        if llmReady {
            heuristicActivity = nil
        } else {
            // Collect the on-device summary once per selected day — not on every appear (Pro perf).
            // heuristicActivity is reset when the day changes (see selectedDay.didSet), so nil == "not
            // loaded for this day yet".
            guard heuristicActivity == nil else { return }
            Task { await refreshHeuristic() }
        }
    }

    /// On-device day summary via CartographerService.collectSummary (no LLM, no egress). Uses the LIGHT
    /// collection — the heuristic card never shows textSamples, so we skip fetching/sanitizing them.
    func refreshHeuristic() async {
        let day = selectedDay
        let activity = try? await service.collectSummary(day: day)
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
        activeRequest = nil
        if phase == .loading { phase = .idle }
    }

    /// Privacy: reset the insights entirely — the history they were built on has been deleted.
    /// Called from AppEnvironment.deleteHistory.
    func reset() {
        generateTask?.cancel()
        generateTask = nil
        activeRequest = nil
        insights = nil
        errorText = nil
        heuristicActivity = nil
        phase = .idle
    }

    // MARK: — internal

    private func run() async {
        errorText = nil; insights = nil
        guard let execution = readiness.currentExecutionContext(for: .dailyInsights) else {
            errorText = AutomationError.noLLM.errorDescription
            phase = .failed
            return
        }
        phase = .loading
        let day = selectedDay
        let requestID = UUID()
        let ownership = AIConsumerRequestOwnership(
            requestID: requestID,
            consumer: .dailyInsights,
            execution: execution
        )
        activeRequest = ownership
        do {
            let result = try await service.generate(
                day: day,
                execution: execution,
                requestID: requestID
            )
            // Race: while we were generating, the selected day could have changed or a cancellation arrived.
            // Don't overwrite the result with another day's (otherwise yesterday's insights show under today).
            guard !Task.isCancelled,
                  activeRequest == ownership,
                  ownership.accepts(
                      requestID: requestID,
                      consumer: .dailyInsights,
                      execution: readiness.currentExecutionContext(for: .dailyInsights)
                  ),
                  Calendar.current.startOfDay(for: selectedDay)
                    == Calendar.current.startOfDay(for: day) else {
                if activeRequest == ownership { activeRequest = nil; phase = .idle }
                return
            }
            insights = result
            phase = .done
            activeRequest = nil
            AchievementCounters.bump(.cartographerRuns)   // Cartographer achievements
        } catch is CancellationError {
            if activeRequest == ownership { activeRequest = nil; phase = .idle }
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            if activeRequest == ownership { activeRequest = nil; phase = .idle }
        } catch {
            guard activeRequest == ownership,
                  ownership.accepts(
                      requestID: requestID,
                      consumer: .dailyInsights,
                      execution: readiness.currentExecutionContext(for: .dailyInsights)
                  ) else {
                if activeRequest == ownership { activeRequest = nil; phase = .idle }
                return
            }
            errorText = (error as? AutomationError)?.errorDescription ?? error.localizedDescription
            phase = .failed
            activeRequest = nil
        }
    }
}
