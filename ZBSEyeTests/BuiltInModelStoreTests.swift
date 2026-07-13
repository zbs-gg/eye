import Foundation
import XCTest

@MainActor
final class BuiltInModelStoreTests: XCTestCase {
    func testFreshOneClickPublishesAuthoritativeRuntimeBeforeActivation() throws {
        let providers = FakeBuiltInProvider(revision: .zero)
        let bridge = BuiltInModelProviderBridge(providers: providers)
        let intent = try XCTUnwrap(
            providers.builtInProvisioningIntent(modelID: BuiltInModelManifest.regular.id)
        )

        XCTAssertNil(providers.availableModelID)
        XCTAssertEqual(bridge.handle(.requestActivation(intent)), .applied)
        XCTAssertEqual(providers.availableModelID, BuiltInModelManifest.regular.id)
        XCTAssertEqual(providers.activeProvider, .zbsEyeLocal)
        XCTAssertEqual(providers.activeModelID, BuiltInModelManifest.regular.id)
    }

    func testProviderSwitchDuringDownloadCannotBeOverwrittenByLateActivation() throws {
        let providers = FakeBuiltInProvider(revision: .zero)
        let bridge = BuiltInModelProviderBridge(providers: providers)
        let intent = try XCTUnwrap(
            providers.builtInProvisioningIntent(modelID: BuiltInModelManifest.regular.id)
        )
        providers.selectOtherProvider()

        XCTAssertEqual(bridge.handle(.requestActivation(intent)), .stale)
        XCTAssertEqual(providers.availableModelID, BuiltInModelManifest.regular.id)
        XCTAssertEqual(providers.activeProvider, .ollama)
        XCTAssertEqual(providers.activeModelID, "other-model")
    }

    func testActivationPersistenceFailureIsRetryableWithoutAdvancingSelection() throws {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        let persistence = PersistenceAcknowledgementSequence([false, true])
        let providers = AIProviderStore(
            defaults: defaults,
            storedKeyExists: { _ in false },
            persistenceSynchronizer: persistence.acknowledge
        )
        _ = providers.publishBuiltInRuntimeAvailability(
            modelID: BuiltInModelManifest.regular.id
        )
        let intent = try XCTUnwrap(
            providers.builtInProvisioningIntent(modelID: BuiltInModelManifest.regular.id)
        )

        XCTAssertEqual(
            providers.commitBuiltInActivation(intent),
            .retryablePersistenceFailure
        )
        XCTAssertNil(providers.activeProvider)
        XCTAssertNil(providers.activeModelID)
        XCTAssertEqual(providers.currentSelectionRevision, .zero)

        XCTAssertEqual(providers.commitBuiltInActivation(intent), .applied)
        XCTAssertEqual(providers.activeProvider, .zbsEyeLocal)
        XCTAssertEqual(providers.activeModelID, BuiltInModelManifest.regular.id)
        XCTAssertEqual(
            providers.currentSelectionRevision,
            SelectionRevision(rawValue: 1)
        )
        XCTAssertEqual(persistence.callCount, 2)
    }

    func testDeactivationPersistenceFailureIsRetryableWithoutTurningProcessingOff() throws {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        let persistence = PersistenceAcknowledgementSequence([false, true])
        let providers = AIProviderStore(
            defaults: defaults,
            storedKeyExists: { _ in false },
            persistenceSynchronizer: persistence.acknowledge
        )
        _ = providers.publishBuiltInRuntimeAvailability(
            modelID: BuiltInModelManifest.regular.id
        )
        let activation = try XCTUnwrap(
            providers.builtInProvisioningIntent(modelID: BuiltInModelManifest.regular.id)
        )
        XCTAssertTrue(providers.commitActivation(activation))
        let deactivation = try XCTUnwrap(providers.deactivationIntent(for: .zbsEyeLocal))

        XCTAssertEqual(
            providers.commitBuiltInDeactivation(deactivation),
            .retryablePersistenceFailure
        )
        XCTAssertEqual(providers.activeProvider, .zbsEyeLocal)
        XCTAssertEqual(providers.activeModelID, BuiltInModelManifest.regular.id)
        XCTAssertEqual(
            providers.currentSelectionRevision,
            SelectionRevision(rawValue: 1)
        )

        XCTAssertEqual(providers.commitBuiltInDeactivation(deactivation), .applied)
        XCTAssertNil(providers.activeProvider)
        XCTAssertNil(providers.activeModelID)
        XCTAssertEqual(
            providers.currentSelectionRevision,
            SelectionRevision(rawValue: 2)
        )
        XCTAssertEqual(persistence.callCount, 2)
    }

    func testActivationRecoveryReceiptIsIdempotentAfterProviderStoreReload() throws {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        var providers: AIProviderStore? = AIProviderStore(
            defaults: defaults,
            storedKeyExists: { _ in false },
            persistenceSynchronizer: { true }
        )
        var bridge: BuiltInModelProviderBridge? = BuiltInModelProviderBridge(
            providers: providers!
        )
        let intent = try XCTUnwrap(
            providers!.builtInProvisioningIntent(
                modelID: BuiltInModelManifest.regular.id
            )
        )

        XCTAssertEqual(bridge!.handle(.requestActivation(intent)), .applied)
        XCTAssertEqual(
            providers!.currentSelectionRevision,
            SelectionRevision(rawValue: 1)
        )
        bridge = nil
        providers = nil

        let restored = AIProviderStore(
            defaults: defaults,
            storedKeyExists: { _ in false },
            persistenceSynchronizer: { true }
        )
        let recoveryBridge = BuiltInModelProviderBridge(providers: restored)

        XCTAssertEqual(
            recoveryBridge.handle(.requestActivation(intent)),
            .stale
        )
        XCTAssertEqual(restored.activeProvider, .zbsEyeLocal)
        XCTAssertEqual(restored.activeModelID, BuiltInModelManifest.regular.id)
        XCTAssertEqual(
            restored.currentSelectionRevision,
            SelectionRevision(rawValue: 1)
        )
    }

    func testDeactivationRecoveryReceiptIsIdempotentAfterProviderStoreReload() throws {
        let defaults = isolatedDefaults()
        defer { clear(defaults) }
        var providers: AIProviderStore? = AIProviderStore(
            defaults: defaults,
            storedKeyExists: { _ in false },
            persistenceSynchronizer: { true }
        )
        var bridge: BuiltInModelProviderBridge? = BuiltInModelProviderBridge(
            providers: providers!
        )
        let activation = try XCTUnwrap(
            providers!.builtInProvisioningIntent(
                modelID: BuiltInModelManifest.regular.id
            )
        )
        XCTAssertEqual(bridge!.handle(.requestActivation(activation)), .applied)
        let deactivation = try XCTUnwrap(
            providers!.deactivationIntent(for: .zbsEyeLocal)
        )

        XCTAssertEqual(
            bridge!.handle(.requestDeactivation(deactivation)),
            .applied
        )
        XCTAssertEqual(
            providers!.currentSelectionRevision,
            SelectionRevision(rawValue: 2)
        )
        bridge = nil
        providers = nil

        let restored = AIProviderStore(
            defaults: defaults,
            storedKeyExists: { _ in false },
            persistenceSynchronizer: { true }
        )
        let recoveryBridge = BuiltInModelProviderBridge(providers: restored)

        XCTAssertEqual(
            recoveryBridge.handle(.requestDeactivation(deactivation)),
            .stale
        )
        XCTAssertNil(restored.activeProvider)
        XCTAssertNil(restored.activeModelID)
        XCTAssertEqual(
            restored.currentSelectionRevision,
            SelectionRevision(rawValue: 2)
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "BuiltInModelStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func clear(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }

    func testExplicitOffRevisionIsPassedToProvisioningInsteadOfResetToZero() async {
        let providers = FakeBuiltInProvider(
            revision: SelectionRevision(rawValue: 7)
        )
        let manager = FakeBuiltInModelManager(blockInstall: false)
        let store = BuiltInModelStore(pollingInterval: .milliseconds(10))
        await store.attach(manager: manager, providers: providers)
        store.setHardwareSupport(.supported)

        store.install()
        await waitUntil { !store.isBusy }

        let revision = await manager.lastInstallRevision
        XCTAssertEqual(revision, SelectionRevision(rawValue: 7))
    }

    func testAttachPublishesActualManagedStorageBytesForTheUI() async {
        let providers = FakeBuiltInProvider(revision: .zero)
        let manager = FakeBuiltInModelManager(blockInstall: false)
        let store = BuiltInModelStore(pollingInterval: .milliseconds(10))

        await store.attach(manager: manager, providers: providers)

        XCTAssertEqual(store.storageSnapshot?.installedBytes, 321)
        XCTAssertEqual(store.storageSnapshot?.stagingBytes, 45)
    }

    func testAttachCachesAvailableCapacityForRendering() async {
        let providers = FakeBuiltInProvider(revision: .zero)
        let manager = FakeBuiltInModelManager(blockInstall: false)
        let store = BuiltInModelStore(
            pollingInterval: .milliseconds(10),
            capacityReader: { _ in 987_654_321 }
        )

        await store.attach(manager: manager, providers: providers)

        XCTAssertEqual(store.availableCapacityBytes, 987_654_321)
    }

    func testCapacityCacheRefreshesAfterRefreshControlAndOperationCompletion() async {
        let providers = FakeBuiltInProvider(revision: .zero)
        let manager = FakeBuiltInModelManager(blockInstall: false)
        let capacity = CapacityReaderSequence([100, 200, 300, 400])
        let store = BuiltInModelStore(
            pollingInterval: .milliseconds(10),
            capacityReader: { try capacity.read($0) }
        )

        await store.attach(manager: manager, providers: providers)
        XCTAssertEqual(store.availableCapacityBytes, 100)

        await store.refresh()
        XCTAssertEqual(store.availableCapacityBytes, 200)

        await store.pause()
        XCTAssertEqual(store.availableCapacityBytes, 300)

        store.setHardwareSupport(.supported)
        store.install()
        await waitUntil { !store.isBusy }
        XCTAssertEqual(store.availableCapacityBytes, 400)
        XCTAssertEqual(capacity.readCount, 4)
    }

    func testLateCapacityReadFromPreviousRootCannotOverwriteRelocatedRoot() async {
        let previousRoot = URL(fileURLWithPath: "/tmp/fake-built-in-model-before-relocation")
        let relocatedRoot = URL(fileURLWithPath: "/tmp/fake-built-in-model-after-relocation")
        let providers = FakeBuiltInProvider(revision: .zero)
        let manager = FakeBuiltInModelManager(
            blockInstall: false,
            pinnedDataRoot: previousRoot
        )
        let capacity = OutOfOrderCapacityReader(
            blockedRoot: previousRoot,
            blockedValue: 111,
            immediateValue: 222
        )
        let store = BuiltInModelStore(
            pollingInterval: .milliseconds(10),
            capacityReader: { capacity.read($0) }
        )

        let attach = Task { @MainActor in
            await store.attach(manager: manager, providers: providers)
        }
        await waitUntil { capacity.blockedReadStarted }

        await manager.setPinnedDataRoot(relocatedRoot)
        let refresh = Task { @MainActor in await store.refresh() }
        await waitUntil { store.availableCapacityBytes == 222 }

        capacity.releaseBlockedRead()
        await attach.value
        await refresh.value

        XCTAssertEqual(store.snapshot?.pinnedDataRoot, relocatedRoot)
        XCTAssertEqual(store.availableCapacityBytes, 222)
    }

    func testEqualRefreshDoesNotRepublishRuntimeAvailability() async {
        let providers = FakeBuiltInProvider(revision: .zero)
        let manager = FakeBuiltInModelManager(blockInstall: false)
        let store = BuiltInModelStore(pollingInterval: .milliseconds(10))

        await store.attach(manager: manager, providers: providers)
        XCTAssertEqual(providers.publishCallCount, 1)

        await store.refresh()
        XCTAssertEqual(providers.publishCallCount, 1)
    }

    func testInstallPollingPublishesProgressAndPauseRemainsAvailable() async {
        let providers = FakeBuiltInProvider(revision: .zero)
        let manager = FakeBuiltInModelManager(blockInstall: true)
        let store = BuiltInModelStore(pollingInterval: .milliseconds(10))
        await store.attach(manager: manager, providers: providers)
        store.setHardwareSupport(.supported)

        store.install()
        await waitUntil {
            store.snapshot?.projection.candidateStatus == .downloading
        }
        XCTAssertTrue(store.isBusy)
        guard case .downloading(let progress) = store.snapshot?.state.provisioningJob else {
            return XCTFail("expected visible download progress")
        }
        XCTAssertEqual(progress.receivedBytes, 25)

        await store.pause()
        await waitUntil { !store.isBusy }

        XCTAssertEqual(store.snapshot?.projection.candidateStatus, .paused)
        let pausedDuringInstall = await manager.pauseWasCalledDuringInstall
        XCTAssertTrue(pausedDuringInstall)
    }

    func testCancelRemainsAvailableDuringInstallAndClearsCandidate() async {
        let providers = FakeBuiltInProvider(revision: .zero)
        let manager = FakeBuiltInModelManager(blockInstall: true)
        let store = BuiltInModelStore(pollingInterval: .milliseconds(10))
        await store.attach(manager: manager, providers: providers)
        store.setHardwareSupport(.supported)

        store.install()
        await waitUntil {
            store.snapshot?.projection.candidateStatus == .downloading
        }
        await store.cancel()
        await waitUntil { !store.isBusy }

        XCTAssertEqual(
            store.snapshot?.projection.candidateStatus,
            CandidateProvisioningStatus.none
        )
        XCTAssertNil(store.snapshot?.state.inventory.candidate)
        let cancelledDuringInstall = await manager.cancelWasCalledDuringInstall
        XCTAssertTrue(cancelledDuringInstall)
    }

    func testUnsupportedHardwareExposesReasonAndDoesNotStartInstall() async {
        let providers = FakeBuiltInProvider(revision: .zero)
        let manager = FakeBuiltInModelManager(blockInstall: false)
        let store = BuiltInModelStore(pollingInterval: .milliseconds(10))
        await store.attach(manager: manager, providers: providers)
        let reason = "This exact Mac is not qualified for the built-in model."
        store.setHardwareSupport(.unsupported(reason: reason))

        store.install()

        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.supportReason, reason)
        XCTAssertEqual(store.operationError, reason)
        let revision = await manager.lastInstallRevision
        XCTAssertNil(revision)
    }

    func testRetryFromRestoredRemovalFailureRoutesBackToRemoval() async {
        let providers = FakeBuiltInProvider(revision: .zero)
        let manager = FakeBuiltInModelManager(
            blockInstall: false,
            restoredRemovalFailure: true
        )
        let store = BuiltInModelStore(pollingInterval: .milliseconds(10))
        await store.attach(manager: manager, providers: providers)

        XCTAssertEqual(store.snapshot?.projection.actions, [.retry])
        store.retry()
        await waitUntil { !store.isBusy }

        let removeCallCount = await manager.removeCallCount
        let retryCallCount = await manager.retryCallCount
        XCTAssertEqual(removeCallCount, 1)
        XCTAssertEqual(retryCallCount, 0)
    }

    func testReinstallDoesNotSwitchAwayFromAnotherActiveProvider() async {
        let providers = FakeBuiltInProvider(revision: .zero)
        providers.selectOtherProvider()
        let manager = FakeBuiltInModelManager(blockInstall: false)
        let store = BuiltInModelStore(pollingInterval: .milliseconds(10))
        await store.attach(manager: manager, providers: providers)
        store.setHardwareSupport(.supported)

        store.reinstall()
        await waitUntil { !store.isBusy }

        let activationIntent = await manager.lastReinstallActivationIntent
        XCTAssertNil(activationIntent)
        XCTAssertEqual(providers.activeProvider, .ollama)
        XCTAssertEqual(providers.activeModelID, "other-model")
    }

    private func waitUntil(
        timeoutIterations: Int = 300,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for store state")
    }
}

private final class CapacityReaderSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [Int64]
    private var nextIndex = 0

    init(_ values: [Int64]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }

    func read(_ url: URL) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(nextIndex, values.count - 1)]
        nextIndex += 1
        return value
    }
}

private final class OutOfOrderCapacityReader: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blockedRoot: URL
    private let blockedValue: Int64
    private let immediateValue: Int64
    private var didStartBlockedRead = false

    init(blockedRoot: URL, blockedValue: Int64, immediateValue: Int64) {
        self.blockedRoot = blockedRoot
        self.blockedValue = blockedValue
        self.immediateValue = immediateValue
    }

    var blockedReadStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStartBlockedRead
    }

    func read(_ root: URL) -> Int64 {
        guard root == blockedRoot else { return immediateValue }
        lock.lock()
        didStartBlockedRead = true
        lock.unlock()
        gate.wait()
        return blockedValue
    }

    func releaseBlockedRead() {
        gate.signal()
    }
}

@MainActor
private final class FakeBuiltInProvider: BuiltInModelProviderControlling {
    var currentSelectionRevision: SelectionRevision
    private(set) var availableModelID: String?
    private(set) var activeProvider: AIProvider?
    private(set) var activeModelID: String?
    private(set) var publishCallCount = 0

    init(revision: SelectionRevision) {
        currentSelectionRevision = revision
    }

    func builtInProvisioningIntent(modelID: String) -> ActivationIntent? {
        ActivationIntent(
            providerID: AIProvider.zbsEyeLocal.rawValue,
            modelID: modelID,
            expectedSelectionRevision: currentSelectionRevision
        )
    }

    func publishBuiltInRuntimeAvailability(modelID: String?) -> Bool {
        publishCallCount += 1
        guard availableModelID != modelID else { return false }
        availableModelID = modelID
        return true
    }

    func commitActivation(
        _ intent: ActivationIntent,
        grantCloudConsent: Bool
    ) -> Bool {
        guard !grantCloudConsent,
              intent.expectedSelectionRevision == currentSelectionRevision,
              intent.providerID == AIProvider.zbsEyeLocal.rawValue,
              intent.modelID == availableModelID else { return false }
        activeProvider = .zbsEyeLocal
        activeModelID = intent.modelID
        currentSelectionRevision.advance()
        return true
    }

    func commitBuiltInActivation(
        _ intent: ActivationIntent
    ) -> BuiltInModelProviderEffectResult {
        commitActivation(intent, grantCloudConsent: false) ? .applied : .stale
    }

    func commitDeactivation(_ intent: DeactivationIntent) -> Bool {
        guard intent.expectedSelectionRevision == currentSelectionRevision,
              intent.providerID == activeProvider?.rawValue,
              intent.modelID == activeModelID else { return false }
        activeProvider = nil
        activeModelID = nil
        currentSelectionRevision.advance()
        return true
    }

    func commitBuiltInDeactivation(
        _ intent: DeactivationIntent
    ) -> BuiltInModelProviderEffectResult {
        commitDeactivation(intent) ? .applied : .stale
    }

    func deactivationIntent(for provider: AIProvider) -> DeactivationIntent? {
        guard activeProvider == provider, let activeModelID else { return nil }
        return DeactivationIntent(
            providerID: provider.rawValue,
            modelID: activeModelID,
            expectedSelectionRevision: currentSelectionRevision
        )
    }

    func selectOtherProvider() {
        activeProvider = .ollama
        activeModelID = "other-model"
        currentSelectionRevision.advance()
    }
}

@MainActor
private final class PersistenceAcknowledgementSequence {
    private var values: [Bool]
    private(set) var callCount = 0

    init(_ values: [Bool]) {
        self.values = values
    }

    func acknowledge() -> Bool {
        callCount += 1
        return values.isEmpty ? false : values.removeFirst()
    }
}

private actor FakeBuiltInModelManager: BuiltInModelManaging {
    private var state: BuiltInModelLifecycleState
    private var pinnedDataRoot: URL
    private let blockInstall: Bool
    private var installWaiter: CheckedContinuation<BuiltInModelManagerResult, Never>?
    private(set) var lastInstallRevision: SelectionRevision?
    private(set) var pauseWasCalledDuringInstall = false
    private(set) var cancelWasCalledDuringInstall = false
    private(set) var retryCallCount = 0
    private(set) var removeCallCount = 0
    private(set) var lastReinstallActivationIntent: ActivationIntent?

    init(
        blockInstall: Bool,
        restoredRemovalFailure: Bool = false,
        pinnedDataRoot: URL = URL(fileURLWithPath: "/tmp/fake-built-in-model")
    ) {
        self.blockInstall = blockInstall
        self.pinnedDataRoot = pinnedDataRoot
        state = restoredRemovalFailure ? Self.removalFailureState() : .initial
    }

    func setPinnedDataRoot(_ root: URL) {
        pinnedDataRoot = root
    }

    func snapshot() -> BuiltInModelManagerSnapshot { makeSnapshot() }

    func storageSnapshot() throws -> BuiltInModelStorageSnapshot {
        BuiltInModelStorageSnapshot(
            pinnedDataRoot: pinnedDataRoot,
            journalBytes: 12,
            installedBytes: 321,
            stagingBytes: 45,
            trashBytes: 0,
            activeInstallationID: nil,
            activeManifestFingerprintSHA256: nil,
            activeVerifiedBytes: 321
        )
    }

    func install(
        manifestID: String,
        activationIntent: ActivationIntent?,
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult {
        lastInstallRevision = currentSelectionRevision
        guard blockInstall else { return result() }

        let installation = Self.installation()
        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .prepareCandidate(
                installation,
                activationIntent: activationIntent
            )
        )
        _ = BuiltInModelLifecycleReducer.reduce(
            state: &state,
            event: .downloadStarted(
                ProvisioningProgress(receivedBytes: 25, expectedBytes: 100)
            )
        )
        return await withCheckedContinuation { installWaiter = $0 }
    }

    func pause() async throws -> BuiltInModelManagerSnapshot {
        pauseWasCalledDuringInstall = installWaiter != nil
        _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .pauseDownload)
        let result = result()
        installWaiter?.resume(returning: result)
        installWaiter = nil
        return result.snapshot
    }

    func cancel() async throws -> BuiltInModelManagerSnapshot {
        cancelWasCalledDuringInstall = installWaiter != nil
        _ = BuiltInModelLifecycleReducer.reduce(state: &state, event: .discardCandidate)
        let result = result()
        installWaiter?.resume(returning: result)
        installWaiter = nil
        return result.snapshot
    }

    func resume(
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult { result() }

    func retry(
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult {
        retryCallCount += 1
        return result()
    }

    func retryRuntimeLoad(
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerSnapshot {
        makeSnapshot()
    }

    func remove(
        deactivationIntent: DeactivationIntent?,
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult {
        removeCallCount += 1
        return result()
    }

    func reinstall(
        manifestID: String,
        activationIntent: ActivationIntent?,
        currentSelectionRevision: SelectionRevision
    ) async throws -> BuiltInModelManagerResult {
        lastReinstallActivationIntent = activationIntent
        return result()
    }

    private func result() -> BuiltInModelManagerResult {
        BuiltInModelManagerResult(snapshot: makeSnapshot(), effects: [])
    }

    private func makeSnapshot() -> BuiltInModelManagerSnapshot {
        BuiltInModelManagerSnapshot(
            state: state,
            projection: BuiltInModelLifecycleReducer.project(state),
            pinnedDataRoot: pinnedDataRoot,
            rootAvailable: true,
            suspendedForRelocation: false
        )
    }

    private static func installation() -> BuiltInModelInstallation {
        let manifest = BuiltInModelManifest.regular
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
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

    private static func removalFailureState() -> BuiltInModelLifecycleState {
        let installation = installation()
        return BuiltInModelLifecycleState(
            inventory: ArtifactInventory(
                lastKnownGood: installation,
                candidate: nil
            ),
            provisioningJob: .failed(
                ProvisioningFailure(
                    stage: .removal,
                    message: "runtime drain failed",
                    isRetryable: true
                )
            ),
            activationIntent: nil,
            runtimeState: .ready(installation)
        )
    }
}
