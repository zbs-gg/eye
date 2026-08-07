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
        let forwardedExactPreparedLease = await fixture.audio.forwardedExactPreparedLease()
        XCTAssertTrue(
            forwardedExactPreparedLease,
            "CallCoordinator must start the sink using the exact lease returned by its installation"
        )

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

    func testSealedBoundaryDoesNotWaitForPostCloseEngineWatermarksOrCreateFalseGap() async throws {
        let fixture = try CallCoordinatorFixture(actual: .init(me: true, system: false))
        defer { fixture.cleanup() }

        let started = try await fixture.coordinator.start(
            request: .init(me: true, system: false),
            idempotencyKey: "start-sealed-boundary"
        )
        let callID = try XCTUnwrap(started.callID)
        await fixture.audio.emit(frame(source: .me, epoch: 0, sequence: 0))
        await fixture.audio.sealFrameBoundary()
        await fixture.audio.advanceAcceptedTargetsWithoutRouting(
            AudioIngressTargets(me: 1_000, system: nil)
        )

        let ended = try await fixture.coordinator.end(
            idempotencyKey: "end-sealed-boundary",
            reason: .user
        )
        XCTAssertEqual(ended.phase, .pendingTranscription)

        let persisted = try await fixture.database.pool.read { db in
            (
                call: try CallRow.fetchOne(db, key: callID),
                gaps: try CallSourceGapRow
                    .filter(Column("callId") == callID)
                    .fetchAll(db)
            )
        }
        XCTAssertNil(persisted.call?.degradationReason)
        XCTAssertTrue(persisted.gaps.isEmpty)
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
                        .fetchAll(db),
                    gaps: try CallSourceGapRow
                        .filter(Column("callId") == callID)
                        .fetchAll(db)
                )
            }
            XCTAssertEqual(persisted.call?.degradationReason, reason.persistenceCode)
            XCTAssertEqual(persisted.spans.map(\.epoch), [0, 1])
            XCTAssertEqual(persisted.gaps.map(\.reason), [AudioIngressGapReason.sourceRestart.rawValue])
            XCTAssertTrue(persisted.gaps.allSatisfy { $0.endMs > $0.startMs })
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

        let restarted = try CallCoordinatorFixture(actual: .init(me: false, system: true))
        defer { restarted.cleanup() }
        let restartStart = try await restarted.coordinator.start(
            request: .init(me: false, system: true),
            idempotencyKey: "start-restart-user"
        )
        let restartCallID = try XCTUnwrap(restartStart.callID)
        await restarted.audio.emit(frame(source: .system, epoch: 0, sequence: 0))
        await restarted.audio.emit(frame(source: .system, epoch: 1, sequence: 2))
        _ = try await restarted.coordinator.end(
            idempotencyKey: "stop-restart-user",
            reason: .user
        )
        let restartEvidence = try await restarted.database.pool.read { db in
            (
                call: try XCTUnwrap(CallRow.fetchOne(db, key: restartCallID)),
                gaps: try CallSourceGapRow.fetchAll(
                    db,
                    sql: "SELECT * FROM call_source_gaps WHERE callId = ?",
                    arguments: [restartCallID]
                )
            )
        }
        XCTAssertEqual(restartEvidence.call.degradationReason, "source_gap")
        XCTAssertEqual(restartEvidence.gaps.map(\.reason), [AudioIngressGapReason.sourceRestart.rawValue])
    }

    func testStartBoundaryRejectsBufferedFrameAndPreCallGap() async throws {
        let fixture = try CallCoordinatorFixture(actual: .init(me: true, system: false))
        defer { fixture.cleanup() }
        await fixture.audio.seed(
            targets: AudioIngressTargets(me: 5, system: nil),
            gaps: [
                AudioIngressGap(
                    source: .me,
                    epoch: 0,
                    firstIngressSequence: 4,
                    lastIngressSequence: 5,
                    reason: .consumerOverflow,
                    startMs: 9_000,
                    endMs: 9_500
                ),
            ]
        )
        let started = try await fixture.coordinator.start(
            request: .init(me: true, system: false),
            idempotencyKey: "boundary-start"
        )
        let callID = try XCTUnwrap(started.callID)

        await fixture.audio.emit(frame(source: .me, epoch: 0, sequence: 5, capturedAt: 9.99))
        await fixture.audio.emit(frame(source: .me, epoch: 0, sequence: 6, capturedAt: 9.98))
        await fixture.audio.emit(frame(source: .me, epoch: 0, sequence: 7, capturedAt: 10.01))
        _ = try await fixture.coordinator.end(idempotencyKey: "boundary-end", reason: .user)

        let persisted = try await fixture.database.pool.read { db in
            (
                call: try XCTUnwrap(CallRow.fetchOne(db, key: callID)),
                samples: try Int64.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(endSample - startSample), 0) FROM call_audio_chunks WHERE callId = ?",
                    arguments: [callID]
                ) ?? -1,
                earliestChunk: try Int64.fetchOne(
                    db,
                    sql: "SELECT MIN(startMs) FROM call_audio_chunks WHERE callId = ?",
                    arguments: [callID]
                ),
                gaps: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_source_gaps WHERE callId = ?",
                    arguments: [callID]
                ) ?? -1
            )
        }
        XCTAssertEqual(persisted.samples, 160)
        XCTAssertGreaterThanOrEqual(persisted.earliestChunk ?? -1, persisted.call.startTs)
        XCTAssertEqual(persisted.gaps, 0)
        XCTAssertNil(persisted.call.degradationReason)
    }

    func testEndGraceKeepsWritingIntoSameCallUntilDirectAutomaticEnd() async throws {
        let fixture = try CallCoordinatorFixture(actual: .init(me: false, system: true))
        defer { fixture.cleanup() }
        let started = try await fixture.coordinator.start(
            request: .init(me: false, system: true),
            idempotencyKey: "grace-start"
        )
        let callID = try XCTUnwrap(started.callID)
        await fixture.audio.emit(frame(source: .system, epoch: 0, sequence: 0))

        // The lifecycle grace is deliberately outside CallCoordinator. Audio keeps flowing into
        // the canonical spool until the timeout (or End & save) performs one direct end.
        let duringGrace = await fixture.coordinator.snapshot()
        XCTAssertEqual(duringGrace.phase, .recording)
        XCTAssertEqual(duringGrace.callID, callID)
        await fixture.audio.emit(frame(source: .system, epoch: 0, sequence: 1))
        let ended = try await fixture.coordinator.end(
            idempotencyKey: "grace-end",
            reason: .automatic
        )
        XCTAssertEqual(ended.phase, .pendingTranscription)
        XCTAssertEqual(ended.stopReason, .automatic)

        let persisted = try await fixture.database.pool.read { db in
            (
                calls: try CallRow.fetchCount(db),
                samples: try Int64.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(endSample - startSample), 0) FROM call_audio_chunks WHERE callId = ?",
                    arguments: [callID]
                ) ?? -1
            )
        }
        XCTAssertEqual(persisted.calls, 1)
        XCTAssertEqual(persisted.samples, 320)
        let stopCount = await fixture.audio.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testRepeatedAutomaticEndCreatesOneFinalJobAndStopsAudioOnce() async throws {
        let fixture = try CallCoordinatorFixture(actual: .init(me: false, system: true))
        defer { fixture.cleanup() }
        let started = try await fixture.coordinator.start(
            request: .init(me: false, system: true),
            idempotencyKey: "automatic-once-start"
        )
        let callID = try XCTUnwrap(started.callID)
        await fixture.audio.emit(frame(source: .system, epoch: 0, sequence: 0))

        let committed = try await fixture.coordinator.end(
            idempotencyKey: "automatic-once-end",
            reason: .automatic
        )
        let duplicate = try await fixture.coordinator.end(
            idempotencyKey: "automatic-duplicate-end",
            reason: .automatic
        )

        XCTAssertEqual(committed.phase, .pendingTranscription)
        XCTAssertEqual(committed.callID, callID)
        XCTAssertEqual(committed.stopReason, .automatic)
        XCTAssertEqual(duplicate, committed)
        let finalJobs = try await fixture.database.pool.read { db in
            try CallTranscriptJobRow
                .filter(
                    Column("callId") == callID
                        && Column("kind") == CallTranscriptJobKind.final.rawValue
                )
                .fetchCount(db)
        }
        XCTAssertEqual(finalJobs, 1)
        let stopCount = await fixture.audio.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testRejectAutomaticStopsWithoutCreatingTranscriptWorkOrAutomation() async throws {
        let fixture = try CallCoordinatorFixture(actual: .init(me: true, system: true))
        defer { fixture.cleanup() }
        let started = try await fixture.coordinator.start(
            request: .init(me: true, system: true),
            idempotencyKey: "automatic-start"
        )
        let callID = try XCTUnwrap(started.callID)
        await fixture.audio.emit(frame(source: .me, epoch: 0, sequence: 0))
        await fixture.audio.emit(frame(source: .system, epoch: 0, sequence: 0))

        let rejected = try await fixture.coordinator.rejectAutomatic()
        XCTAssertEqual(rejected, .idle)

        let persisted = try await fixture.database.pool.read { db in
            (
                call: try CallRow.fetchOne(db, key: callID),
                jobs: try CallTranscriptJobRow
                    .filter(Column("callId") == callID)
                    .fetchCount(db),
                events: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_automation_outbox WHERE callId = ?",
                    arguments: [callID]
                ) ?? -1
            )
        }
        XCTAssertEqual(persisted.call?.state, .interrupted)
        XCTAssertEqual(persisted.call?.degradationReason, "automatic_rejected")
        XCTAssertEqual(persisted.jobs, 0)
        XCTAssertEqual(persisted.events, 0)
        let stopCount = await fixture.audio.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    private func frame(
        source: CallAudioSource,
        epoch: Int,
        sequence: Int64,
        capturedAt: Double? = nil
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
                capturedAt: Date(
                    timeIntervalSince1970: capturedAt ?? (10 + Double(sequence) / 100)
                ),
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
    private var frameAdmission = CallAudioFrameAdmissionLatch()
    private var sealedBoundary: CallAudioFrameBoundary?
    private var installedLease: CallAudioFrameAdmissionLease?
    private var startedLease: CallAudioFrameAdmissionLease?
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
            start: { _, sinkLease, _ in await self.didStart(sinkLease: sinkLease) },
            acceptedTargets: { await self.currentTargets() },
            drainGaps: { await self.takeGaps() },
            stop: { await self.didStop() }
        )
    }

    func emit(_ frame: AudioFrame) async {
        switch frame.timing.source {
        case .me: targets = AudioIngressTargets(me: frame.timing.ingressSequence, system: targets.system)
        case .system: targets = AudioIngressTargets(me: targets.me, system: frame.timing.ingressSequence)
        }
        switch frameAdmission.route(hasCallSink: sink != nil) {
        case .background:
            return
        case .explicitCall:
            _ = await sink?(frame)
        case .dropAtBoundary:
            guard sealedBoundary?.contains(
                source: frame.timing.source,
                ingressSequence: frame.timing.ingressSequence
            ) == true else { return }
            _ = await sink?(frame)
        }
    }

    func recordGap(_ gap: AudioIngressGap) { gaps.append(gap) }
    func seed(targets: AudioIngressTargets, gaps: [AudioIngressGap]) {
        self.targets = targets
        self.gaps = gaps
    }
    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
    func sealFrameBoundary() {
        if sealedBoundary == nil {
            sealedBoundary = CallAudioFrameBoundary(targets: targets)
        }
        frameAdmission.close()
    }
    func advanceAcceptedTargetsWithoutRouting(_ advanced: AudioIngressTargets) {
        targets = advanced
    }
    func forwardedExactPreparedLease() -> Bool {
        installedLease != nil && installedLease == startedLease
    }

    private func setSink(_ sink: CallAudioFrameSink?) -> CallAudioFrameAdmissionLease? {
        self.sink = sink
        sealedBoundary = nil
        let lease = frameAdmission.installSink(present: sink != nil)
        if lease != nil { installedLease = lease }
        return lease
    }
    private func didStart(
        sinkLease: CallAudioFrameAdmissionLease
    ) -> CallSourceSelection {
        starts += 1
        startedLease = sinkLease
        guard frameAdmission.admit(sinkLease) else { return .none }
        return actual
    }
    private func currentTargets() -> AudioIngressTargets {
        CallAudioFinalizationTargetPolicy.targets(
            hasCallSink: sink != nil,
            sealedBoundary: sealedBoundary,
            liveTargets: targets
        )
    }
    private func takeGaps() -> [AudioIngressGap] { defer { gaps.removeAll() }; return gaps }
    private func didStop() { stops += 1 }
}
