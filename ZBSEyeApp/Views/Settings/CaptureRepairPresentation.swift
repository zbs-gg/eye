import Foundation

enum CaptureRepairPresentationState: Sendable, Equatable {
    case hidden
    case recovering
    case repairRequired
    case permissionBlocked
}

struct CaptureRepairPresentation: Sendable, Equatable {
    let state: CaptureRepairPresentationState
    let affectedLegs: [CaptureLeg]
    let title: String
    let detail: String
    let actionTitle: String?
    let guidance: [String]

    init(snapshot: CaptureHealthSnapshot) {
        let requested = snapshot.requestedLegs
        let blocked = requested.filter {
            snapshot.legs[$0]?.state == .permissionBlocked
        }
        let repair = snapshot.repairableLegs
        let recovering = requested.filter {
            snapshot.legs[$0]?.state == .recovering
                && (snapshot.legs[$0]?.attempt ?? 0) > 0
        }

        if !blocked.isEmpty {
            state = .permissionBlocked
            affectedLegs = blocked
            title = String(localized: "Capture permission needed")
            detail = String(localized: "Allow capture in macOS Settings. ZBS Eye will retry after macOS reports that access is granted.")
            actionTitle = nil
            guidance = []
        } else if !repair.isEmpty {
            state = .repairRequired
            affectedLegs = repair
            title = String(localized: "Capture needs repair")
            detail = String(localized: "ZBS Eye stopped automatic retries. Your recording choice and existing history are safe.")
            actionTitle = String(localized: "Repair Capture")
            guidance = [
                String(localized: "Try the Eye-owned repair once."),
                String(localized: "If it still fails, quit other apps currently using screen capture."),
                String(localized: "Log out or restart the Mac only as the final macOS recovery step."),
            ]
        } else if !recovering.isEmpty {
            state = .recovering
            affectedLegs = recovering
            title = String(localized: "Recovering capture…")
            detail = String(localized: "ZBS Eye is rebuilding only its own capture resources.")
            actionTitle = nil
            guidance = []
        } else {
            state = .hidden
            affectedLegs = []
            title = ""
            detail = ""
            actionTitle = nil
            guidance = []
        }
    }

    var affectedLabel: String {
        affectedLegs.map {
            switch $0 {
            case .screen: String(localized: "Screen")
            case .systemAudio: String(localized: "System Audio")
            }
        }.joined(separator: ", ")
    }
}
