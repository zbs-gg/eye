import GRDB
import XCTest

final class SpeakerDiarizationWorkerTests: XCTestCase {
    func testCombinedEvidenceBarrierResumesOnlyWorkersItSuspended() async {
        let recorder = EvidenceBarrierRecorder(ownership: [false, true])
        let barrier = CallEvidenceWorkerBarrier(
            workers: [0, 1].map { index in
                .init(
                    suspend: { await recorder.suspend(index: index) },
                    resume: { await recorder.resume(index: index) }
                )
            }
        )

        let ownsResume = await barrier.suspend()
        XCTAssertTrue(ownsResume)
        await barrier.resume()

        let resumed = await recorder.resumedWorkers()
        XCTAssertEqual(resumed, [1])
    }

    func testMissingModelLeavesFinalTranscriptAnonymousAndDoesNotLaunchHelper() async throws {
        let fixture = try SpeakerDiarizationWorkerFixture()
        let callID = try await fixture.makeReadyCall()
        let worker = fixture.makeWorker(modelReady: false) { _, _, _ in
            XCTFail("helper must not launch when the optional model is absent")
            throw SpeakerDiarizationWorkerError.helperFailed
        }

        let outcome = await worker.runOne(nowMs: 5_000)

        XCTAssertEqual(outcome, .modelUnavailable)
        let preferred = try await fixture.preferredSpeakerRevisionID(callID: callID)
        XCTAssertNil(preferred)
    }

    func testFinalTranscriptRunsHelperAlignsAnonymousClustersAndPromotesRevision() async throws {
        let fixture = try SpeakerDiarizationWorkerFixture()
        let callID = try await fixture.makeReadyCall()
        let recorder = DiarizationManifestRecorder()
        let worker = fixture.makeWorker(modelReady: true) { manifest, relativePath, _ in
            await recorder.record(manifest: manifest, relativePath: relativePath)
            return DiarizationHelperResult(
                formatVersion: 1,
                jobID: manifest.jobID,
                callID: manifest.callID,
                callGeneration: manifest.callGeneration,
                packageVersion: "0.15.5",
                modelRevision: SpeakerDiarizationModelManifest.fluidAudio0155.modelRevision,
                segments: [
                    .init(
                        source: .system,
                        clusterKey: "system:S1",
                        startSeconds: 0,
                        endSeconds: 0.8,
                        quality: 0.9
                    ),
                    .init(
                        source: .system,
                        clusterKey: "system:S2",
                        startSeconds: 0.8,
                        endSeconds: 1,
                        quality: 0.8
                    ),
                ]
            )
        }

        let outcome = await worker.runOne(nowMs: 5_000)

        guard case let .completed(completedCallID, revisionID) = outcome else {
            return XCTFail("expected completed, got \(outcome)")
        }
        XCTAssertEqual(completedCallID, callID)
        let preferred = try await fixture.preferredSpeakerRevisionID(callID: callID)
        XCTAssertEqual(preferred, revisionID)
        let captured = await recorder.snapshot()
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].relativePath.hasSuffix("/manifest.json"))
        XCTAssertEqual(captured[0].manifest.audioRanges.map(\.relativePath), ["media/calls/1/system/0000.pcm"])

        let projection = try await fixture.speakerProjection(revisionID: revisionID)
        XCTAssertEqual(projection.revision.state, .ready)
        XCTAssertEqual(projection.revision.engine, "FluidAudio")
        XCTAssertEqual(projection.clusters.map(\.displayName), [nil])
        XCTAssertEqual(projection.clusters.map(\.namingProvenance), [.anonymous])
        XCTAssertEqual(projection.clusters.map(\.clusterKey), ["system:S1"])
        XCTAssertEqual(projection.intervals.map(\.source), [.system])
        XCTAssertEqual(projection.intervals.map(\.startMs), [1_000])
        XCTAssertEqual(projection.intervals.map(\.endMs), [1_600])
    }

    func testForeignOrStaleHelperResultCreatesNoSpeakerRevision() async throws {
        let fixture = try SpeakerDiarizationWorkerFixture()
        let callID = try await fixture.makeReadyCall()
        let worker = fixture.makeWorker(modelReady: true) { manifest, _, _ in
            DiarizationHelperResult(
                formatVersion: 1,
                jobID: UUID().uuidString.lowercased(),
                callID: manifest.callID,
                callGeneration: manifest.callGeneration,
                packageVersion: "0.15.5",
                modelRevision: SpeakerDiarizationModelManifest.fluidAudio0155.modelRevision,
                segments: []
            )
        }

        let outcome = await worker.runOne(nowMs: 5_000)

        XCTAssertEqual(outcome, .failed(callID: callID, errorCode: "invalid_helper_result"))
        let preferred = try await fixture.preferredSpeakerRevisionID(callID: callID)
        let revisionCount = try await fixture.speakerRevisionCount(callID: callID)
        let latestRevision = try await fixture.latestSpeakerRevision(callID: callID)
        XCTAssertNil(preferred)
        XCTAssertEqual(revisionCount, 1)
        XCTAssertEqual(latestRevision?.state, .failed)
    }
}

private actor EvidenceBarrierRecorder {
    let ownership: [Bool]
    private var resumed: [Int] = []

    init(ownership: [Bool]) { self.ownership = ownership }

    func suspend(index: Int) -> Bool { ownership[index] }
    func resume(index: Int) { resumed.append(index) }
    func resumedWorkers() -> [Int] { resumed }
}

private actor DiarizationManifestRecorder {
    struct Item: Sendable {
        let manifest: DiarizationHelperJobManifest
        let relativePath: String
    }

    private var items: [Item] = []

    func record(manifest: DiarizationHelperJobManifest, relativePath: String) {
        items.append(.init(manifest: manifest, relativePath: relativePath))
    }

    func snapshot() -> [Item] { items }
}

private final class SpeakerDiarizationWorkerFixture {
    struct SpeakerProjection {
        let revision: CallSpeakerRevisionRow
        let clusters: [CallSpeakerClusterRow]
        let intervals: [CallSpeakerIntervalRow]
    }

    let root: URL
    let database: ZBSEyeDatabase
    let repository: CallRepository
    let compute = AIComputeCoordinator(vectorBackfill: .noop)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-speaker-worker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        repository = CallRepository(database: database)
    }

    func makeReadyCall() async throws -> Int64 {
        let call = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "call")
        let callID = try XCTUnwrap(call.id)
        let span = try await repository.recordSourceSpan(
            .init(
                callId: callID,
                source: .system,
                epoch: 0,
                sampleRate: 16_000,
                startedAtMs: 1_000,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .available
            )
        )
        let audioURL = root.appendingPathComponent("media/calls/1/system/0000.pcm")
        try FileManager.default.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: 32_000).write(to: audioURL)
        _ = try await repository.recordAudioChunk(
            .init(
                callId: callID,
                sourceSpanId: try XCTUnwrap(span.id),
                source: .system,
                epoch: 0,
                sequence: 0,
                mediaGeneration: 0,
                startSample: 0,
                endSample: 16_000,
                startMs: 1_000,
                endMs: 2_000,
                relativePath: "calls/1/system/0000.pcm",
                bytes: 32_000,
                sha256: "fixture",
                finalized: true
            )
        )
        let job = try await repository.endCall(
            callID: callID,
            idempotencyKey: "end",
            endedAtMs: 2_000,
            systemEndSample: 16_000
        )
        let claimed = try await repository.claimNextTranscriptJob(nowMs: 2_100)
        XCTAssertEqual(claimed?.id, job.id)
        _ = try await repository.commitTranscriptJob(
            jobID: try XCTUnwrap(job.id),
            segments: [
                .init(source: .system, startMs: 1_000, endMs: 1_600, text: "first speaker"),
                .init(source: .system, startMs: 1_600, endMs: 2_000, text: "ambiguous speaker"),
            ],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture",
            degraded: false,
            nowMs: 2_200
        )
        return callID
    }

    func makeWorker(
        modelReady: Bool,
        launcher: @escaping SpeakerDiarizationWorker.HelperLauncher
    ) -> SpeakerDiarizationWorker {
        SpeakerDiarizationWorker(
            repository: repository,
            computeCoordinator: compute,
            dataRoot: root,
            modelReadiness: { modelReady },
            helperLauncher: launcher,
            cancelHelper: {}
        )
    }

    func preferredSpeakerRevisionID(callID: Int64) async throws -> Int64? {
        try await database.pool.read { db in
            try CallRow.fetchOne(db, key: callID)?.preferredSpeakerRevisionId
        }
    }

    func speakerRevisionCount(callID: Int64) async throws -> Int {
        try await database.pool.read { db in
            try CallSpeakerRevisionRow.filter(Column("callId") == callID).fetchCount(db)
        }
    }

    func latestSpeakerRevision(callID: Int64) async throws -> CallSpeakerRevisionRow? {
        try await database.pool.read { db in
            try CallSpeakerRevisionRow.fetchOne(
                db,
                sql: """
                    SELECT * FROM call_speaker_revisions
                    WHERE callId = ? ORDER BY createdAtMs DESC, id DESC LIMIT 1
                    """,
                arguments: [callID]
            )
        }
    }

    func speakerProjection(revisionID: Int64) async throws -> SpeakerProjection {
        try await database.pool.read { db in
            SpeakerProjection(
                revision: try XCTUnwrap(CallSpeakerRevisionRow.fetchOne(db, key: revisionID)),
                clusters: try CallSpeakerClusterRow
                    .filter(Column("revisionId") == revisionID)
                    .order(Column("ordinal"))
                    .fetchAll(db),
                intervals: try CallSpeakerIntervalRow
                    .filter(Column("revisionId") == revisionID)
                    .order(Column("ordinal"))
                    .fetchAll(db)
            )
        }
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}
