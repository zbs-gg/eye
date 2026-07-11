import Foundation
import XCTest

final class BuiltInModelJournalTests: XCTestCase {
    private let artifact = BuiltInModelArtifact(
        modelID: "zbs-eye-local-v1",
        artifactVersion: 1,
        manifestFingerprintSHA256: String(repeating: "a", count: 64)
    )

    func testJournalExcludesRuntimeAndRestoresItAsUnloaded() throws {
        let installed = installation(1)
        let state = lifecycleState(
            lastKnownGood: installed,
            runtime: .generating(installed)
        )

        let data = try BuiltInModelJournal(state: state).encoded()
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(json["runtimeState"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("generating"))

        let restored = try BuiltInModelJournal.decode(data).restoredState()
        XCTAssertEqual(restored.inventory.lastKnownGood, installed)
        XCTAssertEqual(restored.runtimeState, .unloaded)
    }

    func testSameManifestReinstallRetainsDistinctInstallationIdentityAndDirectory() throws {
        let installed = installation(1)
        let reinstall = installation(2)
        let state = lifecycleState(
            lastKnownGood: installed,
            candidate: BuiltInModelCandidate(
                installation: reinstall,
                verification: .partial
            ),
            runtime: .ready(installed)
        )

        let restored = try BuiltInModelJournal.decode(
            BuiltInModelJournal(state: state).encoded()
        ).restoredState()

        XCTAssertEqual(restored.inventory.lastKnownGood, installed)
        XCTAssertEqual(restored.inventory.candidate?.installation, reinstall)
        XCTAssertNotEqual(
            restored.inventory.lastKnownGood?.installationID,
            restored.inventory.candidate?.installation.installationID
        )
        XCTAssertNotEqual(
            restored.inventory.lastKnownGood?.relativeDirectory,
            restored.inventory.candidate?.installation.relativeDirectory
        )
    }

    func testStartupReconciliationPausesInterruptedDownload() throws {
        let candidate = installation(2)
        let progress = ProvisioningProgress(receivedBytes: 40, expectedBytes: 100)
        let state = lifecycleState(
            candidate: BuiltInModelCandidate(
                installation: candidate,
                verification: .partial
            ),
            job: .downloading(progress)
        )

        let restored = try roundTripThroughJournal(state)

        XCTAssertEqual(restored.provisioningJob, .paused(progress))
        XCTAssertEqual(restored.runtimeState, .unloaded)
    }

    func testStartupReconciliationRequiresFreshVerificationAfterInterruptedVerifier() throws {
        let candidate = installation(2)
        let state = lifecycleState(
            candidate: BuiltInModelCandidate(
                installation: candidate,
                verification: .partial
            ),
            job: .verifying
        )

        let restored = try roundTripThroughJournal(state)

        XCTAssertEqual(restored.provisioningJob, .verificationPending)
        XCTAssertEqual(restored.inventory.candidate?.verification, .partial)
    }

    func testStartupReconciliationKeepsRemovalTombstoneForIdempotentRecovery() throws {
        let installed = installation(1)
        let deactivationIntent = DeactivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: installed.artifact.modelID,
            expectedSelectionRevision: SelectionRevision(rawValue: 17)
        )
        for job in [
            ProvisioningJob.waitingForRuntimeDrain(installed),
            .removing(installed),
        ] {
            let restored = try roundTripThroughJournal(
                lifecycleState(
                    lastKnownGood: installed,
                    job: job,
                    deactivationIntent: deactivationIntent,
                    runtime: .ready(installed)
                )
            )

            XCTAssertEqual(restored.provisioningJob, .removalPending(installed))
            XCTAssertEqual(restored.inventory.lastKnownGood, installed)
            XCTAssertEqual(restored.deactivationIntent, deactivationIntent)
            XCTAssertEqual(restored.runtimeState, .unloaded)
        }
    }

    func testProviderEffectRecoveryRoundTripsAndMissingFieldRemainsBackwardCompatible() throws {
        let installed = installation(1)
        let intent = ActivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: installed.artifact.modelID,
            expectedSelectionRevision: SelectionRevision(rawValue: 4)
        )
        let effect = BuiltInModelLifecycleEffect.requestActivation(intent)
        let state = lifecycleState(
            lastKnownGood: installed,
            providerEffectRecovery: effect
        )

        let data = try BuiltInModelJournal(state: state).encoded()
        let restored = try BuiltInModelJournal.decode(data).restoredState()
        XCTAssertEqual(restored.providerEffectRecovery, effect)

        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        legacyJSON.removeValue(forKey: "providerEffectRecovery")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacy = try BuiltInModelJournal.decode(legacyData).restoredState()
        XCTAssertNil(legacy.providerEffectRecovery)
    }

    func testFutureAndCorruptSchemasFailClosedInsteadOfReturningInitialState() throws {
        let valid = try BuiltInModelJournal(
            state: lifecycleState(lastKnownGood: installation(1))
        ).encoded()
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: valid) as? [String: Any]
        )
        json["schemaVersion"] = BuiltInModelJournal.currentSchemaVersion + 1
        let future = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try BuiltInModelJournal.decode(future)) { error in
            guard case BuiltInModelJournalError.unsupportedSchema = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try BuiltInModelJournal.decode(Data("{".utf8))) { error in
            guard case BuiltInModelJournalError.corrupt = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLogicallyInconsistentInventoryFailsClosed() throws {
        let installed = installation(1)
        let duplicate = BuiltInModelCandidate(
            installation: installed,
            verification: .partial
        )
        let state = lifecycleState(
            lastKnownGood: installed,
            candidate: duplicate
        )

        XCTAssertThrowsError(
            try BuiltInModelJournal(state: state).encoded()
        ) { error in
            guard case BuiltInModelJournalError.inconsistentState = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testUnsafeRelativeDirectoryFailsDuringDecode() throws {
        let state = lifecycleState(lastKnownGood: installation(1))
        let valid = try BuiltInModelJournal(state: state).encoded()
        let unsafe = Data(
            String(decoding: valid, as: UTF8.self)
                .replacingOccurrences(
                    of: "installations\\/1",
                    with: "..\\/outside"
                )
                .utf8
        )

        XCTAssertThrowsError(try BuiltInModelJournal.decode(unsafe)) { error in
            guard case BuiltInModelJournalError.corrupt = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testAtomicStoreOrdersWriteFileSyncRenameAndParentSync() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = StepRecorder()
        let store = BuiltInModelJournalStore(
            journalURL: directory.appending(path: "lifecycle.json"),
            faultHook: { recorder.steps.append($0) }
        )
        let state = lifecycleState(lastKnownGood: installation(1))

        try store.save(state)

        XCTAssertEqual(
            recorder.steps,
            [
                .temporaryFileWritten,
                .temporaryFileSynced,
                .destinationRenamed,
                .parentDirectorySynced,
            ]
        )
        XCTAssertEqual(try store.load().inventory.lastKnownGood, installation(1))
    }

    func testInjectedCrashAtEveryCommitBoundaryLeavesWholeOldOrNewJournal() throws {
        enum InjectedCrash: Error { case now }

        let oldState = lifecycleState(lastKnownGood: installation(1))
        let newState = lifecycleState(lastKnownGood: installation(2))
        let steps: [BuiltInModelJournalStore.CommitStep] = [
            .temporaryFileWritten,
            .temporaryFileSynced,
            .destinationRenamed,
            .parentDirectorySynced,
        ]

        for crashStep in steps {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appending(path: "lifecycle.json")
            try BuiltInModelJournalStore(journalURL: url).save(oldState)
            let crashingStore = BuiltInModelJournalStore(
                journalURL: url,
                faultHook: { step in
                    if step == crashStep { throw InjectedCrash.now }
                }
            )

            XCTAssertThrowsError(try crashingStore.save(newState), "\(crashStep)")
            let recovered = try BuiltInModelJournalStore(journalURL: url).load()
            let expected = crashStep == .temporaryFileWritten
                || crashStep == .temporaryFileSynced
                ? installation(1)
                : installation(2)
            XCTAssertEqual(recovered.inventory.lastKnownGood, expected, "\(crashStep)")
        }
    }

    func testMissingJournalIsDistinctFromCorruption() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BuiltInModelJournalStore(
            journalURL: directory.appending(path: "missing.json")
        )

        XCTAssertThrowsError(try store.load()) { error in
            guard case BuiltInModelJournalError.missing = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func roundTripThroughJournal(
        _ state: BuiltInModelLifecycleState
    ) throws -> BuiltInModelLifecycleState {
        try BuiltInModelJournal.decode(
            BuiltInModelJournal(state: state).encoded()
        ).restoredState()
    }

    private func lifecycleState(
        lastKnownGood: BuiltInModelInstallation? = nil,
        candidate: BuiltInModelCandidate? = nil,
        job: ProvisioningJob = .idle,
        deactivationIntent: DeactivationIntent? = nil,
        pendingProviderEffect: BuiltInModelLifecycleEffect? = nil,
        providerEffectRecovery: BuiltInModelLifecycleEffect? = nil,
        runtime: RuntimeState = .unloaded
    ) -> BuiltInModelLifecycleState {
        BuiltInModelLifecycleState(
            inventory: ArtifactInventory(
                lastKnownGood: lastKnownGood,
                candidate: candidate
            ),
            provisioningJob: job,
            activationIntent: nil,
            deactivationIntent: deactivationIntent,
            pendingProviderEffect: pendingProviderEffect,
            providerEffectRecovery: providerEffectRecovery,
            runtimeState: runtime
        )
    }

    private func installation(_ suffix: Int) -> BuiltInModelInstallation {
        let uuid = UUID(
            uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix)
        )!
        return BuiltInModelInstallation(
            artifact: artifact,
            installationID: uuid,
            relativeDirectory: "installations/\(suffix)"
        )!
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "zbs-eye-journal-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}

private final class StepRecorder {
    var steps: [BuiltInModelJournalStore.CommitStep] = []
}
