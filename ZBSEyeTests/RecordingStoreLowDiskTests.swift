import Foundation
import XCTest

@MainActor
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

    func testLowDiskAndMaintenanceBlockersCompose() async {
        defaults.set(true, forKey: "zbseye.recording.enabled")
        let store = makeStore()
        let capture = CaptureCoordinator()
        store.coordinator = capture
        store.startIfWanted()
        _ = await store.pauseForLowDiskAndDrain()
        _ = await store.pauseForMaintenanceAndDrain()

        store.resumeAfterLowDisk()
        XCTAssertFalse(store.isCapturing)

        store.resumeAfterMaintenance()
        XCTAssertTrue(store.isCapturing)
        XCTAssertEqual(capture.startCount, 2)
    }

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
    private(set) var drainCount = 0

    func start() { startCount += 1 }
    func stop() {}
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

    func start(mic: Bool, system: Bool) {}
    func stop() {}
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
