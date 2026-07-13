import Darwin
import Foundation

enum BuiltInModelJournalError: Error, Equatable {
    case missing
    case unsupportedSchema(found: Int, supported: Int)
    case corrupt(String)
    case inconsistentState(String)
    case io(operation: String, code: Int32)
}

/// Versioned durable subset of the lifecycle. Runtime state is absent on
/// purpose: GPU objects and in-process tasks never survive a relaunch.
struct BuiltInModelJournal: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    var inventory: ArtifactInventory
    var provisioningJob: ProvisioningJob
    var activationIntent: ActivationIntent?
    var deactivationIntent: DeactivationIntent?
    var pendingProviderEffect: BuiltInModelLifecycleEffect?
    var providerEffectRecovery: BuiltInModelLifecycleEffect?

    init(state: BuiltInModelLifecycleState) {
        schemaVersion = Self.currentSchemaVersion
        inventory = state.inventory
        provisioningJob = state.provisioningJob
        activationIntent = state.activationIntent
        deactivationIntent = state.deactivationIntent
        pendingProviderEffect = state.pendingProviderEffect
        providerEffectRecovery = state.providerEffectRecovery
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> BuiltInModelJournal {
        struct Header: Decodable {
            let schemaVersion: Int
        }

        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw BuiltInModelJournalError.corrupt(String(describing: error))
        }

        guard header.schemaVersion == currentSchemaVersion else {
            throw BuiltInModelJournalError.unsupportedSchema(
                found: header.schemaVersion,
                supported: currentSchemaVersion
            )
        }

        let journal: BuiltInModelJournal
        do {
            journal = try decoder.decode(BuiltInModelJournal.self, from: data)
        } catch {
            throw BuiltInModelJournalError.corrupt(String(describing: error))
        }
        try journal.validate()
        return journal
    }

    func restoredState() throws -> BuiltInModelLifecycleState {
        try validate()

        let reconciledJob: ProvisioningJob
        switch provisioningJob {
        case .downloading(let progress):
            reconciledJob = .paused(progress)
        case .verifying:
            reconciledJob = .verificationPending
        case .waitingForRuntimeDrain(let installation),
                .removing(let installation):
            reconciledJob = .removalPending(installation)
        default:
            reconciledJob = provisioningJob
        }

        return BuiltInModelLifecycleState(
            inventory: inventory,
            provisioningJob: reconciledJob,
            activationIntent: activationIntent,
            deactivationIntent: deactivationIntent,
            pendingProviderEffect: pendingProviderEffect,
            providerEffectRecovery: providerEffectRecovery,
            runtimeState: .unloaded
        )
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw BuiltInModelJournalError.unsupportedSchema(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }

        var installationIDs = Set<UUID>()
        var relativeDirectories = Set<String>()
        for installation in inventory.allInstallations {
            guard installationIDs.insert(installation.installationID).inserted else {
                throw BuiltInModelJournalError.inconsistentState(
                    "duplicate installation ID"
                )
            }
            guard relativeDirectories.insert(installation.relativeDirectory).inserted else {
                throw BuiltInModelJournalError.inconsistentState(
                    "duplicate installation directory"
                )
            }
            try validate(installation.artifact)
        }

        if let intent = activationIntent {
            guard let candidate = inventory.candidate,
                  intent.providerID == AIProvider.zbsEyeLocal.rawValue,
                  intent.modelID == candidate.artifact.modelID else {
                throw BuiltInModelJournalError.inconsistentState(
                    "activation intent does not own the candidate"
                )
            }
        }

        if let intent = deactivationIntent {
            guard let lastKnownGood = inventory.lastKnownGood,
                  intent.providerID == AIProvider.zbsEyeLocal.rawValue,
                  intent.modelID == lastKnownGood.artifact.modelID else {
                throw BuiltInModelJournalError.inconsistentState(
                    "deactivation intent does not own the installed model"
                )
            }

            switch provisioningJob {
            case .waitingForRuntimeDrain, .removing, .removalPending:
                break
            case .failed(let failure) where failure.stage == .removal:
                break
            default:
                throw BuiltInModelJournalError.inconsistentState(
                    "deactivation intent exists outside removal"
                )
            }
        }

        if let effect = pendingProviderEffect {
            guard activationIntent == nil, deactivationIntent == nil else {
                throw BuiltInModelJournalError.inconsistentState(
                    "provider effect overlaps an in-progress lifecycle intent"
                )
            }
            switch effect {
            case .requestActivation(let intent):
                guard let installed = inventory.lastKnownGood,
                      inventory.candidate == nil,
                      provisioningJob == .idle,
                      intent.providerID == AIProvider.zbsEyeLocal.rawValue,
                      intent.modelID == installed.artifact.modelID else {
                    throw BuiltInModelJournalError.inconsistentState(
                        "pending activation does not own the installed model"
                    )
                }
            case .requestDeactivation(let intent):
                guard inventory.lastKnownGood == nil,
                      inventory.candidate == nil,
                      provisioningJob == .idle,
                      intent.providerID == AIProvider.zbsEyeLocal.rawValue else {
                    throw BuiltInModelJournalError.inconsistentState(
                        "pending deactivation is not a completed removal"
                    )
                }
            }
        }

        if let effect = providerEffectRecovery {
            try validateRecoveryEffect(effect)
        }

        switch provisioningJob {
        case .preflightBlocked(let requiredBytes, let availableBytes):
            try requireCandidate()
            guard requiredBytes >= 0, availableBytes >= 0 else {
                throw BuiltInModelJournalError.inconsistentState(
                    "negative preflight byte count"
                )
            }

        case .downloading(let progress), .paused(let progress):
            try requireCandidate()
            try validate(progress)

        case .pausedLowDisk(let progress, let requiredBytes, let availableBytes):
            try requireCandidate()
            try validate(progress)
            guard requiredBytes >= 0, availableBytes >= 0 else {
                throw BuiltInModelJournalError.inconsistentState(
                    "negative low-disk byte count"
                )
            }

        case .verifying, .verificationPending:
            try requireCandidate()
            guard inventory.candidate?.verification == .partial else {
                throw BuiltInModelJournalError.inconsistentState(
                    "verified candidate cannot be in verification"
                )
            }

        case .waitingForRuntimeDrain(let installation),
                .removing(let installation),
                .removalPending(let installation):
            guard inventory.lastKnownGood == installation,
                  inventory.candidate == nil else {
                throw BuiltInModelJournalError.inconsistentState(
                    "removal does not own the last-known-good installation"
                )
            }

        case .idle, .failed:
            break
        }
    }

    private func requireCandidate() throws {
        guard inventory.candidate != nil else {
            throw BuiltInModelJournalError.inconsistentState(
                "candidate job has no candidate installation"
            )
        }
    }

    private func validateRecoveryEffect(
        _ effect: BuiltInModelLifecycleEffect
    ) throws {
        let providerID: String
        let modelID: String
        switch effect {
        case .requestActivation(let intent):
            providerID = intent.providerID
            modelID = intent.modelID
        case .requestDeactivation(let intent):
            providerID = intent.providerID
            modelID = intent.modelID
        }
        guard providerID == AIProvider.zbsEyeLocal.rawValue,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BuiltInModelJournalError.inconsistentState(
                "provider recovery effect is invalid"
            )
        }
    }

    private func validate(_ progress: ProvisioningProgress) throws {
        guard progress.receivedBytes >= 0,
              progress.expectedBytes > 0,
              progress.receivedBytes <= progress.expectedBytes else {
            throw BuiltInModelJournalError.inconsistentState(
                "invalid provisioning progress"
            )
        }
    }

    private func validate(_ artifact: BuiltInModelArtifact) throws {
        let fingerprint = artifact.manifestFingerprintSHA256
        guard !artifact.modelID.isEmpty,
              artifact.artifactVersion > 0,
              fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw BuiltInModelJournalError.inconsistentState(
                "invalid artifact identity"
            )
        }
    }
}

/// Atomic single-file journal. The lifecycle owner serializes calls; the store
/// guarantees that a crash exposes either the prior complete journal or the
/// replacement complete journal, never partially written JSON.
struct BuiltInModelJournalStore {
    enum CommitStep: String, Sendable, Equatable {
        case temporaryFileWritten
        case temporaryFileSynced
        case destinationRenamed
        case parentDirectorySynced
    }

    typealias FaultHook = (CommitStep) throws -> Void

    let journalURL: URL
    private let faultHook: FaultHook?

    init(
        journalURL: URL,
        faultHook: FaultHook? = nil
    ) {
        self.journalURL = journalURL
        self.faultHook = faultHook
    }

    func save(_ state: BuiltInModelLifecycleState) throws {
        let data = try BuiltInModelJournal(state: state).encoded()
        let parent = journalURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            throw BuiltInModelJournalError.io(
                operation: "create journal directory",
                code: errno
            )
        }

        let temporaryURL = parent.appending(
            path: ".\(journalURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var fileDescriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else {
            throw BuiltInModelJournalError.io(
                operation: "open temporary journal",
                code: errno
            )
        }

        var renamed = false
        defer {
            if fileDescriptor >= 0 { _ = Darwin.close(fileDescriptor) }
            if !renamed { try? FileManager.default.removeItem(at: temporaryURL) }
        }

        try writeAll(data, to: fileDescriptor)
        try faultHook?(.temporaryFileWritten)

        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw BuiltInModelJournalError.io(
                operation: "fsync temporary journal",
                code: errno
            )
        }
        try faultHook?(.temporaryFileSynced)

        guard Darwin.close(fileDescriptor) == 0 else {
            fileDescriptor = -1
            throw BuiltInModelJournalError.io(
                operation: "close temporary journal",
                code: errno
            )
        }
        fileDescriptor = -1

        let renameResult = temporaryURL.path.withCString { temporaryPath in
            journalURL.path.withCString { journalPath in
                Darwin.rename(temporaryPath, journalPath)
            }
        }
        guard renameResult == 0 else {
            throw BuiltInModelJournalError.io(
                operation: "rename journal",
                code: errno
            )
        }
        renamed = true
        try faultHook?(.destinationRenamed)

        let directoryDescriptor = Darwin.open(
            parent.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw BuiltInModelJournalError.io(
                operation: "open journal directory",
                code: errno
            )
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw BuiltInModelJournalError.io(
                operation: "fsync journal directory",
                code: errno
            )
        }
        try faultHook?(.parentDirectorySynced)
    }

    func load() throws -> BuiltInModelLifecycleState {
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            throw BuiltInModelJournalError.missing
        }

        let data: Data
        do {
            data = try Data(contentsOf: journalURL, options: [.mappedIfSafe])
        } catch {
            throw BuiltInModelJournalError.io(
                operation: "read journal",
                code: errno
            )
        }
        return try BuiltInModelJournal.decode(data).restoredState()
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw BuiltInModelJournalError.io(
                        operation: "write temporary journal",
                        code: errno
                    )
                }
                guard written > 0 else {
                    throw BuiltInModelJournalError.io(
                        operation: "write temporary journal",
                        code: EIO
                    )
                }
                offset += written
            }
        }
    }
}
