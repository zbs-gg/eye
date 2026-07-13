import Foundation
import Observation

enum WorkspaceMode: Sendable, Equatable {
    case timeline
    case ask
}

/// Compact navigation state shared by Timeline and Ask. U5 will project this
/// through the new workspace shell; until then SidebarSection remains a UI
/// adapter and does not own Ask context.
@MainActor
@Observable
final class WorkspaceStore {
    private(set) var mode: WorkspaceMode = .timeline
    private(set) var askScope: AskScope
    private(set) var scopeRevision: UInt64 = 0
    private(set) var timelineReturnTarget: SearchResult?

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
        mode = .ask
    }

    func captureAskScope() -> AskScopeSnapshot {
        askScope.snapshot(revision: scopeRevision, calendar: calendar)
    }

    /// Returning through a citation must not rewrite the scope the answer used;
    /// switching back to Ask therefore preserves its prior context.
    func returnToTimeline(source: SearchResult) {
        timelineReturnTarget = source
        mode = .timeline
    }

    func showTimeline() {
        mode = .timeline
    }

    func consumeTimelineReturnTarget() -> SearchResult? {
        defer { timelineReturnTarget = nil }
        return timelineReturnTarget
    }

    private static func normalized(
        _ scope: AskScope,
        calendar: Calendar
    ) -> AskScope {
        guard case .day(let anchor) = scope else { return scope }
        return .day(calendar.startOfDay(for: anchor))
    }
}
