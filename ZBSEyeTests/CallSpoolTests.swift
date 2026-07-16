import Foundation
import GRDB
import XCTest

final class CallSpoolTests: XCTestCase {
    func testFixedPolicyChunksHaveContiguousSampleCoverage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try CallSpool(
            root: root,
            callID: 42,
            source: .me,
            policy: CallSpoolPolicy(sampleRate: 16_000, maxSamplesPerChunk: 4)
        )
        try await spool.beginEpoch(epoch(startSample: 0))

        _ = try await spool.appendPCM16(
            [100, 200, 300],
            ingressSequence: 0,
            normalizedHostTimeNs: 1_000
        )
        let watermark = try await spool.appendPCM16(
            [400, 500, 600, 700],
            ingressSequence: 1,
            normalizedHostTimeNs: 2_000
        )
        let snapshot = await spool.snapshot()

        XCTAssertEqual(watermark.endSample, 7)
        XCTAssertEqual(watermark.ingressSequence, 1)
        XCTAssertEqual(snapshot.callID, 42)
        XCTAssertEqual(snapshot.source, .me)
        XCTAssertEqual(snapshot.chunks.count, 2)
        XCTAssertEqual(snapshot.chunks[0].sequence, 0)
        XCTAssertEqual(snapshot.chunks[0].startSample, 0)
        XCTAssertEqual(snapshot.chunks[0].endSample, 4)
        XCTAssertEqual(snapshot.chunks[0].committedBytes, 8)
        XCTAssertTrue(snapshot.chunks[0].finalized)
        XCTAssertEqual(snapshot.chunks[1].sequence, 1)
        XCTAssertEqual(snapshot.chunks[1].startSample, 4)
        XCTAssertEqual(snapshot.chunks[1].endSample, 7)
        XCTAssertEqual(snapshot.chunks[1].committedBytes, 6)
        XCTAssertFalse(snapshot.chunks[1].finalized)
    }

    func testSourceRestartCreatesNewEpochAndPreservesExplicitGap() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try CallSpool(
            root: root,
            callID: 9,
            source: .system,
            policy: CallSpoolPolicy(sampleRate: 16_000, maxSamplesPerChunk: 16)
        )
        try await spool.beginEpoch(epoch(index: 0, captureSampleRate: 48_000, startSample: 0))
        _ = try await spool.appendPCM16(
            [1, 2],
            ingressSequence: 0,
            normalizedHostTimeNs: 1_000
        )
        try await spool.recordGap(
            AudioIngressGap(
                source: .system,
                epoch: 0,
                firstIngressSequence: 1,
                lastIngressSequence: 2,
                reason: .sourceRestart
            )
        )
        try await spool.beginEpoch(
            epoch(index: 1, captureSampleRate: 44_100, startSample: 2, startHostTimeNs: 4_000)
        )
        _ = try await spool.appendPCM16(
            [3, 4],
            ingressSequence: 3,
            normalizedHostTimeNs: 5_000
        )

        let snapshot = await spool.snapshot()
        XCTAssertEqual(snapshot.callID, 9, "a source restart must not split the logical call")
        XCTAssertEqual(snapshot.epochs.map(\.epoch), [0, 1])
        XCTAssertEqual(snapshot.epochs.map(\.captureSampleRate), [48_000, 44_100])
        XCTAssertEqual(snapshot.gaps.count, 1)
        XCTAssertEqual(snapshot.gaps[0].firstIngressSequence, 1)
        XCTAssertEqual(snapshot.gaps[0].lastIngressSequence, 2)
        XCTAssertEqual(snapshot.gaps[0].reason, .sourceRestart)
    }

    func testSecureRootRejectsTraversalAndSymlinkAncestorsAndCreatesOwnerOnlyFile() throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let secureRoot = try SecureCallSpoolRoot(root: root)

        XCTAssertThrowsError(
            try secureRoot.createFile(relativePath: "../escaped.pcm")
        )

        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(
            try secureRoot.createFile(relativePath: "linked/escaped.pcm")
        )

        let file = try secureRoot.createFile(relativePath: "calls/42/me/chunk-0.pcm")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testSecureRootRejectsASymlinkRoot() throws {
        let parent = try temporaryDirectory()
        let target = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: target)
        }
        let link = parent.appendingPathComponent("root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try SecureCallSpoolRoot(root: link))
    }

    func testDurableBarrierCommitsOnlyFlushedPrefixToCallRepository() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        let repository = CallRepository(database: database)
        let call = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "spool-call")
        let callID = try XCTUnwrap(call.id)
        let mediaRoot = root.appendingPathComponent("media", isDirectory: true)
        let spool = try CallSpool(
            root: mediaRoot,
            callID: callID,
            source: .me,
            policy: CallSpoolPolicy(sampleRate: 16_000, maxSamplesPerChunk: 4),
            repository: repository
        )
        try await spool.beginEpoch(epoch(startSample: 0))
        _ = try await spool.appendPCM16(
            [10, 20, 30, 40, 50],
            ingressSequence: 7,
            normalizedHostTimeNs: 5_000
        )
        _ = try await spool.flushDurableWatermark()

        let beforeFinish = try await database.pool.read { db in
            try CallAudioChunkRow
                .filter(Column("callId") == callID)
                .order(Column("sequence"))
                .fetchAll(db)
        }
        XCTAssertEqual(beforeFinish.map(\.bytes), [8, 2])
        XCTAssertEqual(beforeFinish.map(\.finalized), [true, false])

        _ = try await spool.finish()
        let afterFinish = try await database.pool.read { db in
            try CallAudioChunkRow
                .filter(Column("callId") == callID)
                .order(Column("sequence"))
                .fetchAll(db)
        }
        XCTAssertEqual(afterFinish.map(\.finalized), [true, true])
        XCTAssertTrue(afterFinish.allSatisfy { $0.sha256?.count == 64 })
    }

    func testPCM16LEAppendPreservesExactBytesAcrossChunkBoundaries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try CallSpool(
            root: root,
            callID: 77,
            source: .me,
            policy: CallSpoolPolicy(sampleRate: 16_000, maxSamplesPerChunk: 2)
        )
        try await spool.beginEpoch(epoch(startSample: 0))
        let expected = Data([0x34, 0x12, 0x00, 0x80, 0xff, 0x7f])

        _ = try await spool.appendPCM16LE(
            expected,
            sampleCount: 3,
            ingressSequence: 9,
            normalizedHostTimeNs: 10_000
        )
        let snapshot = try await spool.finish()
        let actual = try snapshot.chunks.reduce(into: Data()) { bytes, chunk in
            bytes.append(try Data(contentsOf: root.appendingPathComponent(chunk.relativePath)))
        }

        XCTAssertEqual(actual, expected)
        XCTAssertEqual(snapshot.watermark?.endSample, 3)
    }

    private func epoch(
        index: Int = 0,
        captureSampleRate: Int = 16_000,
        startSample: Int64,
        startHostTimeNs: Int64 = 0
    ) -> CallSpoolEpochDescriptor {
        CallSpoolEpochDescriptor(
            epoch: index,
            captureSampleRate: captureSampleRate,
            startSample: startSample,
            startHostTimeNs: startHostTimeNs,
            startedAtMs: 1_000 + Int64(index)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-spool-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
