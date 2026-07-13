import Foundation
import Observation

enum WorkspaceMode: Sendable, Equatable {
    case timeline
    case ask
}

enum TimelineRepresentation: Sendable, Equatable {
    case moments
    case activities
}

enum WorkspaceFeature: String, CaseIterable, Sendable, Equatable, Identifiable {
    case insights
    case automations
    case progress
    case achievements
    case appearance
    case settings

    var id: String { rawValue }
}

/// One navigation authority for the memory workspace. Secondary capabilities
/// are temporary presentations, so opening and closing them never destroys the
/// user's Timeline or Ask context.
@MainActor
@Observable
final class WorkspaceStore {
    private(set) var mode: WorkspaceMode = .timeline
    private(set) var timelineRepresentation: TimelineRepresentation = .moments
    private(set) var presentedFeature: WorkspaceFeature?
    private(set) var askScope: AskScope
    private(set) var scopeRevision: UInt64 = 0
    private(set) var timelineReturnTarget: SearchResult?
    private(set) var timelineMomentTarget: Date?

    @ObservationIgnored private let calendar: Calendar

    init(
        now: Date = Date(),
        calendar: Calendar = .current,
        initialScope: AskScope? = nil
    ) {
        self.calendar = calendar
        self.askScope = Self.normalized(
            initialScope ?? .day(now),
            calendar: calendar
        )
    }

    func setAskScope(_ scope: AskScope) {
        let normalized = Self.normalized(scope, calendar: calendar)
        guard askScope != normalized else { return }
        askScope = normalized
        scopeRevision &+= 1
    }

    func openAsk(scope: AskScope? = nil) {
        if let scope { setAskScope(scope) }
        presentedFeature = nil
        mode = .ask
    }

    func captureAskScope() -> AskScopeSnapshot {
        askScope.snapshot(revision: scopeRevision, calendar: calendar)
    }

    /// Returning through a citation must not rewrite the scope the answer used;
    /// switching back to Ask therefore preserves its prior context.
    func returnToTimeline(source: SearchResult) {
        timelineMomentTarget = nil
        timelineReturnTarget = source
        timelineRepresentation = .moments
        presentedFeature = nil
        mode = .timeline
    }

    func returnToTimeline(moment: Date) {
        timelineReturnTarget = nil
        timelineMomentTarget = moment
        timelineRepresentation = .moments
        presentedFeature = nil
        mode = .timeline
    }

    func showTimeline(representation: TimelineRepresentation? = nil) {
        if let representation { timelineRepresentation = representation }
        presentedFeature = nil
        mode = .timeline
    }

    func showActivities() {
        showTimeline(representation: .activities)
    }

    func present(_ feature: WorkspaceFeature) {
        presentedFeature = feature
    }

    func dismissFeature() {
        presentedFeature = nil
    }

    func consumeTimelineReturnTarget() -> SearchResult? {
        defer { timelineReturnTarget = nil }
        return timelineReturnTarget
    }

    func consumeTimelineMomentTarget() -> Date? {
        defer { timelineMomentTarget = nil }
        return timelineMomentTarget
    }

    private static func normalized(
        _ scope: AskScope,
        calendar: Calendar
    ) -> AskScope {
        guard case .day(let anchor) = scope else { return scope }
        return .day(calendar.startOfDay(for: anchor))
    }
}
