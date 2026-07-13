import Foundation

/// Stable identity of the manifest bytes. A manifest is not an installation:
/// reinstalling the same manifest gets a new installation ID and directory.
struct BuiltInModelArtifact: Codable, Sendable, Equatable, Hashable {
    let modelID: String
    let artifactVersion: Int
    let manifestFingerprintSHA256: String
}

/// One filesystem installation. `relativeDirectory` is deliberately validated
/// at construction and decode time so a journal can never escape the model root.
struct BuiltInModelInstallation: Codable, Sendable, Equatable, Hashable {
    let artifact: BuiltInModelArtifact
    let installationID: UUID
    let relativeDirectory: String

    init?(
        artifact: BuiltInModelArtifact,
        installationID: UUID,
        relativeDirectory: String
    ) {
        guard Self.isSafe(relativeDirectory: relativeDirectory) else { return nil }
        self.artifact = artifact
        self.installationID = installationID
        self.relativeDirectory = relativeDirectory
    }

    static func fresh(artifact: BuiltInModelArtifact) -> BuiltInModelInstallation {
        let id = UUID()
        return BuiltInModelInstallation(
            artifact: artifact,
            installationID: id,
            relativeDirectory: "installations/\(id.uuidString.lowercased())"
        )!
    }

    private enum CodingKeys: String, CodingKey {
        case artifact
        case installationID
        case relativeDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let artifact = try container.decode(BuiltInModelArtifact.self, forKey: .artifact)
        let installationID = try container.decode(UUID.self, forKey: .installationID)
        let relativeDirectory = try container.decode(String.self, forKey: .relativeDirectory)
        guard let validated = BuiltInModelInstallation(
            artifact: artifact,
            installationID: installationID,
            relativeDirectory: relativeDirectory
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .relativeDirectory,
                in: container,
                debugDescription: "Unsafe built-in model relative directory"
            )
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(artifact, forKey: .artifact)
        try container.encode(installationID, forKey: .installationID)
        try container.encode(relativeDirectory, forKey: .relativeDirectory)
    }

    private static func isSafe(relativeDirectory: String) -> Bool {
        guard !relativeDirectory.isEmpty,
              !relativeDirectory.hasPrefix("/"),
              !relativeDirectory.hasSuffix("/"),
              relativeDirectory == relativeDirectory.lowercased(),
              relativeDirectory.utf8.count <= 512,
              relativeDirectory.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 46, 47, 48...57, 65...90, 95, 97...122:
                      return true
                  default:
                      return false
                  }
              }) else { return false }

        let components = relativeDirectory.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.allSatisfy { component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && component.utf8.count <= 255
        }
    }
}

enum BuiltInModelCandidateVerification: String, Codable, Sendable {
    case partial
    case verified
}

struct BuiltInModelCandidate: Codable, Sendable, Equatable {
    let installation: BuiltInModelInstallation
    var verification: BuiltInModelCandidateVerification

    var artifact: BuiltInModelArtifact { installation.artifact }
}

/// Durable inventory. Cleanup tombstones ensure a promotion or discard cannot
/// make a prior directory unreachable if the process exits before deletion.
struct ArtifactInventory: Codable, Sendable, Equatable {
    var lastKnownGood: BuiltInModelInstallation?
    var candidate: BuiltInModelCandidate?
    var cleanupPending: [BuiltInModelInstallation]

    init(
        lastKnownGood: BuiltInModelInstallation?,
        candidate: BuiltInModelCandidate?,
        cleanupPending: [BuiltInModelInstallation] = []
    ) {
        self.lastKnownGood = lastKnownGood
        self.candidate = candidate
        self.cleanupPending = cleanupPending
    }

    static let empty = ArtifactInventory(lastKnownGood: nil, candidate: nil)

    mutating func enqueueCleanup(_ installation: BuiltInModelInstallation) {
        guard !cleanupPending.contains(installation) else { return }
        cleanupPending.append(installation)
    }

    func containsIdentityOrDirectory(
        of installation: BuiltInModelInstallation
    ) -> Bool {
        allInstallations.contains { existing in
            existing.installationID == installation.installationID
                || existing.relativeDirectory == installation.relativeDirectory
        }
    }

    var allInstallations: [BuiltInModelInstallation] {
        [lastKnownGood, candidate?.installation].compactMap { $0 } + cleanupPending
    }

    private enum CodingKeys: String, CodingKey {
        case lastKnownGood
        case candidate
        case cleanupPending
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastKnownGood = try container.decodeIfPresent(
            BuiltInModelInstallation.self,
            forKey: .lastKnownGood
        )
        candidate = try container.decodeIfPresent(
            BuiltInModelCandidate.self,
            forKey: .candidate
        )
        cleanupPending = try container.decodeIfPresent(
            [BuiltInModelInstallation].self,
            forKey: .cleanupPending
        ) ?? []
    }
}

struct ProvisioningProgress: Codable, Sendable, Equatable {
    let receivedBytes: Int64
    let expectedBytes: Int64
}

enum ProvisioningFailureStage: String, Codable, Sendable {
    case preflight
    case download
    case verification
    case runtimeLoad
    case removal
}

struct ProvisioningFailure: Codable, Sendable, Equatable {
    let stage: ProvisioningFailureStage
    let message: String
    let isRetryable: Bool
}

/// Durable work state. Active operations are reconciled into explicit recovery
/// states on startup; a journal never claims that an interrupted worker lives.
enum ProvisioningJob: Codable, Sendable, Equatable {
    case idle
    case preflightBlocked(requiredBytes: Int64, availableBytes: Int64)
    case downloading(ProvisioningProgress)
    case paused(ProvisioningProgress)
    case pausedLowDisk(
        progress: ProvisioningProgress,
        requiredBytes: Int64,
        availableBytes: Int64
    )
    case verifying
    case verificationPending
    case failed(ProvisioningFailure)
    case waitingForRuntimeDrain(BuiltInModelInstallation)
    case removing(BuiltInModelInstallation)
    case removalPending(BuiltInModelInstallation)
}

/// Process-local runtime state. Persistence is intentionally owned by
/// `BuiltInModelJournal`, which does not encode this type.
enum RuntimeState: Codable, Sendable, Equatable {
    case unloaded
    case loading(BuiltInModelInstallation)
    case ready(BuiltInModelInstallation)
    case generating(BuiltInModelInstallation)
    case failed(installation: BuiltInModelInstallation?, reason: String)
}

/// Not Codable by design: callers cannot accidentally persist process-local
/// runtime truth. Use `BuiltInModelJournal` for the durable subset.
struct BuiltInModelLifecycleState: Sendable, Equatable {
    var inventory: ArtifactInventory
    var provisioningJob: ProvisioningJob
    var activationIntent: ActivationIntent?
    var deactivationIntent: DeactivationIntent?
    var pendingProviderEffect: BuiltInModelLifecycleEffect?
    var providerEffectRecovery: BuiltInModelLifecycleEffect?
    var runtimeState: RuntimeState

    init(
        inventory: ArtifactInventory,
        provisioningJob: ProvisioningJob,
        activationIntent: ActivationIntent?,
        deactivationIntent: DeactivationIntent? = nil,
        pendingProviderEffect: BuiltInModelLifecycleEffect? = nil,
        providerEffectRecovery: BuiltInModelLifecycleEffect? = nil,
        runtimeState: RuntimeState
    ) {
        self.inventory = inventory
        self.provisioningJob = provisioningJob
        self.activationIntent = activationIntent
        self.deactivationIntent = deactivationIntent
        self.pendingProviderEffect = pendingProviderEffect
        self.providerEffectRecovery = providerEffectRecovery
        self.runtimeState = runtimeState
    }

    static let initial = BuiltInModelLifecycleState(
        inventory: .empty,
        provisioningJob: .idle,
        activationIntent: nil,
        deactivationIntent: nil,
        pendingProviderEffect: nil,
        providerEffectRecovery: nil,
        runtimeState: .unloaded
    )
}

enum BuiltInModelReadiness: String, Sendable, Equatable {
    case unavailable
    case loading
    case usable
    case installedButRuntimeFailed
    case removing
}

enum CandidateProvisioningStatus: String, Sendable, Equatable {
    case none
    case staged
    case preflightBlocked
    case downloading
    case paused
    case pausedLowDisk
    case verifying
    case verified
    case failed
}

enum BuiltInModelLifecycleAction: String, Sendable, Equatable, Hashable {
    case downloadAndEnable
    case pause
    case resume
    case cancel
    case retry
    case discardCandidate
    case cancelLoad
    case retryLoad
    case reinstall
    case remove
}

struct BuiltInModelLifecycleProjection: Sendable, Equatable {
    let readiness: BuiltInModelReadiness
    let candidateStatus: CandidateProvisioningStatus
    let actions: Set<BuiltInModelLifecycleAction>

    var isUsable: Bool { readiness == .usable }
}

enum BuiltInModelLifecycleEvent: Sendable, Equatable {
    case prepareCandidate(BuiltInModelInstallation, activationIntent: ActivationIntent?)
    case preflightBlocked(requiredBytes: Int64, availableBytes: Int64)
    case downloadStarted(ProvisioningProgress)
    case downloadProgressed(ProvisioningProgress)
    case pauseDownload
    case pauseLowDisk(requiredBytes: Int64, availableBytes: Int64)
    case resumeDownload
    case beginVerification
    case verificationSucceeded
    case provisioningFailed(ProvisioningFailure)
    case candidateLoadFailed(ProvisioningFailure)
    case candidateLoadSucceeded(currentSelectionRevision: SelectionRevision)
    case discardCandidate
    case cleanupSucceeded(BuiltInModelInstallation)
    case runtimeChanged(RuntimeState)
    case beginRemoval(deactivationIntent: DeactivationIntent?)
    case runtimeDrainAcknowledged(BuiltInModelInstallation)
    case removalSucceeded(BuiltInModelInstallation)
    case removalFailed(ProvisioningFailure)
}

enum BuiltInModelLifecycleEffect: Codable, Sendable, Equatable {
    case requestActivation(ActivationIntent)
    case requestDeactivation(DeactivationIntent)
}

enum BuiltInModelLifecycleReducer {
    @discardableResult
    static func reduce(
        state: inout BuiltInModelLifecycleState,
        event: BuiltInModelLifecycleEvent
    ) -> [BuiltInModelLifecycleEffect] {
        switch event {
        case .prepareCandidate(let installation, let activationIntent):
            guard state.inventory.candidate == nil,
                  state.provisioningJob == .idle,
                  state.pendingProviderEffect == nil,
                  !state.inventory.containsIdentityOrDirectory(of: installation) else {
                return []
            }
            if let activationIntent {
                guard activationIntent.providerID == AIProvider.zbsEyeLocal.rawValue,
                      activationIntent.modelID == installation.artifact.modelID else {
                    return []
                }
            }
            state.inventory.candidate = BuiltInModelCandidate(
                installation: installation,
                verification: .partial
            )
            state.activationIntent = activationIntent

        case .preflightBlocked(let requiredBytes, let availableBytes):
            guard state.inventory.candidate != nil else { return [] }
            state.provisioningJob = .preflightBlocked(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )

        case .downloadStarted(let progress):
            guard state.inventory.candidate != nil else { return [] }
            switch state.provisioningJob {
            case .idle, .preflightBlocked:
                state.provisioningJob = .downloading(progress)
            default:
                return []
            }

        case .downloadProgressed(let progress):
            guard case .downloading = state.provisioningJob else { return [] }
            state.provisioningJob = .downloading(progress)

        case .pauseDownload:
            guard case .downloading(let progress) = state.provisioningJob else { return [] }
            state.provisioningJob = .paused(progress)

        case .pauseLowDisk(let requiredBytes, let availableBytes):
            let progress: ProvisioningProgress
            switch state.provisioningJob {
            case .downloading(let current), .paused(let current):
                progress = current
            case .pausedLowDisk(let current, _, _):
                progress = current
            default:
                return []
            }
            state.provisioningJob = .pausedLowDisk(
                progress: progress,
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )

        case .resumeDownload:
            let progress: ProvisioningProgress
            switch state.provisioningJob {
            case .paused(let current), .pausedLowDisk(let current, _, _):
                progress = current
            default:
                return []
            }
            state.provisioningJob = .downloading(progress)

        case .beginVerification:
            guard state.inventory.candidate != nil else { return [] }
            switch state.provisioningJob {
            case .downloading, .paused, .verificationPending:
                state.provisioningJob = .verifying
            default:
                return []
            }

        case .verificationSucceeded:
            guard case .verifying = state.provisioningJob,
                  var candidate = state.inventory.candidate else { return [] }
            candidate.verification = .verified
            state.inventory.candidate = candidate
            state.provisioningJob = .idle

        case .provisioningFailed(let failure):
            guard state.inventory.candidate != nil else { return [] }
            state.provisioningJob = .failed(failure)

        case .candidateLoadFailed(let failure):
            guard let candidate = state.inventory.candidate,
                  candidate.verification == .verified else { return [] }
            state.provisioningJob = .failed(failure)
            if state.inventory.lastKnownGood == nil {
                state.runtimeState = .failed(
                    installation: candidate.installation,
                    reason: failure.message
                )
            }

        case .candidateLoadSucceeded(let currentSelectionRevision):
            guard let candidate = state.inventory.candidate,
                  candidate.verification == .verified else { return [] }

            let intent = state.activationIntent
            if let previous = state.inventory.lastKnownGood,
               previous != candidate.installation {
                state.inventory.enqueueCleanup(previous)
            }
            state.inventory.lastKnownGood = candidate.installation
            state.inventory.candidate = nil
            state.provisioningJob = .idle
            state.runtimeState = .ready(candidate.installation)
            state.activationIntent = nil

            guard let intent,
                  intent.expectedSelectionRevision == currentSelectionRevision,
                  intent.providerID == AIProvider.zbsEyeLocal.rawValue,
                  intent.modelID == candidate.artifact.modelID else { return [] }
            let effect = BuiltInModelLifecycleEffect.requestActivation(intent)
            state.pendingProviderEffect = effect
            return [effect]

        case .discardCandidate:
            guard let discarded = state.inventory.candidate?.installation else { return [] }
            state.inventory.enqueueCleanup(discarded)
            state.inventory.candidate = nil
            state.provisioningJob = .idle
            state.activationIntent = nil
            if state.runtimeState.references(discarded) {
                state.runtimeState = .unloaded
            }

        case .cleanupSucceeded(let installation):
            state.inventory.cleanupPending.removeAll { $0 == installation }

        case .runtimeChanged(let runtimeState):
            guard runtimeState.isValid(for: state.inventory) else { return [] }
            state.runtimeState = runtimeState

        case .beginRemoval(let deactivationIntent):
            guard let lastKnownGood = state.inventory.lastKnownGood,
                  state.inventory.candidate == nil,
                  state.pendingProviderEffect == nil else { return [] }
            if let deactivationIntent {
                guard deactivationIntent.providerID == AIProvider.zbsEyeLocal.rawValue,
                      deactivationIntent.modelID == lastKnownGood.artifact.modelID else {
                    return []
                }
            }
            switch state.provisioningJob {
            case .idle:
                state.provisioningJob = .waitingForRuntimeDrain(lastKnownGood)
                state.deactivationIntent = deactivationIntent
            case .failed(let failure) where failure.stage == .removal:
                state.provisioningJob = .waitingForRuntimeDrain(lastKnownGood)
                state.deactivationIntent = deactivationIntent
            default:
                return []
            }

        case .runtimeDrainAcknowledged(let installation):
            guard case .waitingForRuntimeDrain(let target) = state.provisioningJob,
                  target == installation,
                  state.inventory.lastKnownGood == installation else { return [] }
            state.runtimeState = .unloaded
            state.provisioningJob = .removing(installation)

        case .removalSucceeded(let installation):
            let target: BuiltInModelInstallation
            switch state.provisioningJob {
            case .removing(let current), .removalPending(let current):
                target = current
            default:
                return []
            }
            guard target == installation,
                  state.inventory.lastKnownGood == installation else { return [] }
            let deactivationIntent = state.deactivationIntent
            state.inventory.lastKnownGood = nil
            state.provisioningJob = .idle
            state.deactivationIntent = nil
            state.runtimeState = .unloaded
            guard let deactivationIntent else { return [] }
            let effect = BuiltInModelLifecycleEffect.requestDeactivation(deactivationIntent)
            state.pendingProviderEffect = effect
            return [effect]

        case .removalFailed(let failure):
            guard failure.stage == .removal else { return [] }
            switch state.provisioningJob {
            case .waitingForRuntimeDrain, .removing, .removalPending:
                state.provisioningJob = .failed(failure)
            default:
                return []
            }
        }

        return []
    }

    static func project(
        _ state: BuiltInModelLifecycleState
    ) -> BuiltInModelLifecycleProjection {
        let readiness = readiness(for: state)
        let candidateStatus = candidateStatus(for: state)
        return BuiltInModelLifecycleProjection(
            readiness: readiness,
            candidateStatus: candidateStatus,
            actions: actions(
                for: state,
                readiness: readiness,
                candidateStatus: candidateStatus
            )
        )
    }

    private static func readiness(
        for state: BuiltInModelLifecycleState
    ) -> BuiltInModelReadiness {
        switch state.provisioningJob {
        case .waitingForRuntimeDrain, .removing, .removalPending:
            return .removing
        default:
            break
        }

        guard let lastKnownGood = state.inventory.lastKnownGood else {
            if case .loading(let installation) = state.runtimeState,
               state.inventory.candidate?.verification == .verified,
               state.inventory.candidate?.installation == installation {
                return .loading
            }
            return .unavailable
        }

        switch state.runtimeState {
        case .ready(let installation), .generating(let installation):
            return installation == lastKnownGood ? .usable : .loading
        case .failed:
            return .installedButRuntimeFailed
        case .unloaded, .loading:
            return .loading
        }
    }

    private static func candidateStatus(
        for state: BuiltInModelLifecycleState
    ) -> CandidateProvisioningStatus {
        switch state.provisioningJob {
        case .preflightBlocked:
            return .preflightBlocked
        case .downloading:
            return .downloading
        case .paused:
            return .paused
        case .pausedLowDisk:
            return .pausedLowDisk
        case .verifying, .verificationPending:
            return .verifying
        case .failed:
            return .failed
        case .waitingForRuntimeDrain, .removing, .removalPending:
            return .none
        case .idle:
            switch state.inventory.candidate?.verification {
            case .partial:
                return .staged
            case .verified:
                return .verified
            case nil:
                return .none
            }
        }
    }

    private static func actions(
        for state: BuiltInModelLifecycleState,
        readiness: BuiltInModelReadiness,
        candidateStatus: CandidateProvisioningStatus
    ) -> Set<BuiltInModelLifecycleAction> {
        if readiness == .removing { return [] }

        switch state.provisioningJob {
        case .verificationPending:
            return [.retry, .discardCandidate]
        default:
            break
        }

        switch candidateStatus {
        case .preflightBlocked:
            return [.retry, .cancel]
        case .downloading:
            return [.pause, .cancel]
        case .paused, .staged:
            return [.resume, .cancel]
        case .pausedLowDisk:
            return [.cancel]
        case .verifying:
            return [.cancel]
        case .failed:
            return state.inventory.candidate == nil
                ? [.retry]
                : [.retry, .discardCandidate]
        case .verified:
            return [.retryLoad, .discardCandidate]
        case .none:
            break
        }

        switch readiness {
        case .unavailable:
            return [.downloadAndEnable]
        case .loading:
            // Candidate/runtime loading has no truthful cancellation boundary:
            // the underlying MLX load must finish or fail before another
            // lifecycle action can own it.
            return []
        case .usable:
            return [.reinstall, .remove]
        case .installedButRuntimeFailed:
            return [.retryLoad, .reinstall, .remove]
        case .removing:
            return []
        }
    }
}

private extension RuntimeState {
    func references(_ installation: BuiltInModelInstallation) -> Bool {
        switch self {
        case .unloaded:
            return false
        case .loading(let current), .ready(let current), .generating(let current):
            return current == installation
        case .failed(let current, _):
            return current == installation
        }
    }

    func isValid(for inventory: ArtifactInventory) -> Bool {
        switch self {
        case .unloaded, .failed(installation: nil, reason: _):
            return true
        case .loading(let installation):
            if inventory.lastKnownGood == installation { return true }
            return inventory.candidate?.installation == installation
                && inventory.candidate?.verification == .verified
        case .ready(let installation), .generating(let installation):
            return inventory.lastKnownGood == installation
        case .failed(let installation?, _):
            if inventory.lastKnownGood == installation { return true }
            return inventory.candidate?.installation == installation
                && inventory.candidate?.verification == .verified
        }
    }
}
