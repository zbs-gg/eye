import Foundation
import Observation

/// Settings may be dismissed while an operation is running. Confirmations and
/// file pickers stay view-local, but accepted work and its result live here.
@MainActor
@Observable
final class StorageOperationsStore {
    private(set) var deleting = false
    private(set) var deleteOutcome: String?
    private(set) var exporting = false
    private(set) var exportResult: String?
    private(set) var importing = false
    private(set) var importStatus: String?
    private(set) var browserImporting = false
    private(set) var browserImportStatus: String?

    @ObservationIgnored private var deleteTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var browserTask: Task<Void, Never>?

    func startDelete(_ operation: @escaping @MainActor @Sendable () async -> String) {
        guard deleteTask == nil else { return }
        deleting = true
        deleteOutcome = nil
        deleteTask = Task { @MainActor [weak self] in
            let outcome = await operation()
            guard let self else { return }
            deleteOutcome = outcome
            deleting = false
            deleteTask = nil
        }
    }

    func clearDeleteOutcome() { deleteOutcome = nil }

    func startExport(_ operation: @escaping @MainActor @Sendable () async -> String) {
        guard exportTask == nil else { return }
        exporting = true
        exportResult = nil
        exportTask = Task { @MainActor [weak self] in
            let result = await operation()
            guard let self else { return }
            exportResult = result
            exporting = false
            exportTask = nil
        }
    }

    func startImport(_ operation: @escaping @MainActor @Sendable (
        @escaping @MainActor @Sendable (String) -> Void
    ) async -> String) {
        guard importTask == nil else { return }
        importing = true
        importStatus = nil
        importTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await operation { [weak self] status in
                self?.importStatus = status
            }
            importStatus = result
            importing = false
            importTask = nil
        }
    }

    func startBrowserImport(
        _ operation: @escaping @MainActor @Sendable () async -> String
    ) {
        guard browserTask == nil else { return }
        browserImporting = true
        browserImportStatus = String(localized: "Importing…")
        browserTask = Task { @MainActor [weak self] in
            let result = await operation()
            guard let self else { return }
            browserImportStatus = result
            browserImporting = false
            browserTask = nil
        }
    }
}
