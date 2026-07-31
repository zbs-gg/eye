import Foundation

enum RecordingMaintenanceOwner: String, Sendable, Equatable, Hashable, CaseIterable {
    case repair
    case relocation
    case lowDisk
    case termination
    case keepMedia
}

struct RecordingMaintenanceLease: Sendable, Equatable, Hashable {
    let owner: RecordingMaintenanceOwner
    fileprivate let admissionID: UUID
    fileprivate let token: UInt64
}

/// Small value gate kept separate from the recording engines so maintenance
/// admission can be tested without launching capture frameworks.
struct RecordingMaintenanceAdmission: Sendable, Equatable {
    private let admissionID = UUID()
    private var nextToken: UInt64 = 0
    private var leases: [UInt64: RecordingMaintenanceOwner] = [:]

    var isSuspended: Bool { !leases.isEmpty }
    var permitsStart: Bool { leases.isEmpty }
    var activeLeaseCount: Int { leases.count }
    var activeOwners: [RecordingMaintenanceOwner] {
        let owners = Set(leases.values)
        return RecordingMaintenanceOwner.allCases.filter(owners.contains)
    }

    mutating func acquire(_ owner: RecordingMaintenanceOwner) -> RecordingMaintenanceLease {
        nextToken &+= 1
        leases[nextToken] = owner
        return RecordingMaintenanceLease(
            owner: owner,
            admissionID: admissionID,
            token: nextToken
        )
    }

    @discardableResult
    mutating func release(_ lease: RecordingMaintenanceLease) -> Bool {
        guard lease.admissionID == admissionID,
              leases[lease.token] == lease.owner else { return false }
        leases[lease.token] = nil
        return true
    }

    func contains(_ lease: RecordingMaintenanceLease) -> Bool {
        lease.admissionID == admissionID && leases[lease.token] == lease.owner
    }
}
