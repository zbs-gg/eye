import Foundation
import XCTest

@MainActor
final class KeepMediaPolicyCoordinatorTests: XCTestCase {
    func testForeverRevokesTheFinitePermitAndPersistsClosedPolicy() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let settings = harness.makeFiniteSettings()
        let admission = AutomaticRetentionAdmission(record: settings.automaticRetentionRecord)
        XCTAssertNotNil(admission.currentPermit())
        let coordinator = KeepMediaPolicyCoordinator(refreshStorage: { _, _ in })

        let result = await coordinator.change(
            .forever,
            storageSettings: settings,
            recording: harness.recording,
            storage: harness.storage,
            database: harness.database,
            admission: admission
        )

        XCTAssertEqual(result, .applied)
        XCTAssertEqual(settings.keepMediaPolicy, .forever)
        XCTAssertEqual(settings.automaticRetentionRecord.phase, .closed)
        XCTAssertFalse(settings.automaticDeletionAdmitted)
        XCTAssertNil(admission.currentPermit())
    }

    func testOverlappingSelectionCannotOverrideTheChangeAlreadyInProgress() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let settings = harness.makeFiniteSettings()
        let admission = AutomaticRetentionAdmission(record: settings.automaticRetentionRecord)
        let gate = KeepMediaInventoryGate()
        let coordinator = KeepMediaPolicyCoordinator(
            resolveInventory: { _, _ in await gate.resolve() },
            refreshStorage: { _, _ in }
        )

        let first = Task { @MainActor in
            await coordinator.change(
                .tenGB,
                storageSettings: settings,
                recording: harness.recording,
                storage: harness.storage,
                database: harness.database,
                admission: admission
            )
        }
        await gate.waitUntilStarted()
        let overlapping = await coordinator.change(
            .forever,
            storageSettings: settings,
            recording: harness.recording,
            storage: harness.storage,
            database: harness.database,
            admission: admission
        )
        await gate.release()
        let firstResult = await first.value

        guard case let .unavailable(message) = overlapping else {
            return XCTFail("Expected the overlapping selection to be rejected")
        }
        XCTAssertTrue(message.contains("still finishing"))
        XCTAssertEqual(firstResult, .applied)
        XCTAssertEqual(settings.keepMediaPolicy, .tenGB)
        XCTAssertTrue(settings.automaticDeletionAdmitted)
    }
}

private actor KeepMediaInventoryGate {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func resolve() async -> KeepMediaInventoryEvidence {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        return .reconciled(capturedMediaBytes: 0)
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
private final class Harness {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let storage: StorageManager
    let database: ZBSEyeDatabase
    let recording: RecordingStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ZBSEyeKeepMediaCoordinatorTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "ZBSEyeKeepMediaCoordinatorTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        storage = try StorageManager(mediaDirectory: root.appendingPathComponent("media"))
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("test.sqlite").path)
        recording = RecordingStore(defaults: defaults)
    }

    func makeFiniteSettings() -> StorageSettingsStore {
        let settings = StorageSettingsStore(defaults: defaults)
        let resolution = settings.initializeKeepMediaPolicy(inventory: .positivelyEmpty)
        XCTAssertEqual(resolution.policy, .fiveGB)
        XCTAssertTrue(settings.automaticDeletionAdmitted)
        return settings
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
