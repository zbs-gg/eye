import Foundation
import GRDB
import XCTest

final class CallStorageRelocationTests: XCTestCase {
    func testRelocationCopiesCallPCMAndBothManagedModelFamiliesWithParity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-relocation-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let chosen = root.appendingPathComponent("chosen", isDirectory: true)
        let sourceMedia = sourceRoot.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceMedia, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseURL = sourceRoot.appendingPathComponent("zbseye.sqlite")
        let database = try ZBSEyeDatabase(path: databaseURL.path)
        defer { try? database.pool.close() }
        let repository = CallRepository(database: database)
        let detectorFingerprint = String(repeating: "b", count: 64)
        let call = try await repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "automatic:\(detectorFingerprint)"
        )
        let callID = try XCTUnwrap(call.id)
        let span = try await repository.recordSourceSpan(
            .init(
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
        let relativePath = "calls/\(callID)/me/epoch-0000/chunk-000000.pcm"
        let pcmURL = sourceMedia.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: pcmURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pcm = Data([1, 0, 2, 0, 3, 0, 4, 0])
        try pcm.write(to: pcmURL)
        _ = try await repository.recordAudioChunk(
            .init(
                callId: callID,
                sourceSpanId: try XCTUnwrap(span.id),
                source: .me,
                epoch: 0,
                sequence: 0,
                mediaGeneration: 0,
                startSample: 0,
                endSample: 4,
                startMs: 1_000,
                endMs: 3_000,
                relativePath: relativePath,
                bytes: Int64(pcm.count),
                sha256: "fixture",
                finalized: true
            )
        )
        _ = try await repository.endCall(
            callID: callID,
            idempotencyKey: "relocate-end",
            endedAtMs: 3_000
        )
        let privacyReceipt = try CallPrivacyIntentJournal(mediaRoot: sourceMedia)
            .persistAutomaticRejection(
                callID: callID,
                detectorFingerprint: detectorFingerprint
            )

        let generativeRoot = StorageLocation.builtInModelRoot(under: sourceRoot)
        let generativeFile = generativeRoot.appendingPathComponent("model.fixture")
        let generativeBytes = Data("verified generative model fixture".utf8)
        try FileManager.default.createDirectory(
            at: generativeFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try generativeBytes.write(to: generativeFile)

        let speechRoot = StorageLocation.speechModelRoot(under: sourceRoot)
        let speechFile = speechRoot.appendingPathComponent("ggml-large-v3-turbo.bin")
        let speechBytes = Data("verified speech model fixture".utf8)
        try FileManager.default.createDirectory(
            at: speechFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try speechBytes.write(to: speechFile)

        let report = try await StorageRelocator().migrate(
            sourcePool: database.pool,
            sourceDBURL: databaseURL,
            sourceMedia: sourceMedia,
            chosen: chosen,
            currentRootOverride: sourceRoot,
            progress: { _, _ in }
        )

        XCTAssertEqual(report.mediaFilesCopied, 2)
        XCTAssertEqual(report.modelFilesCopied, 1)
        XCTAssertEqual(report.modelBytesCopied, Int64(generativeBytes.count))
        XCTAssertEqual(report.speechModelFilesCopied, 1)
        XCTAssertEqual(report.speechModelBytesCopied, Int64(speechBytes.count))
        XCTAssertEqual(
            try Data(contentsOf: report.newDataRoot.appendingPathComponent("media/\(relativePath)")),
            pcm
        )
        let relocatedMedia = report.newDataRoot.appendingPathComponent(
            "media",
            isDirectory: true
        )
        let relocatedPrivacyJournal = try CallPrivacyIntentJournal(mediaRoot: relocatedMedia)
        XCTAssertTrue(try relocatedPrivacyJournal.contains(privacyReceipt))
        XCTAssertEqual(
            try relocatedPrivacyJournal.pendingAutomaticRejections(),
            [privacyReceipt]
        )
        XCTAssertEqual(
            try Data(
                contentsOf: StorageLocation.builtInModelRoot(under: report.newDataRoot)
                    .appendingPathComponent("model.fixture")
            ),
            generativeBytes
        )
        XCTAssertEqual(
            try Data(
                contentsOf: StorageLocation.speechModelRoot(under: report.newDataRoot)
                    .appendingPathComponent("ggml-large-v3-turbo.bin")
            ),
            speechBytes
        )
        let relocated = try DatabaseQueue(
            path: report.newDataRoot.appendingPathComponent("zbseye.sqlite").path
        )
        let counts = try await relocated.read { db in
            (
                calls: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calls") ?? -1,
                chunks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_audio_chunks") ?? -1,
                jobs: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_transcript_jobs") ?? -1
            )
        }
        XCTAssertEqual(counts.calls, 1)
        XCTAssertEqual(counts.chunks, 1)
        XCTAssertEqual(counts.jobs, 1)
    }
}
