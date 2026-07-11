import CryptoKit
import Darwin
import Foundation
import XCTest

final class BuiltInModelManagerTests: XCTestCase {
    func testFreshInstallUsesSecureWrapperVerifiesLoadsAndActivates() async throws {
        let fixture = try Fixture(payload: Data("tiny-model".utf8))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        let loaded = LoadRecorder()
        let manager = try fixture.manager(
            transport: transport,
            loader: { directory, manifest in try await loaded.load(directory, manifest) }
        )
        let intent = fixture.activationIntent(revision: 7)

        let result = try await manager.install(
            manifestID: fixture.manifest.id,
            activationIntent: intent,
            currentSelectionRevision: SelectionRevision(rawValue: 7)
        )

        let installation = try XCTUnwrap(result.snapshot.state.inventory.lastKnownGood)
        XCTAssertNil(result.snapshot.state.inventory.candidate)
        XCTAssertEqual(result.effects, [.requestActivation(intent)])
        let loadedManifestIDs = await loaded.loadedManifestIDs()
        XCTAssertEqual(loadedManifestIDs, [fixture.manifest.id])
        let wrapper = fixture.root
            .appending(path: "installed")
            .appending(path: installation.installationID.uuidString.lowercased())
        XCTAssertTrue(FileManager.default.fileExists(atPath: wrapper.appending(path: "verified.json").path))
        XCTAssertEqual(try permissions(wrapper), 0o700)
        XCTAssertEqual(try permissions(wrapper.appending(path: "payload")), 0o700)
        XCTAssertEqual(try permissions(wrapper.appending(path: "payload/model.bin")), 0o600)
        XCTAssertEqual(try permissions(wrapper.appending(path: "verified.json")), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: "staging").appending(path: installation.installationID.uuidString.lowercased()).path))

        let storage = try await manager.storageSnapshot()
        XCTAssertEqual(storage.activeManifestFingerprintSHA256, fixture.manifest.aggregateFingerprintSHA256)
        XCTAssertEqual(storage.activeVerifiedBytes, Int64(fixture.payload.count))
        XCTAssertGreaterThan(storage.journalBytes, 0)
    }

    func testAppliedActivationBecomesRecoveryUntilNextProcessReplay() async throws {
        let fixture = try Fixture(payload: Data("activation-recovery".utf8))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: fixture.payload]
        )
        let intent = fixture.activationIntent(revision: 3)
        let handler = ScriptedEffectHandler([.applied, .stale])
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await handler.handle($0) }
        )

        let installed = try await manager!.install(
            manifestID: fixture.manifest.id,
            activationIntent: intent,
            currentSelectionRevision: SelectionRevision(rawValue: 3)
        )

        XCTAssertNil(installed.snapshot.state.pendingProviderEffect)
        XCTAssertEqual(
            installed.snapshot.state.providerEffectRecovery,
            .requestActivation(intent)
        )
        let sameProcess = try await manager!.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 3)
        )
        let sameProcessAttempts = await handler.values()
        XCTAssertEqual(
            sameProcess.snapshot.state.providerEffectRecovery,
            .requestActivation(intent)
        )
        XCTAssertEqual(sameProcessAttempts, [.requestActivation(intent)])
        manager = nil

        let reopened = try fixture.manager(
            transport: transport,
            effectHandler: { await handler.handle($0) }
        )
        let reconciled = try await reopened.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 4)
        )

        let replayedEffects = await handler.values()
        XCTAssertNil(reconciled.snapshot.state.providerEffectRecovery)
        XCTAssertEqual(replayedEffects, [
            .requestActivation(intent),
            .requestActivation(intent),
        ])
    }

    func testRecoveryDoesNotBlockSameProcessRemoveAndReinstallAndNewEffectSupersedesIt() async throws {
        let fixture = try Fixture(payload: Data("recovery-does-not-block".utf8))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: fixture.payload]
        )
        let manager = try fixture.manager(
            transport: transport,
            effectHandler: { _ in .applied }
        )
        let activation = fixture.activationIntent(revision: 1)
        _ = try await manager.install(
            manifestID: fixture.manifest.id,
            activationIntent: activation,
            currentSelectionRevision: SelectionRevision(rawValue: 1)
        )
        let deactivation = DeactivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: fixture.manifest.id,
            expectedSelectionRevision: SelectionRevision(rawValue: 2)
        )

        let removed = try await manager.remove(
            deactivationIntent: deactivation,
            currentSelectionRevision: SelectionRevision(rawValue: 2)
        )
        XCTAssertEqual(
            removed.snapshot.state.providerEffectRecovery,
            .requestDeactivation(deactivation)
        )

        let replacement = fixture.activationIntent(revision: 3)
        let reinstalled = try await manager.install(
            manifestID: fixture.manifest.id,
            activationIntent: replacement,
            currentSelectionRevision: SelectionRevision(rawValue: 3)
        )
        XCTAssertEqual(
            reinstalled.snapshot.state.providerEffectRecovery,
            .requestActivation(replacement)
        )
    }

    func testCrashAfterProviderWriteBeforeRecoveryJournalLeavesReplayablePendingEffect() async throws {
        let fixture = try Fixture(payload: Data("before-recovery-journal".utf8))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: fixture.payload]
        )
        let intent = fixture.activationIntent(revision: 5)
        let recorder = EffectRecorder()
        let fault = OneShotFault(point: .afterProviderEffectAppliedBeforeRecoveryJournal)
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) },
            faultHook: fault.hit
        )

        await XCTAssertThrowsErrorAsync(
            try await manager!.install(
                manifestID: fixture.manifest.id,
                activationIntent: intent,
                currentSelectionRevision: SelectionRevision(rawValue: 5)
            )
        )
        manager = nil

        let reopened = try fixture.manager(
            transport: transport,
            effectHandler: { _ in .applied }
        )
        let recovered = try await reopened.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 5)
        )
        XCTAssertNil(recovered.snapshot.state.pendingProviderEffect)
        XCTAssertEqual(
            recovered.snapshot.state.providerEffectRecovery,
            .requestActivation(intent)
        )
    }

    func testCrashAfterRecoveryJournalReplaysReceiptOnNextProcess() async throws {
        let fixture = try Fixture(payload: Data("after-recovery-journal".utf8))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: fixture.payload]
        )
        let intent = fixture.activationIntent(revision: 6)
        let fault = OneShotFault(point: .afterProviderEffectRecoveryJournal)
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { _ in .applied },
            faultHook: fault.hit
        )

        await XCTAssertThrowsErrorAsync(
            try await manager!.install(
                manifestID: fixture.manifest.id,
                activationIntent: intent,
                currentSelectionRevision: SelectionRevision(rawValue: 6)
            )
        )
        manager = nil

        let replay = ScriptedEffectHandler([.stale])
        let reopened = try fixture.manager(
            transport: transport,
            effectHandler: { await replay.handle($0) }
        )
        let recovered = try await reopened.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 7)
        )
        let replayedEffects = await replay.values()
        XCTAssertNil(recovered.snapshot.state.providerEffectRecovery)
        XCTAssertEqual(replayedEffects, [.requestActivation(intent)])
    }

    func testCrashAfterActivationOutboxCommitAppliesThenReplaysRecoveryOnceAcrossRestarts() async throws {
        let fixture = try Fixture(payload: Data("activation-outbox".utf8))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: fixture.payload]
        )
        let intent = fixture.activationIntent(revision: 9)
        let recorder = EffectRecorder()
        let fault = OneShotFault(point: .afterProviderEffectJournalBeforeDispatch)
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) },
            faultHook: fault.hit
        )

        await XCTAssertThrowsErrorAsync(
            try await manager!.install(
                manifestID: fixture.manifest.id,
                activationIntent: intent,
                currentSelectionRevision: SelectionRevision(rawValue: 9)
            )
        )
        let effectsBeforeRestart = await recorder.values()
        XCTAssertEqual(effectsBeforeRestart, [])
        manager = nil

        var reopened: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) }
        )
        let reconciled = try await reopened!.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 9)
        )

        XCTAssertEqual(reconciled.effects, [.requestActivation(intent)])
        let effectsAfterReplay = await recorder.values()
        XCTAssertEqual(effectsAfterReplay, [.requestActivation(intent)])
        XCTAssertNil(reconciled.snapshot.state.pendingProviderEffect)
        XCTAssertEqual(
            reconciled.snapshot.state.providerEffectRecovery,
            .requestActivation(intent)
        )
        reopened = nil

        let secondReopen = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) }
        )
        let secondReconcile = try await secondReopen.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 9)
        )
        XCTAssertEqual(secondReconcile.effects, [.requestActivation(intent)])
        XCTAssertNil(secondReconcile.snapshot.state.providerEffectRecovery)
        let effectsAfterSecondRestart = await recorder.values()
        XCTAssertEqual(effectsAfterSecondRestart, [
            .requestActivation(intent),
            .requestActivation(intent),
        ])
    }

    func testActivationPersistenceFailureKeepsOutboxUntilRestartReplayIsAcknowledged() async throws {
        let fixture = try Fixture(payload: Data("activation-persistence-retry".utf8))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: fixture.payload]
        )
        let intent = fixture.activationIntent(revision: 11)
        let handler = ScriptedEffectHandler([
            .retryablePersistenceFailure,
            .applied,
            .stale,
        ])
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await handler.handle($0) }
        )

        let firstResult = try await manager!.install(
            manifestID: fixture.manifest.id,
            activationIntent: intent,
            currentSelectionRevision: SelectionRevision(rawValue: 11)
        )

        XCTAssertEqual(firstResult.snapshot.state.pendingProviderEffect, .requestActivation(intent))
        let firstAttempts = await handler.values()
        XCTAssertEqual(firstAttempts, [.requestActivation(intent)])
        manager = nil

        var reopened: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await handler.handle($0) }
        )
        let replayed = try await reopened!.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 11)
        )

        XCTAssertNil(replayed.snapshot.state.pendingProviderEffect)
        let replayAttempts = await handler.values()
        let appliedCount = await handler.appliedCount()
        XCTAssertEqual(replayAttempts, [
            .requestActivation(intent),
            .requestActivation(intent),
        ])
        XCTAssertEqual(appliedCount, 1)
        XCTAssertEqual(
            replayed.snapshot.state.providerEffectRecovery,
            .requestActivation(intent)
        )
        reopened = nil

        let finalReopen = try fixture.manager(
            transport: transport,
            effectHandler: { await handler.handle($0) }
        )
        let finalized = try await finalReopen.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 11)
        )
        let finalAttempts = await handler.values()
        XCTAssertEqual(finalAttempts.count, 3)
        XCTAssertNil(finalized.snapshot.state.providerEffectRecovery)
    }

    func testStaleActivationOutboxIsAcknowledgedWithoutReplayAfterRestart() async throws {
        let fixture = try Fixture(payload: Data("stale-activation-outbox".utf8))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: fixture.payload]
        )
        let intent = fixture.activationIntent(revision: 9)
        let recorder = EffectRecorder()
        let fault = OneShotFault(point: .afterProviderEffectJournalBeforeDispatch)
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) },
            faultHook: fault.hit
        )

        await XCTAssertThrowsErrorAsync(
            try await manager!.install(
                manifestID: fixture.manifest.id,
                activationIntent: intent,
                currentSelectionRevision: SelectionRevision(rawValue: 9)
            )
        )
        manager = nil

        var reopened: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) }
        )
        let reconciled = try await reopened!.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 10)
        )

        XCTAssertTrue(reconciled.effects.isEmpty)
        let replayedEffects = await recorder.values()
        XCTAssertTrue(replayedEffects.isEmpty)
        XCTAssertNil(reconciled.snapshot.state.pendingProviderEffect)
        XCTAssertTrue(reconciled.snapshot.projection.isUsable)
        reopened = nil

        let secondReopen = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) }
        )
        let secondReconcile = try await secondReopen.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 10)
        )
        let effectsAfterSecondReopen = await recorder.values()
        XCTAssertTrue(secondReconcile.effects.isEmpty)
        XCTAssertTrue(effectsAfterSecondReopen.isEmpty)
    }

    func testCrashAfterDeactivationOutboxCommitAppliesThenReplaysRecoveryOnceAcrossRestarts() async throws {
        let fixture = try Fixture(payload: Data("deactivation-outbox".utf8))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: fixture.payload]
        )
        let recorder = EffectRecorder()
        let fault = OneShotFault(point: .afterProviderEffectJournalBeforeDispatch)
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) },
            faultHook: fault.hit
        )
        _ = try await manager!.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )
        let intent = DeactivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: fixture.manifest.id,
            expectedSelectionRevision: SelectionRevision(rawValue: 5)
        )

        await XCTAssertThrowsErrorAsync(
            try await manager!.remove(
                deactivationIntent: intent,
                currentSelectionRevision: SelectionRevision(rawValue: 5)
            )
        )
        let effectsBeforeRestart = await recorder.values()
        XCTAssertEqual(effectsBeforeRestart, [])
        manager = nil

        var reopened: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) }
        )
        let reconciled = try await reopened!.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 5)
        )

        XCTAssertEqual(reconciled.effects, [.requestDeactivation(intent)])
        let effectsAfterReplay = await recorder.values()
        XCTAssertEqual(effectsAfterReplay, [.requestDeactivation(intent)])
        XCTAssertNil(reconciled.snapshot.state.pendingProviderEffect)
        XCTAssertEqual(
            reconciled.snapshot.state.providerEffectRecovery,
            .requestDeactivation(intent)
        )
        reopened = nil

        let secondReopen = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) }
        )
        let secondReconcile = try await secondReopen.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 5)
        )
        let effectsAfterSecondRestart = await recorder.values()
        XCTAssertEqual(secondReconcile.effects, [.requestDeactivation(intent)])
        XCTAssertNil(secondReconcile.snapshot.state.providerEffectRecovery)
        XCTAssertEqual(effectsAfterSecondRestart, [
            .requestDeactivation(intent),
            .requestDeactivation(intent),
        ])
    }

    func testDeactivationPersistenceFailureKeepsOutboxUntilRestartReplayIsAcknowledged() async throws {
        let fixture = try Fixture(payload: Data("deactivation-persistence-retry".utf8))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: fixture.payload]
        )
        let intent = DeactivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: fixture.manifest.id,
            expectedSelectionRevision: SelectionRevision(rawValue: 13)
        )
        let handler = ScriptedEffectHandler([
            .retryablePersistenceFailure,
            .applied,
            .stale,
        ])
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await handler.handle($0) }
        )
        _ = try await manager!.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )

        let firstResult = try await manager!.remove(
            deactivationIntent: intent,
            currentSelectionRevision: SelectionRevision(rawValue: 13)
        )

        XCTAssertEqual(firstResult.snapshot.state.pendingProviderEffect, .requestDeactivation(intent))
        let firstAttempts = await handler.values()
        XCTAssertEqual(firstAttempts, [.requestDeactivation(intent)])
        manager = nil

        var reopened: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await handler.handle($0) }
        )
        let replayed = try await reopened!.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 13)
        )

        XCTAssertNil(replayed.snapshot.state.pendingProviderEffect)
        let replayAttempts = await handler.values()
        let appliedCount = await handler.appliedCount()
        XCTAssertEqual(replayAttempts, [
            .requestDeactivation(intent),
            .requestDeactivation(intent),
        ])
        XCTAssertEqual(appliedCount, 1)
        XCTAssertEqual(
            replayed.snapshot.state.providerEffectRecovery,
            .requestDeactivation(intent)
        )
        reopened = nil

        let finalReopen = try fixture.manager(
            transport: transport,
            effectHandler: { await handler.handle($0) }
        )
        let finalized = try await finalReopen.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 13)
        )
        let finalAttempts = await handler.values()
        XCTAssertEqual(finalAttempts.count, 3)
        XCTAssertNil(finalized.snapshot.state.providerEffectRecovery)
    }

    func testStaleDeactivationOutboxIsAcknowledgedWithoutReplayAfterRestart() async throws {
        let fixture = try Fixture(payload: Data("stale-deactivation-outbox".utf8))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: fixture.payload]
        )
        let recorder = EffectRecorder()
        let fault = OneShotFault(point: .afterProviderEffectJournalBeforeDispatch)
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) },
            faultHook: fault.hit
        )
        _ = try await manager!.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )
        let intent = DeactivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: fixture.manifest.id,
            expectedSelectionRevision: SelectionRevision(rawValue: 5)
        )

        await XCTAssertThrowsErrorAsync(
            try await manager!.remove(
                deactivationIntent: intent,
                currentSelectionRevision: SelectionRevision(rawValue: 5)
            )
        )
        manager = nil

        var reopened: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) }
        )
        let reconciled = try await reopened!.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 6)
        )

        XCTAssertTrue(reconciled.effects.isEmpty)
        let replayedEffects = await recorder.values()
        XCTAssertTrue(replayedEffects.isEmpty)
        XCTAssertNil(reconciled.snapshot.state.pendingProviderEffect)
        XCTAssertNil(reconciled.snapshot.state.inventory.lastKnownGood)
        reopened = nil

        let secondReopen = try fixture.manager(
            transport: transport,
            effectHandler: { await recorder.record($0) }
        )
        let secondReconcile = try await secondReopen.reconcileAfterRestart(
            currentSelectionRevision: SelectionRevision(rawValue: 6)
        )
        let effectsAfterSecondReopen = await recorder.values()
        XCTAssertTrue(secondReconcile.effects.isEmpty)
        XCTAssertTrue(effectsAfterSecondReopen.isEmpty)
    }

    func testWrongHashPreservesLastKnownGood() async throws {
        let fixture = try Fixture(payload: Data("known-good".utf8))
        defer { fixture.cleanup() }
        let replacement = fixture.manifest(
            id: "tiny-replacement",
            payload: Data("expected-value".utf8),
            sourceURL: URL(string: "https://assets.example/replacement.bin")!
        )
        let transport = ScriptedManagerTransport(payloads: [
            fixture.sourceURL: fixture.payload,
            replacement.files[0].sourceURL: Data("wrong----value".utf8),
        ])
        let manager = try fixture.manager(
            manifests: [fixture.manifest, replacement],
            transport: transport
        )
        _ = try await manager.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )
        let installedSnapshot = await manager.snapshot()
        let before = try XCTUnwrap(installedSnapshot.state.inventory.lastKnownGood)

        let result = try await manager.install(
            manifestID: replacement.id,
            currentSelectionRevision: .zero
        )

        XCTAssertEqual(result.snapshot.state.inventory.lastKnownGood, before)
        guard case .failed(let failure) = result.snapshot.state.provisioningJob else {
            return XCTFail("Expected verification failure")
        }
        XCTAssertEqual(failure.stage, .verification)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.installedWrapper(before).path))
    }

    func testCandidateLoadFailurePreservesLastKnownGoodAndRetryIsIdempotent() async throws {
        let fixture = try Fixture(payload: Data("known-good".utf8))
        defer { fixture.cleanup() }
        let replacementPayload = Data("replacement".utf8)
        let replacement = fixture.manifest(
            id: "tiny-load-failure",
            payload: replacementPayload,
            sourceURL: URL(string: "https://assets.example/load-failure.bin")!
        )
        let transport = ScriptedManagerTransport(payloads: [
            fixture.sourceURL: fixture.payload,
            replacement.files[0].sourceURL: replacementPayload,
        ])
        let loader = LoadRecorder(failingManifestIDs: [replacement.id])
        let manager = try fixture.manager(
            manifests: [fixture.manifest, replacement],
            transport: transport,
            loader: { directory, manifest in try await loader.load(directory, manifest) }
        )
        _ = try await manager.install(manifestID: fixture.manifest.id, currentSelectionRevision: .zero)
        let installedSnapshot = await manager.snapshot()
        let before = try XCTUnwrap(installedSnapshot.state.inventory.lastKnownGood)

        let failed = try await manager.install(manifestID: replacement.id, currentSelectionRevision: .zero)
        XCTAssertEqual(failed.snapshot.state.inventory.lastKnownGood, before)
        guard case .failed(let failure) = failed.snapshot.state.provisioningJob else {
            return XCTFail("Expected runtime load failure")
        }
        XCTAssertEqual(failure.stage, .runtimeLoad)
        XCTAssertEqual(failed.snapshot.state.runtimeState, .ready(before))
        XCTAssertTrue(failed.snapshot.projection.isUsable)

        await loader.allow(replacement.id)
        let succeeded = try await manager.retry(currentSelectionRevision: .zero)
        let retried = try await manager.retry(currentSelectionRevision: .zero)
        XCTAssertEqual(
            succeeded.snapshot.state.inventory.lastKnownGood,
            retried.snapshot.state.inventory.lastKnownGood
        )
        XCTAssertEqual(try installedWrapperCount(fixture.root), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installedWrapper(before).path))
    }

    func testCandidateLoadFailureMarksRuntimeFailedWhenLastKnownGoodCannotBeRestored() async throws {
        let fixture = try Fixture(payload: Data("known-good".utf8))
        defer { fixture.cleanup() }
        let replacementPayload = Data("replacement".utf8)
        let replacement = fixture.manifest(
            id: "tiny-load-and-restore-failure",
            payload: replacementPayload,
            sourceURL: URL(string: "https://assets.example/load-and-restore-failure.bin")!
        )
        let transport = ScriptedManagerTransport(payloads: [
            fixture.sourceURL: fixture.payload,
            replacement.files[0].sourceURL: replacementPayload,
        ])
        let loader = LoadRecorder(failingManifestIDs: [replacement.id])
        let manager = try fixture.manager(
            manifests: [fixture.manifest, replacement],
            transport: transport,
            loader: { directory, manifest in try await loader.load(directory, manifest) }
        )
        _ = try await manager.install(manifestID: fixture.manifest.id, currentSelectionRevision: .zero)
        let installedSnapshot = await manager.snapshot()
        let before = try XCTUnwrap(installedSnapshot.state.inventory.lastKnownGood)
        await loader.reject(fixture.manifest.id)

        let failed = try await manager.install(manifestID: replacement.id, currentSelectionRevision: .zero)

        guard case .failed(let failedInstallation, _) = failed.snapshot.state.runtimeState else {
            return XCTFail("Expected failed last-known-good runtime")
        }
        XCTAssertEqual(failedInstallation, before)
        XCTAssertEqual(failed.snapshot.projection.readiness, .installedButRuntimeFailed)
        XCTAssertFalse(failed.snapshot.projection.isUsable)
    }

    func testInterruptedDownloadsResumeAfterRestartAtTenFiftyAndNinetyPercent() async throws {
        for cut in [10, 50, 90] {
            let payload = Data((0..<100).map(UInt8.init))
            let fixture = try Fixture(payload: payload, suffix: "resume-\(cut)")
            defer { fixture.cleanup() }
            let transport = ScriptedManagerTransport(
                payloads: [fixture.sourceURL: payload],
                interruptOnceAt: cut
            )
            var manager: BuiltInModelManager? = try fixture.manager(transport: transport)
            let interrupted = try await manager!.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
            guard case .paused(let progress) = interrupted.snapshot.state.provisioningJob else {
                XCTFail("Expected paused restart state at \(cut)%")
                fixture.cleanup()
                continue
            }
            XCTAssertEqual(progress.receivedBytes, Int64(cut))

            manager = nil
            let reopened = try fixture.manager(transport: transport)
            let restored = await reopened.snapshot()
            guard case .paused(let restoredProgress) = restored.state.provisioningJob else {
                XCTFail("Expected reconciled pause")
                fixture.cleanup()
                continue
            }
            XCTAssertEqual(restoredProgress.receivedBytes, Int64(cut))
            let result = try await reopened.resume(currentSelectionRevision: .zero)
            XCTAssertNotNil(result.snapshot.state.inventory.lastKnownGood)
            let sawExpectedRange = await transport.sawRange("bytes=\(cut)-")
            XCTAssertTrue(sawExpectedRange)
            fixture.cleanup()
        }
    }

    func testFreshAndResumeCapacityFormulaAndCapacityErrorsFailClosed() async throws {
        let fixture = try Fixture(payload: Data(repeating: 7, count: 100))
        defer { fixture.cleanup() }
        let required = Int64(2 * fixture.payload.count)
            + BuiltInModelManager.captureReserveBytes
            + BuiltInModelManager.capacitySafetyBytes
        let capacity = CapacityRecorder(value: required - 1)
        let transport = ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        let orphan = fixture.root.appending(path: "staging/orphan/payload")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)

        let manager = try fixture.manager(
            transport: transport,
            capacityReader: capacity.read
        )
        let blocked = try await manager.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )
        guard case .preflightBlocked(let actualRequired, let available) = blocked.snapshot.state.provisioningJob else {
            return XCTFail("Expected preflight block")
        }
        XCTAssertEqual(actualRequired, required)
        XCTAssertEqual(available, required - 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: "staging/orphan").path))

        let throwingFixture = try Fixture(payload: Data("capacity".utf8), suffix: "capacity-error")
        defer { throwingFixture.cleanup() }
        let throwingManager = try throwingFixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [throwingFixture.sourceURL: throwingFixture.payload]
            ),
            capacityReader: { _ in throw CapacityFailure.unavailable }
        )
        await XCTAssertThrowsErrorAsync(
            try await throwingManager.install(
                manifestID: throwingFixture.manifest.id,
                currentSelectionRevision: .zero
            )
        ) { error in
            XCTAssertEqual(error as? BuiltInModelManagerError, .capacityUnavailable)
        }
    }

    func testDownloadLowDiskReclaimsUnverifiedCandidateWithoutRetention() async throws {
        let fixture = try Fixture(payload: Data(repeating: 4, count: 32))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        let client = BuiltInDownloadClient(
            transport: transport,
            allowedAssetHosts: ["assets.example"],
            capacityCheck: { _ in .insufficient(requiredBytes: 999, availableBytes: 1) }
        )
        let manager = try fixture.manager(
            downloadClient: client,
            capacityReader: { _ in Int64.max }
        )

        let result = try await manager.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )

        guard case .pausedLowDisk(_, let required, let available) = result.snapshot.state.provisioningJob else {
            return XCTFail("Expected low-disk pause")
        }
        XCTAssertEqual(required, 999)
        XCTAssertEqual(available, 1)
        XCTAssertEqual(try stagingWrapperCount(fixture.root), 0)
        XCTAssertNil(result.snapshot.state.inventory.lastKnownGood)
    }

    func testManagerRechecksInjectedCapacityAfterStreamingProgress() async throws {
        let fixture = try Fixture(payload: Data(repeating: 6, count: 32), suffix: "dynamic-capacity")
        defer { fixture.cleanup() }
        let capacity = SequenceCapacityReader(values: [.value(Int64.max), .value(1)])
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload]),
            capacityReader: capacity.read
        )

        let result = try await manager.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )

        guard case .pausedLowDisk(let progress, _, let available) = result.snapshot.state.provisioningJob else {
            return XCTFail("Expected manager-owned progress capacity pause")
        }
        XCTAssertEqual(progress.receivedBytes, 0)
        XCTAssertEqual(available, 1)
        XCTAssertEqual(try stagingWrapperCount(fixture.root), 0)
    }

    func testCorruptAndFutureJournalFailClosed() throws {
        for (suffix, data, expected) in [
            ("corrupt", Data("{".utf8), BuiltInModelManagerError.corruptJournal),
            ("future", Data("{\"schemaVersion\":999}".utf8), BuiltInModelManagerError.futureJournal),
        ] {
            let fixture = try Fixture(payload: Data("journal".utf8), suffix: suffix)
            defer { fixture.cleanup() }
            try data.write(to: fixture.root.appending(path: "journal.json"))
            XCTAssertThrowsError(
                try fixture.manager(
                    transport: ScriptedManagerTransport(
                        payloads: [fixture.sourceURL: fixture.payload]
                    )
                )
            ) { error in
                XCTAssertEqual(error as? BuiltInModelManagerError, expected)
            }
        }
    }

    func testStaleSelectionInstallsWithoutActivationEffect() async throws {
        let fixture = try Fixture(payload: Data("stale".utf8))
        defer { fixture.cleanup() }
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        )
        let intent = fixture.activationIntent(revision: 3)

        let result = try await manager.install(
            manifestID: fixture.manifest.id,
            activationIntent: intent,
            currentSelectionRevision: SelectionRevision(rawValue: 4)
        )

        XCTAssertNotNil(result.snapshot.state.inventory.lastKnownGood)
        XCTAssertTrue(result.effects.isEmpty)
    }

    func testRemoveMovesOnlyExactInstallationThroughTrashAndDeactivatesRevisionSafely() async throws {
        let fixture = try Fixture(payload: Data("remove".utf8))
        defer { fixture.cleanup() }
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        )
        _ = try await manager.install(manifestID: fixture.manifest.id, currentSelectionRevision: .zero)
        let installedSnapshot = await manager.snapshot()
        let installation = try XCTUnwrap(installedSnapshot.state.inventory.lastKnownGood)
        let unrelated = fixture.root.appending(path: "installed/unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let intent = DeactivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: fixture.manifest.id,
            expectedSelectionRevision: SelectionRevision(rawValue: 8)
        )

        let result = try await manager.remove(
            deactivationIntent: intent,
            currentSelectionRevision: SelectionRevision(rawValue: 8)
        )

        XCTAssertNil(result.snapshot.state.inventory.lastKnownGood)
        XCTAssertEqual(result.effects, [.requestDeactivation(intent)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.installedWrapper(installation).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(try trashWrapperCount(fixture.root), 0)
    }

    func testCrashAfterPromotionReconcilesCandidateAndKeepsLastKnownGoodUntilLoadCommits() async throws {
        let fixture = try Fixture(payload: Data("crash".utf8))
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        let fault = OneShotFault(point: .afterPromotionBeforeLoad)
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            faultHook: fault.hit
        )
        await XCTAssertThrowsErrorAsync(
            try await manager!.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        )
        let beforeRestart = await manager!.snapshot()
        XCTAssertNil(beforeRestart.state.inventory.lastKnownGood)
        XCTAssertEqual(beforeRestart.state.inventory.candidate?.verification, .verified)
        manager = nil

        let reopened = try fixture.manager(transport: transport)
        let result = try await reopened.reconcileAfterRestart(currentSelectionRevision: .zero)
        XCTAssertNotNil(result.snapshot.state.inventory.lastKnownGood)
        XCTAssertNil(result.snapshot.state.inventory.candidate)
        XCTAssertEqual(try installedWrapperCount(fixture.root), 1)
    }

    func testUnavailablePinnedRootFailsClosed() async throws {
        let fixture = try Fixture(payload: Data("root".utf8))
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        )
        try FileManager.default.removeItem(at: fixture.root)

        await XCTAssertThrowsErrorAsync(try await manager.storageSnapshot()) { error in
            XCTAssertEqual(error as? BuiltInModelManagerError, .rootUnavailable)
        }
    }

    func testRelocationDrainProducesByteFingerprintSnapshotAndBlocksUntilResume() async throws {
        let fixture = try Fixture(payload: Data("relocate".utf8))
        defer { fixture.cleanup() }
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        )
        _ = try await manager.install(manifestID: fixture.manifest.id, currentSelectionRevision: .zero)

        let drain = try await manager.suspendAndDrainForRelocation()
        XCTAssertEqual(drain.download.activeDownloads, 0)
        XCTAssertEqual(drain.storage.activeManifestFingerprintSHA256, fixture.manifest.aggregateFingerprintSHA256)
        XCTAssertEqual(drain.storage.activeVerifiedBytes, Int64(fixture.payload.count))
        await XCTAssertThrowsErrorAsync(
            try await manager.reinstall(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        ) { error in
            XCTAssertEqual(error as? BuiltInModelManagerError, .suspendedForRelocation)
        }

        try await manager.resumeAfterRelocation()
        let result = try await manager.reinstall(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )
        XCTAssertNotNil(result.snapshot.state.inventory.lastKnownGood)
        XCTAssertEqual(try installedWrapperCount(fixture.root), 1)
    }

    func testRelocationDrainWaitsForEntireInFlightCandidateLoad() async throws {
        let fixture = try Fixture(payload: Data("drain-operation".utf8), suffix: "drain-operation")
        defer { fixture.cleanup() }
        let loadGate = ManagerOperationGate()
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [fixture.sourceURL: fixture.payload]
            ),
            loader: { _, _ in await loadGate.hold() }
        )

        let installTask = Task {
            try await manager.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        }
        await loadGate.waitUntilEntered()

        let drainCompletion = CompletionProbe()
        let drainTask = Task {
            let drain = try await manager.suspendAndDrainForRelocation()
            await drainCompletion.markCompleted()
            return drain
        }
        while !(await manager.snapshot()).suspendedForRelocation {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(100))

        let completedBeforeRelease = await drainCompletion.isCompleted
        XCTAssertFalse(
            completedBeforeRelease,
            "Relocation acknowledged while candidate load still owned manager mutation"
        )

        await loadGate.release()
        let installed = try await installTask.value
        let drain = try await drainTask.value
        XCTAssertNotNil(installed.snapshot.state.inventory.lastKnownGood)
        XCTAssertEqual(
            drain.storage.activeInstallationID,
            installed.snapshot.state.inventory.lastKnownGood?.installationID
        )
    }

    func testRelocationInvokesRuntimeDrainerBeforeWaitingForCandidateLoadMutation() async throws {
        let fixture = try Fixture(
            payload: Data("drain-before-load-wait".utf8),
            suffix: "drain-before-load-wait"
        )
        defer { fixture.cleanup() }
        let loadGate = ManagerOperationGate()
        let drainRecorder = RuntimeDrainRecorder()
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [fixture.sourceURL: fixture.payload]
            ),
            loader: { _, _ in await loadGate.hold() },
            runtimeDrainer: { installation in
                await drainRecorder.record(installation)
                await loadGate.release()
            }
        )

        let installTask = Task {
            try await manager.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        }
        await loadGate.waitUntilEntered()

        let relocationTask = Task {
            try await manager.suspendAndDrainForRelocation()
        }
        let bounded = await LocalRuntimeTaskDeadline.wait(
            for: relocationTask,
            timeout: .milliseconds(500)
        )
        if bounded != .completed {
            await loadGate.release()
        }
        XCTAssertEqual(
            bounded,
            .completed,
            "runtime drainer must be able to interrupt a load before mutation drain waits"
        )
        _ = try await relocationTask.value
        _ = try await installTask.value
        let drainedInstallations = await drainRecorder.values()
        XCTAssertEqual(drainedInstallations, [nil])
    }

    func testCancelCancelsSuspendedVerificationAndNeverPromotesCandidate() async throws {
        let fixture = try Fixture(payload: Data("cancel-verification".utf8), suffix: "cancel-verification")
        defer { fixture.cleanup() }
        let verificationGate = VerificationCancellationGate()
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [fixture.sourceURL: fixture.payload]
            ),
            verifier: { directory, manifest in
                try await verificationGate.verify(directory: directory, manifest: manifest)
            }
        )

        let installTask = Task {
            try await manager.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        }
        await verificationGate.waitUntilEntered()

        let cancelTask = Task { try await manager.cancel() }
        await verificationGate.waitUntilCancellationObserved()
        let cancelled = try await cancelTask.value

        await XCTAssertThrowsErrorAsync(try await installTask.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(cancelled.state.inventory.candidate)
        XCTAssertNil(cancelled.state.inventory.lastKnownGood)
        XCTAssertEqual(try installedWrapperCount(fixture.root), 0)
        XCTAssertEqual(try stagingWrapperCount(fixture.root), 0)
    }

    func testRelocationCancelsSuspendedVerificationAndPreservesRetryableCandidate() async throws {
        let fixture = try Fixture(payload: Data("relocate-verification".utf8), suffix: "relocate-verification")
        defer { fixture.cleanup() }
        let verificationGate = VerificationCancellationGate()
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [fixture.sourceURL: fixture.payload]
            ),
            verifier: { directory, manifest in
                try await verificationGate.verify(directory: directory, manifest: manifest)
            }
        )

        let installTask = Task {
            try await manager.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        }
        await verificationGate.waitUntilEntered()

        let relocationTask = Task { try await manager.suspendAndDrainForRelocation() }
        await verificationGate.waitUntilCancellationObserved()
        _ = try await relocationTask.value

        await XCTAssertThrowsErrorAsync(try await installTask.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let suspended = await manager.snapshot()
        XCTAssertNotNil(suspended.state.inventory.candidate)
        XCTAssertEqual(suspended.state.provisioningJob, .verificationPending)
        XCTAssertNil(suspended.state.inventory.lastKnownGood)
        XCTAssertEqual(try installedWrapperCount(fixture.root), 0)
        XCTAssertEqual(try stagingWrapperCount(fixture.root), 1)
    }

    func testShutdownCancelsSuspendedVerificationAndLeavesRestartRecoveryPoint() async throws {
        let fixture = try Fixture(payload: Data("shutdown-verification".utf8), suffix: "shutdown-verification")
        defer { fixture.cleanup() }
        let verificationGate = VerificationCancellationGate()
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [fixture.sourceURL: fixture.payload]
            ),
            verifier: { directory, manifest in
                try await verificationGate.verify(directory: directory, manifest: manifest)
            }
        )

        let installTask = Task {
            try await manager.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        }
        await verificationGate.waitUntilEntered()

        let shutdownTask = Task { await manager.shutdown() }
        await verificationGate.waitUntilCancellationObserved()
        _ = await shutdownTask.value

        await XCTAssertThrowsErrorAsync(try await installTask.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let stopped = await manager.snapshot()
        XCTAssertNotNil(stopped.state.inventory.candidate)
        XCTAssertEqual(stopped.state.provisioningJob, .verificationPending)
        XCTAssertNil(stopped.state.inventory.lastKnownGood)
        XCTAssertEqual(try installedWrapperCount(fixture.root), 0)
        XCTAssertEqual(try stagingWrapperCount(fixture.root), 1)
    }

    func testShutdownReturnsFalseAndKeepsFailedStateWhenRuntimeReleaseIsUnconfirmed() async throws {
        let fixture = try Fixture(
            payload: Data("shutdown-runtime-failure".utf8),
            suffix: "shutdown-runtime-failure"
        )
        defer { fixture.cleanup() }
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [fixture.sourceURL: fixture.payload]
            ),
            runtimeDrainer: { _ in throw RuntimeDrainFailure.unconfirmed }
        )
        _ = try await manager.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )

        let stopped = await manager.shutdown()

        XCTAssertFalse(stopped)
        let snapshot = await manager.snapshot()
        guard case .failed(let installation, _) = snapshot.state.runtimeState else {
            return XCTFail("failed runtime release was reported unloaded")
        }
        XCTAssertEqual(installation, snapshot.state.inventory.lastKnownGood)

        await manager.waitForFailedShutdownRecovery()
        let recoveredSnapshot = await manager.snapshot()
        XCTAssertFalse(recoveredSnapshot.suspendedForRelocation)
        let reinstalled = try await manager.reinstall(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )
        XCTAssertNotNil(reinstalled.snapshot.state.inventory.lastKnownGood)
    }

    func testCancelledQuitReopensManagerAfterSuccessfulShutdownBarrier() async throws {
        let fixture = try Fixture(
            payload: Data("cancelled-successful-shutdown".utf8),
            suffix: "cancelled-successful-shutdown"
        )
        defer { fixture.cleanup() }
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [fixture.sourceURL: fixture.payload]
            )
        )
        _ = try await manager.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )

        let stopped = await manager.shutdown()
        XCTAssertTrue(stopped)
        let suspended = await manager.snapshot()
        XCTAssertTrue(suspended.suspendedForRelocation)

        await manager.recoverAfterCancelledShutdown()

        let recovered = await manager.snapshot()
        XCTAssertFalse(recovered.suspendedForRelocation)
        let reconciled = try await manager.reconcileAfterRestart(
            currentSelectionRevision: .zero
        )
        let installed = try XCTUnwrap(
            reconciled.snapshot.state.inventory.lastKnownGood
        )
        XCTAssertEqual(
            reconciled.snapshot.state.runtimeState,
            .ready(installed)
        )
    }

    func testFailedShutdownRecoversAdmissionOnlyAfterActiveMutationDrains() async throws {
        let fixture = try Fixture(
            payload: Data("shutdown-active-mutation".utf8),
            suffix: "shutdown-active-mutation"
        )
        defer { fixture.cleanup() }
        let loadGate = ManagerOperationGate()
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [fixture.sourceURL: fixture.payload]
            ),
            loader: { _, _ in
                await loadGate.hold()
                throw CancellationError()
            },
            runtimeDrainer: { _ in throw RuntimeDrainFailure.unconfirmed }
        )
        let installTask = Task {
            try await manager.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        }
        await loadGate.waitUntilEntered()

        let stopped = await manager.shutdown()

        XCTAssertFalse(stopped)
        let suspendedWithActiveMutation = await manager.snapshot()
        XCTAssertTrue(suspendedWithActiveMutation.suspendedForRelocation)
        try await Task.sleep(for: .milliseconds(50))
        let stillSuspended = await manager.snapshot()
        XCTAssertTrue(
            stillSuspended.suspendedForRelocation,
            "admission reopened while a pre-shutdown mutation still owned the manager"
        )
        let recoveryWait = Task {
            await manager.waitForFailedShutdownRecovery()
        }
        let prematureRecovery = await LocalRuntimeTaskDeadline.wait(
            for: recoveryWait,
            timeout: .milliseconds(20)
        )
        XCTAssertEqual(prematureRecovery, .timedOut)

        await loadGate.release()
        await XCTAssertThrowsErrorAsync(try await installTask.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        await recoveryWait.value
        let recoveredSnapshot = await manager.snapshot()
        XCTAssertFalse(recoveredSnapshot.suspendedForRelocation)
        _ = try await manager.cancel()
    }

    func testImmediateRetrySupersedesFailedShutdownRecoveryWithoutSpinning() async throws {
        let fixture = try Fixture(
            payload: Data("shutdown-retry-generation".utf8),
            suffix: "shutdown-retry-generation"
        )
        defer { fixture.cleanup() }
        let loadGate = ManagerOperationGate()
        let drainGate = SupersededShutdownDrainGate()
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [fixture.sourceURL: fixture.payload]
            ),
            loader: { _, _ in
                await loadGate.hold()
                throw CancellationError()
            },
            runtimeDrainer: { installation in
                try await drainGate.drain(installation)
            }
        )
        let installTask = Task {
            try await manager.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        }
        await loadGate.waitUntilEntered()

        let firstStopped = await manager.shutdown()
        XCTAssertFalse(firstStopped)
        let firstRecoveryWait = Task {
            await manager.waitForFailedShutdownRecovery()
        }
        for _ in 0..<10 { await Task.yield() }

        let secondShutdown = Task { await manager.shutdown() }
        await drainGate.waitUntilSecondDrainEntered()
        await loadGate.release()
        await XCTAssertThrowsErrorAsync(try await installTask.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        await drainGate.releaseSecondDrain()

        let secondShutdownDeadline = await LocalRuntimeTaskDeadline.wait(
            for: secondShutdown,
            timeout: .milliseconds(500)
        )
        XCTAssertEqual(
            secondShutdownDeadline,
            .completed,
            "a waiter for the superseded recovery must not monopolize the manager actor"
        )
        let secondStopped = await secondShutdown.value
        XCTAssertFalse(secondStopped)
        let firstWaitDeadline = await LocalRuntimeTaskDeadline.wait(
            for: firstRecoveryWait,
            timeout: .milliseconds(500)
        )
        XCTAssertEqual(firstWaitDeadline, .completed)
        await manager.waitForFailedShutdownRecovery()

        let recovered = await manager.snapshot()
        XCTAssertFalse(recovered.suspendedForRelocation)
    }

    func testNewShutdownSupersedesAnOlderInFlightShutdownGeneration() async throws {
        let fixture = try Fixture(
            payload: Data("in-flight-shutdown-generation".utf8),
            suffix: "in-flight-shutdown-generation"
        )
        defer { fixture.cleanup() }
        let drainGate = InFlightShutdownGenerationGate()
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [fixture.sourceURL: fixture.payload]
            ),
            runtimeDrainer: { installation in
                try await drainGate.drain(installation)
            }
        )
        _ = try await manager.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )

        let firstShutdown = Task { await manager.shutdown() }
        await drainGate.waitUntilFirstDrainEntered()
        let secondStopped = await manager.shutdown()
        XCTAssertFalse(secondStopped)
        await manager.waitForFailedShutdownRecovery()

        await drainGate.releaseFirstDrain()
        let firstDeadline = await LocalRuntimeTaskDeadline.wait(
            for: firstShutdown,
            timeout: .milliseconds(500)
        )
        XCTAssertEqual(firstDeadline, .completed)
        let supersededStopped = await firstShutdown.value
        XCTAssertFalse(
            supersededStopped,
            "an older shutdown must not publish success over a newer generation"
        )
    }

    func testCancelAlsoCancelsInstalledPayloadReverification() async throws {
        let fixture = try Fixture(payload: Data("cancel-reverification".utf8), suffix: "cancel-reverification")
        defer { fixture.cleanup() }
        let verificationGate = VerificationCancellationGate(blockingInvocation: 2)
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [fixture.sourceURL: fixture.payload]
            ),
            verifier: { directory, manifest in
                try await verificationGate.verify(directory: directory, manifest: manifest)
            }
        )

        let installTask = Task {
            try await manager.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        }
        await verificationGate.waitUntilEntered()

        let cancelTask = Task { try await manager.cancel() }
        await verificationGate.waitUntilCancellationObserved()
        let cancelled = try await cancelTask.value

        await XCTAssertThrowsErrorAsync(try await installTask.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(cancelled.state.inventory.candidate)
        XCTAssertNil(cancelled.state.inventory.lastKnownGood)
        XCTAssertEqual(try installedWrapperCount(fixture.root), 0)
        XCTAssertEqual(try stagingWrapperCount(fixture.root), 0)
    }

    func testConcurrentRemoveCannotBypassRejectedBeginRemovalTransition() async throws {
        let fixture = try Fixture(payload: Data("remove-gate".utf8), suffix: "remove-gate")
        defer { fixture.cleanup() }
        let drainGate = FirstRuntimeDrainGate()
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(
                payloads: [fixture.sourceURL: fixture.payload]
            ),
            runtimeDrainer: { installation in
                try await drainGate.drain(installation)
            }
        )
        _ = try await manager.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )
        let installedSnapshot = await manager.snapshot()
        let installation = try XCTUnwrap(installedSnapshot.state.inventory.lastKnownGood)

        let firstRemoval = Task {
            try await manager.remove(currentSelectionRevision: .zero)
        }
        await drainGate.waitUntilFirstDrainEntered()

        await XCTAssertThrowsErrorAsync(
            try await manager.remove(currentSelectionRevision: .zero)
        ) { error in
            guard let managerError = error as? BuiltInModelManagerError,
                  case .invalidState = managerError else {
                return XCTFail("Expected rejected removal transition, got \(error)")
            }
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.installedWrapper(installation).path
            )
        )

        await drainGate.releaseFirstDrain()
        _ = try await firstRemoval.value
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.installedWrapper(installation).path
            )
        )
    }

    func testPauseResumeAndCancelOwnOnlyTheUnverifiedCandidate() async throws {
        let fixture = try Fixture(payload: Data(repeating: 3, count: 20), suffix: "pause-resume")
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: fixture.payload],
            interruptOnceAt: 5
        )
        let manager = try fixture.manager(transport: transport)
        let interrupted = try await manager.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )
        guard case .paused = interrupted.snapshot.state.provisioningJob else {
            return XCTFail("Expected interrupted candidate")
        }

        let explicitlyPaused = try await manager.pause()
        guard case .paused = explicitlyPaused.state.provisioningJob else {
            return XCTFail("Expected explicit pause")
        }
        let resumed = try await manager.resume(currentSelectionRevision: .zero)
        XCTAssertNotNil(resumed.snapshot.state.inventory.lastKnownGood)

        let cancelFixture = try Fixture(payload: Data(repeating: 5, count: 20), suffix: "cancel")
        defer { cancelFixture.cleanup() }
        let cancelTransport = ScriptedManagerTransport(
            payloads: [cancelFixture.sourceURL: cancelFixture.payload],
            interruptOnceAt: 5
        )
        let cancelManager = try cancelFixture.manager(transport: cancelTransport)
        _ = try await cancelManager.install(
            manifestID: cancelFixture.manifest.id,
            currentSelectionRevision: .zero
        )
        let cancelled = try await cancelManager.cancel()
        XCTAssertNil(cancelled.state.inventory.candidate)
        XCTAssertNil(cancelled.state.inventory.lastKnownGood)
        XCTAssertEqual(try stagingWrapperCount(cancelFixture.root), 0)
        XCTAssertEqual(try installedWrapperCount(cancelFixture.root), 0)
    }

    func testResumeCapacitySubtractsDurablePartialBytes() async throws {
        let payload = Data(repeating: 8, count: 100)
        let fixture = try Fixture(payload: payload, suffix: "resume-capacity")
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: payload],
            interruptOnceAt: 50
        )
        var manager: BuiltInModelManager? = try fixture.manager(transport: transport)
        _ = try await manager!.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )
        manager = nil

        let freshRequired = Int64(2 * payload.count)
            + BuiltInModelManager.captureReserveBytes
            + BuiltInModelManager.capacitySafetyBytes
        let reopened = try fixture.manager(
            transport: transport,
            capacityReader: { _ in freshRequired - 50 }
        )
        let resumed = try await reopened.resume(currentSelectionRevision: .zero)
        XCTAssertNotNil(resumed.snapshot.state.inventory.lastKnownGood)
    }

    func testCrashAfterCandidateLoadBeforeJournalReplaysWithoutAdoptingUnknownBytes() async throws {
        let fixture = try Fixture(payload: Data("load-journal-crash".utf8), suffix: "load-journal")
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        let fault = OneShotFault(point: .candidateLoadedBeforeJournal)
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            faultHook: fault.hit
        )
        await XCTAssertThrowsErrorAsync(
            try await manager!.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        )
        let interrupted = await manager!.snapshot()
        XCTAssertNil(interrupted.state.inventory.lastKnownGood)
        XCTAssertEqual(interrupted.state.inventory.candidate?.verification, .verified)
        manager = nil

        let reopened = try fixture.manager(transport: transport)
        let reconciled = try await reopened.reconcileAfterRestart(currentSelectionRevision: .zero)
        XCTAssertNotNil(reconciled.snapshot.state.inventory.lastKnownGood)
    }

    func testCrashAfterTrashBeforeJournalFinishesExactRemovalOnRestart() async throws {
        let fixture = try Fixture(payload: Data("trash-crash".utf8), suffix: "trash-crash")
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        let fault = OneShotFault(point: .afterTrashBeforeJournal)
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            faultHook: fault.hit
        )
        _ = try await manager!.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )
        await XCTAssertThrowsErrorAsync(
            try await manager!.remove(currentSelectionRevision: .zero)
        )
        XCTAssertEqual(try installedWrapperCount(fixture.root), 0)
        XCTAssertEqual(try trashWrapperCount(fixture.root), 1)
        manager = nil

        let reopened = try fixture.manager(transport: transport)
        let reconciled = try await reopened.reconcileAfterRestart(currentSelectionRevision: .zero)
        XCTAssertNil(reconciled.snapshot.state.inventory.lastKnownGood)
        XCTAssertEqual(try trashWrapperCount(fixture.root), 0)
    }

    func testHardwareGuardAndStaleDeactivationFailClosed() async throws {
        let fixture = try Fixture(payload: Data("hardware".utf8), suffix: "hardware")
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        var unsupported: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            hardwareEligibility: { _ in false }
        )
        await XCTAssertThrowsErrorAsync(
            try await unsupported!.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        ) { error in
            XCTAssertEqual(error as? BuiltInModelManagerError, .unsupportedHardware)
        }
        unsupported = nil

        let supported = try fixture.manager(transport: transport)
        _ = try await supported.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: SelectionRevision(rawValue: 1)
        )
        let staleIntent = DeactivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: fixture.manifest.id,
            expectedSelectionRevision: SelectionRevision(rawValue: 1)
        )
        let removed = try await supported.remove(
            deactivationIntent: staleIntent,
            currentSelectionRevision: SelectionRevision(rawValue: 2)
        )
        XCTAssertTrue(removed.effects.isEmpty)
        XCTAssertNil(removed.snapshot.state.inventory.lastKnownGood)
    }

    func testCrashAfterVerifiedMarkerBeforeJournalReverifiesOnRestart() async throws {
        let fixture = try Fixture(payload: Data("marker-crash".utf8), suffix: "marker-crash")
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        let fault = OneShotFault(point: .afterVerifiedMarker)
        var manager: BuiltInModelManager? = try fixture.manager(
            transport: transport,
            faultHook: fault.hit
        )
        await XCTAssertThrowsErrorAsync(
            try await manager!.install(
                manifestID: fixture.manifest.id,
                currentSelectionRevision: .zero
            )
        )
        let interrupted = await manager!.snapshot()
        guard case .verifying = interrupted.state.provisioningJob else {
            return XCTFail("Expected durable verification recovery point")
        }
        manager = nil

        let reopened = try fixture.manager(transport: transport)
        let restored = await reopened.snapshot()
        guard case .verificationPending = restored.state.provisioningJob else {
            return XCTFail("Expected verificationPending after restart")
        }
        let reconciled = try await reopened.reconcileAfterRestart(currentSelectionRevision: .zero)
        XCTAssertNotNil(reconciled.snapshot.state.inventory.lastKnownGood)
    }

    func testRestartReverifiesInstalledPayloadBeforeLoading() async throws {
        let fixture = try Fixture(payload: Data("reverify".utf8), suffix: "reverify")
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        var manager: BuiltInModelManager? = try fixture.manager(transport: transport)
        _ = try await manager!.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )
        let installedSnapshot = await manager!.snapshot()
        let installation = try XCTUnwrap(installedSnapshot.state.inventory.lastKnownGood)
        try Data("tampered".utf8).write(
            to: fixture.installedWrapper(installation).appending(path: "payload/model.bin")
        )
        manager = nil

        let reopened = try fixture.manager(transport: transport)
        let reconciled = try await reopened.reconcileAfterRestart(currentSelectionRevision: .zero)
        XCTAssertEqual(reconciled.snapshot.state.inventory.lastKnownGood, installation)
        guard case .failed(let failedInstallation, _) = reconciled.snapshot.state.runtimeState else {
            return XCTFail("Tampered LKG must not load")
        }
        XCTAssertEqual(failedInstallation, installation)
    }

    func testRetryRuntimeLoadRecoversVerifiedLastKnownGoodWithoutCandidate() async throws {
        let fixture = try Fixture(payload: Data("runtime-retry".utf8), suffix: "runtime-retry")
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        var manager: BuiltInModelManager? = try fixture.manager(transport: transport)
        _ = try await manager!.install(
            manifestID: fixture.manifest.id,
            currentSelectionRevision: .zero
        )
        manager = nil

        let loader = LoadRecorder(failingManifestIDs: [fixture.manifest.id])
        let reopened = try fixture.manager(
            transport: transport,
            loader: { directory, manifest in try await loader.load(directory, manifest) }
        )
        let failed = try await reopened.reconcileAfterRestart(
            currentSelectionRevision: .zero
        )
        XCTAssertNil(failed.snapshot.state.inventory.candidate)
        XCTAssertEqual(
            failed.snapshot.projection.readiness,
            .installedButRuntimeFailed
        )

        await loader.allow(fixture.manifest.id)
        let recovered = try await reopened.retryRuntimeLoad(
            currentSelectionRevision: .zero
        )

        XCTAssertEqual(recovered.projection.readiness, .usable)
        XCTAssertNil(recovered.state.inventory.candidate)
        let loadedManifestIDs = await loader.loadedManifestIDs()
        XCTAssertEqual(loadedManifestIDs, [fixture.manifest.id])
    }

    func testRecreatedPathDoesNotReplacePinnedRootIdentity() async throws {
        let fixture = try Fixture(payload: Data("inode".utf8), suffix: "inode")
        let manager = try fixture.manager(
            transport: ScriptedManagerTransport(payloads: [fixture.sourceURL: fixture.payload])
        )
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        defer { fixture.cleanup() }

        await XCTAssertThrowsErrorAsync(try await manager.storageSnapshot()) { error in
            XCTAssertEqual(error as? BuiltInModelManagerError, .rootUnavailable)
        }
        let unavailableSnapshot = await manager.snapshot()
        XCTAssertFalse(unavailableSnapshot.rootAvailable)
    }

    func testSecondManagerFailsClosedUntilFirstManagerDeinitializes() throws {
        let fixture = try Fixture(payload: Data("process-lock".utf8), suffix: "process-lock")
        defer { fixture.cleanup() }
        let transport = ScriptedManagerTransport(
            payloads: [fixture.sourceURL: fixture.payload]
        )
        var first: BuiltInModelManager? = try fixture.manager(transport: transport)

        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try fixture.manager(transport: transport)) { error in
                XCTAssertEqual(error as? BuiltInModelManagerError, .modelStoreInUse)
            }
        }

        first = nil
        XCTAssertNoThrow(try fixture.manager(transport: transport))
    }
}

private enum CapacityFailure: Error { case unavailable }
private enum TransportInterruption: Error { case interrupted }
private enum RuntimeDrainFailure: Error { case unconfirmed }

private final class Fixture: @unchecked Sendable {
    let root: URL
    let payload: Data
    let sourceURL: URL
    let manifest: BuiltInModelManifest

    init(payload: Data, suffix: String = UUID().uuidString) throws {
        self.payload = payload
        sourceURL = URL(string: "https://assets.example/\(suffix).bin")!
        root = FileManager.default.temporaryDirectory
            .appending(path: "zbseye-manager-\(suffix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manifest = Self.makeManifest(id: "tiny-\(suffix)", payload: payload, sourceURL: sourceURL)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func manifest(id: String, payload: Data, sourceURL: URL) -> BuiltInModelManifest {
        Self.makeManifest(id: id, payload: payload, sourceURL: sourceURL)
    }

    func activationIntent(revision: UInt64) -> ActivationIntent {
        ActivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: manifest.id,
            expectedSelectionRevision: SelectionRevision(rawValue: revision)
        )
    }

    func manager(
        manifests: [BuiltInModelManifest]? = nil,
        transport: ScriptedManagerTransport,
        loader: @escaping BuiltInModelManager.CandidateLoader = { _, _ in },
        verifier: @escaping BuiltInModelManager.CandidateVerifier = {
            try BuiltInModelVerifier.verify(directory: $0, manifest: $1)
        },
        capacityReader: @escaping BuiltInModelManager.CapacityReader = { _ in Int64.max },
        hardwareEligibility: @escaping BuiltInModelManager.HardwareEligibility = { _ in true },
        runtimeDrainer: @escaping BuiltInModelManager.RuntimeDrainer = { _ in },
        effectHandler: @escaping BuiltInModelManager.EffectHandler = { _ in .applied },
        faultHook: @escaping BuiltInModelManager.FaultHook = { _ in }
    ) throws -> BuiltInModelManager {
        try manager(
            manifests: manifests,
            downloadClient: BuiltInDownloadClient(
                transport: transport,
                allowedAssetHosts: ["assets.example"]
            ),
            loader: loader,
            verifier: verifier,
            capacityReader: capacityReader,
            hardwareEligibility: hardwareEligibility,
            runtimeDrainer: runtimeDrainer,
            effectHandler: effectHandler,
            faultHook: faultHook
        )
    }

    func manager(
        manifests: [BuiltInModelManifest]? = nil,
        downloadClient: BuiltInDownloadClient,
        loader: @escaping BuiltInModelManager.CandidateLoader = { _, _ in },
        verifier: @escaping BuiltInModelManager.CandidateVerifier = {
            try BuiltInModelVerifier.verify(directory: $0, manifest: $1)
        },
        capacityReader: @escaping BuiltInModelManager.CapacityReader = { _ in Int64.max },
        hardwareEligibility: @escaping BuiltInModelManager.HardwareEligibility = { _ in true },
        runtimeDrainer: @escaping BuiltInModelManager.RuntimeDrainer = { _ in },
        effectHandler: @escaping BuiltInModelManager.EffectHandler = { _ in .applied },
        faultHook: @escaping BuiltInModelManager.FaultHook = { _ in }
    ) throws -> BuiltInModelManager {
        try BuiltInModelManager(
            dataRoot: root,
            manifests: manifests ?? [manifest],
            downloadClient: downloadClient,
            hardwareEligibility: hardwareEligibility,
            capacityReader: capacityReader,
            candidateLoader: loader,
            candidateVerifier: verifier,
            runtimeDrainer: runtimeDrainer,
            effectHandler: effectHandler,
            faultHook: faultHook
        )
    }

    func installedWrapper(_ installation: BuiltInModelInstallation) -> URL {
        root.appending(path: "installed")
            .appending(path: installation.installationID.uuidString.lowercased())
    }

    private static func makeManifest(
        id: String,
        payload: Data,
        sourceURL: URL
    ) -> BuiltInModelManifest {
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return BuiltInModelManifest(
            id: id,
            artifactVersion: 1,
            repositoryID: "tests/\(id)",
            revision: String(repeating: "1", count: 40),
            displayName: id,
            modelFamily: "Tiny",
            license: BuiltInModelLicense(
                spdxIdentifier: "Apache-2.0",
                displayName: "Apache License 2.0",
                upstreamModelID: "tests/\(id)",
                upstreamLicenseURL: URL(string: "https://assets.example/license")!,
                immutableProvenanceURL: URL(string: "https://assets.example/provenance")!
            ),
            hardware: BuiltInModelHardwareEnvelope(
                minimumUnifiedMemoryBytes: 1,
                maximumUnifiedMemoryBytesExclusive: nil,
                minimumMacOSMajorVersion: 15,
                supportedArchitectures: ["arm64"],
                maximumIncrementalMemoryBytes: 1
            ),
            generation: BuiltInModelGenerationProfile(
                contextTokenCeiling: 128,
                thinkingMode: .disabled,
                temperature: 0.2,
                topP: 0.95,
                benchmarkProtocol: "test"
            ),
            expectedDownloadBytes: Int64(payload.count),
            aggregateFingerprintSHA256: SHA256.hash(data: Data("manifest-\(id)".utf8))
                .map { String(format: "%02x", $0) }.joined(),
            files: [
                BuiltInModelFile(
                    relativePath: "model.bin",
                    sourceURL: sourceURL,
                    expectedBytes: Int64(payload.count),
                    sha256: digest,
                    role: .weights,
                    requirement: .required
                )
            ]
        )
    }
}

private actor LoadRecorder {
    private var failingManifestIDs: Set<String>
    private var loaded: [String] = []

    init(failingManifestIDs: Set<String> = []) {
        self.failingManifestIDs = failingManifestIDs
    }

    func load(_ directory: URL, _ manifest: BuiltInModelManifest) throws {
        _ = directory
        if failingManifestIDs.contains(manifest.id) { throw LoadFailure.rejected }
        loaded.append(manifest.id)
    }

    func allow(_ id: String) { failingManifestIDs.remove(id) }
    func reject(_ id: String) { failingManifestIDs.insert(id) }
    func loadedManifestIDs() -> [String] { loaded }

    private enum LoadFailure: Error { case rejected }
}

private actor ManagerOperationGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor RuntimeDrainRecorder {
    private var installations: [BuiltInModelInstallation?] = []

    func record(_ installation: BuiltInModelInstallation?) {
        installations.append(installation)
    }

    func values() -> [BuiltInModelInstallation?] { installations }
}

private actor VerificationCancellationGate {
    private let blockingInvocation: Int
    private var invocationCount = 0
    private var entered = false
    private var cancellationObserved = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var verificationWaiter: CheckedContinuation<Void, Never>?

    init(blockingInvocation: Int = 1) {
        self.blockingInvocation = blockingInvocation
    }

    func verify(
        directory: URL,
        manifest: BuiltInModelManifest
    ) async throws -> BuiltInModelVerification {
        invocationCount += 1
        guard invocationCount == blockingInvocation else {
            return try BuiltInModelVerifier.verify(directory: directory, manifest: manifest)
        }
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { verificationWaiter = $0 }
        } onCancel: {
            Task { await self.observeCancellation() }
        }
        try Task.checkCancellation()
        return try BuiltInModelVerifier.verify(directory: directory, manifest: manifest)
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func waitUntilCancellationObserved() async {
        guard !cancellationObserved else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func observeCancellation() {
        cancellationObserved = true
        verificationWaiter?.resume()
        verificationWaiter = nil
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor CompletionProbe {
    private(set) var isCompleted = false
    func markCompleted() { isCompleted = true }
}

private actor FirstRuntimeDrainGate {
    private var callCount = 0
    private var firstEntered = false
    private var firstReleased = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func drain(_ installation: BuiltInModelInstallation?) async throws {
        _ = installation
        callCount += 1
        guard callCount == 1 else { return }
        firstEntered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !firstReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilFirstDrainEntered() async {
        guard !firstEntered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func releaseFirstDrain() {
        firstReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor SupersededShutdownDrainGate {
    private var invocationCount = 0
    private var secondEntered = false
    private var secondReleased = false
    private var secondEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func drain(_ installation: BuiltInModelInstallation?) async throws {
        _ = installation
        invocationCount += 1
        guard invocationCount == 2 else {
            throw RuntimeDrainFailure.unconfirmed
        }
        secondEntered = true
        let entered = secondEnteredWaiters
        secondEnteredWaiters.removeAll()
        for waiter in entered { waiter.resume() }
        if !secondReleased {
            await withCheckedContinuation { secondReleaseWaiters.append($0) }
        }
        throw RuntimeDrainFailure.unconfirmed
    }

    func waitUntilSecondDrainEntered() async {
        guard !secondEntered else { return }
        await withCheckedContinuation { secondEnteredWaiters.append($0) }
    }

    func releaseSecondDrain() {
        secondReleased = true
        let waiters = secondReleaseWaiters
        secondReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor InFlightShutdownGenerationGate {
    private var invocationCount = 0
    private var firstEntered = false
    private var firstReleased = false
    private var firstEnteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstReleaseWaiters: [CheckedContinuation<Void, Never>] = []

    func drain(_ installation: BuiltInModelInstallation?) async throws {
        _ = installation
        invocationCount += 1
        if invocationCount == 1 {
            firstEntered = true
            let entered = firstEnteredWaiters
            firstEnteredWaiters.removeAll()
            for waiter in entered { waiter.resume() }
            if !firstReleased {
                await withCheckedContinuation { firstReleaseWaiters.append($0) }
            }
            return
        }
        throw RuntimeDrainFailure.unconfirmed
    }

    func waitUntilFirstDrainEntered() async {
        guard !firstEntered else { return }
        await withCheckedContinuation { firstEnteredWaiters.append($0) }
    }

    func releaseFirstDrain() {
        firstReleased = true
        let waiters = firstReleaseWaiters
        firstReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class CapacityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(value: Int64) { self.value = value }
    func read(_ root: URL) throws -> Int64 {
        _ = root
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class SequenceCapacityReader: @unchecked Sendable {
    enum Step { case value(Int64); case failure }
    private let lock = NSLock()
    private var values: [Step]

    init(values: [Step]) { self.values = values }

    func read(_ root: URL) throws -> Int64 {
        _ = root
        lock.lock()
        defer { lock.unlock() }
        let step = values.isEmpty ? .failure : values.removeFirst()
        switch step {
        case .value(let value): return value
        case .failure: throw CapacityFailure.unavailable
        }
    }
}

private final class OneShotFault: @unchecked Sendable {
    private let lock = NSLock()
    private let point: BuiltInModelManagerFaultPoint
    private var fired = false

    init(point: BuiltInModelManagerFaultPoint) { self.point = point }

    func hit(_ candidate: BuiltInModelManagerFaultPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard candidate == point, !fired else { return }
        fired = true
        throw FaultFailure.injected
    }

    private enum FaultFailure: Error { case injected }
}

private actor EffectRecorder {
    private var effects: [BuiltInModelLifecycleEffect] = []

    func record(
        _ effect: BuiltInModelLifecycleEffect
    ) -> BuiltInModelProviderEffectResult {
        effects.append(effect)
        return .applied
    }

    func values() -> [BuiltInModelLifecycleEffect] { effects }
}

private actor ScriptedEffectHandler {
    private var outcomes: [BuiltInModelProviderEffectResult]
    private var effects: [BuiltInModelLifecycleEffect] = []
    private var acknowledgedApplications = 0

    init(_ outcomes: [BuiltInModelProviderEffectResult]) {
        self.outcomes = outcomes
    }

    func handle(
        _ effect: BuiltInModelLifecycleEffect
    ) -> BuiltInModelProviderEffectResult {
        effects.append(effect)
        let outcome = outcomes.isEmpty
            ? BuiltInModelProviderEffectResult.retryablePersistenceFailure
            : outcomes.removeFirst()
        if outcome == .applied {
            acknowledgedApplications += 1
        }
        return outcome
    }

    func values() -> [BuiltInModelLifecycleEffect] { effects }
    func appliedCount() -> Int { acknowledgedApplications }
}

private actor ScriptedManagerTransport: BuiltInDownloadTransport {
    private let payloads: [URL: Data]
    private let interruptOnceAt: Int?
    private var didInterrupt = false
    private var requests: [BuiltInDownloadHTTPRequest] = []

    init(payloads: [URL: Data], interruptOnceAt: Int? = nil) {
        self.payloads = payloads
        self.interruptOnceAt = interruptOnceAt
    }

    func open(_ request: BuiltInDownloadHTTPRequest) async throws -> BuiltInDownloadStream {
        requests.append(request)
        guard let payload = payloads[request.url] else { throw TransportInterruption.interrupted }
        let offset = Self.rangeOffset(request.headers["Range"]) ?? 0
        let remaining = payload.dropFirst(offset)
        let shouldInterrupt = !didInterrupt && offset == 0 && interruptOnceAt != nil
        if shouldInterrupt { didInterrupt = true }
        let source = ManagerChunkSource(
            data: Data(remaining),
            firstChunkLength: shouldInterrupt ? interruptOnceAt : nil,
            interruptAfterFirstChunk: shouldInterrupt
        )
        let response: BuiltInDownloadHTTPResponse
        if offset == 0 {
            response = BuiltInDownloadHTTPResponse(
                url: request.url,
                statusCode: 200,
                headers: [
                    "ETag": "\"tiny-etag\"",
                    "Content-Length": "\(payload.count)",
                    "Content-Encoding": "identity",
                ]
            )
        } else {
            response = BuiltInDownloadHTTPResponse(
                url: request.url,
                statusCode: 206,
                headers: [
                    "ETag": "\"tiny-etag\"",
                    "Content-Length": "\(payload.count - offset)",
                    "Content-Range": "bytes \(offset)-\(payload.count - 1)/\(payload.count)",
                    "Content-Encoding": "identity",
                ]
            )
        }
        return BuiltInDownloadStream(
            response: response,
            nextChunk: { try await source.next() },
            cancel: { Task { await source.cancel() } }
        )
    }

    func sawRange(_ range: String) -> Bool {
        requests.contains { $0.headers["Range"] == range }
    }

    private static func rangeOffset(_ value: String?) -> Int? {
        guard let value, value.hasPrefix("bytes="), value.hasSuffix("-") else { return nil }
        return Int(value.dropFirst(6).dropLast())
    }
}

private actor ManagerChunkSource {
    private let data: Data
    private let firstChunkLength: Int?
    private let interruptAfterFirstChunk: Bool
    private var position = 0
    private var interrupted = false
    private var cancelled = false

    init(data: Data, firstChunkLength: Int?, interruptAfterFirstChunk: Bool) {
        self.data = data
        self.firstChunkLength = firstChunkLength
        self.interruptAfterFirstChunk = interruptAfterFirstChunk
    }

    func next() throws -> Data? {
        if cancelled { throw TransportInterruption.interrupted }
        if interruptAfterFirstChunk, position > 0, !interrupted {
            interrupted = true
            throw TransportInterruption.interrupted
        }
        guard position < data.count else { return nil }
        let count = min(firstChunkLength ?? data.count, data.count - position)
        let chunk = data.subdata(in: position..<(position + count))
        position += count
        return chunk
    }

    func cancel() { cancelled = true }
}

private func permissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func installedWrapperCount(_ root: URL) throws -> Int {
    try directoryCount(root.appending(path: "installed"), excluding: ["unrelated"])
}

private func stagingWrapperCount(_ root: URL) throws -> Int {
    try directoryCount(root.appending(path: "staging"), excluding: [])
}

private func trashWrapperCount(_ root: URL) throws -> Int {
    try directoryCount(root.appending(path: "trash"), excluding: [])
}

private func directoryCount(_ url: URL, excluding: Set<String>) throws -> Int {
    guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
    return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        .filter { !excluding.contains($0.lastPathComponent) }.count
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error")
    } catch {
        verify(error)
    }
}
