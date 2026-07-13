import Foundation
import GRDB
import XCTest

final class RetentionManagerTests: XCTestCase {
    private let gb = KeepMediaPolicy.bytesPerGB

    func testReconcilerCountsExactCapturedBytesAndExcludesImportedSentinels() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        try harness.writeFile("frame.heic", bytes: 3)
        try harness.writeFile("audio.m4a", bytes: 5)
        try await harness.insertScreen(ts: 1, path: "frame.heic", bytes: 3)
        try await harness.insertScreen(ts: 2, path: nil, bytes: nil)
        try await harness.insertAudio(ts: 3, path: "audio.m4a", bytes: 5)
        try await harness.insertAudio(ts: 4, path: "imported", bytes: nil)

        let evidence = await CapturedMediaReconciler.reconcile(
            db: harness.db,
            storage: harness.storage
        )

        XCTAssertEqual(evidence, .reconciled(capturedMediaBytes: 8))
    }

    func testReconcilerFailsClosedForMissingStaleAndOrphanedMedia() async throws {
        do {
            let harness = try Harness()
            defer { harness.remove() }
            try await harness.insertScreen(ts: 1, path: "missing.heic", bytes: 3)
            let evidence = await CapturedMediaReconciler.reconcile(
                db: harness.db,
                storage: harness.storage
            )
            XCTAssertEqual(evidence, .uncertain(.referencedFileMissing))
        }
        do {
            let harness = try Harness()
            defer { harness.remove() }
            try harness.writeFile("stale.heic", bytes: 4)
            try await harness.insertScreen(ts: 1, path: "stale.heic", bytes: 3)
            let evidence = await CapturedMediaReconciler.reconcile(
                db: harness.db,
                storage: harness.storage
            )
            XCTAssertEqual(evidence, .uncertain(.byteMetadataMismatch))
        }
        do {
            let harness = try Harness()
            defer { harness.remove() }
            try harness.writeFile("orphan.m4a", bytes: 2)
            let evidence = await CapturedMediaReconciler.reconcile(
                db: harness.db,
                storage: harness.storage
            )
            XCTAssertEqual(evidence, .uncertain(.orphanCapturedMedia))
        }
    }

    func testReconcilerFailsClosedForNullDuplicateAndUnsafeReferences() async throws {
        do {
            let harness = try Harness()
            defer { harness.remove() }
            try harness.writeFile("null.heic", bytes: 2)
            try await harness.insertScreen(ts: 1, path: "null.heic", bytes: nil)
            let evidence = await CapturedMediaReconciler.reconcile(
                db: harness.db,
                storage: harness.storage
            )
            XCTAssertEqual(evidence, .uncertain(.byteMetadataMismatch))
        }
        do {
            let harness = try Harness()
            defer { harness.remove() }
            try harness.writeFile("zero.heic", bytes: 0)
            try await harness.insertScreen(ts: 1, path: "zero.heic", bytes: 0)
            let evidence = await CapturedMediaReconciler.reconcile(
                db: harness.db,
                storage: harness.storage
            )
            XCTAssertEqual(evidence, .uncertain(.byteMetadataMismatch))
        }
        do {
            let harness = try Harness()
            defer { harness.remove() }
            try harness.writeFile("duplicate.heic", bytes: 2)
            try await harness.insertScreen(ts: 1, path: "duplicate.heic", bytes: 2)
            try await harness.insertScreen(ts: 2, path: "duplicate.heic", bytes: 2)
            let evidence = await CapturedMediaReconciler.reconcile(
                db: harness.db,
                storage: harness.storage
            )
            XCTAssertEqual(evidence, .uncertain(.byteMetadataMismatch))
        }
        do {
            let harness = try Harness()
            defer { harness.remove() }
            try await harness.insertAudio(ts: 1, path: "../escape.m4a", bytes: 1)
            let evidence = await CapturedMediaReconciler.reconcile(
                db: harness.db,
                storage: harness.storage
            )
            XCTAssertEqual(evidence, .uncertain(.unsafeRelativePath))
        }
    }

    func testReconcilerDetectsDatabaseChangesAcrossTheInventoryBoundary() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        try harness.writeFile("first.heic", bytes: 2)
        try await harness.insertScreen(ts: 1, path: "first.heic", bytes: 2)

        let evidence = await CapturedMediaReconciler.reconcile(
            db: harness.db,
            storage: harness.storage,
            afterFirstSnapshot: {
                try? await harness.insertScreen(ts: 2, path: nil, bytes: nil)
            }
        )

        XCTAssertEqual(evidence, .uncertain(.changedDuringReconciliation))
    }

    func testAutomaticRetentionDeletesSmallestGlobalOldestMixedPrefix() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let oldestFrame = try await harness.insertScreenFile(ts: 100, name: "f1.heic", bytes: gb)
        let oldestAudio = try await harness.insertAudioFile(ts: 200, name: "a1.m4a", bytes: 2 * gb)
        let newestFrame = try await harness.insertScreenFile(ts: 300, name: "f2.heic", bytes: 4 * gb)
        let admission = admittedFiveGB()
        let permit = try XCTUnwrap(admission.currentPermit())
        let retention = RetentionManager(db: harness.db, storage: harness.storage)

        let report = try await retention.pruneAutomatically(
            permit: permit,
            admission: admission
        )

        XCTAssertEqual(
            report.victims,
            [
                .init(kind: .frame, id: oldestFrame, ts: 100, relativePath: "f1.heic", bytes: gb),
                .init(kind: .audio, id: oldestAudio, ts: 200, relativePath: "a1.m4a", bytes: 2 * gb),
            ]
        )
        let remainingFrames = try await harness.screenIDs()
        let remainingAudio = try await harness.audioIDs()
        XCTAssertEqual(remainingFrames, [newestFrame])
        XCTAssertEqual(remainingAudio, [])
        XCTAssertFalse(harness.fileExists("f1.heic"))
        XCTAssertFalse(harness.fileExists("a1.m4a"))
        XCTAssertTrue(harness.fileExists("f2.heic"))
    }

    func testAutomaticRetentionUsesTimestampKindThenIDAndStopsAtBoundary() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let frame1 = try await harness.insertScreenFile(ts: 100, name: "f1.heic", bytes: gb)
        let frame2 = try await harness.insertScreenFile(ts: 100, name: "f2.heic", bytes: gb)
        _ = try await harness.insertAudioFile(ts: 100, name: "a1.m4a", bytes: gb)
        _ = try await harness.insertAudioFile(ts: 100, name: "a2.m4a", bytes: 4 * gb)
        let admission = admittedFiveGB()
        let permit = try XCTUnwrap(admission.currentPermit())
        let retention = RetentionManager(db: harness.db, storage: harness.storage)

        let report = try await retention.pruneAutomatically(
            permit: permit,
            admission: admission
        )

        XCTAssertEqual(report.victims.map(\.kind), [.frame, .frame])
        XCTAssertEqual(report.victims.map(\.id), [frame1, frame2])
        XCTAssertEqual(report.framesDeleted, 2)
        XCTAssertEqual(report.audioDeleted, 0)
    }

    func testAutomaticRetentionReconcilesDependentFTSVectorsAndEmbedQueue() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let frame = try await harness.insertScreenFile(
            ts: 100,
            name: "frame.heic",
            bytes: 4 * gb
        )
        let audio = try await harness.insertAudioFile(
            ts: 200,
            name: "audio.m4a",
            bytes: 8 * gb
        )
        try await harness.insertSearchDependencies(frameID: frame, audioID: audio)
        let admission = admittedFiveGB()
        let permit = try XCTUnwrap(admission.currentPermit())
        let retention = RetentionManager(db: harness.db, storage: harness.storage)

        _ = try await retention.pruneAutomatically(
            permit: permit,
            admission: admission
        )

        let counts = try await harness.dependentCounts()
        XCTAssertEqual(counts, [0, 0, 0, 0, 0, 0, 0])
    }

    func testAutomaticRetentionExcludesPathlessAndImportedRowsFromBudget() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let pathless = try await harness.insertScreen(ts: 1, path: nil, bytes: 6 * gb)
        let imported = try await harness.insertAudio(ts: 2, path: "imported", bytes: 6 * gb)
        let admission = admittedFiveGB()
        let permit = try XCTUnwrap(admission.currentPermit())
        let retention = RetentionManager(db: harness.db, storage: harness.storage)

        let report = try await retention.pruneAutomatically(
            permit: permit,
            admission: admission
        )

        XCTAssertTrue(report.victims.isEmpty)
        let remainingFrames = try await harness.screenIDs()
        let remainingAudio = try await harness.audioIDs()
        XCTAssertEqual(remainingFrames, [pathless])
        XCTAssertEqual(remainingAudio, [imported])
    }

    func testAutomaticRetentionRejectsZeroByteMediaWithoutDeletingAnyRow() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        try harness.writeFile("zero.heic", bytes: 0)
        let zero = try await harness.insertScreen(ts: 1, path: "zero.heic", bytes: 0)
        let valid = try await harness.insertScreenFile(
            ts: 2,
            name: "valid.heic",
            bytes: 6 * gb
        )
        let admission = admittedFiveGB()
        let permit = try XCTUnwrap(admission.currentPermit())
        let retention = RetentionManager(db: harness.db, storage: harness.storage)

        await XCTAssertThrowsErrorAsync(
            try await retention.pruneAutomatically(permit: permit, admission: admission)
        ) { error in
            XCTAssertEqual(error as? AutomaticRetentionError, .invalidCandidateState)
        }

        let remaining = try await harness.screenIDs()
        XCTAssertEqual(remaining, [zero, valid])
        XCTAssertTrue(harness.fileExists("zero.heic"))
        XCTAssertTrue(harness.fileExists("valid.heic"))
    }

    func testAutomaticRetentionRevalidatesFileBeforeDeletingDatabaseRows() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let id = try await harness.insertScreenFile(
            ts: 1,
            name: "stale.heic",
            bytes: 6 * gb
        )
        try harness.truncateFile("stale.heic", bytes: 1)
        let admission = admittedFiveGB()
        let permit = try XCTUnwrap(admission.currentPermit())
        let retention = RetentionManager(db: harness.db, storage: harness.storage)

        await XCTAssertThrowsErrorAsync(
            try await retention.pruneAutomatically(permit: permit, admission: admission)
        ) { error in
            XCTAssertEqual(error as? AutomaticRetentionError, .invalidCandidateState)
        }

        let remaining = try await harness.screenIDs()
        XCTAssertEqual(remaining, [id])
        XCTAssertTrue(harness.fileExists("stale.heic"))
    }

    func testForeverRejectsAutomaticDeletion() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let id = try await harness.insertScreenFile(ts: 1, name: "keep.heic", bytes: 6 * gb)
        let admission = AutomaticRetentionAdmission()
        let stale = AutomaticRetentionPermit(revision: 1, policy: .fiveGB, maxBytes: 5 * gb)
        let retention = RetentionManager(db: harness.db, storage: harness.storage)

        await XCTAssertThrowsErrorAsync(
            try await retention.pruneAutomatically(permit: stale, admission: admission)
        ) { error in
            XCTAssertEqual(error as? AutomaticRetentionAdmissionError, .stalePermit)
        }
        let remainingFrames = try await harness.screenIDs()
        XCTAssertEqual(remainingFrames, [id])
        XCTAssertTrue(harness.fileExists("keep.heic"))
    }

    func testPostCommitFileFailureStopsBeforeAnotherBatchAndReturnsLedger() async throws {
        let harness = try Harness(failingDeletePath: "f1.heic")
        defer { harness.remove() }
        let first = try await harness.insertScreenFile(ts: 1, name: "f1.heic", bytes: gb)
        let second = try await harness.insertScreenFile(ts: 2, name: "f2.heic", bytes: gb)
        let third = try await harness.insertScreenFile(ts: 3, name: "f3.heic", bytes: 5 * gb)
        let admission = admittedFiveGB()
        let permit = try XCTUnwrap(admission.currentPermit())
        let retention = RetentionManager(
            db: harness.db,
            storage: harness.storage,
            automaticBatchSize: 1
        )

        do {
            _ = try await retention.pruneAutomatically(permit: permit, admission: admission)
            XCTFail("Expected post-commit media deletion failure")
        } catch let AutomaticRetentionError.postCommitFileDeletionFailed(ledger) {
            XCTAssertEqual(ledger.committedVictims.map(\.id), [first])
            XCTAssertEqual(ledger.physicallyDeletedPaths, [])
            XCTAssertEqual(ledger.failedPath, "f1.heic")
        }

        let remainingFrames = try await harness.screenIDs()
        XCTAssertEqual(remainingFrames, [second, third])
        XCTAssertTrue(harness.fileExists("f1.heic"))
        XCTAssertTrue(harness.fileExists("f2.heic"))
        XCTAssertTrue(harness.fileExists("f3.heic"))
        XCTAssertNil(admission.currentPermit())

        await XCTAssertThrowsErrorAsync(
            try await retention.pruneAutomatically(permit: permit, admission: admission)
        ) { error in
            guard let automaticError = error as? AutomaticRetentionError,
                  case .postCommitFileDeletionFailed = automaticError else {
                return XCTFail("Expected the retained post-commit failure")
            }
        }
        let afterRetry = try await harness.screenIDs()
        XCTAssertEqual(afterRetry, [second, third])
    }

    private func admittedFiveGB() -> AutomaticRetentionAdmission {
        AutomaticRetentionAdmission(record: AutomaticRetentionRecord(
            revision: 1,
            policy: .fiveGB,
            phase: .finiteAdmitted,
            source: .explicitSelection
        ))
    }
}

private final class Harness: @unchecked Sendable {
    let root: URL
    let db: ZBSEyeDatabase
    let storage: StorageManager

    init(failingDeletePath: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ZBSEyeRetentionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("media", isDirectory: true)
        if let failingDeletePath {
            storage = try StorageManager(mediaDirectory: media) { url in
                if url.lastPathComponent == failingDeletePath {
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.removeItem(at: url)
            }
        } else {
            storage = try StorageManager(mediaDirectory: media)
        }
        db = try ZBSEyeDatabase(path: root.appendingPathComponent("test.sqlite").path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeFile(_ name: String, bytes: Int) throws {
        try Data(repeating: 0xA5, count: bytes).write(to: storage.url(forRelative: name))
    }

    func truncateFile(_ name: String, bytes: UInt64) throws {
        let url = storage.url(forRelative: name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: bytes)
    }

    func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: storage.url(forRelative: name).path)
    }

    @discardableResult
    func insertScreen(ts: Int64, path: String?, bytes: Int64?) async throws -> Int64 {
        try await db.pool.write { database in
            try database.execute(
                sql: "INSERT INTO screen_captures(ts, monitorId, relativePath, bytes) VALUES (?, 'test', ?, ?)",
                arguments: [ts, path, bytes]
            )
            return database.lastInsertedRowID
        }
    }

    @discardableResult
    func insertAudio(ts: Int64, path: String, bytes: Int64?) async throws -> Int64 {
        try await db.pool.write { database in
            try database.execute(
                sql: "INSERT INTO audio_captures(ts, relativePath, durationSec, channel, bytes) VALUES (?, ?, 1, 'mic', ?)",
                arguments: [ts, path, bytes]
            )
            return database.lastInsertedRowID
        }
    }

    func insertScreenFile(ts: Int64, name: String, bytes: Int64) async throws -> Int64 {
        try truncateFile(name, bytes: UInt64(bytes))
        return try await insertScreen(ts: ts, path: name, bytes: bytes)
    }

    func insertAudioFile(ts: Int64, name: String, bytes: Int64) async throws -> Int64 {
        try truncateFile(name, bytes: UInt64(bytes))
        return try await insertAudio(ts: ts, path: name, bytes: bytes)
    }

    func screenIDs() async throws -> [Int64] {
        try await db.pool.read { try Int64.fetchAll($0, sql: "SELECT id FROM screen_captures ORDER BY id") }
    }

    func audioIDs() async throws -> [Int64] {
        try await db.pool.read { try Int64.fetchAll($0, sql: "SELECT id FROM audio_captures ORDER BY id") }
    }

    func insertSearchDependencies(frameID: Int64, audioID: Int64) async throws {
        let vector = Data(count: ZBSEyeDatabase.embeddingDim * MemoryLayout<Float>.size)
        try await db.pool.write { database in
            try database.execute(
                sql: "INSERT INTO text_blocks(captureId, source, text, confidence) VALUES (?, 'ocr', 'frame text', 1)",
                arguments: [frameID]
            )
            try database.execute(
                sql: "INSERT INTO transcriptions(audioId, text, language, engine) VALUES (?, 'audio text', 'en', 'test')",
                arguments: [audioID]
            )
            let transcriptionID = database.lastInsertedRowID
            try database.execute(
                sql: "INSERT INTO vec_screen(capture_id, bucket_month, embedding) VALUES (?, 202607, ?)",
                arguments: [frameID, vector]
            )
            try database.execute(
                sql: "INSERT INTO vec_transcripts(transcription_id, bucket_month, embedding) VALUES (?, 202607, ?)",
                arguments: [transcriptionID, vector]
            )
            try database.execute(
                sql: "INSERT INTO embed_queue(row_id, kind, ts) VALUES (?, 0, 100), (?, 1, 200)",
                arguments: [frameID, transcriptionID]
            )
        }
    }

    func dependentCounts() async throws -> [Int] {
        try await db.pool.read { database in
            try [
                "text_blocks", "text_fts", "transcriptions",
                "transcription_fts", "vec_screen", "vec_transcripts",
            ].map { table in
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            } + [try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM embed_queue") ?? -1]
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown")
    } catch {
        errorHandler(error)
    }
}
