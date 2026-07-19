import Foundation

enum AutomaticCallBannerPhase: String, Sendable, Equatable {
    case started
    case endingGrace = "ending_grace"
    case endedUndo = "ended_undo"
}

struct AutomaticCallBannerState: Sendable, Equatable {
    let phase: AutomaticCallBannerPhase
    let callID: Int64
    let deadline: Date?
}
