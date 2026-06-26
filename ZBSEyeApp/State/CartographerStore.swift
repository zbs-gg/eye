import Foundation
import Observation

/// UI-состояние раздела «Картограф»: инсайты дня + busy/ошибка. @MainActor @Observable — по
/// паттерну AskStore/DaySummaryStore. Генерацию делегирует CartographerService (actor).
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

    /// Какой день выбран для анализа (по умолчанию — сегодня).
    var selectedDay: Date = Calendar.current.startOfDay(for: Date()) {
        didSet {
            guard Calendar.current.startOfDay(for: selectedDay)
                    != Calendar.current.startOfDay(for: oldValue) else { return }
            // Смена дня → сбрасываем предыдущий результат (он был за другой день).
            insights = nil; errorText = nil
            if phase != .loading { phase = .idle }
        }
    }

    var isBusy: Bool { phase == .loading }

    /// LLM настроена и локальная — показываем кнопку генерации, иначе подсказку.
    var llmReady: Bool { connections.llm.isConfigured && connections.llm.isLocalOnly }

    @ObservationIgnored private let service: CartographerService
    @ObservationIgnored private let connections: ConnectionStore
    @ObservationIgnored private var generateTask: Task<Void, Never>?

    init(service: CartographerService, connections: ConnectionStore) {
        self.service = service
        self.connections = connections
    }

    // MARK: — действия

    func generate() {
        guard !isBusy else { return }
        generateTask?.cancel()
        generateTask = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        generateTask?.cancel()
        generateTask = nil
        if phase == .loading { phase = .idle }
    }

    // MARK: — внутреннее

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
            if Task.isCancelled { phase = .idle; return }
            insights = result
            phase = .done
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
