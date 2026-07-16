import GRDB
import XCTest

final class CallCoordinatorTests: XCTestCase {
    func testMicOnlyCallWorksWithoutScreenCaptureAndPersistsOneFinalJob() async throws {
        let fixture = try CallCoordinatorFixture(actual: .init(me: true, system: false))
        defer { fixture.cleanup() }

        let started = try await fixture.coordinator.start(
            request: .init(me: true, system: false),
            idempotencyKey: "start-mic"
        )
        let callID = try XCTUnwrap(started.callID)
        XCTAssertEqual(started.phase, .recording)
        XCTAssertEqual(started.me, .recording)
        XCTAssertEqual(started.system, .disabled)

        await fixture.audio.emit(frame(source: .me, epoch: 0, sequence: 0))
        let ended = try await fixture.coordinator.end(
            idempotencyKey: "end-mic",
            reason: .user
        )

        XCTAssertEqual(ended.phase, .pendingTranscription)
        let persisted = try await fixture.database.pool.read { db in
            (
                call: try CallRow.fetchOne(db, key: callID),
                chunks: try CallAudioChunkRow
                    .filter(Column("callId") == callID)
                    .fetchAll(db),
                finals: try CallTranscriptJobRow
                    .filter(
                        Column("callId") == callID
                            && Column("kind") == CallTranscriptJobKind.final.rawValue
                    )
                    .fetchAll(db)
            )
        }
        XCTAssertEqual(persisted.call?.state, .finalizing)
        XCTAssertEqual(persisted.chunks.map(\.source), [.me])
        XCTAssertEqual(persisted.finals.count, 1)
        XCTAssertTrue(persisted.finals[0].coverageFrozen)
    }

    func testZeroSourceRefusesWithoutLeavingCallAndDuplicateStartIsIdempotent() async throws {
        let unavailable = try CallCoordinatorFixture(actual: .init(me: false, system: false))
        defer { unavailable.cleanup() }

        do {
            _ = try await unavailable.coordinator.start(
                request: .init(me: true, system: false),
                idempotencyKey: "unavailable"
            )
            XCTFail("zero-source start must fail")
        } catch {
            XCTAssertEqual(error as? CallCoordinatorError, .noAvailableSource)
        }
        let emptyCount = try await unavailable.database.pool.read {
            try CallRow.fetchCount($0)
        }
        XCTAssertEqual(emptyCount, 0)

        let fixture = try CallCoordinatorFixture(actual: .init(me: true, system: true))
        defer { fixture.cleanup() }
        let first = try await fixture.coordinator.start(
            request: .init(me: true, system: true),
            idempotencyKey: "first"
        )
        let duplicate = try await fixture.coordinator.start(
            request: .init(me: true, system: true),
            idempotencyKey: "ignored-duplicate"
        )
        XCTAssertEqual(first.callID, duplicate.callID)
        let startCount = await fixture.audio.startCount()
        let countAfterDuplicate = try await fixture.database.pool.read { try CallRow.fetchCount($0) }
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(countAfterDuplicate, 1)

        _ = try await fixture.coordinator.end(idempotencyKey: "end", reason: .user)
        let idleEnd = try await fixture.coordinator.end(idempotencyKey: "end-again", reason: .user)
        XCTAssertEqual(idleEnd.phase, .pendingTranscription)
        let countAfterEnd = try await fixture.database.pool.read { try CallRow.fetchCount($0) }
        XCTAssertEqual(countAfterEnd, 1)
    }

    func testBookmarkThenImmediateEndKeepsCheckpointAndCreatesExactlyOneFinalJob() async throws {
        let fixture = try CallCoordinatorFixture(actual: .init(me: true, system: true))
        defer { fixture.cleanup() }
        let started = try await fixture.coordinator.start(
            request: .init(me: true, system: true),
            idempotencyKey: "start"
        )
        let callID = try XCTUnwrap(started.callID)

        await fixture.audio.emit(frame(source: .me, epoch: 0, sequence: 0))
        await fixture.audio.emit(frame(source: .system, epoch: 0, sequence: 0))
        let coordinator = fixture.coordinator
        let bookmarkTask = Task {
            try await coordinator.bookmark(idempotencyKey: "bookmark-1")
        }
        await Task.yield()
        let endTask = Task {
            try await coordinator.end(idempotencyKey: "end", reason: .user)
        }
        let bookmark = try await bookmarkTask.value
        XCTAssertEqual(bookmark.state, .pending)
        let ended = try await endTask.value
        XCTAssertEqual(ended.phase, .pendingTranscription)

        let jobs = try await fixture.database.pool.read { db in
            try CallTranscriptJobRow
                .filter(Column("callId") == callID)
                .order(Column("priority"), Column("id"))
                .fetchAll(db)
        }
        XCTAssertEqual(jobs.filter { $0.kind == .checkpoint }.count, 1)
        XCTAssertEqual(jobs.filter { $0.kind == .final }.count, 1)
        XCTAssertTrue(jobs.allSatisfy(\.coverageFrozen))
        let stopCount = await fixture.audio.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testSourceRestartAndSystemStopsPreserveCallIdentityAndHonestTerminalReason() async throws {
        for reason in [CallStopReason.privacy, .maintenance, .lowDisk] {
            let fixture = try CallCoordinatorFixture(actual: .init(me: false, system: true))
            defer { fixture.cleanup() }
            let started = try await fixture.coordinator.start(
                request: .init(me: false, system: true),
                idempotencyKey: "start-\(reason.rawValue)"
            )
            let callID = try XCTUnwrap(started.callID)

            await fixture.audio.emit(frame(source: .system, epoch: 0, sequence: 0))
            await fixture.audio.recordGap(
                AudioIngressGap(
                    source: .system,
                    epoch: 0,
                    firstIngressSequence: 1,
                    lastIngressSequence: 1,
                    reason: .sourceRestart
                )
            )
            await fixture.audio.emit(frame(source: .system, epoch: 1, sequence: 2))
            let duplicate = try await fixture.coordinator.start(
                request: .init(me: false, system: true),
                idempotencyKey: "meeting-edge"
            )
            XCTAssertEqual(duplicate.callID, callID)

            _ = try await fixture.coordinator.end(
                idempotencyKey: "stop-\(reason.rawValue)",
                reason: reason
            )
            let persisted = try await fixture.database.pool.read { db in
                (
                    call: try CallRow.fetchOne(db, key: callID),
                    spans: try CallSourceSpanRow
                        .filter(Column("callId") == callID)
                        .order(Column("epoch"))
                        .fetchAll(db)
                )
            }
            XCTAssertEqual(persisted.call?.degradationReason, reason.persistenceCode)
            XCTAssertEqual(persisted.spans.map(\.epoch), [0, 1])
        }

        let gapOnly = try CallCoordinatorFixture(actual: .init(me: false, system: true))
        defer { gapOnly.cleanup() }
        let started = try await gapOnly.coordinator.start(
            request: .init(me: false, system: true),
            idempotencyKey: "start-gap-only"
        )
        let callID = try XCTUnwrap(started.callID)
        await gapOnly.audio.recordGap(
            AudioIngressGap(
                source: .system,
                epoch: 0,
                firstIngressSequence: 0,
                lastIngressSequence: 0,
                reason: .consumerOverflow
            )
        )
        _ = try await gapOnly.coordinator.end(
            idempotencyKey: "stop-gap-only",
            reason: .user
        )
        let gapCall = try await gapOnly.database.pool.read {
            try CallRow.fetchOne($0, key: callID)
        }
        XCTAssertEqual(gapCall?.degradationReason, "source_gap")
    }

    private func frame(
        source: CallAudioSource,
        epoch: Int,
        sequence: Int64
    ) -> AudioFrame {
        AudioFrame(
            samples: Array(repeating: 0.25, count: 480),
            rms: 0.25,
            timing: AudioFrameTiming(
                source: source,
                epoch: epoch,
                ingressSequence: sequence,
                normalizedHostTimeNs: 1_000_000_000 + sequence * 10_000_000,
                sourceSampleTime: sequence * 480,
                captureSampleRate: 48_000,
                frameCount: 480,
                capturedAt: Date(timeIntervalSince1970: 1 + Double(sequence) / 100),
                provenance: source == .me ? .microphone : .screenCaptureKit
            )
        )
    }
}

private final class CallCoordinatorFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let audio: FakeCallAudio
    let coordinator: CallCoordinator

    init(actual: CallSourceSelection) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        audio = FakeCallAudio(actual: actual)
        coordinator = CallCoordinator(
            repository: CallRepository(database: database),
            mediaRoot: root.appendingPathComponent("media", isDirectory: true),
            audio: audio.control(),
            now: { Date(timeIntervalSince1970: 10) },
            barrierTimeout: .milliseconds(50)
        )
    }

    func cleanup() {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor FakeCallAudio {
    private let actual: CallSourceSelection
    private var sink: CallAudioFrameSink?
    private var targets = AudioIngressTargets(me: nil, system: nil)
    private var gaps: [AudioIngressGap] = []
    private var starts = 0
    private var stops = 0

    init(actual: CallSourceSelection) {
        self.actual = actual
    }

    nonisolated func control() -> CallAudioControl {
        CallAudioControl(
            installSink: { sink in await self.setSink(sink) },
            start: { _ in await self.didStart() },
            acceptedTargets: { await self.currentTargets() },
            drainGaps: { await self.takeGaps() },
            stop: { await self.didStop() }
        )
    }

    func emit(_ frame: AudioFrame) async {
        let owned = await sink?(frame) ?? false
        guard owned else { return }
        switch frame.timing.source {
        case .me: targets = AudioIngressTargets(me: frame.timing.ingressSequence, system: targets.system)
        case .system: targets = AudioIngressTargets(me: targets.me, system: frame.timing.ingressSequence)
        }
    }

    func recordGap(_ gap: AudioIngressGap) { gaps.append(gap) }
    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }

    private func setSink(_ sink: CallAudioFrameSink?) { self.sink = sink }
    private func didStart() -> CallSourceSelection { starts += 1; return actual }
    private func currentTargets() -> AudioIngressTargets { targets }
    private func takeGaps() -> [AudioIngressGap] { defer { gaps.removeAll() }; return gaps }
    private func didStop() { stops += 1 }
}
