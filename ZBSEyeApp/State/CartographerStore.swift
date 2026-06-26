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

    /// First-run consent (Pro #13): до явного согласия дневные фрагменты экрана НЕ уходят в локальную
    /// LLM. UI показывает consent-карточку; генерация заблокирована.
    private(set) var hasConsent: Bool = UserDefaults.standard.bool(forKey: "zbseye.cartographer.consent")

    /// Пользователь согласился — фиксируем и сразу запускаем генерацию.
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

    // MARK: — действия

    func generate() {
        guard hasConsent, !isBusy else { return }   // без явного согласия фрагменты в LLM не уходят
        generateTask?.cancel()
        generateTask = Task { [weak self] in await self?.run() }
    }

    func cancel() {
        generateTask?.cancel()
        generateTask = nil
        if phase == .loading { phase = .idle }
    }

    /// Privacy: сбросить инсайты целиком — историю, на которой они построены, удалили.
    /// Вызывается из AppEnvironment.deleteHistory.
    func reset() {
        generateTask?.cancel()
        generateTask = nil
        insights = nil
        errorText = nil
        phase = .idle
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
            // Гонка: пока генерили — мог смениться выбранный день или прийти отмена.
            // Не перезаписываем результат чужого дня (иначе инсайты вчера показываются под сегодня).
            guard !Task.isCancelled,
                  Calendar.current.startOfDay(for: selectedDay)
                    == Calendar.current.startOfDay(for: day) else { phase = .idle; return }
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
