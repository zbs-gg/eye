import Foundation
import XCTest

final class BuiltInModelLifecycleTests: XCTestCase {
    private let artifactV1 = BuiltInModelArtifact(
        modelID: "zbs-eye-local-v1",
        artifactVersion: 1,
        manifestFingerprintSHA256: String(repeating: "1", count: 64)
    )
    private let artifactV2 = BuiltInModelArtifact(
        modelID: "zbs-eye-local-v2",
        artifactVersion: 2,
        manifestFingerprintSHA256: String(repeating: "2", count: 64)
    )

    func testInstallationRejectsUnsafeRelativeDirectories() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let unsafe = [
            "", "/absolute", "../outside", "installations/../outside",
            "./installations/one", "installations\\one", "~/one",
            "installations//one", "installations/CaseVariant",
        ]

        for path in unsafe {
            XCTAssertNil(
                BuiltInModelInstallation(
                    artifact: artifactV1,
                    installationID: id,
                    relativeDirectory: path
                ),
                path
            )
        }
        XCTAssertNotNil(
            BuiltInModelInstallation(
                artifact: artifactV1,
                installationID: id,
                relativeDirectory: "installations/model-1"
            )
        )
    }

    func testArtifactInventoryKeepsSameManifestInstallationsDistinct() {
        let installed = installation(artifactV1, 1)
        let reinstall = installation(artifactV1, 2)
        let inventory = ArtifactInventory(
            lastKnownGood: installed,
            candidate: BuiltInModelCandidate(
                installation: reinstall,
                verification: .partial
            )
        )

        XCTAssertEqual(inventory.lastKnownGood, installed)
        XCTAssertEqual(inventory.candidate?.installation, reinstall)
        XCTAssertEqual(inventory.candidate?.artifact, artifactV1)
        XCTAssertNotEqual(
            inventory.lastKnownGood?.installationID,
            inventory.candidate?.installation.installationID
        )
    }

    func testEveryProvisioningJobStateRoundTrips() throws {
        let installed = installation(artifactV1, 1)
        let progress = ProvisioningProgress(receivedBytes: 25, expectedBytes: 100)
        let failure = ProvisioningFailure(
            stage: .verification,
            message: "checksum mismatch",
            isRetryable: true
        )
        let states: [ProvisioningJob] = [
            .idle,
            .preflightBlocked(requiredBytes: 300, availableBytes: 200),
            .downloading(progress),
            .paused(progress),
            .pausedLowDisk(progress: progress, requiredBytes: 300, availableBytes: 200),
            .verifying,
            .verificationPending,
            .failed(failure),
            .waitingForRuntimeDrain(installed),
            .removing(installed),
            .removalPending(installed),
        ]

        for state in states {
            XCTAssertEqual(try roundTrip(state), state)
        }
    }

    func testEveryRuntimeStateRoundTrips() throws {
        let installed = installation(artifactV1, 1)
        let states: [RuntimeState] = [
            .unloaded,
            .loading(installed),
            .ready(installed),
            .generating(installed),
            .failed(installation: installed, reason: "out of memory"),
            .failed(installation: nil, reason: "runtime unavailable"),
        ]

        for state in states {
            XCTAssertEqual(try roundTrip(state), state)
        }
    }

    func testPrepareCandidateCannotSilentlyOverwriteAnExistingCandidate() {
        let current = installation(artifactV1, 1)
        let attempted = installation(artifactV2, 2)
        let progress = ProvisioningProgress(receivedBytes: 25, expectedBytes: 100)
        let intent = ActivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: artifactV1.modelID,
            expectedSelectionRevision: SelectionRevision(rawValue: 3)
        )
        var state = lifecycleState(
            candidate: BuiltInModelCandidate(
                installation: current,
                verification: .partial
            ),
            job: .downloading(progress),
            activationIntent: intent
        )
        let before = state

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .prepareCandidate(attempted, activationIntent: nil)
        )

        XCTAssertEqual(state, before)
    }

    func testPrepareCandidateRejectsIdentityOrDirectoryCollisionWithLKG() {
        let installed = installation(artifactV1, 1)
        let sameIdentity = BuiltInModelInstallation(
            artifact: artifactV2,
            installationID: installed.installationID,
            relativeDirectory: "installations/different"
        )!
        let sameDirectory = BuiltInModelInstallation(
            artifact: artifactV2,
            installationID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000099"
            )!,
            relativeDirectory: installed.relativeDirectory
        )!

        for attempted in [sameIdentity, sameDirectory] {
            var state = lifecycleState(
                lastKnownGood: installed,
                runtime: .ready(installed)
            )
            let before = state

            _ = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .prepareCandidate(attempted, activationIntent: nil)
            )

            XCTAssertEqual(state, before)
        }
    }

    func testPrepareCandidateRejectsIntentThatDoesNotOwnCandidate() {
        let candidate = installation(artifactV2, 2)
        let invalidIntents = [
            ActivationIntent(
                providerID: AIProvider.openrouter.rawValue,
                modelID: artifactV2.modelID,
                expectedSelectionRevision: SelectionRevision(rawValue: 1)
            ),
            ActivationIntent(
                providerID: AIProvider.zbsEyeLocal.rawValue,
                modelID: artifactV1.modelID,
                expectedSelectionRevision: SelectionRevision(rawValue: 1)
            ),
        ]

        for intent in invalidIntents {
            var state = BuiltInModelLifecycleState.initial
            _ = BuiltInModelLifecycleReducer.reduce(
                state: &state,
                event: .prepareCandidate(candidate, activationIntent: intent)
            )
            XCTAssertEqual(state, .initial)
        }
    }

    func testReducerMovesDownloadThroughPauseResumeAndVerification() {
        let candidate = installation(artifactV2, 2)
        let intent = ActivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: artifactV2.modelID,
            expectedSelectionRevision: SelectionRevision(rawValue: 5)
        )
        let progress = ProvisioningProgress(receivedBytes: 25, expectedBytes: 100)
        var state = BuiltInModelLifecycleState.initial

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .prepareCandidate(candidate, activationIntent: intent)
        )
        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .downloadStarted(progress)
        )
        _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .pauseDownload)
        XCTAssertEqual(state.provisioningJob, .paused(progress))
        _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .resumeDownload)
        XCTAssertEqual(state.provisioningJob, .downloading(progress))
        _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .beginVerification)
        XCTAssertEqual(state.provisioningJob, .verifying)
        _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .verificationSucceeded)

        XCTAssertEqual(state.inventory.candidate?.verification, .verified)
        XCTAssertEqual(state.provisioningJob, .idle)
        XCTAssertEqual(state.activationIntent, intent)
    }

    func testRuntimeEventsRejectUnknownOrUnverifiedInstallations() {
        let installed = installation(artifactV1, 1)
        let partial = installation(artifactV2, 2)
        let unknown = installation(artifactV2, 3)
        var state = lifecycleState(
            lastKnownGood: installed,
            candidate: BuiltInModelCandidate(
                installation: partial,
                verification: .partial
            ),
            runtime: .ready(installed)
        )

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .runtimeChanged(.ready(unknown))
        )
        XCTAssertEqual(state.runtimeState, .ready(installed))

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .runtimeChanged(.loading(partial))
        )
        XCTAssertEqual(state.runtimeState, .ready(installed))

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .runtimeChanged(.unloaded)
        )
        XCTAssertEqual(state.runtimeState, .unloaded)
    }

    func testVerifiedCandidateCanEnterLoadingButCannotGenerateBeforePromotion() {
        let installed = installation(artifactV1, 1)
        let candidate = installation(artifactV2, 2)
        var state = lifecycleState(
            lastKnownGood: installed,
            candidate: BuiltInModelCandidate(
                installation: candidate,
                verification: .verified
            ),
            runtime: .ready(installed)
        )

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .runtimeChanged(.loading(candidate))
        )
        XCTAssertEqual(state.runtimeState, .loading(candidate))

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .runtimeChanged(.generating(candidate))
        )
        XCTAssertEqual(state.runtimeState, .loading(candidate))
    }

    func testReplacementFailurePreservesLastKnownGoodAndItsReadyRuntime() {
        let installed = installation(artifactV1, 1)
        let candidate = installation(artifactV2, 2)
        let failure = ProvisioningFailure(
            stage: .runtimeLoad,
            message: "candidate would not load",
            isRetryable: true
        )
        var state = lifecycleState(
            lastKnownGood: installed,
            candidate: BuiltInModelCandidate(
                installation: candidate,
                verification: .verified
            ),
            runtime: .ready(installed)
        )

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .candidateLoadFailed(failure)
        )

        XCTAssertEqual(state.inventory.lastKnownGood, installed)
        XCTAssertEqual(state.inventory.candidate?.installation, candidate)
        XCTAssertEqual(state.runtimeState, .ready(installed))
        XCTAssertEqual(state.provisioningJob, .failed(failure))
        XCTAssertEqual(BuiltInModelLifecycleReducer.project(state).readiness, .usable)
    }

    func testDiscardCandidateCreatesDurableCleanupTombstoneWithoutTouchingLKG() {
        let installed = installation(artifactV1, 1)
        let candidate = installation(artifactV2, 2)
        var state = lifecycleState(
            lastKnownGood: installed,
            candidate: BuiltInModelCandidate(
                installation: candidate,
                verification: .partial
            ),
            job: .paused(ProvisioningProgress(receivedBytes: 25, expectedBytes: 100)),
            runtime: .ready(installed)
        )

        _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .discardCandidate)

        XCTAssertEqual(state.inventory.lastKnownGood, installed)
        XCTAssertNil(state.inventory.candidate)
        XCTAssertEqual(state.inventory.cleanupPending, [candidate])
        XCTAssertEqual(state.runtimeState, .ready(installed))
    }

    func testPromotionMovesPreviousLKGToDurableCleanupAndCurrentIntentActivates() {
        let installed = installation(artifactV1, 1)
        let candidate = installation(artifactV2, 2)
        let revision = SelectionRevision(rawValue: 7)
        let intent = ActivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: artifactV2.modelID,
            expectedSelectionRevision: revision
        )
        var state = lifecycleState(
            lastKnownGood: installed,
            candidate: BuiltInModelCandidate(
                installation: candidate,
                verification: .verified
            ),
            activationIntent: intent,
            runtime: .ready(installed)
        )

        let effects = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .candidateLoadSucceeded(currentSelectionRevision: revision)
        )

        XCTAssertEqual(effects, [.requestActivation(intent)])
        XCTAssertEqual(state.inventory.lastKnownGood, candidate)
        XCTAssertNil(state.inventory.candidate)
        XCTAssertEqual(state.inventory.cleanupPending, [installed])
        XCTAssertEqual(state.runtimeState, .ready(candidate))
        XCTAssertNil(state.activationIntent)
    }

    func testStaleActivationInstallsCandidateWithoutStealingSelection() {
        let installed = installation(artifactV1, 1)
        let candidate = installation(artifactV2, 2)
        let intent = ActivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: artifactV2.modelID,
            expectedSelectionRevision: SelectionRevision(rawValue: 7)
        )
        var state = lifecycleState(
            lastKnownGood: installed,
            candidate: BuiltInModelCandidate(
                installation: candidate,
                verification: .verified
            ),
            activationIntent: intent,
            runtime: .ready(installed)
        )

        let effects = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .candidateLoadSucceeded(
                currentSelectionRevision: SelectionRevision(rawValue: 8)
            )
        )

        XCTAssertEqual(effects, [])
        XCTAssertEqual(state.inventory.lastKnownGood, candidate)
        XCTAssertEqual(state.inventory.cleanupPending, [installed])
        XCTAssertEqual(state.runtimeState, .ready(candidate))
        XCTAssertNil(state.activationIntent)
    }

    func testBeginRemovalWaitsForRuntimeDrainAcknowledgement() {
        let installed = installation(artifactV1, 1)
        var state = lifecycleState(
            lastKnownGood: installed,
            runtime: .generating(installed)
        )

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .beginRemoval(deactivationIntent: nil)
        )

        XCTAssertEqual(state.provisioningJob, .waitingForRuntimeDrain(installed))
        XCTAssertEqual(state.runtimeState, .generating(installed))

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .runtimeDrainAcknowledged(installation(artifactV2, 2))
        )
        XCTAssertEqual(state.runtimeState, .generating(installed))

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .runtimeDrainAcknowledged(installed)
        )
        XCTAssertEqual(state.provisioningJob, .removing(installed))
        XCTAssertEqual(state.runtimeState, .unloaded)
    }

    func testRemovalFailurePreservesCoherentInstalledInventory() {
        let installed = installation(artifactV1, 1)
        let failure = ProvisioningFailure(
            stage: .removal,
            message: "directory rename failed",
            isRetryable: true
        )
        var state = lifecycleState(
            lastKnownGood: installed,
            job: .removing(installed),
            runtime: .unloaded
        )

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .removalFailed(failure)
        )

        XCTAssertEqual(state.inventory.lastKnownGood, installed)
        XCTAssertEqual(state.provisioningJob, .failed(failure))
        XCTAssertEqual(state.runtimeState, .unloaded)
        XCTAssertEqual(
            BuiltInModelLifecycleReducer.project(state).readiness,
            .loading
        )
    }

    func testRemovalSuccessMustMatchExactInstallationNotJustManifest() {
        let installed = installation(artifactV1, 1)
        let sameManifestReinstall = installation(artifactV1, 2)
        var state = lifecycleState(
            lastKnownGood: installed,
            job: .removing(installed),
            runtime: .unloaded
        )

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .removalSucceeded(sameManifestReinstall)
        )
        XCTAssertEqual(state.inventory.lastKnownGood, installed)

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .removalSucceeded(installed)
        )
        XCTAssertNil(state.inventory.lastKnownGood)
        XCTAssertEqual(state.provisioningJob, .idle)
    }

    func testRemovalSuccessRequestsRevisionOwnedDeactivation() {
        let installed = installation(artifactV1, 1)
        let intent = DeactivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: installed.artifact.modelID,
            expectedSelectionRevision: SelectionRevision(rawValue: 11)
        )
        var state = lifecycleState(
            lastKnownGood: installed,
            runtime: .ready(installed)
        )

        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .beginRemoval(deactivationIntent: intent)
        )
        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .runtimeDrainAcknowledged(installed)
        )
        let effects = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .removalSucceeded(installed)
        )

        XCTAssertEqual(effects, [.requestDeactivation(intent)])
        XCTAssertNil(state.deactivationIntent)
    }

    func testProjectionTruthMatrix() {
        struct Row {
            let name: String
            let state: BuiltInModelLifecycleState
            let readiness: BuiltInModelReadiness
            let candidateStatus: CandidateProvisioningStatus
            let actions: Set<BuiltInModelLifecycleAction>
        }

        let installed = installation(artifactV1, 1)
        let candidate = installation(artifactV2, 2)
        let progress = ProvisioningProgress(receivedBytes: 25, expectedBytes: 100)
        let partial = BuiltInModelCandidate(
            installation: candidate,
            verification: .partial
        )
        let rows: [Row] = [
            Row(
                name: "fresh idle",
                state: .initial,
                readiness: .unavailable,
                candidateStatus: .none,
                actions: [.downloadAndEnable]
            ),
            Row(
                name: "replacement downloading while LKG stays ready",
                state: lifecycleState(
                    lastKnownGood: installed,
                    candidate: partial,
                    job: .downloading(progress),
                    runtime: .ready(installed)
                ),
                readiness: .usable,
                candidateStatus: .downloading,
                actions: [.pause, .cancel]
            ),
            Row(
                name: "interrupted verification",
                state: lifecycleState(
                    lastKnownGood: installed,
                    candidate: partial,
                    job: .verificationPending,
                    runtime: .unloaded
                ),
                readiness: .loading,
                candidateStatus: .verifying,
                actions: [.retry, .discardCandidate]
            ),
            Row(
                name: "waiting for runtime drain",
                state: lifecycleState(
                    lastKnownGood: installed,
                    job: .waitingForRuntimeDrain(installed),
                    runtime: .generating(installed)
                ),
                readiness: .removing,
                candidateStatus: .none,
                actions: []
            ),
            Row(
                name: "startup removal recovery",
                state: lifecycleState(
                    lastKnownGood: installed,
                    job: .removalPending(installed),
                    runtime: .unloaded
                ),
                readiness: .removing,
                candidateStatus: .none,
                actions: []
            ),
        ]

        for row in rows {
            let projection = BuiltInModelLifecycleReducer.project(row.state)
            XCTAssertEqual(projection.readiness, row.readiness, row.name)
            XCTAssertEqual(projection.candidateStatus, row.candidateStatus, row.name)
            XCTAssertEqual(projection.actions, row.actions, row.name)
        }
    }

    private func lifecycleState(
        lastKnownGood: BuiltInModelInstallation? = nil,
        candidate: BuiltInModelCandidate? = nil,
        job: ProvisioningJob = .idle,
        activationIntent: ActivationIntent? = nil,
        runtime: RuntimeState = .unloaded
    ) -> BuiltInModelLifecycleState {
        BuiltInModelLifecycleState(
            inventory: ArtifactInventory(
                lastKnownGood: lastKnownGood,
                candidate: candidate
            ),
            provisioningJob: job,
            activationIntent: activationIntent,
            runtimeState: runtime
        )
    }

    private func installation(
        _ artifact: BuiltInModelArtifact,
        _ suffix: Int
    ) -> BuiltInModelInstallation {
        let uuid = UUID(
            uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix)
        )!
        return BuiltInModelInstallation(
            artifact: artifact,
            installationID: uuid,
            relativeDirectory: "installations/\(suffix)"
        )!
    }

    private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}
