import Foundation

/// Read-only disclosure attached after history retrieval. It deliberately
/// carries no captured text or media and cannot affect ranking or pagination.
struct CaptureCoverageDisclosure: Codable, Sendable, Equatable {
    enum Availability: String, Codable, Sendable {
        case available
        case metadataUnavailable
    }

    let availability: Availability
    let intervals: [CaptureCoverageInterval]

    static let clean = CaptureCoverageDisclosure(
        availability: .available,
        intervals: []
    )
    static let metadataUnavailable = CaptureCoverageDisclosure(
        availability: .metadataUnavailable,
        intervals: []
    )

    init(_ read: CaptureCoverageRead) {
        switch read {
        case .metadataUnavailable:
            self = .metadataUnavailable
        case .available(let intervals):
            self.init(availability: .available, intervals: intervals)
        }
    }

    init(
        availability: Availability,
        intervals: [CaptureCoverageInterval]
    ) {
        self.availability = availability
        self.intervals = intervals
    }

    var hasWarning: Bool {
        availability == .metadataUnavailable || !intervals.isEmpty
    }

    var affectedLegs: [CaptureLeg] {
        CaptureLeg.allCases.filter { leg in intervals.contains { $0.leg == leg } }
    }

    var userFacingWarning: String? {
        if availability == .metadataUnavailable {
            return String(localized: "Capture coverage could not be verified for this range. Missing results do not prove inactivity.")
        }
        guard !intervals.isEmpty else { return nil }
        let sources = affectedLegs.map(Self.legLabel).joined(separator: ", ")
        return String(localized: "Capture may be incomplete for \(sources) in this range. Missing results do not prove inactivity.")
    }

    func modelInstruction(russian: Bool) -> String? {
        guard hasWarning else { return nil }
        if availability == .metadataUnavailable {
            return russian
                ? "Метаданные полноты записи для выбранного диапазона недоступны. Отсутствие фрагментов не доказывает бездействие пользователя."
                : "Capture-coverage metadata is unavailable for the selected range. Missing fragments do not prove user inactivity."
        }
        let sources = affectedLegs.map(\.rawValue).joined(separator: ", ")
        return russian
            ? "В выбранном диапазоне есть подтверждённый пробел записи (\(sources)). Отсутствие фрагментов внутри пробела не доказывает бездействие пользователя."
            : "The selected range contains a confirmed capture gap (\(sources)). Missing fragments inside the gap do not prove user inactivity."
    }

    private static func legLabel(_ leg: CaptureLeg) -> String {
        switch leg {
        case .screen: String(localized: "Screen")
        case .systemAudio: String(localized: "System Audio")
        }
    }
}

extension CaptureCoverageQuery {
    /// Search and Ask bounds are inclusive; coverage intervals are half-open.
    func disclosure(from: Date?, to: Date?) async throws -> CaptureCoverageDisclosure {
        let startMs = from.map(msFromDate) ?? 0
        let inclusiveEndMs = to.map(msFromDate) ?? Int64.max
        let endMs = inclusiveEndMs == Int64.max ? Int64.max : inclusiveEndMs + 1
        return CaptureCoverageDisclosure(
            try await overlapping(startMs: startMs, endMs: endMs)
        )
    }
}

struct CaptureLegStatusDTO: Codable, Sendable, Equatable {
    let leg: CaptureLeg
    let state: CaptureLegState
    let reason: CaptureHealthReason
    let generation: Int64
    let attempt: Int
    let stateSinceMs: Int64
    let lastCycleAtMs: Int64?
    let lastVerifiedProgressAtMs: Int64?
}

struct CaptureStatusDTO: Codable, Sendable, Equatable {
    let state: CaptureAggregateState
    let suspension: CaptureSuspensionReason?
    let screenEnabled: Bool
    let systemAudioEnabled: Bool
    let legs: [CaptureLegStatusDTO]
    let coverage: CaptureCoverageDisclosure

    init(snapshot: CaptureHealthSnapshot, coverage: CaptureCoverageDisclosure) {
        state = snapshot.aggregate
        suspension = snapshot.suspension
        screenEnabled = snapshot.intent.screenEnabled
        systemAudioEnabled = snapshot.intent.systemAudioEnabled
        legs = CaptureLeg.allCases.compactMap { leg in
            snapshot.legs[leg].map {
                CaptureLegStatusDTO(
                    leg: leg,
                    state: $0.state,
                    reason: $0.reason,
                    generation: $0.generation,
                    attempt: $0.attempt,
                    stateSinceMs: $0.stateSinceMs,
                    lastCycleAtMs: $0.lastCycleAtMs,
                    lastVerifiedProgressAtMs: $0.lastVerifiedProgressAtMs
                )
            }
        }
        self.coverage = coverage
    }
}
