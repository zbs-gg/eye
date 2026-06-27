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

    /// Which day is selected for analysis (today by default).
    var selectedDay: Date = Calendar.current.startOfDay(for: Date()) {
        didSet {
            guard Calendar.current.startOfDay(for: selectedDay)
                    != Calendar.current.startOfDay(for: oldValue) else { return }
            // Day changed → reset the previous result (it was for a different day).
            insights = nil; errorText = nil
            if phase != .loading { phase = .idle }
        }
    }

    var isBusy: Bool { phase == .loading }

    /// The LLM is configured and local — show the generate button, otherwise a hint.
    var llmReady: Bool { connections.llm.isConfigured && connections.llm.isLocalOnly }

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
    @ObservationIgnored private let connections: ConnectionStore
    @ObservationIgnored private var generateTask: Task<Void, Never>?

    init(service: CartographerService, connections: ConnectionStore) {
        self.service = service
        self.connections = connections
    }

    // MARK: — actions

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
        phase = .idle
    }

    // MARK: — internal

    private func run() async {
        errorText = nil; insights = nil
        guard connections.llm.isConfigured, connections.llm.isLocalOnly else {
            errorText = AutomationError.noLLM.errorDescription
            phase = .failed
            return
        }
        phase = .loading
        let day = selectedDay
        let llm = connections.llm
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
