import Foundation
import Observation
import AppKit

/// UI-состояние pipe «саммари дня». Поток жёстко preview-then-write (план: firstRunRequiresPreview):
/// сначала «Собрать превью» (collect+LLM, без записи) → пользователь видит результат → «Записать».
/// Так приватная история и возможный prompt-injection не уходят в файл без явного подтверждения.
@MainActor
@Observable
final class DaySummaryStore {
    enum Phase: Sendable, Equatable { case idle, summarizing, writing, done, failed }

    @ObservationIgnored private let service: DailySummaryService
    @ObservationIgnored let connections: ConnectionStore
    @ObservationIgnored private let safety: PipeSafety = .default
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    /// Превью валидно только для дня, под который собрано. Смена дня в DatePicker обнуляет превью и
    /// карточку записи — иначе кнопка «Записать» обещала бы новый день, а записала бы старое превью.
    var selectedDay: Date = Calendar.current.startOfDay(for: Date()) {
        didSet {
            guard Calendar.current.startOfDay(for: selectedDay) != Calendar.current.startOfDay(for: oldValue)
            else { return }
            preview = nil; lastWrite = nil; errorText = nil
            if phase != .summarizing && phase != .writing { phase = .idle }
        }
    }
    var phase: Phase = .idle
    var preview: SummaryPreview?
    var lastWrite: WriteResult?
    var errorText: String?
    var audit: [AuditEntry] = []

    init(service: DailySummaryService, connections: ConnectionStore) {
        self.service = service
        self.connections = connections
    }

    var isBusy: Bool { phase == .summarizing || phase == .writing }
    var isReady: Bool { connections.isReady }

    /// Запуск превью с удержанием Task — чтобы долгий вызов локальной модели можно было отменить.
    func startPreview() {
        guard !isBusy else { return }
        previewTask?.cancel()
        previewTask = Task { [weak self] in await self?.buildPreview() }
    }

    func cancelPreview() { previewTask?.cancel() }

    /// Стадии collect+summarize. Запись НЕ делает. Вызывать через startPreview (для отменяемости).
    func buildPreview() async {
        guard !isBusy else { return }
        errorText = nil; lastWrite = nil; preview = nil
        guard connections.llm.isConfigured, connections.llm.isLocalOnly else {
            errorText = PipeError.noLLM.errorDescription; phase = .failed; return
        }
        phase = .summarizing
        do {
            let p = try await service.preview(day: selectedDay, llm: connections.llm, safety: safety)
            if Task.isCancelled { phase = .idle; return }   // отменили во время запроса — без ошибки
            preview = p; phase = .done
        } catch is CancellationError {
            phase = .idle
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            phase = .idle
        } catch {
            errorText = (error as? PipeError)?.errorDescription ?? error.localizedDescription
            phase = .failed
        }
        await refreshAudit()
    }

    /// Запись подтверждённого превью в выбранную папку.
    func writeApproved() async {
        guard let p = preview, !isBusy else { return }
        guard let url = connections.resolveDestinationURL() else {
            errorText = PipeError.noDestination.errorDescription; phase = .failed; return
        }
        phase = .writing
        do {
            lastWrite = try await service.write(preview: p, destinationURL: url,
                                                subfolder: connections.destination.subfolder)
            phase = .done
        } catch {
            errorText = (error as? PipeError)?.errorDescription ?? error.localizedDescription
            phase = .failed
        }
        await refreshAudit()
    }

    func refreshAudit() async { audit = await service.recentAudit() }

    func revealLastWrite() {
        guard let path = lastWrite?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
