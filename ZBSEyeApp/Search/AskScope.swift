import Foundation

/// The user-visible slice of memory Ask is allowed to retrieve from.
/// A scope is resolved into an immutable snapshot when Send is pressed so a
/// later selection or time-zone change cannot broaden an in-flight request.
enum AskScope: Sendable, Equatable {
    case all
    case day(Date)
    case moment(Date)
    case range(from: Date, to: Date)

    /// Five minutes on either side keeps a selected moment useful without
    /// turning it into an implicit all-day search or a user-facing preference.
    static let momentRadius: TimeInterval = 5 * 60

    func snapshot(
        revision: UInt64,
        calendar: Calendar
    ) -> AskScopeSnapshot {
        switch self {
        case .all:
            return AskScopeSnapshot(
                value: self,
                revision: revision,
                from: nil,
                to: nil
            )
        case .day(let anchor):
            guard let interval = calendar.dateInterval(of: .day, for: anchor) else {
                return AskScopeSnapshot(
                    value: self,
                    revision: revision,
                    from: .distantFuture,
                    to: .distantPast
                )
            }
            // Capture timestamps are integer milliseconds. Search bounds are
            // inclusive, so the final millisecond belongs to this local day
            // and the next local midnight does not.
            let inclusiveEnd = dateFromMs(msFromDate(interval.end) - 1)
            return AskScopeSnapshot(
                value: self,
                revision: revision,
                from: interval.start,
                to: inclusiveEnd
            )
        case .moment(let cursor):
            return AskScopeSnapshot(
                value: self,
                revision: revision,
                from: cursor.addingTimeInterval(-Self.momentRadius),
                to: cursor.addingTimeInterval(Self.momentRadius)
            )
        case .range(let from, let to):
            // Do not reorder an invalid range: from > to intentionally matches
            // nothing instead of silently widening user-selected context.
            return AskScopeSnapshot(
                value: self,
                revision: revision,
                from: from,
                to: to
            )
        }
    }
}

/// Fully resolved and request-safe time bounds. This is the value that crosses
/// actor boundaries and is attached to the resulting conversation messages.
struct AskScopeSnapshot: Sendable, Equatable {
    let value: AskScope
    let revision: UInt64
    let from: Date?
    let to: Date?

    static let allHistory = AskScopeSnapshot(
        value: .all,
        revision: 0,
        from: nil,
        to: nil
    )

    var isAllHistory: Bool {
        if case .all = value { return true }
        return false
    }

    func searchFilters(limit: Int) -> SearchFilters {
        SearchFilters(from: from, to: to, limit: limit)
    }

    func includes(_ timestamp: Date) -> Bool {
        searchFilters(limit: 1).includes(timestamp: timestamp)
    }

    /// Compact copy for the Ask header and per-answer provenance. The resolved
    /// bounds remain the authority for retrieval; this label never recomputes
    /// or widens them.
    var displayLabel: String {
        switch value {
        case .all:
            return String(localized: "All history")
        case .day(let anchor):
            if Calendar.current.isDateInToday(anchor) {
                return String(localized: "Today")
            }
            return anchor.formatted(date: .abbreviated, time: .omitted)
        case .moment(let cursor):
            return String(localized: "Moment · \(cursor.formatted(date: .abbreviated, time: .shortened))")
        case .range(let from, let to):
            return String(localized: "Range · \(from.formatted(date: .abbreviated, time: .shortened)) – \(to.formatted(date: .abbreviated, time: .shortened))")
        }
    }
}
