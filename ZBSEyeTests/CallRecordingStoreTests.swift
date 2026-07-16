import GRDB
import XCTest

@MainActor
final class CallRecordingStoreTests: XCTestCase {
    func testPrivacyEndJoinsAnInFlightStartAndLeavesNoActiveCall() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }

        store.start()
        XCTAssertEqual(store.snapshot.phase, .starting)
        await store.endAndWait(reason: .privacy)

        XCTAssertEqual(store.snapshot.phase, .pendingTranscription)
        let calls = try await fixture.database.pool.read { db in
            try CallRow.fetchAll(db)
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].degradationReason, CallStopReason.privacy.persistenceCode)
        XCTAssertNotNil(calls[0].endTs)
    }

    func testStartRechecksAdmissionInsideScheduledTask() async throws {
        let fixture = try CallRecordingStoreFixture()
        defer { fixture.cleanup() }
        let store = CallRecordingStore()
        store.attach(fixture.coordinator)
        store.requestedSources = { CallSourceSelection(me: true, system: false) }
        let admission = StoreAdmissionFlag()
        store.admissionAllowed = { admission.value }

        store.start()
        admission.value = false
        await Task.yield()
        await Task.yield()

        let count = try await fixture.database.pool.read { try CallRow.fetchCount($0) }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(store.snapshot.phase, .idle)
    }
}

@MainActor
private final class StoreAdmissionFlag {
    var value = true
}

private final class CallRecordingStoreFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let coordinator: CallCoordinator
    private let audio = StoreCallAudio()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        coordinator = CallCoordinator(
            repository: CallRepository(database: database),
            mediaRoot: root.appendingPathComponent("media", isDirectory: true),
            audio: audio.control(),
            now: { Date(timeIntervalSince1970: 1) }
        )
    }

    func cleanup() {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor StoreCallAudio {
    private var sink: CallAudioFrameSink?

    nonisolated func control() -> CallAudioControl {
        CallAudioControl(
            installSink: { [weak self] sink in await self?.setSink(sink) },
            start: { requested in requested },
            acceptedTargets: { AudioIngressTargets(me: nil, system: nil) },
            drainGaps: { [] },
            stop: {}
        )
    }

    private func setSink(_ sink: CallAudioFrameSink?) {
        self.sink = sink
    }
}
