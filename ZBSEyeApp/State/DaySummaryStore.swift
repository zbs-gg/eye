import Foundation
import Observation
import AppKit
import UserNotifications

/// UI state for the "day summary" automation. The flow is strictly preview-then-write (plan: firstRunRequiresPreview):
/// first "Build preview" (collect+LLM, no write) → the user sees the result → "Write".
/// This way private history and any possible prompt injection never reach a file without explicit confirmation.
@MainActor
@Observable
final class DaySummaryStore {
    enum Phase: Sendable, Equatable { case idle, summarizing, writing, done, failed }

    @ObservationIgnored private let service: DailySummaryService
    @ObservationIgnored let connections: ConnectionStore
    @ObservationIgnored private let safety: AutomationSafety = .default
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    /// A preview is valid only for the day it was built for. Changing the day in the DatePicker clears the preview and
    /// the write card — otherwise the "Write" button would promise a new day but write the old preview.
    // ── schedule: "summary writes itself at the end of the day" (US-33). Auto-write only after ≥1 manual write —
    //    a first-run preview is mandatory (prompt-injection gate from the automations design). ──
    var scheduleEnabled: Bool = UserDefaults.standard.bool(forKey: "zbseye.automation.scheduleEnabled") {
        didSet {
            UserDefaults.standard.set(scheduleEnabled, forKey: "zbseye.automation.scheduleEnabled")
            if scheduleEnabled {
                Self.requestNotificationAuth()
                // baseline = yesterday: enabling the schedule must not immediately generate a catch-up
                if UserDefaults.standard.string(forKey: "zbseye.automation.lastAutoDone") == nil {
                    let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                    UserDefaults.standard.set(DailySummaryService.ymd(y), forKey: "zbseye.automation.lastAutoDone")
                }
            }
        }
    }
    var scheduleHour: Int = UserDefaults.standard.object(forKey: "zbseye.automation.scheduleHour") == nil
        ? 21 : UserDefaults.standard.integer(forKey: "zbseye.automation.scheduleHour") {
        didSet { UserDefaults.standard.set(scheduleHour, forKey: "zbseye.automation.scheduleHour") }
    }
    var autoWriteEnabled: Bool = UserDefaults.standard.bool(forKey: "zbseye.automation.autoWrite") {
        didSet { UserDefaults.standard.set(autoWriteEnabled, forKey: "zbseye.automation.autoWrite") }
    }
    /// Whether there has been at least one MANUAL write (the user saw and approved the format) — the gate for auto-write.
    private(set) var hasWrittenManually = UserDefaults.standard.bool(forKey: "zbseye.automation.manualWriteDone")
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

    /// Start the preview while holding onto the Task — so a long local-model call can be cancelled.
    func startPreview() {
        guard !isBusy else { return }
        previewTask?.cancel()
        previewTask = Task { [weak self] in await self?.buildPreview() }
    }

    func cancelPreview() { previewTask?.cancel() }

    /// Privacy (Pro NO-GO follow-up): clear the collected preview/write — it is an LLM inference over the history
    /// that was just deleted (deleteHistory). We don't touch the schedule/settings/audit.
    func reset() {
        previewTask?.cancel()
        preview = nil
        lastWrite = nil
        errorText = nil
        phase = .idle
    }

    /// The collect+summarize stages. Does NOT write. Call via startPreview (for cancellability).
    func buildPreview() async {
        guard !isBusy else { return }
        errorText = nil; lastWrite = nil; preview = nil
        guard connections.llm.isConfigured, connections.llm.isLocalOnly else {
            errorText = AutomationError.noLLM.errorDescription; phase = .failed; return
        }
        phase = .summarizing
        do {
            let p = try await service.preview(day: selectedDay, llm: connections.llm, safety: safety)
            if Task.isCancelled { phase = .idle; return }   // cancelled during the request — no error
            preview = p; phase = .done
        } catch is CancellationError {
            phase = .idle
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            phase = .idle
        } catch {
            errorText = (error as? AutomationError)?.errorDescription ?? error.localizedDescription
            phase = .failed
        }
        await refreshAudit()
    }

    /// Write the confirmed preview into the selected folder.
    func writeApproved() async {
        guard let p = preview, !isBusy else { return }
        guard let url = connections.resolveDestinationURL() else {
            errorText = AutomationError.noDestination.errorDescription; phase = .failed; return
        }
        phase = .writing
        do {
            lastWrite = try await service.write(preview: p, destinationURL: url,
                                                subfolder: connections.destination.subfolder)
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

    // MARK: schedule

    /// Ticks once every 5 minutes: after scheduleHour, once a day. Started from bootstrap.
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
        let done = UserDefaults.standard.string(forKey: "zbseye.automation.lastAutoDone") ?? yesterdayYmd

        // Target of the run: a catch-up for YESTERDAY (the Mac was asleep at scheduleHour — the day must not be lost;
        // yesterday's history is already complete, no hour gate needed), otherwise today after scheduleHour.
        let targetDay: Date
        let targetYmd: String
        if done < yesterdayYmd {
            targetDay = cal.startOfDay(for: yesterday); targetYmd = yesterdayYmd
        } else if done < todayYmd && cal.component(.hour, from: now) >= scheduleHour {
            targetDay = cal.startOfDay(for: now); targetYmd = todayYmd
        } else {
            return
        }

        // Retries: a transient failure (Ollama not yet up at 21:00) must not kill the day — up to 3 attempts
        // with a ≥15-minute step. A success commits the day for good.
        let attemptDay = UserDefaults.standard.string(forKey: "zbseye.automation.attemptDay")
        var attempts = attemptDay == targetYmd ? UserDefaults.standard.integer(forKey: "zbseye.automation.attemptCount") : 0
        let lastAttempt = UserDefaults.standard.object(forKey: "zbseye.automation.lastAttemptAt") as? Date ?? .distantPast
        guard attempts < 3, now.timeIntervalSince(lastAttempt) >= 900 || attempts == 0 else { return }
        attempts += 1
        UserDefaults.standard.set(targetYmd, forKey: "zbseye.automation.attemptDay")
        UserDefaults.standard.set(attempts, forKey: "zbseye.automation.attemptCount")
        UserDefaults.standard.set(now, forKey: "zbseye.automation.lastAttemptAt")

        // Don't overwrite the user's work: if they're looking at a DIFFERENT day with a built preview — don't touch
        // their selection (didSet would wipe the preview), just nudge with a notification.
        if preview != nil && cal.startOfDay(for: selectedDay) != targetDay {
            UserDefaults.standard.set(targetYmd, forKey: "zbseye.automation.lastAutoDone")
            Self.notify(title: "ZBS Eye", body: "Time to build the summary (\(targetYmd)) — open Automations.")
            return
        }

        selectedDay = targetDay
        // via previewTask — the "Cancel" button also applies to a scheduled run
        previewTask?.cancel()
        previewTask = Task { [weak self] in await self?.buildPreview() }
        await previewTask?.value
        guard preview != nil, phase == .done else {
            if attempts >= 3 {
                Self.notify(title: "ZBS Eye", body: "The summary (\(targetYmd)) didn't build after 3 attempts — open Automations (\(errorText ?? "error")).")
                UserDefaults.standard.set(targetYmd, forKey: "zbseye.automation.lastAutoDone")
            }
            return   // attempts < 3 → next attempt in ≥15 min
        }
        UserDefaults.standard.set(targetYmd, forKey: "zbseye.automation.lastAutoDone")
        if autoWriteEnabled && hasWrittenManually {
            await writeApproved()
            Self.notify(title: "ZBS Eye", body: lastWrite != nil
                ? "The summary (\(targetYmd)) was written to \(connections.destination.subfolder.isEmpty ? "the folder" : connections.destination.subfolder)."
                : "The summary was built, but the write failed — open Automations.")
        } else {
            Self.notify(title: "ZBS Eye", body: "The summary (\(targetYmd)) is ready — open Automations, review it and write.")
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
