import AppKit
import Foundation
import Observation
import UserNotifications

/// Timeline Review state. Generation always saves the successful result inside
/// Eye; exporting that result to a user folder remains an explicit second step.
@MainActor
@Observable
final class DaySummaryStore {
    enum Phase: Sendable, Equatable { case idle, summarizing, writing, done, failed }

    @ObservationIgnored private let service: DailySummaryService
    @ObservationIgnored let connections: ConnectionStore
    @ObservationIgnored private let readiness: any AIConsumerReadinessProviding
    @ObservationIgnored private let safety: AutomationSafety = .default
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var activeRequest: AIConsumerRequestOwnership?
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?

    var scheduleEnabled: Bool = UserDefaults.standard.bool(forKey: "zbseye.review.scheduleEnabled") {
        didSet {
            UserDefaults.standard.set(scheduleEnabled, forKey: "zbseye.review.scheduleEnabled")
            if scheduleEnabled {
                Self.requestNotificationAuth()
                if UserDefaults.standard.string(forKey: "zbseye.review.lastAutoDone") == nil,
                   let due = ReviewSchedulePolicy.latestDuePeriod(
                       now: Date(), frequency: scheduleFrequency,
                       hour: scheduleHour, weeklyWeekday: weeklyWeekday
                   ) {
                    UserDefaults.standard.set(
                        DailySummaryService.periodKey(due),
                        forKey: "zbseye.review.lastAutoDone"
                    )
                }
            }
        }
    }
    var scheduleFrequency: ReviewScheduleFrequency = ReviewScheduleFrequency(
        rawValue: UserDefaults.standard.string(forKey: "zbseye.review.scheduleFrequency") ?? ""
    ) ?? .daily {
        didSet {
            UserDefaults.standard.set(scheduleFrequency.rawValue, forKey: "zbseye.review.scheduleFrequency")
        }
    }
    var scheduleHour: Int = UserDefaults.standard.object(forKey: "zbseye.review.scheduleHour") == nil
        ? (UserDefaults.standard.object(forKey: "zbseye.automation.scheduleHour") == nil
            ? 18 : UserDefaults.standard.integer(forKey: "zbseye.automation.scheduleHour"))
        : UserDefaults.standard.integer(forKey: "zbseye.review.scheduleHour") {
        didSet { UserDefaults.standard.set(scheduleHour, forKey: "zbseye.review.scheduleHour") }
    }
    /// Calendar weekday: 1 Sunday … 6 Friday … 7 Saturday.
    var weeklyWeekday: Int = UserDefaults.standard.object(forKey: "zbseye.review.weeklyWeekday") == nil
        ? 6 : UserDefaults.standard.integer(forKey: "zbseye.review.weeklyWeekday") {
        didSet { UserDefaults.standard.set(weeklyWeekday, forKey: "zbseye.review.weeklyWeekday") }
    }
    var autoWriteEnabled: Bool = UserDefaults.standard.bool(forKey: "zbseye.automation.autoWrite") {
        didSet { UserDefaults.standard.set(autoWriteEnabled, forKey: "zbseye.automation.autoWrite") }
    }
    private(set) var hasWrittenManually = UserDefaults.standard.bool(forKey: "zbseye.automation.manualWriteDone")

    var selectedDay: Date = Calendar.current.startOfDay(for: Date()) {
        didSet {
            guard Calendar.current.startOfDay(for: selectedDay)
                    != Calendar.current.startOfDay(for: oldValue) else { return }
            selectionChanged()
        }
    }
    var selectedPeriodKind: ReviewPeriodKind = .day {
        didSet { if selectedPeriodKind != oldValue { selectionChanged() } }
    }
    var phase: Phase = .idle
    var preview: SummaryPreview?
    var lastWrite: WriteResult?
    var errorText: String?
    var audit: [AuditEntry] = []

    init(
        service: DailySummaryService,
        connections: ConnectionStore,
        readiness: any AIConsumerReadinessProviding
    ) {
        self.service = service
        self.connections = connections
        self.readiness = readiness
        // Migrate the shipped on/off preference without creating a catch-up.
        let defaults = UserDefaults.standard
        let latestDueKey = ReviewSchedulePolicy.latestDuePeriod(
            now: Date(),
            frequency: scheduleFrequency,
            hour: scheduleHour,
            weeklyWeekday: weeklyWeekday
        ).map(DailySummaryService.periodKey)
        let migration = ReviewSchedulePreferenceMigration.resolve(
            explicitReviewEnabled: defaults.object(forKey: "zbseye.review.scheduleEnabled") == nil
                ? nil
                : defaults.bool(forKey: "zbseye.review.scheduleEnabled"),
            legacyEnabled: defaults.bool(forKey: "zbseye.automation.scheduleEnabled"),
            lastAutoDone: defaults.string(forKey: "zbseye.review.lastAutoDone"),
            latestDueKey: latestDueKey
        )
        scheduleEnabled = migration.enabled
        if migration.shouldPersistEnabled {
            // Property observers do not run during initialization. Persist the
            // migration explicitly and seed the cursor so enabling an upgraded
            // profile never launches an immediate historical catch-up.
            defaults.set(migration.enabled, forKey: "zbseye.review.scheduleEnabled")
            if let seeded = migration.seededLastAutoDone {
                defaults.set(seeded, forKey: "zbseye.review.lastAutoDone")
            }
        }
    }

    var isBusy: Bool { phase == .summarizing || phase == .writing }
    var llmReady: Bool { readiness.currentExecutionContext(for: .manualSummary) != nil }
    var isReady: Bool { llmReady }
    var canExport: Bool { connections.destination.isConfigured }
    var currentPeriod: ReviewPeriod {
        .ending(at: selectedDay, kind: selectedPeriodKind)
    }

    func startPreview() {
        guard !isBusy else { return }
        previewTask?.cancel()
        let period = currentPeriod
        previewTask = Task { [weak self] in
            await self?.buildPreview(period: period, consumer: .manualSummary)
        }
    }

    func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        activeRequest = nil
        if phase == .summarizing { phase = .idle }
    }

    func loadSavedSummary() async {
        guard !isBusy else { return }
        let period = currentPeriod
        if let saved = await service.savedSummary(for: period), currentPeriod == period {
            preview = SummaryPreview(saved: saved)
            phase = .done
        } else if currentPeriod == period {
            preview = nil
            phase = .idle
        }
    }

    func reset() {
        previewTask?.cancel()
        loadTask?.cancel()
        previewTask = nil
        loadTask = nil
        activeRequest = nil
        preview = nil
        lastWrite = nil
        errorText = nil
        phase = .idle
    }

    func buildPreview(
        period: ReviewPeriod? = nil,
        consumer: AIConsumer = .manualSummary
    ) async {
        guard !isBusy,
              consumer == .manualSummary || consumer == .scheduledSummary else { return }
        errorText = nil
        lastWrite = nil
        let target = period ?? currentPeriod
        guard let execution = readiness.currentExecutionContext(for: consumer) else {
            errorText = AutomationError.noLLM.errorDescription
            phase = .failed
            return
        }
        phase = .summarizing
        let requestID = UUID()
        let ownership = AIConsumerRequestOwnership(
            requestID: requestID,
            consumer: consumer,
            execution: execution
        )
        activeRequest = ownership
        do {
            let result = try await service.preview(
                period: target,
                execution: execution,
                consumer: consumer,
                requestID: requestID,
                safety: safety,
                trigger: consumer == .scheduledSummary ? .scheduled : .manual
            )
            guard !Task.isCancelled,
                  activeRequest == ownership,
                  ownership.accepts(
                      requestID: requestID,
                      consumer: consumer,
                      execution: readiness.currentExecutionContext(for: consumer)
                  ) else {
                if activeRequest == ownership { activeRequest = nil; phase = .idle }
                return
            }
            if currentPeriod == target { preview = result }
            phase = .done
            activeRequest = nil
        } catch is CancellationError {
            if activeRequest == ownership { activeRequest = nil; phase = .idle }
        } catch let error as URLError where error.code == .cancelled {
            if activeRequest == ownership { activeRequest = nil; phase = .idle }
        } catch {
            guard activeRequest == ownership else { return }
            errorText = (error as? AutomationError)?.errorDescription ?? error.localizedDescription
            phase = .failed
            activeRequest = nil
        }
        await refreshAudit()
    }

    func writeApproved() async {
        guard let preview, !isBusy else { return }
        guard let url = connections.resolveDestinationURL() else {
            errorText = AutomationError.noDestination.errorDescription
            phase = .failed
            return
        }
        phase = .writing
        do {
            lastWrite = try await service.write(
                preview: preview,
                destinationURL: url,
                subfolder: connections.destination.subfolder
            )
            phase = .done
            if !hasWrittenManually {
                hasWrittenManually = true
                UserDefaults.standard.set(true, forKey: "zbseye.automation.manualWriteDone")
            }
        } catch {
            errorText = (error as? AutomationError)?.errorDescription ?? error.localizedDescription
            phase = .failed
        }
        await refreshAudit()
    }

    func refreshAudit() async { audit = await service.recentAudit() }

    func startScheduler() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            await self?.scheduledTick()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await self?.scheduledTick()
            }
        }
    }

    private func scheduledTick() async {
        guard scheduleEnabled,
              let execution = readiness.currentExecutionContext(for: .scheduledSummary),
              !isBusy,
              let target = ReviewSchedulePolicy.latestDuePeriod(
                  now: Date(), frequency: scheduleFrequency,
                  hour: scheduleHour, weeklyWeekday: weeklyWeekday
              ) else { return }
        let key = DailySummaryService.periodKey(target)
        guard UserDefaults.standard.string(forKey: "zbseye.review.lastAutoDone") != key else { return }

        let attemptKey = UserDefaults.standard.string(forKey: "zbseye.review.attemptPeriod")
        var attempts = attemptKey == key
            ? UserDefaults.standard.integer(forKey: "zbseye.review.attemptCount") : 0
        let lastAttempt = UserDefaults.standard.object(forKey: "zbseye.review.lastAttemptAt") as? Date
            ?? .distantPast
        guard attempts < 3, attempts == 0 || Date().timeIntervalSince(lastAttempt) >= 900 else { return }
        attempts += 1
        UserDefaults.standard.set(key, forKey: "zbseye.review.attemptPeriod")
        UserDefaults.standard.set(attempts, forKey: "zbseye.review.attemptCount")
        UserDefaults.standard.set(Date(), forKey: "zbseye.review.lastAttemptAt")

        do {
            let result = try await service.preview(
                period: target,
                execution: execution,
                consumer: .scheduledSummary,
                safety: safety,
                trigger: .scheduled
            )
            UserDefaults.standard.set(key, forKey: "zbseye.review.lastAutoDone")
            if currentPeriod == target {
                preview = result
                phase = .done
            }
            if autoWriteEnabled, hasWrittenManually,
               let destination = connections.resolveDestinationURL() {
                _ = try? await service.write(
                    preview: result,
                    destinationURL: destination,
                    subfolder: connections.destination.subfolder
                )
            }
            Self.notify(title: "ZBS Eye", body: "Review \(key) is ready in Timeline.")
        } catch {
            if attempts >= 3 {
                UserDefaults.standard.set(key, forKey: "zbseye.review.lastAutoDone")
                Self.notify(
                    title: "ZBS Eye",
                    body: "Review \(key) did not build after three attempts."
                )
            }
        }
    }

    private func selectionChanged() {
        previewTask?.cancel()
        loadTask?.cancel()
        activeRequest = nil
        preview = nil
        lastWrite = nil
        errorText = nil
        phase = .idle
        loadTask = Task { [weak self] in await self?.loadSavedSummary() }
    }

    private static func requestNotificationAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func revealLastWrite() {
        guard let path = lastWrite?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
