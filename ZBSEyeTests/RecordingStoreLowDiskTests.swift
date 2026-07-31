import Foundation
import XCTest

final class RecordingStoreLowDiskTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RecordingStoreLowDiskTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testColdLaunchLowDiskBlocksAutostartButPreservesIntent() async {
        defaults.set(true, forKey: "zbseye.recording.enabled")
        let store = makeStore()
        let capture = CaptureCoordinator()
        store.coordinator = capture
        store.setLowDisk(true)

        store.startIfWanted()

        XCTAssertFalse(store.isCapturing)
        XCTAssertTrue(store.wantsRecording)
        XCTAssertEqual(capture.startCount, 0)
    }

    @MainActor
    func testLowDiskPauseAwaitsScreenAndAudioDrain() async {
        defaults.set(true, forKey: "zbseye.recording.enabled")
        let store = makeStore()
        let capture = CaptureCoordinator()
        let audio = AudioCoordinator()
        store.coordinator = capture
        store.audio = audio
        store.startIfWanted()
        XCTAssertTrue(store.isCapturing)

        let drain = await store.pauseForLowDiskAndDrain()

        XCTAssertTrue(store.lowDiskPaused)
        XCTAssertFalse(store.isCapturing)
        XCTAssertTrue(store.wantsRecording)
        XCTAssertEqual(capture.drainCount, 1)
        XCTAssertEqual(audio.drainCount, 1)
        XCTAssertEqual(drain.capture.activeCycles, 0)
        XCTAssertEqual(drain.audio.activeLegs, 0)
        XCTAssertTrue(drain.audio.systemCaptureOutcome.isConfirmedStopped)
    }

    @MainActor
    func testManualStopDuringLowDiskPreventsRecoveryResume() async {
        defaults.set(true, forKey: "zbseye.recording.enabled")
        let store = makeStore()
        let capture = CaptureCoordinator()
        store.coordinator = capture
        store.startIfWanted()
        _ = await store.pauseForLowDiskAndDrain()

        store.toggle()
        store.resumeAfterLowDisk()

        XCTAssertFalse(store.wantsRecording)
        XCTAssertFalse(store.isCapturing)
        XCTAssertEqual(capture.startCount, 1)
    }

    @MainActor
    func testLowDiskAndMaintenanceBlockersCompose() async {
        defaults.set(true, forKey: "zbseye.recording.enabled")
        let store = makeStore()
        let capture = CaptureCoordinator()
        store.coordinator = capture
        store.startIfWanted()
        _ = await store.pauseForLowDiskAndDrain()
        let relocation = await store.pauseForMaintenanceAndDrain(owner: .relocation)

        store.resumeAfterLowDisk()
        XCTAssertFalse(store.isCapturing)

        store.resumeAfterMaintenance(relocation.lease)
        XCTAssertTrue(store.isCapturing)
        XCTAssertEqual(capture.startCount, 2)
    }

    @MainActor
    func testAudioStartKeepsMicrophoneAndSystemAudioIndependent() {
        defaults.set(true, forKey: "zbseye.recording.enabled")
        let store = makeStore()
        store.coordinator = CaptureCoordinator()
        let audio = AudioCoordinator()
        store.audio = audio
        store.micEnabled = { true }
        store.systemEnabled = { false }

        store.startIfWanted()

        XCTAssertEqual(audio.lastMicEnabled, true)
        XCTAssertEqual(audio.lastSystemEnabled, false)
    }

    @MainActor
    func testManualStopWhileMaintenanceLeaseIsHeldDisarmsFinalResume() async {
        defaults.set(true, forKey: "zbseye.recording.enabled")
        let store = makeStore()
        let capture = CaptureCoordinator()
        store.coordinator = capture
        store.startIfWanted()
        let repair = await store.pauseForMaintenanceAndDrain(owner: .repair)

        store.toggle()
        store.resumeAfterMaintenance(repair.lease)

        XCTAssertFalse(store.wantsRecording)
        XCTAssertFalse(store.isCapturing)
        XCTAssertEqual(capture.startCount, 1)
    }

    @MainActor
    func testManualStopDuringScreenRepairWinsBeforeLeaseRelease() {
        defaults.set(true, forKey: "zbseye.recording.enabled")
        let store = makeStore()
        let capture = CaptureCoordinator()
        let audio = AudioCoordinator()
        store.coordinator = capture
        store.audio = audio
        store.startIfWanted()
        let lease = store.acquireMaintenanceLease(.repair)

        store.toggle()
        store.completeCaptureRepair(
            lease,
            screenWasDrained: true,
            drainSucceeded: true
        )

        XCTAssertFalse(store.wantsRecording)
        XCTAssertFalse(store.isCapturing)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(audio.stopCount, 1)
    }

    @MainActor
    func testLatestStartIntentDuringScreenRepairRestartsExactlyOnce() {
        defaults.set(true, forKey: "zbseye.recording.enabled")
        let store = makeStore()
        let capture = CaptureCoordinator()
        store.coordinator = capture
        store.startIfWanted()
        let lease = store.acquireMaintenanceLease(.repair)

        store.toggle()
        store.toggle()
        store.completeCaptureRepair(
            lease,
            screenWasDrained: true,
            drainSucceeded: true
        )

        XCTAssertTrue(store.wantsRecording)
        XCTAssertTrue(store.isCapturing)
        XCTAssertEqual(capture.startCount, 2)
    }

    @MainActor
    private func makeStore() -> RecordingStore {
        let store = RecordingStore(defaults: defaults)
        store.canCapture = { true }
        store.micEnabled = { true }
        store.systemEnabled = { true }
        return store
    }
}

// The unhosted test target shares RecordingStore without loading capture frameworks.
// These deterministic doubles prove its admission and drain ownership only.
@MainActor
final class CaptureCoordinator {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var drainCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func stopAndDrain() async -> CaptureDrainAcknowledgement {
        drainCount += 1
        return CaptureDrainAcknowledgement(
            hadActiveCapture: true,
            hadInFlightCycle: true,
            activeCycles: 0
        )
    }
}

struct CaptureDrainAcknowledgement: Sendable, Equatable {
    let hadActiveCapture: Bool
    let hadInFlightCycle: Bool
    let activeCycles: Int
}

@MainActor
final class AudioCoordinator {
    private(set) var drainCount = 0
    private(set) var stopCount = 0
    private(set) var lastMicEnabled: Bool?
    private(set) var lastSystemEnabled: Bool?

    func start(mic: Bool, system: Bool) {
        lastMicEnabled = mic
        lastSystemEnabled = system
    }
    func stop() { stopCount += 1 }
    func reconfigure(mic: Bool, system: Bool) {
        lastMicEnabled = mic
        lastSystemEnabled = system
    }
    func stopAndDrain(
        waitForTranscription: Bool = true,
        systemCaptureTimeout: Duration? = nil
    ) async -> AudioDrainAcknowledgement {
        drainCount += 1
        return AudioDrainAcknowledgement(
            hadActiveAudio: true,
            activeLegs: 0,
            transcriptionDrained: waitForTranscription,
            systemCaptureOutcome: .stopped
        )
    }
}

struct AudioDrainAcknowledgement: Sendable, Equatable {
    let hadActiveAudio: Bool
    let activeLegs: Int
    let transcriptionDrained: Bool
    let systemCaptureOutcome: SystemAudioCaptureTeardownOutcome
}

enum PrivacyPauseLog {
    static func record(startMs: Int64, endMs: Int64) {}
    static func closeLast(atMs: Int64) {}
}
