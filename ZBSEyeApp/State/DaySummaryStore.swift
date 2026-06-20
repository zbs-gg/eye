import Foundation
import Observation
import AppKit
import UserNotifications

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
    // ── расписание: «конспект сам в конце дня» (US-33). Auto-write только после ≥1 ручной записи —
    //    first-run preview обязателен (prompt-injection гейт из дизайна pipes). ──
    var scheduleEnabled: Bool = UserDefaults.standard.bool(forKey: "zbseye.pipe.scheduleEnabled") {
        didSet {
            UserDefaults.standard.set(scheduleEnabled, forKey: "zbseye.pipe.scheduleEnabled")
            if scheduleEnabled {
                Self.requestNotificationAuth()
                // точка отсчёта = вчера: включение расписания не должно тут же генерить catch-up
                if UserDefaults.standard.string(forKey: "zbseye.pipe.lastAutoDone") == nil {
                    let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                    UserDefaults.standard.set(DailySummaryService.ymd(y), forKey: "zbseye.pipe.lastAutoDone")
                }
            }
        }
    }
    var scheduleHour: Int = UserDefaults.standard.object(forKey: "zbseye.pipe.scheduleHour") == nil
        ? 21 : UserDefaults.standard.integer(forKey: "zbseye.pipe.scheduleHour") {
        didSet { UserDefaults.standard.set(scheduleHour, forKey: "zbseye.pipe.scheduleHour") }
    }
    var autoWriteEnabled: Bool = UserDefaults.standard.bool(forKey: "zbseye.pipe.autoWrite") {
        didSet { UserDefaults.standard.set(autoWriteEnabled, forKey: "zbseye.pipe.autoWrite") }
    }
    /// Была ли хоть одна РУЧНАЯ запись (юзер видел и одобрил формат) — гейт для auto-write.
    private(set) var hasWrittenManually = UserDefaults.standard.bool(forKey: "zbseye.pipe.manualWriteDone")
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?

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
            if !hasWrittenManually {
                hasWrittenManually = true
                UserDefaults.standard.set(true, forKey: "zbseye.pipe.manualWriteDone")
            }
        } catch {
            errorText = (error as? PipeError)?.errorDescription ?? error.localizedDescription
            phase = .failed
        }
        await refreshAudit()
    }

    func refreshAudit() async { audit = await service.recentAudit() }

    // MARK: расписание

    /// Тик раз в 5 минут: после scheduleHour, один раз в день. Запуск из bootstrap.
    func startScheduler() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.scheduledTick()
            }
        }
    }

    private func scheduledTick() async {
        guard scheduleEnabled, isReady, !isBusy else { return }
        let now = Date()
        let cal = Calendar.current
        let todayYmd = DailySummaryService.ymd(now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: now) ?? now
        let yesterdayYmd = DailySummaryService.ymd(yesterday)
        let done = UserDefaults.standard.string(forKey: "zbseye.pipe.lastAutoDone") ?? yesterdayYmd

        // Цель прогона: catch-up за ВЧЕРА (Mac спал в scheduleHour — день не должен выпасть; история
        // вчера уже полная, hour-гейт не нужен), иначе сегодня после scheduleHour.
        let targetDay: Date
        let targetYmd: String
        if done < yesterdayYmd {
            targetDay = cal.startOfDay(for: yesterday); targetYmd = yesterdayYmd
        } else if done < todayYmd && cal.component(.hour, from: now) >= scheduleHour {
            targetDay = cal.startOfDay(for: now); targetYmd = todayYmd
        } else {
            return
        }

        // Ретраи: transient-фейл (Ollama ещё не поднят в 21:00) не должен убивать день — до 3 попыток
        // с шагом ≥15 минут. Успех фиксирует день окончательно.
        let attemptDay = UserDefaults.standard.string(forKey: "zbseye.pipe.attemptDay")
        var attempts = attemptDay == targetYmd ? UserDefaults.standard.integer(forKey: "zbseye.pipe.attemptCount") : 0
        let lastAttempt = UserDefaults.standard.object(forKey: "zbseye.pipe.lastAttemptAt") as? Date ?? .distantPast
        guard attempts < 3, now.timeIntervalSince(lastAttempt) >= 900 || attempts == 0 else { return }
        attempts += 1
        UserDefaults.standard.set(targetYmd, forKey: "zbseye.pipe.attemptDay")
        UserDefaults.standard.set(attempts, forKey: "zbseye.pipe.attemptCount")
        UserDefaults.standard.set(now, forKey: "zbseye.pipe.lastAttemptAt")

        // Не перетираем работу юзера: если он смотрит ДРУГОЙ день с собранным превью — не трогаем
        // его выбор (didSet снёс бы превью), просто зовём уведомлением.
        if preview != nil && cal.startOfDay(for: selectedDay) != targetDay {
            UserDefaults.standard.set(targetYmd, forKey: "zbseye.pipe.lastAutoDone")
            Self.notify(title: "ZBS Eye", body: "Пора собрать конспект (\(targetYmd)) — открой Плагины.")
            return
        }

        selectedDay = targetDay
        // через previewTask — кнопка «Отмена» действует и на scheduled-прогон
        previewTask?.cancel()
        previewTask = Task { [weak self] in await self?.buildPreview() }
        await previewTask?.value
        guard preview != nil, phase == .done else {
            if attempts >= 3 {
                Self.notify(title: "ZBS Eye", body: "Конспект (\(targetYmd)) не собрался после 3 попыток — открой Плагины (\(errorText ?? "ошибка")).")
                UserDefaults.standard.set(targetYmd, forKey: "zbseye.pipe.lastAutoDone")
            }
            return   // attempts < 3 → следующая попытка через ≥15 мин
        }
        UserDefaults.standard.set(targetYmd, forKey: "zbseye.pipe.lastAutoDone")
        if autoWriteEnabled && hasWrittenManually {
            await writeApproved()
            Self.notify(title: "ZBS Eye", body: lastWrite != nil
                ? "Конспект (\(targetYmd)) записан в \(connections.destination.subfolder.isEmpty ? "папку" : connections.destination.subfolder)."
                : "Конспект собран, но запись не удалась — открой Плагины.")
        } else {
            Self.notify(title: "ZBS Eye", body: "Конспект (\(targetYmd)) готов — открой Плагины, проверь и запиши.")
        }
    }

    private static func requestNotificationAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func revealLastWrite() {
        guard let path = lastWrite?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
