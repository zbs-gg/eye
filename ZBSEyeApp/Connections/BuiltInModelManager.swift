import Darwin
import Foundation

enum BuiltInModelManagerError: Error, LocalizedError, Sendable, Equatable {
    case rootUnavailable
    case corruptJournal
    case futureJournal
    case unknownManifest
    case unsupportedHardware
    case capacityUnavailable
    case modelStoreInUse
    case suspendedForRelocation
    case invalidState(String)
    case filesystem(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .rootUnavailable: "The pinned built-in model data root is unavailable."
        case .corruptJournal: "The built-in model journal is corrupt."
        case .futureJournal: "The built-in model journal was written by a newer app."
        case .unknownManifest: "The requested built-in model manifest is unavailable."
        case .unsupportedHardware: "This exact Mac configuration is not qualified."
        case .capacityUnavailable: "Free storage could not be read safely."
        case .modelStoreInUse: "Another ZBS Eye process already owns the built-in model store."
        case .suspendedForRelocation: "Built-in model work is suspended for relocation."
        case .invalidState(let message): message
        case .filesystem(let operation, let code):
            "Built-in model filesystem operation failed: \(operation) (errno \(code))."
        }
    }
}

enum BuiltInModelManagerFaultPoint: String, Sendable, Equatable {
    case afterVerifiedMarker
    case afterPromotionBeforeLoad
    case candidateLoadedBeforeJournal
    case afterTrashBeforeJournal
    case afterProviderEffectJournalBeforeDispatch
    case afterProviderEffectAppliedBeforeRecoveryJournal
    case afterProviderEffectRecoveryJournal
}

struct BuiltInModelManagerSnapshot: Sendable, Equatable {
    let state: BuiltInModelLifecycleState
    let projection: BuiltInModelLifecycleProjection
    let pinnedDataRoot: URL
    let rootAvailable: Bool
    let suspendedForRelocation: Bool
}

struct BuiltInModelManagerResult: Sendable, Equatable {
    let snapshot: BuiltInModelManagerSnapshot
    let effects: [BuiltInModelLifecycleEffect]
}

struct BuiltInModelStorageSnapshot: Sendable, Equatable {
    let pinnedDataRoot: URL
    let journalBytes: Int64
    let installedBytes: Int64
    let stagingBytes: Int64
    let trashBytes: Int64
    let activeInstallationID: UUID?
    let activeManifestFingerprintSHA256: String?
    let activeVerifiedBytes: Int64

}

struct BuiltInModelRelocationDrain: Sendable, Equatable {
    let download: BuiltInDownloadDrainAcknowledgement
    let storage: BuiltInModelStorageSnapshot
}

/// Single orchestration owner for built-in model bytes and lifecycle truth.
/// The root is resolved and pinned once: if that exact path disappears, work
/// fails closed instead of silently creating a second model store elsewhere.
actor BuiltInModelManager {
    typealias HardwareEligibility = @Sendable (BuiltInModelManifest) throws -> Bool
    typealias CapacityReader = @Sendable (URL) throws -> Int64
    typealias CandidateLoader = @Sendable (URL, BuiltInModelManifest) async throws -> Void
    typealias CandidateVerifier = @Sendable (
        URL,
        BuiltInModelManifest
    ) async throws -> BuiltInModelVerification
    typealias RuntimeDrainer = @Sendable (BuiltInModelInstallation?) async throws -> Void
    typealias EffectHandler = @Sendable (
        BuiltInModelLifecycleEffect
    ) async -> BuiltInModelProviderEffectResult
    typealias FaultHook = @Sendable (BuiltInModelManagerFaultPoint) throws -> Void

    // Compatibility names for existing lifecycle tests. The policy itself is
    // shared with continuous capture rather than duplicated in model code.
    static let captureReserveBytes = DiskReservePolicy.standard.pauseBytes
    static let capacitySafetyBytes = DiskReservePolicy.standard.modelSafetyBytes

    private struct ResumeLedger: Codable, Sendable {
        var files: [String: BuiltInDownloadResumeState]
    }

    private struct VerifiedRecord: Codable, Sendable {
        let schemaVersion: Int
        let manifestID: String
        let artifactVersion: Int
        let manifestFingerprintSHA256: String
        let verifiedBytes: Int64
        let verifiedFileCount: Int
    }

    private struct ActiveVerification: Sendable {
        let id: UUID
        let installation: BuiltInModelInstallation
        let expectedState: BuiltInModelLifecycleState
        let task: Task<BuiltInModelVerification, Error>
    }

    private let pinnedDataRoot: URL
    private let pinnedRootDevice: UInt64
    private let pinnedRootInode: UInt64
    private let processLock: BuiltInModelProcessLock
    private let journalStore: BuiltInModelJournalStore
    private let manifestsByID: [String: BuiltInModelManifest]
    private let manifestsByFingerprint: [String: BuiltInModelManifest]
    private let downloadClient: BuiltInDownloadClient
    private let hardwareEligibility: HardwareEligibility
    private let capacityReader: CapacityReader
    private let candidateLoader: CandidateLoader
    private let candidateVerifier: CandidateVerifier
    private let runtimeDrainer: RuntimeDrainer
    private let effectHandler: EffectHandler
    private let faultHook: FaultHook

    private var state: BuiltInModelLifecycleState
    /// Only receipts restored by this manager's initializer are eligible for
    /// replay. A receipt created now must survive into a later process.
    private var providerEffectRecoveryForReplay: BuiltInModelLifecycleEffect?
    private var relocationSuspended = false
    private var activeVerification: ActiveVerification?
    private var activeMutations: Set<UUID> = []
    private var mutationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var failedShutdownRecoveryID: UUID?
    private var failedShutdownRecoveryTask: Task<Void, Never>?
    private var deferredProgressError: BuiltInModelManagerError?
    private var deferredLowDisk: (requiredBytes: Int64, availableBytes: Int64)?

    init(
        dataRoot: URL,
        manifests: [BuiltInModelManifest],
        downloadClient: BuiltInDownloadClient,
        hardwareEligibility: @escaping HardwareEligibility,
        capacityReader: @escaping CapacityReader,
        candidateLoader: @escaping CandidateLoader,
        candidateVerifier: @escaping CandidateVerifier = {
            try BuiltInModelVerifier.verify(directory: $0, manifest: $1)
        },
        runtimeDrainer: @escaping RuntimeDrainer,
        effectHandler: @escaping EffectHandler = { _ in .applied },
        faultHook: @escaping FaultHook = { _ in }
    ) throws {
        let root = dataRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isAvailableDirectory(root) else {
            throw BuiltInModelManagerError.rootUnavailable
        }
        try Self.secureDirectory(root)
        for child in ["staging", "installed", "trash"] {
            try Self.secureDirectory(root.appending(path: child, directoryHint: .isDirectory))
        }
        let rootIdentity = try Self.directoryIdentity(root)
        let processLock: BuiltInModelProcessLock
        do {
            processLock = try BuiltInModelProcessLock(modelRoot: root)
        } catch BuiltInModelProcessLockError.alreadyOwned {
            throw BuiltInModelManagerError.modelStoreInUse
        } catch BuiltInModelProcessLockError.unsafeLockFile {
            throw BuiltInModelManagerError.invalidState(
                "The built-in model process lock is unsafe."
            )
        } catch BuiltInModelProcessLockError.filesystem(let operation, let code) {
            throw BuiltInModelManagerError.filesystem(
                operation: "process lock \(operation)",
                code: code
            )
        }

        var byID: [String: BuiltInModelManifest] = [:]
        var byFingerprint: [String: BuiltInModelManifest] = [:]
        for manifest in manifests {
            try Self.validateManifest(manifest)
            guard byID[manifest.id] == nil,
                  byFingerprint[manifest.aggregateFingerprintSHA256] == nil else {
                throw BuiltInModelManagerError.invalidState("Duplicate manifest identity.")
            }
            byID[manifest.id] = manifest
            byFingerprint[manifest.aggregateFingerprintSHA256] = manifest
        }
        guard !byID.isEmpty else { throw BuiltInModelManagerError.unknownManifest }

        let store = BuiltInModelJournalStore(journalURL: root.appending(path: "journal.json"))
        let restored: BuiltInModelLifecycleState
        do {
            restored = try store.load()
        } catch BuiltInModelJournalError.missing {
            restored = .initial
        } catch BuiltInModelJournalError.unsupportedSchema {
            throw BuiltInModelManagerError.futureJournal
        } catch BuiltInModelJournalError.corrupt,
                BuiltInModelJournalError.inconsistentState {
            throw BuiltInModelManagerError.corruptJournal
        } catch BuiltInModelJournalError.io(_, let code) {
            throw BuiltInModelManagerError.filesystem(operation: "read journal", code: code)
        } catch {
            throw BuiltInModelManagerError.corruptJournal
        }
        for installation in restored.inventory.allInstallations {
            let expectedDirectory = "installed/"
                + installation.installationID.uuidString.lowercased()
                + "/payload"
            guard installation.relativeDirectory == expectedDirectory,
                  let manifest = byFingerprint[installation.artifact.manifestFingerprintSHA256],
                  manifest.id == installation.artifact.modelID,
                  manifest.artifactVersion == installation.artifact.artifactVersion else {
                throw BuiltInModelManagerError.corruptJournal
            }
        }

        self.pinnedDataRoot = root
        self.pinnedRootDevice = rootIdentity.device
        self.pinnedRootInode = rootIdentity.inode
        self.processLock = processLock
        self.journalStore = store
        self.manifestsByID = byID
        self.manifestsByFingerprint = byFingerprint
        self.downloadClient = downloadClient
        self.hardwareEligibility = hardwareEligibility
        self.capacityReader = capacityReader
        self.candidateLoader = candidateLoader
        self.candidateVerifier = candidateVerifier
        self.runtimeDrainer = runtimeDrainer
        self.effectHandler = effectHandler
        self.faultHook = faultHook
        self.state = restored
        self.providerEffectRecoveryForReplay = restored.providerEffectRecovery
    }

    func snapshot() -> BuiltInModelManagerSnapshot {
        makeSnapshot()
    }

    func install(
        manifestID: String,
        activationIntent: ActivationIntent? = nil,
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult {
        try requireOperationalRoot()
        let mutationID = try beginMutation()
        defer { finishMutation(mutationID) }
        guard let manifest = manifestsByID[manifestID] else {
            throw BuiltInModelManagerError.unknownManifest
        }
        guard try hardwareEligibility(manifest) else {
            throw BuiltInModelManagerError.unsupportedHardware
        }
        guard state.inventory.candidate == nil else {
            throw BuiltInModelManagerError.invalidState(
                "A built-in model candidate already owns provisioning."
            )
        }

        let installation = Self.makeInstallation(for: manifest)
        let previous = state
        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .prepareCandidate(installation, activationIntent: activationIntent)
        )
        guard state != previous, state.inventory.candidate?.installation == installation else {
            throw BuiltInModelManagerError.invalidState("Candidate preparation was rejected.")
        }
        try commit()
        return try await provision(
            manifest: manifest,
            installation: installation,
            currentSelectionRevision: currentSelectionRevision,
            resuming: false
        )
    }

    func reinstall(
        manifestID: String,
        activationIntent: ActivationIntent? = nil,
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult {
        try await install(
            manifestID: manifestID,
            activationIntent: activationIntent,
            currentSelectionRevision: currentSelectionRevision
        )
    }

    func pause() async throws -> BuiltInModelManagerSnapshot {
        try requireOperationalRoot()
        let mutationID = try beginMutation()
        defer { finishMutation(mutationID) }
        _ = await downloadClient.suspendAndDrain()
        if case .downloading = state.provisioningJob {
            _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .pauseDownload)
            try commit()
        }
        return makeSnapshot()
    }

    func resume(
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult {
        try requireOperationalRoot()
        let mutationID = try beginMutation()
        defer { finishMutation(mutationID) }
        await downloadClient.resumeAfterDrain()
        guard let candidate = state.inventory.candidate,
              let manifest = manifest(for: candidate.artifact) else {
            return result()
        }
        guard try hardwareEligibility(manifest) else {
            throw BuiltInModelManagerError.unsupportedHardware
        }

        if case .pausedLowDisk = state.provisioningJob,
           !FileManager.default.fileExists(atPath: stagingWrapper(candidate.installation).path) {
            state.provisioningJob = .paused(
                ProvisioningProgress(receivedBytes: 0, expectedBytes: manifest.expectedDownloadBytes)
            )
            try commit()
        }
        _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .resumeDownload)
        try commit()
        return try await provision(
            manifest: manifest,
            installation: candidate.installation,
            currentSelectionRevision: currentSelectionRevision,
            resuming: true
        )
    }

    func retry(
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult {
        try requireOperationalRoot()
        let mutationID = try beginMutation()
        defer { finishMutation(mutationID) }
        guard let candidate = state.inventory.candidate,
              let manifest = manifest(for: candidate.artifact) else {
            return result()
        }
        guard try hardwareEligibility(manifest) else {
            throw BuiltInModelManagerError.unsupportedHardware
        }

        if candidate.verification == .verified,
           FileManager.default.fileExists(atPath: installedWrapper(candidate.installation).path) {
            return try await loadPromotedCandidate(
                manifest: manifest,
                installation: candidate.installation,
                currentSelectionRevision: currentSelectionRevision
            )
        }

        if case .failed = state.provisioningJob {
            try removeIfPresent(stagingWrapper(candidate.installation))
            state.inventory.candidate?.verification = .partial
            state.provisioningJob = .idle
            try commit()
        }
        if case .preflightBlocked = state.provisioningJob {
            state.provisioningJob = .idle
            try commit()
        }
        if case .pausedLowDisk = state.provisioningJob {
            state.provisioningJob = .paused(
                ProvisioningProgress(receivedBytes: 0, expectedBytes: manifest.expectedDownloadBytes)
            )
            try commit()
        }
        await downloadClient.resumeAfterDrain()
        return try await provision(
            manifest: manifest,
            installation: candidate.installation,
            currentSelectionRevision: currentSelectionRevision,
            resuming: true
        )
    }

    /// Reloads an already verified last-known-good installation after a
    /// process-local runtime failure. Provisioning retry deliberately remains
    /// candidate-only; this is the honest action behind `retryLoad` when no
    /// candidate exists.
    func retryRuntimeLoad(
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerSnapshot {
        try requireOperationalRoot()
        let mutationID = try beginMutation()
        defer { finishMutation(mutationID) }
        try discardStaleProviderWork(
            currentSelectionRevision: currentSelectionRevision
        )
        guard state.inventory.candidate == nil,
              let installation = state.inventory.lastKnownGood,
              let manifest = manifest(for: installation.artifact) else {
            throw BuiltInModelManagerError.invalidState(
                "No installed built-in runtime is available to reload."
            )
        }
        guard try hardwareEligibility(manifest) else {
            throw BuiltInModelManagerError.unsupportedHardware
        }

        try await validateVerifiedInstallation(installation, manifest: manifest)
        state.runtimeState = .loading(installation)
        do {
            try await candidateLoader(installedPayload(installation), manifest)
            state.runtimeState = .ready(installation)
        } catch {
            state.runtimeState = .failed(
                installation: installation,
                reason: BuiltInModelFailureMessage.userFacing(error, context: .runtimeLoad)
            )
            throw error
        }
        if let pending = state.pendingProviderEffect,
           case .requestActivation = pending {
            try await dispatch([pending])
        }
        return makeSnapshot()
    }

    func cancel() async throws -> BuiltInModelManagerSnapshot {
        try requireOperationalRoot()
        let mutationID = try beginMutation()
        defer { finishMutation(mutationID) }
        await cancelActiveVerificationAndDrain()
        _ = await downloadClient.cancelAndDrain()
        guard state.inventory.candidate != nil else { return makeSnapshot() }
        _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .discardCandidate)
        try commit()
        try cleanupPendingInstallations()
        return makeSnapshot()
    }

    func remove(
        deactivationIntent: DeactivationIntent? = nil,
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult {
        try requireOperationalRoot()
        let mutationID = try beginMutation()
        defer { finishMutation(mutationID) }
        guard let installation = state.inventory.lastKnownGood else { return result() }
        let ownedDeactivationIntent = deactivationIntent.flatMap { intent in
            intent.expectedSelectionRevision == currentSelectionRevision
                ? intent
                : nil
        }

        let beforeBegin = state
        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .beginRemoval(deactivationIntent: ownedDeactivationIntent)
        )
        guard state != beforeBegin,
              case .waitingForRuntimeDrain(let target) = state.provisioningJob,
              target == installation else {
            throw BuiltInModelManagerError.invalidState(
                "Built-in model removal was rejected by the current lifecycle state."
            )
        }
        try commit()
        do {
            try await runtimeDrainer(installation)
        } catch {
            _ = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .removalFailed(
                    ProvisioningFailure(
                        stage: .removal,
                        message: BuiltInModelFailureMessage.userFacing(error, context: .removal),
                        isRetryable: true
                    )
                )
            )
            try commit()
            return result()
        }

        let beforeAcknowledgement = state
        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .runtimeDrainAcknowledged(installation)
        )
        guard state != beforeAcknowledgement,
              case .removing(let target) = state.provisioningJob,
              target == installation else {
            _ = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .removalFailed(
                    ProvisioningFailure(
                        stage: .removal,
                        message: "runtime drain acknowledgement was rejected",
                        isRetryable: true
                    )
                )
            )
            try commit()
            throw BuiltInModelManagerError.invalidState(
                "Built-in model runtime drain acknowledgement was rejected."
            )
        }
        try commit()
        let tombstone = try moveInstallationToTrash(installation)
        try faultHook(.afterTrashBeforeJournal)
        let effects = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .removalSucceeded(installation)
        )
        try commit()
        if !effects.isEmpty {
            try faultHook(.afterProviderEffectJournalBeforeDispatch)
        }
        try await dispatch(effects)
        try removeIfPresent(tombstone)
        return result(effects: effects)
    }

    func reconcileAfterRestart(
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult {
        try requireOperationalRoot()
        let mutationID = try beginMutation()
        defer { finishMutation(mutationID) }
        try discardStaleProviderWork(
            currentSelectionRevision: currentSelectionRevision
        )
        try reconcileTrashAndCleanup()

        switch state.provisioningJob {
        case .removalPending(let installation):
            let tombstone = trashWrapper(installation)
            if FileManager.default.fileExists(atPath: installedWrapper(installation).path) {
                _ = try moveInstallationToTrash(installation)
            }
            let effects = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .removalSucceeded(installation)
            )
            try commit()
            try await dispatch(effects)
            try removeIfPresent(tombstone)
            return try await finishReconciliation(effects: effects)

        case .verificationPending:
            guard let candidate = state.inventory.candidate,
                  let manifest = manifest(for: candidate.artifact) else {
                return try await finishReconciliation()
            }
            guard try hardwareEligibility(manifest) else {
                throw BuiltInModelManagerError.unsupportedHardware
            }
            let recovered = try await verifyPromoteAndLoad(
                manifest: manifest,
                installation: candidate.installation,
                currentSelectionRevision: currentSelectionRevision
            )
            return try await finishReconciliation(effects: recovered.effects)

        default:
            break
        }

        if let candidate = state.inventory.candidate,
           candidate.verification == .verified,
           let manifest = manifest(for: candidate.artifact),
           (FileManager.default.fileExists(atPath: installedWrapper(candidate.installation).path)
                || FileManager.default.fileExists(atPath: stagingWrapper(candidate.installation).path)) {
            guard try hardwareEligibility(manifest) else {
                throw BuiltInModelManagerError.unsupportedHardware
            }
            let recovered = try await verifyPromoteAndLoad(
                manifest: manifest,
                installation: candidate.installation,
                currentSelectionRevision: currentSelectionRevision
            )
            return try await finishReconciliation(effects: recovered.effects)
        }

        if let lastKnownGood = state.inventory.lastKnownGood,
           let manifest = manifest(for: lastKnownGood.artifact) {
            guard try hardwareEligibility(manifest) else {
                throw BuiltInModelManagerError.unsupportedHardware
            }
            do {
                try await validateVerifiedInstallation(lastKnownGood, manifest: manifest)
                try await candidateLoader(installedPayload(lastKnownGood), manifest)
                state.runtimeState = .ready(lastKnownGood)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                state.runtimeState = .failed(
                    installation: lastKnownGood,
                    reason: BuiltInModelFailureMessage.userFacing(error, context: .runtimeLoad)
                )
            }
        }
        var effects: [BuiltInModelLifecycleEffect] = []
        if let pending = state.pendingProviderEffect {
            switch pending {
            case .requestActivation:
                if let installed = state.inventory.lastKnownGood,
                   state.runtimeState == .ready(installed) {
                    effects = [pending]
                }
            case .requestDeactivation:
                effects = [pending]
            }
        }
        try await dispatch(effects)
        return try await finishReconciliation(effects: effects)
    }

    func suspendAndDrainForRelocation() async throws -> BuiltInModelRelocationDrain {
        try requireOperationalRoot()
        failedShutdownRecoveryTask?.cancel()
        failedShutdownRecoveryID = nil
        failedShutdownRecoveryTask = nil
        relocationSuspended = true
        await cancelActiveVerificationAndDrain()
        let acknowledgement = await downloadClient.suspendAndDrain()
        // Candidate loading/warm-up is itself an admitted mutation. Ask the
        // runtime owner to interrupt it before waiting for all mutations, or a
        // non-cooperative MLX warm-up could deadlock relocation forever.
        try await runtimeDrainer(state.inventory.lastKnownGood)
        // URLSession drain is not the manager boundary: an install may still
        // be recording its resume ledger, promoting, loading, or cleaning up.
        // The root is immutable only after every operation that entered before
        // relocation has left the actor-owned mutation set.
        await waitForMutationDrain()
        state.runtimeState = .unloaded
        return BuiltInModelRelocationDrain(
            download: acknowledgement,
            storage: try makeStorageSnapshot()
        )
    }

    /// Final process-lifetime barrier. New model mutations fail closed, an
    /// active download reaches a durable pause, every admitted mutation leaves
    /// the actor, and the process-local MLX runtime is unloaded before quit.
    /// The kernel process lock intentionally remains held until deinit/exit.
    @discardableResult
    func shutdown() async -> Bool {
        let recoveryID = UUID()
        // A retry owns a new shutdown generation. Do not leave waiters chasing
        // the superseded task after it exits on the ID mismatch.
        failedShutdownRecoveryTask?.cancel()
        failedShutdownRecoveryTask = nil
        failedShutdownRecoveryID = recoveryID
        relocationSuspended = true
        await cancelActiveVerificationAndDrain()
        guard failedShutdownRecoveryID == recoveryID else { return false }
        _ = await downloadClient.suspendAndDrain()
        guard failedShutdownRecoveryID == recoveryID else { return false }
        do {
            // This must precede mutation drain for the same reason as
            // relocation: the active mutation may be waiting inside MLX.
            try await runtimeDrainer(nil)
        } catch {
            guard failedShutdownRecoveryID == recoveryID else { return false }
            state.runtimeState = .failed(
                installation: state.inventory.lastKnownGood,
                reason: BuiltInModelFailureMessage.userFacing(
                    error,
                    context: .runtimeLoad
                )
            )
            scheduleFailedShutdownRecovery(id: recoveryID)
            return false
        }
        guard failedShutdownRecoveryID == recoveryID else { return false }
        await waitForMutationDrain()
        guard failedShutdownRecoveryID == recoveryID else { return false }
        failedShutdownRecoveryID = nil
        failedShutdownRecoveryTask = nil
        state.runtimeState = .unloaded
        return true
    }

    /// Waits only for recovery from a failed shutdown attempt. The app uses
    /// this after cancelling Quit so UI admission and startup reconciliation
    /// restart only after the pre-quit mutations and download drain are fully
    /// released. A successful/no-op shutdown has nothing to wait for.
    func waitForFailedShutdownRecovery() async {
        // Wait for the generation that existed at entry only. A newer Quit owns
        // its own waiter; following a replaced task here can spin on a completed
        // superseded task and starve the actor.
        let recovery = failedShutdownRecoveryTask
        await recovery?.value
    }

    /// A bounded Quit may be cancelled after this manager already completed its
    /// shutdown barrier. Reopen admission only after any failed-shutdown cleanup
    /// has finished; startup reconciliation owns loading the verified LKG again.
    func recoverAfterCancelledShutdown() async {
        let recovery = failedShutdownRecoveryTask
        await recovery?.value
        guard !Task.isCancelled, relocationSuspended else { return }
        await downloadClient.resumeAfterDrain()
        guard !Task.isCancelled else {
            _ = await downloadClient.suspendAndDrain()
            return
        }
        relocationSuspended = false
    }

    func resumeAfterRelocation() async throws {
        try requireOperationalRoot()
        failedShutdownRecoveryTask?.cancel()
        failedShutdownRecoveryID = nil
        failedShutdownRecoveryTask = nil
        defer { relocationSuspended = false }
        await downloadClient.resumeAfterDrain()
        if let installation = state.inventory.lastKnownGood,
           let manifest = manifest(for: installation.artifact) {
            guard try hardwareEligibility(manifest) else {
                throw BuiltInModelManagerError.unsupportedHardware
            }
            try await validateVerifiedInstallation(installation, manifest: manifest)
            try await candidateLoader(installedPayload(installation), manifest)
            state.runtimeState = .ready(installation)
        }
    }

    func storageSnapshot() throws -> BuiltInModelStorageSnapshot {
        try requireOperationalRoot()
        return try makeStorageSnapshot()
    }

    // MARK: - Provisioning

    private func provision(
        manifest: BuiltInModelManifest,
        installation: BuiltInModelInstallation,
        currentSelectionRevision: SelectionRevision,
        resuming: Bool
    ) async throws -> BuiltInModelManagerResult {
        guard state.inventory.candidate?.installation == installation else { return result() }
        try reclaimUnverifiedStaging(excluding: installation.installationID)
        let savedBytes = try savedPayloadBytes(for: installation)
        let requiredBytes = Self.requiredCapacity(
            artifactBytes: manifest.expectedDownloadBytes,
            savedBytes: savedBytes
        )
        let availableBytes: Int64
        do {
            availableBytes = try capacityReader(pinnedDataRoot)
        } catch {
            _ = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .provisioningFailed(
                    ProvisioningFailure(
                        stage: .preflight,
                        message: "capacity unavailable",
                        isRetryable: true
                    )
                )
            )
            try commit()
            throw BuiltInModelManagerError.capacityUnavailable
        }
        guard availableBytes >= requiredBytes else {
            _ = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .preflightBlocked(
                    requiredBytes: requiredBytes,
                    availableBytes: max(0, availableBytes)
                )
            )
            try commit()
            return result()
        }

        try prepareStaging(installation)
        let initialProgress = ProvisioningProgress(
            receivedBytes: savedBytes,
            expectedBytes: manifest.expectedDownloadBytes
        )
        if resuming {
            switch state.provisioningJob {
            case .paused, .pausedLowDisk:
                _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .resumeDownload)
            case .idle, .preflightBlocked, .failed:
                state.provisioningJob = .idle
                _ = BuiltInModelLifecycleReducer.reduce(
                    state: &state,
                    event: .downloadStarted(initialProgress)
                )
            case .downloading:
                break
            default:
                break
            }
        } else {
            _ = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .downloadStarted(initialProgress)
            )
        }
        if case .downloading = state.provisioningJob {
            try commit()
        }

        var completedBytes: Int64 = 0
        var ledger = loadResumeLedger(for: installation)
        for file in manifest.files {
            guard state.inventory.candidate?.installation == installation else { return result() }
            let finalURL = stagingPayload(installation).appending(path: file.relativePath)
            try securePayloadDirectory(
                finalURL.deletingLastPathComponent(),
                installation: installation
            )
            if try exactRegularFile(finalURL, expectedBytes: file.expectedBytes) {
                completedBytes += file.expectedBytes
                continue
            }

            let partialURL = finalURL.appendingPathExtension("partial")
            let plan = BuiltInDownloadPlan(
                sourceURL: file.sourceURL,
                revision: manifest.revision,
                manifestFingerprintSHA256: manifest.aggregateFingerprintSHA256,
                expectedBytes: file.expectedBytes,
                partialFileURL: partialURL
            )
            deferredProgressError = nil
            deferredLowDisk = nil
            let completedBeforeFile = completedBytes
            let outcome: BuiltInDownloadOutcome
            do {
                outcome = try await downloadClient.download(
                    plan: plan,
                    resumeState: ledger.files[file.relativePath],
                    onProgress: { [weak self] resumeState in
                        await self?.recordProgress(
                            resumeState,
                            relativePath: file.relativePath,
                            completedBytes: completedBeforeFile,
                            expectedBytes: manifest.expectedDownloadBytes,
                            artifactBytes: manifest.expectedDownloadBytes,
                            installation: installation
                        )
                    }
                )
            } catch {
                _ = BuiltInModelLifecycleReducer.reduce(
                    state: &state,
                    event: .provisioningFailed(
                        ProvisioningFailure(
                            stage: .download,
                            message: BuiltInModelFailureMessage.userFacing(error, context: .download),
                            isRetryable: true
                        )
                    )
                )
                try commit()
                return result()
            }
            if let deferredProgressError {
                _ = BuiltInModelLifecycleReducer.reduce(
                    state: &state,
                    event: .provisioningFailed(
                        ProvisioningFailure(
                            stage: .download,
                            message: deferredProgressError.localizedDescription,
                            isRetryable: true
                        )
                    )
                )
                try commit()
                throw deferredProgressError
            }
            guard state.inventory.candidate?.installation == installation else { return result() }

            if let deferredLowDisk {
                _ = BuiltInModelLifecycleReducer.reduce(
                    state: &state,
                    event: .pauseLowDisk(
                        requiredBytes: deferredLowDisk.requiredBytes,
                        availableBytes: deferredLowDisk.availableBytes
                    )
                )
                try removeIfPresent(stagingWrapper(installation))
                state.provisioningJob = .pausedLowDisk(
                    progress: ProvisioningProgress(
                        receivedBytes: 0,
                        expectedBytes: manifest.expectedDownloadBytes
                    ),
                    requiredBytes: deferredLowDisk.requiredBytes,
                    availableBytes: deferredLowDisk.availableBytes
                )
                try commit()
                return result()
            }

            switch outcome {
            case .completed:
                try promotePartialFile(partialURL, to: finalURL)
                completedBytes += file.expectedBytes
                ledger.files.removeValue(forKey: file.relativePath)
                try saveResumeLedger(ledger, for: installation)
                _ = BuiltInModelLifecycleReducer.reduce(
                    state: &state,
                    event: .downloadProgressed(
                        ProvisioningProgress(
                            receivedBytes: completedBytes,
                            expectedBytes: manifest.expectedDownloadBytes
                        )
                    )
                )
                try commit()

            case .paused(let resume), .interrupted(let resume):
                if let resume {
                    ledger.files[file.relativePath] = resume
                    _ = BuiltInModelLifecycleReducer.reduce(
                        state: &state,
                        event: .downloadProgressed(
                            ProvisioningProgress(
                                receivedBytes: min(
                                    manifest.expectedDownloadBytes,
                                    completedBytes + resume.receivedBytes
                                ),
                                expectedBytes: manifest.expectedDownloadBytes
                            )
                        )
                    )
                }
                try saveResumeLedger(ledger, for: installation)
                _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .pauseDownload)
                try commit()
                return result()

            case .pausedLowDisk(let resume, let required, let available):
                if let resume { ledger.files[file.relativePath] = resume }
                try saveResumeLedger(ledger, for: installation)
                _ = BuiltInModelLifecycleReducer.reduce(
                    state: &state,
                    event: .pauseLowDisk(requiredBytes: required, availableBytes: available)
                )
                try removeIfPresent(stagingWrapper(installation))
                state.provisioningJob = .pausedLowDisk(
                    progress: ProvisioningProgress(
                        receivedBytes: 0,
                        expectedBytes: manifest.expectedDownloadBytes
                    ),
                    requiredBytes: required,
                    availableBytes: available
                )
                try commit()
                return result()

            case .cancelled:
                return result()
            }
        }

        _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .beginVerification)
        try commit()
        return try await verifyPromoteAndLoad(
            manifest: manifest,
            installation: installation,
            currentSelectionRevision: currentSelectionRevision
        )
    }

    private func verifyPromoteAndLoad(
        manifest: BuiltInModelManifest,
        installation: BuiltInModelInstallation,
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult {
        if !FileManager.default.fileExists(atPath: installedWrapper(installation).path) {
            if case .verificationPending = state.provisioningJob {
                state.provisioningJob = .verifying
                try commit()
            }
            let operation = try startCandidateVerification(
                manifest: manifest,
                installation: installation
            )
            let verification: BuiltInModelVerification
            do {
                verification = try await awaitVerification(operation)
                guard ownsUnchangedVerification(operation),
                      state.inventory.candidate?.installation == installation else {
                    throw CancellationError()
                }
                try writeVerifiedRecord(
                    verification,
                    manifest: manifest,
                    wrapper: stagingWrapper(installation)
                )
                activeVerification = nil
            } catch is CancellationError {
                invalidateVerification(operation)
                try restoreVerificationRecoveryPointIfNeeded(installation)
                throw CancellationError()
            } catch {
                let stillOwned = ownsUnchangedVerification(operation)
                invalidateVerification(operation)
                guard stillOwned,
                      state.inventory.candidate?.installation == installation,
                      case .verifying = state.provisioningJob else {
                    try restoreVerificationRecoveryPointIfNeeded(installation)
                    throw CancellationError()
                }
                _ = BuiltInModelLifecycleReducer.reduce(
                    state: &state,
                    event: .provisioningFailed(
                        ProvisioningFailure(
                            stage: .verification,
                            message: BuiltInModelFailureMessage.userFacing(error, context: .verification),
                            isRetryable: true
                        )
                    )
                )
                try commit()
                return result()
            }
            try faultHook(.afterVerifiedMarker)
            _ = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .verificationSucceeded
            )
            try commit()
            try promoteStagingWrapper(installation)
            try faultHook(.afterPromotionBeforeLoad)
        }
        return try await loadPromotedCandidate(
            manifest: manifest,
            installation: installation,
            currentSelectionRevision: currentSelectionRevision
        )
    }

    private func startCandidateVerification(
        manifest: BuiltInModelManifest,
        installation: BuiltInModelInstallation
    ) throws -> ActiveVerification {
        guard activeVerification == nil,
              state.inventory.candidate?.installation == installation,
              case .verifying = state.provisioningJob else {
            throw CancellationError()
        }
        return try startVerification(
            directory: stagingPayload(installation),
            manifest: manifest,
            installation: installation
        )
    }

    private func startVerification(
        directory: URL,
        manifest: BuiltInModelManifest,
        installation: BuiltInModelInstallation
    ) throws -> ActiveVerification {
        guard activeVerification == nil else { throw CancellationError() }
        // Multi-gigabyte hashing must yield the manager actor so Cancel and
        // maintenance barriers can invalidate ownership and drain the reader.
        let verifier = candidateVerifier
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let verification = try await verifier(directory, manifest)
            try Task.checkCancellation()
            return verification
        }
        let operation = ActiveVerification(
            id: UUID(),
            installation: installation,
            expectedState: state,
            task: task
        )
        activeVerification = operation
        return operation
    }

    private func awaitVerification(
        _ operation: ActiveVerification
    ) async throws -> BuiltInModelVerification {
        try await withTaskCancellationHandler {
            try await operation.task.value
        } onCancel: {
            operation.task.cancel()
        }
    }

    private func ownsVerification(_ operation: ActiveVerification) -> Bool {
        activeVerification?.id == operation.id
            && activeVerification?.installation == operation.installation
    }

    private func ownsUnchangedVerification(_ operation: ActiveVerification) -> Bool {
        ownsVerification(operation) && state == operation.expectedState
    }

    private func invalidateVerification(_ operation: ActiveVerification) {
        guard ownsVerification(operation) else { return }
        activeVerification = nil
    }

    private func cancelActiveVerificationAndDrain() async {
        guard let operation = activeVerification else { return }
        activeVerification = nil
        operation.task.cancel()
        _ = await operation.task.result
    }

    private func restoreVerificationRecoveryPointIfNeeded(
        _ installation: BuiltInModelInstallation
    ) throws {
        guard state.inventory.candidate?.installation == installation,
              case .verifying = state.provisioningJob else { return }
        state.provisioningJob = .verificationPending
        try commit()
    }

    private func loadPromotedCandidate(
        manifest: BuiltInModelManifest,
        installation: BuiltInModelInstallation,
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult {
        guard state.inventory.candidate?.installation == installation else { return result() }
        do {
            try await validateVerifiedInstallation(installation, manifest: manifest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .candidateLoadFailed(
                    ProvisioningFailure(
                        stage: .verification,
                        message: BuiltInModelFailureMessage.userFacing(error, context: .verification),
                        isRetryable: true
                    )
                )
            )
            try commit()
            return result()
        }
        state.runtimeState = .loading(installation)
        do {
            try await candidateLoader(installedPayload(installation), manifest)
        } catch is CancellationError {
            // A relocation/shutdown runtime barrier invalidated this in-flight
            // load. Leave candidate recovery state intact; the barrier owns the
            // final unloaded runtime state after the mutation exits.
            throw CancellationError()
        } catch {
            _ = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .candidateLoadFailed(
                    ProvisioningFailure(
                        stage: .runtimeLoad,
                        message: BuiltInModelFailureMessage.userFacing(error, context: .runtimeLoad),
                        isRetryable: true
                    )
                )
            )
            do {
                try await restoreLastKnownGoodRuntimeAfterCandidateFailure()
            } catch is CancellationError {
                try commit()
                throw CancellationError()
            }
            try commit()
            return result()
        }
        try faultHook(.candidateLoadedBeforeJournal)

        let effects = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .candidateLoadSucceeded(currentSelectionRevision: currentSelectionRevision)
        )
        try commit()
        if !effects.isEmpty {
            try faultHook(.afterProviderEffectJournalBeforeDispatch)
        }
        try await dispatch(effects)
        try cleanupPendingInstallations()
        return result(effects: effects)
    }

    private func restoreLastKnownGoodRuntimeAfterCandidateFailure() async throws {
        guard let lastKnownGood = state.inventory.lastKnownGood else { return }
        guard let manifest = manifest(for: lastKnownGood.artifact) else {
            state.runtimeState = .failed(
                installation: lastKnownGood,
                reason: String(localized: "The installed built-in model manifest is unavailable.")
            )
            return
        }

        do {
            try await validateVerifiedInstallation(lastKnownGood, manifest: manifest)
            try await candidateLoader(installedPayload(lastKnownGood), manifest)
            state.runtimeState = .ready(lastKnownGood)
        } catch is CancellationError {
            state.runtimeState = .unloaded
            throw CancellationError()
        } catch {
            state.runtimeState = .failed(
                installation: lastKnownGood,
                reason: BuiltInModelFailureMessage.userFacing(error, context: .runtimeLoad)
            )
        }
    }

    private func recordProgress(
        _ resumeState: BuiltInDownloadResumeState,
        relativePath: String,
        completedBytes: Int64,
        expectedBytes: Int64,
        artifactBytes: Int64,
        installation: BuiltInModelInstallation
    ) {
        guard state.inventory.candidate?.installation == installation else { return }
        do {
            var ledger = loadResumeLedger(for: installation)
            ledger.files[relativePath] = resumeState
            try saveResumeLedger(ledger, for: installation)
            _ = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .downloadProgressed(
                    ProvisioningProgress(
                        receivedBytes: min(
                            expectedBytes,
                            completedBytes + resumeState.receivedBytes
                        ),
                        expectedBytes: expectedBytes
                    )
                )
            )
            try commit()
            let savedBytes = min(expectedBytes, completedBytes + resumeState.receivedBytes)
            let requiredBytes = Self.requiredCapacity(
                artifactBytes: artifactBytes,
                savedBytes: savedBytes
            )
            let availableBytes: Int64
            do {
                availableBytes = try capacityReader(pinnedDataRoot)
            } catch {
                deferredProgressError = .capacityUnavailable
                let client = downloadClient
                Task { _ = await client.suspendAndDrain() }
                return
            }
            if availableBytes < requiredBytes {
                deferredLowDisk = (
                    requiredBytes: requiredBytes,
                    availableBytes: max(0, availableBytes)
                )
                let client = downloadClient
                Task { _ = await client.suspendAndDrain() }
            }
        } catch let error as BuiltInModelManagerError {
            deferredProgressError = error
        } catch {
            deferredProgressError = .filesystem(operation: "commit progress", code: EIO)
        }
    }

    // MARK: - Restart, cleanup, and filesystem

    private func cleanupPendingInstallations() throws {
        for installation in state.inventory.cleanupPending {
            try removeIfPresent(stagingWrapper(installation))
            let tombstone: URL
            if FileManager.default.fileExists(atPath: installedWrapper(installation).path) {
                tombstone = try moveInstallationToTrash(installation)
            } else {
                tombstone = trashWrapper(installation)
            }
            try removeIfPresent(tombstone)
            _ = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .cleanupSucceeded(installation)
            )
            try commit()
        }
    }

    private func reconcileTrashAndCleanup() throws {
        try cleanupPendingInstallations()
        let referenced = Set(
            state.inventory.allInstallations.map {
                $0.installationID.uuidString.lowercased()
            }
        )
        let trash = pinnedDataRoot.appending(path: "trash", directoryHint: .isDirectory)
        for item in try FileManager.default.contentsOfDirectory(
            at: trash,
            includingPropertiesForKeys: nil
        ) where !referenced.contains(item.lastPathComponent) {
            try removeIfPresent(item)
        }
    }

    private func reclaimUnverifiedStaging(excluding installationID: UUID) throws {
        let staging = pinnedDataRoot.appending(path: "staging", directoryHint: .isDirectory)
        for item in try FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        ) where item.lastPathComponent != installationID.uuidString.lowercased() {
            try removeIfPresent(item)
        }
    }

    private func prepareStaging(_ installation: BuiltInModelInstallation) throws {
        try Self.secureDirectory(stagingWrapper(installation))
        try Self.secureDirectory(stagingPayload(installation))
    }

    private func securePayloadDirectory(
        _ directory: URL,
        installation: BuiltInModelInstallation
    ) throws {
        let base = stagingPayload(installation).standardizedFileURL
        let target = directory.standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
            throw BuiltInModelManagerError.invalidState("Manifest path escaped staging payload.")
        }
        try Self.secureDirectory(base)
        var current = base
        let suffix = target.path.dropFirst(base.path.count)
            .split(separator: "/")
        for component in suffix {
            current.append(path: String(component), directoryHint: .isDirectory)
            try Self.secureDirectory(current)
        }
    }

    private func promotePartialFile(_ partial: URL, to final: URL) throws {
        try removeIfPresent(final)
        guard chmod(partial.path, S_IRUSR | S_IWUSR) == 0 else {
            throw BuiltInModelManagerError.filesystem(operation: "chmod model file", code: errno)
        }
        guard rename(partial.path, final.path) == 0 else {
            throw BuiltInModelManagerError.filesystem(operation: "promote model file", code: errno)
        }
        try Self.syncDirectory(final.deletingLastPathComponent())
    }

    private func writeVerifiedRecord(
        _ verification: BuiltInModelVerification,
        manifest: BuiltInModelManifest,
        wrapper: URL
    ) throws {
        let record = VerifiedRecord(
            schemaVersion: 1,
            manifestID: manifest.id,
            artifactVersion: manifest.artifactVersion,
            manifestFingerprintSHA256: verification.aggregateFingerprintSHA256,
            verifiedBytes: verification.verifiedBytes,
            verifiedFileCount: verification.verifiedFileCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try Self.writeSecureAtomic(
            try encoder.encode(record),
            to: wrapper.appending(path: "verified.json")
        )
        try Self.syncDirectory(wrapper)
    }

    private func validateVerifiedInstallation(
        _ installation: BuiltInModelInstallation,
        manifest: BuiltInModelManifest
    ) async throws {
        let wrapper = installedWrapper(installation)
        let markerURL = wrapper.appending(path: "verified.json")
        try Self.validateSecureRegularFile(markerURL)
        let markerData = try Data(contentsOf: markerURL)
        let marker = try JSONDecoder().decode(VerifiedRecord.self, from: markerData)
        guard marker.schemaVersion == 1,
              marker.manifestID == manifest.id,
              marker.artifactVersion == manifest.artifactVersion,
              marker.manifestFingerprintSHA256 == manifest.aggregateFingerprintSHA256,
              marker.verifiedBytes == manifest.expectedDownloadBytes,
              marker.verifiedFileCount == manifest.files.count else {
            throw BuiltInModelManagerError.invalidState("Verified installation marker mismatch.")
        }
        let operation = try startVerification(
            directory: installedPayload(installation),
            manifest: manifest,
            installation: installation
        )
        do {
            _ = try await awaitVerification(operation)
            guard ownsUnchangedVerification(operation) else {
                throw CancellationError()
            }
            invalidateVerification(operation)
        } catch {
            invalidateVerification(operation)
            throw error
        }
    }

    private func promoteStagingWrapper(_ installation: BuiltInModelInstallation) throws {
        let source = stagingWrapper(installation)
        let destination = installedWrapper(installation)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BuiltInModelManagerError.invalidState("Installation destination already exists.")
        }
        guard rename(source.path, destination.path) == 0 else {
            throw BuiltInModelManagerError.filesystem(operation: "promote installation", code: errno)
        }
        try Self.syncDirectory(source.deletingLastPathComponent())
        try Self.syncDirectory(destination.deletingLastPathComponent())
    }

    private func moveInstallationToTrash(_ installation: BuiltInModelInstallation) throws -> URL {
        let source = installedWrapper(installation)
        let destination = trashWrapper(installation)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard FileManager.default.fileExists(atPath: source.path) else { return destination }
        guard rename(source.path, destination.path) == 0 else {
            throw BuiltInModelManagerError.filesystem(operation: "tombstone installation", code: errno)
        }
        try Self.syncDirectory(source.deletingLastPathComponent())
        try Self.syncDirectory(destination.deletingLastPathComponent())
        return destination
    }

    private func loadResumeLedger(for installation: BuiltInModelInstallation) -> ResumeLedger {
        let url = resumeLedgerURL(installation)
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(ResumeLedger.self, from: data) else {
            return ResumeLedger(files: [:])
        }
        return ledger
    }

    private func saveResumeLedger(
        _ ledger: ResumeLedger,
        for installation: BuiltInModelInstallation
    ) throws {
        try Self.writeSecureAtomic(
            try JSONEncoder().encode(ledger),
            to: resumeLedgerURL(installation)
        )
    }

    private func savedPayloadBytes(for installation: BuiltInModelInstallation) throws -> Int64 {
        try Self.byteCount(stagingPayload(installation))
    }

    private func exactRegularFile(_ url: URL, expectedBytes: Int64) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_nlink == 1,
              metadata.st_size == expectedBytes else {
            try removeIfPresent(url)
            return false
        }
        return true
    }

    private func makeStorageSnapshot() throws -> BuiltInModelStorageSnapshot {
        let lastKnownGood = state.inventory.lastKnownGood
        let activeManifest = lastKnownGood.flatMap { manifest(for: $0.artifact) }
        return BuiltInModelStorageSnapshot(
            pinnedDataRoot: pinnedDataRoot,
            journalBytes: try Self.fileBytes(pinnedDataRoot.appending(path: "journal.json")),
            installedBytes: try Self.byteCount(
                pinnedDataRoot.appending(path: "installed", directoryHint: .isDirectory)
            ),
            stagingBytes: try Self.byteCount(
                pinnedDataRoot.appending(path: "staging", directoryHint: .isDirectory)
            ),
            trashBytes: try Self.byteCount(
                pinnedDataRoot.appending(path: "trash", directoryHint: .isDirectory)
            ),
            activeInstallationID: lastKnownGood?.installationID,
            activeManifestFingerprintSHA256: lastKnownGood?.artifact.manifestFingerprintSHA256,
            activeVerifiedBytes: activeManifest?.expectedDownloadBytes ?? 0
        )
    }

    private func requireOperationalRoot() throws {
        guard let identity = try? Self.directoryIdentity(pinnedDataRoot),
              identity.device == pinnedRootDevice,
              identity.inode == pinnedRootInode,
              pinnedDataRoot.resolvingSymlinksInPath().standardizedFileURL == pinnedDataRoot else {
            throw BuiltInModelManagerError.rootUnavailable
        }
    }

    private func beginMutation() throws -> UUID {
        guard !relocationSuspended else {
            throw BuiltInModelManagerError.suspendedForRelocation
        }
        let id = UUID()
        activeMutations.insert(id)
        return id
    }

    private func finishMutation(_ id: UUID) {
        guard activeMutations.remove(id) != nil,
              activeMutations.isEmpty else { return }
        let waiters = mutationDrainWaiters
        mutationDrainWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func waitForMutationDrain() async {
        guard !activeMutations.isEmpty else { return }
        await withCheckedContinuation { mutationDrainWaiters.append($0) }
    }

    private func scheduleFailedShutdownRecovery(id: UUID) {
        let recovery = Task {
            await self.waitForMutationDrain()
            guard !Task.isCancelled,
                  self.failedShutdownRecoveryID == id else { return }
            await self.downloadClient.resumeAfterDrain()
            guard !Task.isCancelled,
                  self.failedShutdownRecoveryID == id else {
                _ = await self.downloadClient.suspendAndDrain()
                return
            }
            self.relocationSuspended = false
            self.failedShutdownRecoveryID = nil
            self.failedShutdownRecoveryTask = nil
        }
        failedShutdownRecoveryTask = recovery
    }

    private func commit() throws {
        do {
            try journalStore.save(state)
        } catch let error as BuiltInModelJournalError {
            switch error {
            case .unsupportedSchema: throw BuiltInModelManagerError.futureJournal
            case .corrupt, .inconsistentState: throw BuiltInModelManagerError.corruptJournal
            case .missing: throw BuiltInModelManagerError.corruptJournal
            case .io(_, let code):
                throw BuiltInModelManagerError.filesystem(operation: "journal commit", code: code)
            }
        }
    }

    private func makeSnapshot() -> BuiltInModelManagerSnapshot {
        let currentIdentity = try? Self.directoryIdentity(pinnedDataRoot)
        let rootAvailable = currentIdentity?.device == pinnedRootDevice
            && currentIdentity?.inode == pinnedRootInode
        return BuiltInModelManagerSnapshot(
            state: state,
            projection: BuiltInModelLifecycleReducer.project(state),
            pinnedDataRoot: pinnedDataRoot,
            rootAvailable: rootAvailable,
            suspendedForRelocation: relocationSuspended
        )
    }

    private func result(
        effects: [BuiltInModelLifecycleEffect] = []
    ) -> BuiltInModelManagerResult {
        BuiltInModelManagerResult(snapshot: makeSnapshot(), effects: effects)
    }

    private func dispatch(_ effects: [BuiltInModelLifecycleEffect]) async throws {
        for effect in effects {
            guard state.pendingProviderEffect == effect else { continue }
            let outcome = await effectHandler(effect)
            guard state.pendingProviderEffect == effect else { continue }
            switch outcome {
            case .applied:
                try faultHook(.afterProviderEffectAppliedBeforeRecoveryJournal)
                state.pendingProviderEffect = nil
                state.providerEffectRecovery = effect
                // This receipt was created by the current process. Even when
                // it supersedes an older restored receipt, it may only be
                // acknowledged by a later manager initialization.
                providerEffectRecoveryForReplay = nil
                try commit()
                try faultHook(.afterProviderEffectRecoveryJournal)
            case .stale:
                state.pendingProviderEffect = nil
                try commit()
            case .retryablePersistenceFailure:
                continue
            }
        }
    }

    /// Replays only the receipt that existed when this manager was initialized.
    /// A receipt written during the current process remains durable until the
    /// next process boundary, even when reconcile created it moments ago.
    private func replayRestoredProviderEffectRecoveryIfEligible() async throws
        -> [BuiltInModelLifecycleEffect] {
        guard let effect = providerEffectRecoveryForReplay,
              state.providerEffectRecovery == effect else {
            providerEffectRecoveryForReplay = nil
            return []
        }

        if case .requestActivation(let intent) = effect {
            guard let installed = state.inventory.lastKnownGood,
                  installed.artifact.modelID == intent.modelID else {
                state.providerEffectRecovery = nil
                providerEffectRecoveryForReplay = nil
                try commit()
                return []
            }
            guard state.runtimeState == .ready(installed) else {
                return []
            }
        }

        let outcome = await effectHandler(effect)
        guard providerEffectRecoveryForReplay == effect,
              state.providerEffectRecovery == effect else { return [effect] }
        switch outcome {
        case .applied, .stale:
            state.providerEffectRecovery = nil
            providerEffectRecoveryForReplay = nil
            try commit()
        case .retryablePersistenceFailure:
            break
        }
        return [effect]
    }

    private func finishReconciliation(
        effects: [BuiltInModelLifecycleEffect] = []
    ) async throws -> BuiltInModelManagerResult {
        let recoveryEffects = try await replayRestoredProviderEffectRecoveryIfEligible()
        return result(effects: effects + recoveryEffects)
    }

    /// Provider selection is persisted separately from the model journal. A
    /// crash-safe lifecycle effect is replayable only while it still owns the
    /// exact selection revision that created it; stale work is durably
    /// acknowledged without mutating the user's newer provider choice.
    private func discardStaleProviderWork(
        currentSelectionRevision: SelectionRevision
    ) throws {
        var changed = false

        if let intent = state.activationIntent,
           intent.expectedSelectionRevision != currentSelectionRevision {
            state.activationIntent = nil
            changed = true
        }
        if let intent = state.deactivationIntent,
           intent.expectedSelectionRevision != currentSelectionRevision {
            state.deactivationIntent = nil
            changed = true
        }
        if let effect = state.pendingProviderEffect {
            let expectedRevision: SelectionRevision
            switch effect {
            case .requestActivation(let intent):
                expectedRevision = intent.expectedSelectionRevision
            case .requestDeactivation(let intent):
                expectedRevision = intent.expectedSelectionRevision
            }
            if expectedRevision != currentSelectionRevision {
                state.pendingProviderEffect = nil
                changed = true
            }
        }

        if changed {
            try commit()
        }
    }

    private func manifest(for artifact: BuiltInModelArtifact) -> BuiltInModelManifest? {
        guard let manifest = manifestsByFingerprint[artifact.manifestFingerprintSHA256],
              manifest.id == artifact.modelID,
              manifest.artifactVersion == artifact.artifactVersion else { return nil }
        return manifest
    }

    private func stagingWrapper(_ installation: BuiltInModelInstallation) -> URL {
        pinnedDataRoot.appending(path: "staging", directoryHint: .isDirectory)
            .appending(path: installation.installationID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func stagingPayload(_ installation: BuiltInModelInstallation) -> URL {
        stagingWrapper(installation).appending(path: "payload", directoryHint: .isDirectory)
    }

    private func installedWrapper(_ installation: BuiltInModelInstallation) -> URL {
        pinnedDataRoot.appending(path: "installed", directoryHint: .isDirectory)
            .appending(path: installation.installationID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func installedPayload(_ installation: BuiltInModelInstallation) -> URL {
        installedWrapper(installation).appending(path: "payload", directoryHint: .isDirectory)
    }

    private func trashWrapper(_ installation: BuiltInModelInstallation) -> URL {
        pinnedDataRoot.appending(path: "trash", directoryHint: .isDirectory)
            .appending(path: installation.installationID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    private func resumeLedgerURL(_ installation: BuiltInModelInstallation) -> URL {
        stagingWrapper(installation).appending(path: "resume.json")
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            try Self.syncDirectory(url.deletingLastPathComponent())
        } catch {
            if let managerError = error as? BuiltInModelManagerError { throw managerError }
            throw BuiltInModelManagerError.filesystem(operation: "remove \(url.lastPathComponent)", code: errno)
        }
    }

    private static func makeInstallation(
        for manifest: BuiltInModelManifest
    ) -> BuiltInModelInstallation {
        let id = UUID()
        return BuiltInModelInstallation(
            artifact: BuiltInModelArtifact(
                modelID: manifest.id,
                artifactVersion: manifest.artifactVersion,
                manifestFingerprintSHA256: manifest.aggregateFingerprintSHA256
            ),
            installationID: id,
            relativeDirectory: "installed/\(id.uuidString.lowercased())/payload"
        )!
    }

    private static func validateManifest(_ manifest: BuiltInModelManifest) throws {
        let fingerprint = manifest.aggregateFingerprintSHA256
        guard !manifest.id.isEmpty,
              manifest.artifactVersion > 0,
              manifest.expectedDownloadBytes > 0,
              fingerprint.utf8.count == 64,
              fingerprint.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }),
              !manifest.files.isEmpty else {
            throw BuiltInModelManagerError.invalidState("Invalid manifest identity.")
        }

        var paths = Set<String>()
        var expectedBytes: Int64 = 0
        for file in manifest.files {
            let path = file.relativePath.precomposedStringWithCanonicalMapping
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path == file.relativePath,
                  !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.contains("\\"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  paths.insert(path).inserted,
                  file.expectedBytes > 0,
                  file.sha256.utf8.count == 64,
                  file.sha256.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (97...102).contains(byte)
                  }) else {
                throw BuiltInModelManagerError.invalidState("Unsafe manifest file inventory.")
            }
            let sum = expectedBytes.addingReportingOverflow(file.expectedBytes)
            guard !sum.overflow else {
                throw BuiltInModelManagerError.invalidState("Manifest size overflow.")
            }
            expectedBytes = sum.partialValue
        }
        for path in paths {
            guard !paths.contains(path + ".partial") else {
                throw BuiltInModelManagerError.invalidState("Manifest partial-path collision.")
            }
            let prefix = path + "/"
            guard !paths.contains(where: { $0.hasPrefix(prefix) }) else {
                throw BuiltInModelManagerError.invalidState("Manifest file/directory collision.")
            }
        }
        guard expectedBytes == manifest.expectedDownloadBytes else {
            throw BuiltInModelManagerError.invalidState("Manifest byte total mismatch.")
        }
    }

    private static func requiredCapacity(
        artifactBytes: Int64,
        savedBytes: Int64
    ) -> Int64 {
        let doubled = artifactBytes.multipliedReportingOverflow(by: 2)
        guard !doubled.overflow else { return Int64.max }
        return DiskReservePolicy.standard.addingModelReserve(
            to: max(0, doubled.partialValue - max(0, savedBytes))
        )
    }

    private static func secureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw BuiltInModelManagerError.filesystem(operation: "create directory", code: errno)
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              chmod(url.path, S_IRWXU) == 0 else {
            throw BuiltInModelManagerError.filesystem(operation: "secure directory", code: errno)
        }
    }

    private static func writeSecureAtomic(_ data: Data, to destination: URL) throws {
        try secureDirectory(destination.deletingLastPathComponent())
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw BuiltInModelManagerError.filesystem(operation: "open atomic file", code: errno)
        }
        var shouldRemove = true
        defer {
            _ = close(descriptor)
            if shouldRemove { try? FileManager.default.removeItem(at: temporary) }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw BuiltInModelManagerError.filesystem(operation: "write atomic file", code: errno)
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw BuiltInModelManagerError.filesystem(operation: "fsync atomic file", code: errno)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw BuiltInModelManagerError.filesystem(operation: "rename atomic file", code: errno)
        }
        shouldRemove = false
        try syncDirectory(destination.deletingLastPathComponent())
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw BuiltInModelManagerError.filesystem(operation: "open directory for fsync", code: errno)
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw BuiltInModelManagerError.filesystem(operation: "fsync directory", code: errno)
        }
    }

    private static func isAvailableDirectory(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
            && (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    private static func directoryIdentity(_ url: URL) throws -> (device: UInt64, inode: UInt64) {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw BuiltInModelManagerError.rootUnavailable
        }
        return (UInt64(metadata.st_dev), UInt64(metadata.st_ino))
    }

    private static func fileBytes(_ url: URL) throws -> Int64 {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return 0 }
            throw BuiltInModelManagerError.filesystem(operation: "stat file", code: errno)
        }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return 0 }
        return metadata.st_size
    }

    private static func validateSecureRegularFile(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_nlink == 1,
              (metadata.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw BuiltInModelManagerError.invalidState("Unsafe verified installation marker.")
        }
    }

    private static func byteCount(_ root: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true {
                total += try fileBytes(item)
            }
        }
        return total
    }
}
