import Foundation

/// Small value gate kept separate from the recording engines so maintenance
/// admission can be tested without launching capture frameworks.
struct RecordingMaintenanceAdmission: Sendable, Equatable {
    private(set) var isSuspended = false

    var permitsStart: Bool { !isSuspended }

    mutating func suspend() { isSuspended = true }
    mutating func resume() { isSuspended = false }
}
