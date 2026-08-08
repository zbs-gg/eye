import Foundation
import Observation

protocol ActivityDaySummaryCaching: Sendable {
    func snapshot(dayKey: String) async throws -> ActivityDaySummaryCacheSnapshot
    func replace(
        _ entry: ActivityDaySummaryCacheEntry,
        expectedInvalidationEpoch: Int64
    ) async throws -> Bool
}

extension ActivityDaySummaryRepository: ActivityDaySummaryCaching {}

struct ActivityDaySummaryContent: Sendable, Equatable {
    let bullets: [String]
    let providerID: String
    let modelID: String
    let executedLocally: Bool
    let brokerUpstream: String?
    let recipientDisclosure: String?
    let endpointDisclosure: String?
    let generatedAt: Date
}

/// Exact user-facing copy kept outside SwiftUI so the unhosted test target can
/// protect all summary-card states without launching an ad-hoc app.
enum ActivityDaySummaryPresentation {
    static let title = String(localized: "What I did")
    static let unavailable = String(localized: "Choose an Activity summary model in Settings → AI, or retry after it reconnects.")
    static let staleAndUnavailable = String(localized: "This recap is out of date. Reconnect the Activity summary model to update it.")
    static let loading = String(localized: "Summarizing this day…")
    static let updating = String(localized: "Updating…")
    static let noActivity = String(localized: "There is no activity to summarize for this day.")
    static let refresh = String(localized: "Refresh")
    static let retry = String(localized: "Retry")

    static func unavailableMessage(hasContent: Bool) -> String {
        hasContent ? staleAndUnavailable : unavailable
    }
}

@MainActor
@Observable
final class ActivityDaySummaryStore {
    private struct AutomaticAttemptKey: Hashable {
        let dayKey: String
        let sourceStartMs: Int64
        let sourceEndMs: Int64
        let selection: ProviderSelectionSnapshot
        let contextTokenCeiling: Int
        let executedLocally: Bool
        let recipientDisclosure: String?
        let endpointDisclosure: String?
        let endpointIdentity: String?

        init(
            input: ActivityDaySummaryInput,
            execution: AIConsumerExecutionContext,
            routeIdentity: ActivitySummaryRouteIdentity
        ) {
            dayKey = input.dayKey
            sourceStartMs = input.sourceStartMs
            sourceEndMs = input.sourceEndMs
            selection = execution.selection
            contextTokenCeiling = execution.contextTokenCeiling
            executedLocally = execution.executedLocally
            recipientDisclosure = execution.recipientDisclosure
            endpointDisclosure = routeIdentity.endpointDisclosure
            endpointIdentity = routeIdentity.endpointIdentity
        }
    }

    enum Phase: Sendable, Equatable {
        case idle
        case unavailable
        case loading
        case cached
        case updating
        case noActivity
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var selectedDay: Date
    private(set) var content: ActivityDaySummaryContent?
    private(set) var errorText: String?

    @ObservationIgnored private let service: any ActivityDaySummaryServicing
    @ObservationIgnored private let cache: any ActivityDaySummaryCaching
    @ObservationIgnored private let readiness: any AIConsumerReadinessProviding
    @ObservationIgnored private let fixedTimeZone: TimeZone?
    @ObservationIgnored private let timeZoneProvider: @Sendable () -> TimeZone
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var requestTask: Task<Void, Never>?
    @ObservationIgnored private var privacyDrainTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var activeRequest: AIConsumerRequestOwnership?
    @ObservationIgnored private var lastAutomaticAttempt: [AutomaticAttemptKey: Date] = [:]
    @ObservationIgnored private var privacyMutationDepth = 0

    init(
        service: any ActivityDaySummaryServicing,
        cache: any ActivityDaySummaryCaching,
        readiness: any AIConsumerReadinessProviding,
        timeZone: TimeZone? = nil,
        timeZoneProvider: @escaping @Sendable () -> TimeZone = { .current },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.service = service
        self.cache = cache
        self.readiness = readiness
        fixedTimeZone = timeZone
        self.timeZoneProvider = timeZoneProvider
        self.now = now
        let initialTimeZone = timeZone ?? timeZoneProvider()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = initialTimeZone
        selectedDay = calendar.startOfDay(for: now())
    }

    var hasContent: Bool { content != nil }
    var isBusy: Bool { phase == .loading || phase == .updating }

    /// Called only after the Activities list has loaded its selected day.
    /// Cancelling the previous task plus generation checks makes the latest day win.
    func load(day: Date) async {
        guard privacyMutationDepth == 0 else { return }
        await start(day: day, force: false)
    }

    /// Explicit refresh bypasses the current-day 30-minute automatic limit.
    func refresh() async {
        guard privacyMutationDepth == 0 else { return }
        await start(day: selectedDay, force: true)
    }

    /// Closes the egress gate before a privacy deletion starts, then waits until
    /// the current preparation/generation task can no longer dispatch or save.
    /// Nesting is supported so overlapping privacy operations cannot reopen it.
    func suspendAndDrainForPrivacyMutation() async {
        privacyMutationDepth += 1
        guard privacyMutationDepth == 1 else {
            await privacyDrainTask?.value
            return
        }

        loadGeneration += 1
        let task = requestTask
        privacyDrainTask = task
        requestTask = nil
        task?.cancel()
        activeRequest = nil
        content = nil
        errorText = nil
        phase = .idle
        await task?.value
        privacyDrainTask = nil
    }

    /// Must be paired with `suspendAndDrainForPrivacyMutation`, including the
    /// failure path of the deletion. Resetting keeps deleted derived text out of
    /// the open Activities surface; a later normal load rebuilds what remains.
    func resumeAfterPrivacyMutation(resetState: Bool = true) {
        guard privacyMutationDepth > 0 else { return }
        if resetState {
            content = nil
            errorText = nil
            phase = .idle
            lastAutomaticAttempt = [:]
        }
        privacyMutationDepth -= 1
    }

    func cancel() {
        loadGeneration += 1
        requestTask?.cancel()
        requestTask = nil
        activeRequest = nil
        if isBusy { phase = content == nil ? .idle : .cached }
    }

    /// Privacy/full-history deletion clears the derived UI state immediately;
    /// the repository owner separately deletes the durable rows transactionally.
    func reset() {
        cancel()
        content = nil
        errorText = nil
        phase = .idle
        lastAutomaticAttempt = [:]
    }

    var provenanceLabel: String? {
        guard let content else { return nil }
        if let recipient = content.recipientDisclosure {
            let upstream = content.brokerUpstream.map { " → \($0)" } ?? ""
            return String(localized: "Generated with \(recipient)\(upstream) · \(content.modelID)")
        }
        if content.executedLocally, let endpoint = content.endpointDisclosure {
            return String(localized: "Generated on this Mac via \(endpoint) · \(content.modelID)")
        }
        if content.executedLocally {
            return String(localized: "Generated on this Mac · \(content.modelID)")
        }
        let upstream = content.brokerUpstream.map { " → \($0)" } ?? ""
        return String(localized: "Generated with \(content.providerID)\(upstream) · \(content.modelID)")
    }

    private func start(day: Date, force: Bool) async {
        // Production follows a runtime system-timezone change, but one load must
        // use one immutable calendar boundary from normalization through save.
        let timeZone = fixedTimeZone ?? timeZoneProvider()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let normalizedDay = calendar.startOfDay(for: day)
        let changedDay = normalizedDay != selectedDay
        selectedDay = normalizedDay
        loadGeneration += 1
        let generation = loadGeneration
        requestTask?.cancel()
        activeRequest = nil
        if changedDay || force { errorText = nil }
        if changedDay {
            content = nil
            phase = .loading
        } else if content == nil {
            phase = .loading
        }

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.run(
                day: normalizedDay,
                timeZone: timeZone,
                force: force,
                generation: generation
            )
        }
        requestTask = task
        await task.value
        if generation == loadGeneration { requestTask = nil }
    }

    private func run(
        day: Date,
        timeZone: TimeZone,
        force: Bool,
        generation: Int
    ) async {
        let dayKey = ActivityDaySummaryDayKey.make(for: day, timeZone: timeZone)
        // The epoch must be captured before collecting source fragments. A
        // privacy/retention mutation after this point makes the eventual write
        // fail atomically instead of resurrecting deleted derived text.
        let cacheSnapshot: ActivityDaySummaryCacheSnapshot
        do {
            cacheSnapshot = try await cache.snapshot(dayKey: dayKey)
        } catch {
            finishFailure(error, generation: generation)
            return
        }
        guard accepts(generation) else { return }

        let input: ActivityDaySummaryInput
        do {
            input = try await service.prepare(day: day, timeZone: timeZone)
        } catch ActivityDaySummaryError.noActivity {
            guard accepts(generation) else { return }
            content = nil
            errorText = nil
            phase = .noActivity
            return
        } catch {
            finishFailure(error, generation: generation)
            return
        }
        guard accepts(generation) else { return }

        guard let routeIdentity = readiness.activitySummaryRouteIdentity() else {
            content = nil
            phase = .unavailable
            return
        }

        // A cache produced by another route or prompt is not an older version
        // of this summary. Never paint it, and never let its timestamp throttle
        // the newly selected model. Source drift under the same identity is the
        // only case where showing the old summary while updating is truthful.
        let cached: ActivityDaySummaryCacheEntry?
        if let fetchedCache = cacheSnapshot.entry,
           Self.hasCurrentIdentity(
               fetchedCache,
               input: input,
               routeIdentity: routeIdentity
           ),
           let cachedContent = Self.content(from: fetchedCache) {
            cached = fetchedCache
            content = cachedContent
            phase = .cached
        } else {
            cached = nil
            content = nil
        }

        if !force,
           let cached,
           cached.inputFingerprint == input.inputFingerprint {
            phase = .cached
            return
        }

        // A matching durable recap remains useful while its explicitly enabled
        // route is temporarily offline. Execution readiness is required only to
        // refresh changed source material, never to read unchanged local text.
        guard let execution = readiness.currentExecutionContext(for: .activitySummary),
              Self.execution(execution, matches: routeIdentity) else {
            errorText = nil
            phase = .unavailable
            return
        }

        let currentTime = now()
        if !force,
           isCurrentDay(day, at: currentTime, timeZone: timeZone),
           !mayAutomaticallyRefresh(
                input: input,
                cached: cached,
                execution: execution,
                routeIdentity: routeIdentity,
                at: currentTime
           ) {
            phase = content == nil
                ? (errorText == nil ? .idle : .failed)
                : .cached
            return
        }

        let automaticAttemptKey = AutomaticAttemptKey(
            input: input,
            execution: execution,
            routeIdentity: routeIdentity
        )
        if !force { lastAutomaticAttempt[automaticAttemptKey] = currentTime }
        errorText = nil
        phase = content == nil ? .loading : .updating
        let requestID = UUID()
        let ownership = AIConsumerRequestOwnership(
            requestID: requestID,
            consumer: .activitySummary,
            execution: execution
        )
        activeRequest = ownership

        do {
            let generated = try await service.generate(
                input: input,
                execution: execution,
                requestID: requestID
            )
            guard accepts(generation),
                  !Task.isCancelled,
                  activeRequest == ownership,
                  ownership.accepts(
                    requestID: requestID,
                    consumer: .activitySummary,
                    execution: readiness.currentExecutionContext(for: .activitySummary)
                  ) else {
                if accepts(generation), activeRequest == ownership {
                    activeRequest = nil
                    phase = content == nil ? .unavailable : .cached
                }
                return
            }

            let generatedAt = now()
            let entry = ActivityDaySummaryCacheEntry(
                dayKey: input.dayKey,
                inputFingerprint: input.inputFingerprint,
                summary: generated.summary,
                providerID: routeIdentity.providerID,
                modelID: routeIdentity.modelID,
                executedLocally: routeIdentity.executedLocally,
                brokerUpstream: generated.provenance.brokerUpstream,
                recipientDisclosure: routeIdentity.recipientDisclosure,
                endpointDisclosure: routeIdentity.endpointDisclosure,
                endpointIdentity: routeIdentity.endpointIdentity,
                promptVersion: generated.promptVersion,
                generatedAtMs: msFromDate(generatedAt),
                sourceStartMs: input.sourceStartMs,
                sourceEndMs: input.sourceEndMs,
                sourceCount: input.sourceCount
            )
            let replaced = try await cache.replace(
                entry,
                expectedInvalidationEpoch: cacheSnapshot.invalidationEpoch
            )
            guard replaced else {
                guard accepts(generation), activeRequest == ownership else { return }
                activeRequest = nil
                lastAutomaticAttempt.removeValue(forKey: automaticAttemptKey)
                content = nil
                errorText = nil
                phase = .idle
                return
            }
            guard accepts(generation),
                  activeRequest == ownership,
                  ownership.accepts(
                    requestID: requestID,
                    consumer: .activitySummary,
                    execution: readiness.currentExecutionContext(for: .activitySummary)
                  ) else {
                if accepts(generation), activeRequest == ownership {
                    activeRequest = nil
                    phase = content == nil ? .unavailable : .cached
                }
                return
            }
            content = Self.content(from: entry)
            errorText = nil
            phase = .cached
            activeRequest = nil
        } catch is CancellationError {
            if accepts(generation), activeRequest == ownership {
                activeRequest = nil
                phase = content == nil ? .idle : .cached
            }
        } catch let urlError as URLError where urlError.code == .cancelled {
            if accepts(generation), activeRequest == ownership {
                activeRequest = nil
                phase = content == nil ? .idle : .cached
            }
        } catch {
            guard accepts(generation), activeRequest == ownership else { return }
            activeRequest = nil
            finishFailure(error, generation: generation)
        }
    }

    private func accepts(_ generation: Int) -> Bool {
        generation == loadGeneration && !Task.isCancelled
    }

    private func finishFailure(_ error: Error, generation: Int) {
        guard accepts(generation) else { return }
        errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        phase = .failed
    }

    private func isCurrentDay(
        _ day: Date,
        at date: Date,
        timeZone: TimeZone
    ) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.isDate(day, inSameDayAs: date)
    }

    private func mayAutomaticallyRefresh(
        input: ActivityDaySummaryInput,
        cached: ActivityDaySummaryCacheEntry?,
        execution: AIConsumerExecutionContext,
        routeIdentity: ActivitySummaryRouteIdentity,
        at date: Date
    ) -> Bool {
        let attemptKey = AutomaticAttemptKey(
            input: input,
            execution: execution,
            routeIdentity: routeIdentity
        )
        let last = [
            cached.map { dateFromMs($0.generatedAtMs) },
            lastAutomaticAttempt[attemptKey],
        ].compactMap { $0 }.max() ?? .distantPast
        return date.timeIntervalSince(last) >= 30 * 60
    }

    private static func hasCurrentIdentity(
        _ cached: ActivityDaySummaryCacheEntry,
        input: ActivityDaySummaryInput,
        routeIdentity: ActivitySummaryRouteIdentity
    ) -> Bool {
        cached.promptVersion == AIConsumerPromptFactory.activitySummaryVersion
            && cached.providerID == routeIdentity.providerID
            && cached.modelID == routeIdentity.modelID
            && cached.executedLocally == routeIdentity.executedLocally
            && cached.recipientDisclosure == routeIdentity.recipientDisclosure
            && cached.endpointDisclosure == routeIdentity.endpointDisclosure
            && cached.endpointIdentity == routeIdentity.endpointIdentity
            && cached.sourceStartMs == input.sourceStartMs
            && cached.sourceEndMs == input.sourceEndMs
    }

    private static func execution(
        _ execution: AIConsumerExecutionContext,
        matches routeIdentity: ActivitySummaryRouteIdentity
    ) -> Bool {
        execution.selection.providerID == routeIdentity.providerID
            && execution.selection.modelID == routeIdentity.modelID
            && execution.executedLocally == routeIdentity.executedLocally
            && execution.recipientDisclosure == routeIdentity.recipientDisclosure
    }

    private static func content(
        from entry: ActivityDaySummaryCacheEntry
    ) -> ActivityDaySummaryContent? {
        guard let bullets = try? ActivityDaySummaryService.safeBullets(entry.summary) else {
            return nil
        }
        return ActivityDaySummaryContent(
            bullets: bullets,
            providerID: entry.providerID,
            modelID: entry.modelID,
            executedLocally: entry.executedLocally,
            brokerUpstream: entry.brokerUpstream,
            recipientDisclosure: entry.recipientDisclosure,
            endpointDisclosure: entry.endpointDisclosure,
            generatedAt: dateFromMs(entry.generatedAtMs)
        )
    }
}
