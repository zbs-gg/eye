import GRDB
import XCTest

final class CallTranscriptWorkerTests: XCTestCase {
    func testFailedCheckpointDoesNotDelayAWaitingFinalJob() {
        XCTAssertEqual(
            CallTranscriptWorker.loopDelay(
                after: .failed(jobID: 7, errorCode: "invalid_helper_result"),
                finalWaiting: true
            ),
            .milliseconds(100)
        )
        XCTAssertEqual(
            CallTranscriptWorker.loopDelay(
                after: .retryScheduled(jobID: 7, errorCode: "helper_failed"),
                finalWaiting: false
            ),
            .seconds(10)
        )
        XCTAssertEqual(
            CallTranscriptWorker.loopDelay(
                after: .retryScheduled(jobID: 7, errorCode: "helper_failed"),
                finalWaiting: true
            ),
            .seconds(1)
        )
    }

    func testMissingModelDoesNotClaimDurableWork() async throws {
        let fixture = try CallTranscriptWorkerFixture()
        let created = try await fixture.makePendingCheckpoint()
        let worker = fixture.makeWorker(modelReady: false) { _, _, _ in
            XCTFail("helper must not launch without a verified model")
            throw FixtureError.helperFailed
        }

        let outcome = await worker.runOne(nowMs: 3_000)

        XCTAssertEqual(outcome, .modelUnavailable)
        let job = try await fixture.job(id: try XCTUnwrap(created.job.id))
        XCTAssertEqual(job.state, .pending)
        XCTAssertEqual(job.attempts, 0)
    }

    func testDirectMaintenanceResumeCannotOpenAnActivePrivacyBarrier() async throws {
        let fixture = try CallTranscriptWorkerFixture()
        _ = try await fixture.makePendingCheckpoint()
        let worker = fixture.makeWorker(modelReady: false) { _, _, _ in
            XCTFail("helper must remain closed")
            throw FixtureError.helperFailed
        }

        await worker.suspendAndDrainForPrivacyBarrier()
        await worker.suspendAndDrain()
        await worker.resume()
        let whilePrivacyHeld = await worker.runOne(nowMs: 3_000)
        XCTAssertEqual(whilePrivacyHeld, .suspended)

        await worker.resumeFromPrivacyBarrier()
        let afterPrivacyRelease = await worker.runOne(nowMs: 3_001)
        XCTAssertEqual(afterPrivacyRelease, .modelUnavailable)
    }

    func testPrivacyReleaseBalancesWhileMaintenanceStillOwnsSuspension() async throws {
        let fixture = try CallTranscriptWorkerFixture()
        _ = try await fixture.makePendingCheckpoint()
        let worker = fixture.makeWorker(modelReady: false) { _, _, _ in
            XCTFail("helper must remain closed")
            throw FixtureError.helperFailed
        }

        await worker.suspendAndDrainForPrivacyBarrier()
        await worker.suspendAndDrain()
        await worker.resumeFromPrivacyBarrier()
        let whileMaintenanceHeld = await worker.runOne(nowMs: 3_000)
        XCTAssertEqual(whileMaintenanceHeld, .suspended)

        await worker.resume()
        let afterMaintenanceRelease = await worker.runOne(nowMs: 3_001)
        XCTAssertEqual(afterMaintenanceRelease, .modelUnavailable)
    }

    func testOneCheckpointRunsHelperAndCommitsSourceAttributedProjection() async throws {
        let fixture = try CallTranscriptWorkerFixture()
        let created = try await fixture.makePendingCheckpoint()
        let recorder = HelperManifestRecorder()
        let worker = fixture.makeWorker(modelReady: true) { manifest, relativePath, _ in
            await recorder.record(manifest: manifest, relativePath: relativePath)
            let range = try XCTUnwrap(manifest.audioRanges.first)
            let start = Double(range.startSample) / Double(range.sampleRate)
            return WhisperHelperResult(
                formatVersion: 1,
                jobID: manifest.jobID,
                callID: manifest.callID,
                callGeneration: manifest.callGeneration,
                modelSHA256: manifest.modelSHA256,
                runtimeRelease: "fixture-runtime",
                segments: [
                    WhisperHelperResultSegment(
                        source: .me,
                        startSeconds: start + 0.1,
                        endSeconds: start + 0.8,
                        text: "checkpoint words"
                    ),
                ]
            )
        }

        let outcome = await worker.runOne(nowMs: 3_000)

        XCTAssertEqual(
            outcome,
            .completed(jobID: try XCTUnwrap(created.job.id), final: false)
        )
        let captured = await recorder.snapshot()
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.manifest.audioRanges.first?.relativePath, "media/calls/1/me/0000.pcm")
        XCTAssertTrue(captured.first?.relativePath.hasSuffix("/manifest.json") == true)
        let projection = try await fixture.database.pool.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT r.text FROM calls c
                    JOIN call_transcript_revisions r ON r.id = c.preferredRevisionId
                    WHERE c.id = 1
                    """
            )
        }
        XCTAssertEqual(projection, "checkpoint words")
        let helperDirectory = try XCTUnwrap(captured.first).relativePath
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root
                .appendingPathComponent(helperDirectory)
                .deletingLastPathComponent()
                .path
        ))
    }

    func testHelperFailureReturnsClaimedJobToRetryablePending() async throws {
        let fixture = try CallTranscriptWorkerFixture()
        let created = try await fixture.makePendingCheckpoint()
        let worker = fixture.makeWorker(modelReady: true) { _, _, _ in
            throw FixtureError.helperFailed
        }

        let outcome = await worker.runOne(nowMs: 3_000)

        XCTAssertEqual(
            outcome,
            .retryScheduled(jobID: try XCTUnwrap(created.job.id), errorCode: "helper_failed")
        )
        let job = try await fixture.job(id: try XCTUnwrap(created.job.id))
        XCTAssertEqual(job.state, .pending)
        XCTAssertEqual(job.attempts, 1)
        XCTAssertEqual(job.errorCode, "helper_failed")
    }

    func testRepeatedHelperFailureStopsAfterBoundedAutomaticAttempts() async throws {
        let fixture = try CallTranscriptWorkerFixture()
        let created = try await fixture.makePendingCheckpoint()
        let worker = fixture.makeWorker(modelReady: true) { _, _, _ in
            throw FixtureError.helperFailed
        }

        for attempt in 1...CallRepository.maximumAutomaticTranscriptAttempts {
            _ = await worker.runOne(nowMs: 3_000 + Int64(attempt))
        }

        let job = try await fixture.job(id: try XCTUnwrap(created.job.id))
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.attempts, CallRepository.maximumAutomaticTranscriptAttempts)
        XCTAssertEqual(job.errorCode, "helper_failed")
    }

    func testCheckpointPlansFrozenPrefixFromAnUnfinalizedActiveChunk() async throws {
        let fixture = try CallTranscriptWorkerFixture()
        let created = try await fixture.makePendingCheckpoint(finalized: false)
        let recorder = HelperManifestRecorder()
        let worker = fixture.makeWorker(modelReady: true) { manifest, relativePath, _ in
            await recorder.record(manifest: manifest, relativePath: relativePath)
            return WhisperHelperResult(
                formatVersion: 1,
                jobID: manifest.jobID,
                callID: manifest.callID,
                callGeneration: manifest.callGeneration,
                modelSHA256: manifest.modelSHA256,
                runtimeRelease: "fixture-runtime",
                segments: []
            )
        }

        let outcome = await worker.runOne(nowMs: 3_000)

        XCTAssertEqual(outcome, .completed(jobID: try XCTUnwrap(created.job.id), final: false))
        let recorded = await recorder.snapshot()
        let manifest = try XCTUnwrap(recorded.first?.manifest)
        XCTAssertEqual(manifest.audioRanges.map(\.lengthBytes), [32_000])
    }

    func testResultFromAnotherHelperJobIsRejected() async throws {
        let fixture = try CallTranscriptWorkerFixture()
        let created = try await fixture.makePendingCheckpoint()
        let worker = fixture.makeWorker(modelReady: true) { manifest, _, _ in
            WhisperHelperResult(
                formatVersion: 1,
                jobID: UUID().uuidString.lowercased(),
                callID: manifest.callID,
                callGeneration: manifest.callGeneration,
                modelSHA256: manifest.modelSHA256,
                runtimeRelease: "fixture-runtime",
                segments: []
            )
        }

        let outcome = await worker.runOne(nowMs: 3_000)

        XCTAssertEqual(
            outcome,
            .failed(
                jobID: try XCTUnwrap(created.job.id),
                errorCode: "invalid_helper_result"
            )
        )
        let job = try await fixture.job(id: try XCTUnwrap(created.job.id))
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.errorCode, "invalid_helper_result")
    }

    func testMaintenanceCancelsActiveHelperAndReturnsJobToPending() async throws {
        let fixture = try CallTranscriptWorkerFixture()
        let created = try await fixture.makePendingCheckpoint()
        let recorder = HelperManifestRecorder()
        let worker = fixture.makeWorker(modelReady: true) { manifest, relativePath, _ in
            await recorder.record(manifest: manifest, relativePath: relativePath)
            try await Task.sleep(for: .seconds(60))
            throw FixtureError.helperFailed
        }
        let run = Task { await worker.runOne(nowMs: 3_000) }
        for _ in 0..<100 {
            if !(await recorder.snapshot()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let launched = await recorder.snapshot()
        XCTAssertFalse(launched.isEmpty)

        await worker.suspendAndDrain()
        let outcome = await run.value

        XCTAssertEqual(
            outcome,
            .retryScheduled(jobID: try XCTUnwrap(created.job.id), errorCode: "helper_cancelled")
        )
        let job = try await fixture.job(id: try XCTUnwrap(created.job.id))
        XCTAssertEqual(job.state, .pending)
        XCTAssertEqual(job.attempts, 0)
        XCTAssertEqual(job.errorCode, "helper_cancelled")
    }

    func testSyntheticTwoHourEvidencePlansBoundedRangesForOneHelperJob() throws {
        let startMs: Int64 = 1_000
        let chunkDurationMs: Int64 = 30_000
        let samplesPerChunk: Int64 = 16_000 * 30
        let chunks = (0..<240).map { index in
            let offsetMs = Int64(index) * chunkDurationMs
            let startSample = Int64(index) * samplesPerChunk
            return CallAudioChunkRow(
                id: Int64(index + 1),
                callId: 1,
                sourceSpanId: 1,
                source: .me,
                epoch: 0,
                sequence: index,
                mediaGeneration: 0,
                startSample: startSample,
                endSample: startSample + samplesPerChunk,
                startMs: startMs + offsetMs,
                endMs: startMs + offsetMs + chunkDurationMs,
                relativePath: "calls/1/me/\(index).pcm",
                bytes: samplesPerChunk * 2,
                sha256: "fixture",
                finalized: true
            )
        }
        let evidence = CallTranscriptJobEvidence(
            call: CallRow(
                id: 1,
                startIdempotencyKey: "two-hours",
                endIdempotencyKey: "end",
                startTs: startMs,
                endTs: startMs + 7_200_000,
                state: .finalizing,
                interrupted: false,
                degradationReason: nil,
                mediaGeneration: 0,
                preferredRevisionId: nil,
                createdAtMs: startMs,
                updatedAtMs: startMs
            ),
            job: CallTranscriptJobRow(
                id: 1,
                identity: "final:1:0",
                callId: 1,
                bookmarkId: nil,
                kind: .final,
                mediaGeneration: 0,
                state: .running,
                priority: 0,
                logicalStartMs: startMs,
                logicalEndMs: startMs + 7_200_000,
                contextStartMs: startMs,
                meEndSample: 16_000 * 7_200,
                systemEndSample: nil,
                coverageFrozen: true,
                attempts: 1,
                errorCode: nil,
                createdAtMs: startMs,
                updatedAtMs: startMs
            ),
            bookmark: nil,
            chunks: chunks
        )

        let ranges = try CallTranscriptWorker.plannedAudioRanges(evidence: evidence)

        XCTAssertEqual(ranges.reduce(Int64(0)) { $0 + $1.lengthBytes }, 230_400_000)
        XCTAssertEqual(ranges.count, 240)
        XCTAssertTrue(ranges.allSatisfy { $0.lengthBytes <= 16 * 1_024 * 1_024 })
    }

    func testProcessRunnerLaunchesAndReadsBoundedAtomicResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-helper-process-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobID = UUID().uuidString.lowercased()
        let resultRelativePath = "call-helper/jobs/\(jobID)/result.json"
        let resultURL = root.appendingPathComponent(resultRelativePath)
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let expected = WhisperHelperResult(
            formatVersion: 1,
            jobID: jobID,
            callID: 7,
            callGeneration: 0,
            modelSHA256: String(repeating: "b", count: 64),
            runtimeRelease: "fixture-runtime",
            segments: []
        )
        try JSONEncoder().encode(expected).write(to: resultURL, options: .atomic)
        let manifest = WhisperHelperJobManifest(
            formatVersion: 1,
            jobID: jobID,
            callID: 7,
            callGeneration: 0,
            modelRelativePath: "ai/speech/v1/model.bin",
            modelSHA256: expected.modelSHA256,
            resultRelativePath: resultRelativePath,
            audioRanges: []
        )

        let actual = try await WhisperHelperProcessRunner(
            executablePath: "/usr/bin/true"
        ).run(
            manifest: manifest,
            manifestRelativePath: "call-helper/jobs/\(jobID)/manifest.json",
            dataRoot: root
        )

        XCTAssertEqual(actual, expected)
    }
}

private enum FixtureError: Error {
    case helperFailed
}

private actor HelperManifestRecorder {
    struct Item: Sendable {
        let manifest: WhisperHelperJobManifest
        let relativePath: String
    }

    private var items: [Item] = []

    func record(manifest: WhisperHelperJobManifest, relativePath: String) {
        items.append(Item(manifest: manifest, relativePath: relativePath))
    }

    func snapshot() -> [Item] { items }
}

private final class CallTranscriptWorkerFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let repository: CallRepository
    let compute = AIComputeCoordinator(vectorBackfill: .noop)
    let model = WhisperModelManifest(
        id: "fixture-model",
        displayName: "Fixture",
        repositoryID: "fixture/model",
        revision: String(repeating: "a", count: 40),
        sourceURL: URL(string: "https://example.invalid/model.bin")!,
        relativePath: "model/fixture.bin",
        expectedBytes: 1,
        sha256: String(repeating: "b", count: 64),
        licenseSPDX: "MIT",
        licenseURL: URL(string: "https://example.invalid/license")!,
        runtimeRelease: "fixture-runtime",
        runtimeArchiveSHA256: String(repeating: "c", count: 64)
    )

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-worker-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        repository = CallRepository(database: database)
    }

    func makePendingCheckpoint(finalized: Bool = true) async throws -> CallBookmarkCreation {
        let call = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "call")
        let callID = try XCTUnwrap(call.id)
        let span = try await repository.recordSourceSpan(
            CallSourceSpanDraft(
                callId: callID,
                source: .me,
                epoch: 0,
                sampleRate: 16_000,
                startedAtMs: 1_000,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .available
            )
        )
        let audioURL = root.appendingPathComponent("media/calls/1/me/0000.pcm")
        try FileManager.default.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: 32_000).write(to: audioURL)
        _ = try await repository.recordAudioChunk(
            CallAudioChunkDraft(
                callId: callID,
                sourceSpanId: try XCTUnwrap(span.id),
                source: .me,
                epoch: 0,
                sequence: 0,
                mediaGeneration: 0,
                startSample: 0,
                endSample: 16_000,
                startMs: 1_000,
                endMs: 2_000,
                relativePath: "calls/1/me/0000.pcm",
                bytes: 32_000,
                sha256: "fixture",
                finalized: finalized
            )
        )
        let created = try await repository.createBookmark(
            callID: callID,
            idempotencyKey: "bookmark",
            acceptedAtMs: 2_000,
            meIngressTarget: 16_000,
            systemIngressTarget: nil,
            logicalStartMs: 1_000,
            logicalEndMs: 2_000,
            contextStartMs: 1_000
        )
        _ = try await repository.freezeBookmarkCoverage(
            bookmarkID: try XCTUnwrap(created.bookmark.id),
            jobID: try XCTUnwrap(created.job.id),
            meEndSample: 16_000,
            systemEndSample: nil,
            degraded: false,
            nowMs: 2_000
        )
        return created
    }

    func makeWorker(
        modelReady: Bool,
        launcher: @escaping CallTranscriptWorker.HelperLauncher
    ) -> CallTranscriptWorker {
        CallTranscriptWorker(
            repository: repository,
            computeCoordinator: compute,
            dataRoot: root,
            modelManifest: model,
            modelReadiness: { modelReady },
            helperLauncher: launcher,
            cancelHelper: {}
        )
    }

    func job(id: Int64) async throws -> CallTranscriptJobRow {
        try await database.pool.read { db in
            try XCTUnwrap(CallTranscriptJobRow.fetchOne(db, key: id))
        }
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}
