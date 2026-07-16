import CryptoKit
import GRDB
import XCTest

final class CallExportTests: XCTestCase {
    func testExportsDegradedMicOnlyEnvelopeWithRelativeEvidenceReferences() async throws {
        let fixture = try CallExportFixture()
        let callID = try await fixture.makeReadyMicOnlyCall()
        let destination = fixture.root.appendingPathComponent("destination", isDirectory: true)

        let report = try await fixture.export.exportCall(
            id: callID,
            into: destination,
            includeAudio: true
        )

        let manifestURL = URL(fileURLWithPath: report.path)
            .appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CallExportManifest.self, from: data)
        let mic = try XCTUnwrap(manifest.sources.first { $0.source == .me })
        let system = try XCTUnwrap(manifest.sources.first { $0.source == .system })

        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.call.identifier, "call-\(callID)")
        XCTAssertEqual(mic.availability, .availableWithGaps)
        XCTAssertEqual(mic.gaps.map(\.reason), ["dropped_frames"])
        XCTAssertEqual(system.availability, .unavailable)
        XCTAssertEqual(manifest.bookmarks.map(\.ordinal), [1])
        XCTAssertEqual(manifest.transcript.status, .final)
        XCTAssertEqual(manifest.transcript.segments.map(\.text), ["hello from mic"])
        XCTAssertEqual(manifest.audio.count, 1)
        XCTAssertEqual(report.audioFiles, 1)

        let audio = try XCTUnwrap(manifest.audio.first)
        XCTAssertFalse(audio.file.hasPrefix("/"))
        XCTAssertFalse(audio.file.contains(".."))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: report.path).appendingPathComponent(audio.file)),
            fixture.audio
        )
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains(fixture.mediaRoot.path))
        XCTAssertFalse(json.contains(fixture.sourceRelativePath))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("scratch"))

        let metadataOnly = try await fixture.export.exportCall(
            id: callID,
            into: destination,
            includeAudio: false
        )
        let replaced = try JSONDecoder().decode(
            CallExportManifest.self,
            from: Data(
                contentsOf: URL(fileURLWithPath: metadataOnly.path)
                    .appendingPathComponent("manifest.json")
            )
        )
        XCTAssertTrue(replaced.audio.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: metadataOnly.path).appendingPathComponent("audio").path
        ))
    }

    func testCallOnlyHistoryExportIncludesManifestWithoutOptionalAudio() async throws {
        let fixture = try CallExportFixture()
        let callID = try await fixture.makeReadyMicOnlyCall()
        let destination = fixture.root.appendingPathComponent("history-export", isDirectory: true)

        let report = try await fixture.export.export(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 10),
            into: destination,
            includeMedia: false
        )

        XCTAssertEqual(report.calls, 1)
        XCTAssertEqual(report.mediaFiles, 0)
        let callsRoot = URL(fileURLWithPath: report.path).appendingPathComponent("calls")
        let bundles = try FileManager.default.contentsOfDirectory(
            at: callsRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(bundles.count, 1)
        let manifest = try JSONDecoder().decode(
            CallExportManifest.self,
            from: Data(contentsOf: bundles[0].appendingPathComponent("manifest.json"))
        )
        XCTAssertEqual(manifest.call.identifier, "call-\(callID)")
        XCTAssertTrue(manifest.audio.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: bundles[0].appendingPathComponent("audio").path
        ))
    }

    func testRefusesUnfinishedCallBundle() async throws {
        let fixture = try CallExportFixture()
        let call = try await fixture.repository.createCall(
            startedAtMs: 1_000,
            idempotencyKey: "active"
        )

        do {
            _ = try await fixture.export.exportCall(
                id: try XCTUnwrap(call.id),
                into: fixture.root,
                includeAudio: false
            )
            XCTFail("Expected active call export to be rejected")
        } catch let error as CallExportError {
            XCTAssertEqual(error, .callStillRecording)
        }
    }
}

private final class CallExportFixture {
    let root: URL
    let mediaRoot: URL
    let database: ZBSEyeDatabase
    let repository: CallRepository
    let export: ExportService
    let audio = Data([1, 0, 2, 0])
    private(set) var sourceRelativePath = ""

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-export-\(UUID().uuidString)", isDirectory: true)
        mediaRoot = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        repository = CallRepository(database: database)
        export = ExportService(db: database, mediaDirectory: mediaRoot)
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }

    func makeReadyMicOnlyCall() async throws -> Int64 {
        let call = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "export")
        let callID = try XCTUnwrap(call.id)
        let span = try await repository.recordSourceSpan(
            .init(
                callId: callID,
                source: .me,
                epoch: 0,
                sampleRate: 2,
                startedAtMs: 1_000,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .available
            )
        )
        sourceRelativePath = "calls/\(callID)/me/epoch-0000/chunk-000000.pcm"
        let sourceURL = mediaRoot.appendingPathComponent(sourceRelativePath)
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try audio.write(to: sourceURL)
        let sha = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        _ = try await repository.recordAudioChunk(
            .init(
                callId: callID,
                sourceSpanId: try XCTUnwrap(span.id),
                source: .me,
                epoch: 0,
                sequence: 0,
                mediaGeneration: 0,
                startSample: 0,
                endSample: 2,
                startMs: 1_000,
                endMs: 2_000,
                relativePath: sourceRelativePath,
                bytes: Int64(audio.count),
                sha256: sha,
                finalized: true
            )
        )
        _ = try await repository.createBookmark(
            callID: callID,
            idempotencyKey: "bookmark",
            acceptedAtMs: 1_500,
            meIngressTarget: 2,
            systemIngressTarget: nil,
            logicalStartMs: 1_000,
            logicalEndMs: 1_500,
            contextStartMs: 1_000
        )
        _ = try await repository.endCall(
            callID: callID,
            idempotencyKey: "end",
            endedAtMs: 2_000,
            meEndSample: 2,
            degradationReason: "system_unavailable"
        )
        let finalCandidate = try await repository.claimNextTranscriptJob(nowMs: 2_100)
        let final = try XCTUnwrap(finalCandidate)
        _ = try await repository.commitTranscriptJob(
            jobID: try XCTUnwrap(final.id),
            segments: [
                .init(source: .me, startMs: 1_100, endMs: 1_900, text: "hello from mic"),
            ],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: true,
            nowMs: 2_200
        )
        try await database.pool.write { db in
            var gap = CallSourceGapRow(
                id: nil,
                callId: callID,
                mediaGeneration: 0,
                source: .me,
                startMs: 1_250,
                endMs: 1_300,
                reason: "dropped_frames",
                createdAtMs: 2_200
            )
            try gap.insert(db)
        }
        return callID
    }
}
