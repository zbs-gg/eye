import Foundation

/// The single owner of automation-audit.jsonl appends. Relocation closes
/// admission before resolving StorageLocation and waits for every append that
/// already resolved the old root. This prevents a suspended AI run from
/// straddling the root flip and also serializes Cartographer/Summary appends.
actor AutomationAuditWriter {
    typealias URLResolver = @Sendable () throws -> URL
    typealias DataAppender = @Sendable (URL, Data) async throws -> Void

    private let maintenanceGate = DatabaseWriterMaintenanceGate()
    private let resolveURL: URLResolver
    private let appendData: DataAppender

    init(
        resolveURL: @escaping URLResolver = { try ZBSEyeSupport.auditLogURL() },
        appendData: @escaping DataAppender = AutomationAuditWriter.appendToFile
    ) {
        self.resolveURL = resolveURL
        self.appendData = appendData
    }

    func append(_ entry: AuditEntry) async throws {
        guard maintenanceGate.beginOperation() else {
            throw DatabaseWriterMaintenanceError.suspendedForRelocation
        }
        defer { maintenanceGate.finishOperation() }

        var data = try JSONEncoder().encode(entry)
        data.append(0x0A)
        try await appendData(resolveURL(), data)
    }

    func suspendAndDrainForRelocation() async -> DatabaseWriterDrainAcknowledgement {
        await maintenanceGate.suspendAndDrain()
    }

    func resumeAfterRelocation() {
        maintenanceGate.resume()
    }

    private static func appendToFile(_ url: URL, _ data: Data) async throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}
