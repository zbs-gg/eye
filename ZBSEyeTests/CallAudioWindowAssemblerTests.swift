import Foundation
import XCTest

final class CallAudioWindowAssemblerTests: XCTestCase {
    func testWindowReconstructsFinalizedChunksAndBoundedActivePrefixWithoutRotatingSpool() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = try CallSpool(
            root: root,
            callID: 73,
            source: .me,
            policy: CallSpoolPolicy(sampleRate: 16_000, maxSamplesPerChunk: 4)
        )
        try await spool.beginEpoch(
            CallSpoolEpochDescriptor(
                epoch: 0,
                captureSampleRate: 16_000,
                startSample: 0,
                startHostTimeNs: 10_000,
                startedAtMs: 1_000
            )
        )

        let bookmarkWatermark = try await spool.appendPCM16(
            [100, 200, 300, 400, 500, 600],
            ingressSequence: 11,
            normalizedHostTimeNs: 20_000
        )
        let frozenSnapshot = await spool.snapshot()
        let activeSequenceAtBookmark = try XCTUnwrap(frozenSnapshot.activeChunk?.sequence)

        _ = try await spool.appendPCM16(
            [700],
            ingressSequence: 12,
            normalizedHostTimeNs: 21_000
        )

        let assembler = try CallAudioWindowAssembler(root: root)
        let window = try assembler.assemble(
            snapshot: frozenSnapshot,
            through: bookmarkWatermark
        )
        let currentSnapshot = await spool.snapshot()

        XCTAssertEqual(window.callID, 73)
        XCTAssertEqual(window.source, .me)
        XCTAssertEqual(window.sampleRate, 16_000)
        XCTAssertEqual(window.startSample, 0)
        XCTAssertEqual(window.endSample, 6)
        XCTAssertEqual(window.pcm16LE, pcm16LE([100, 200, 300, 400, 500, 600]))
        XCTAssertEqual(currentSnapshot.activeChunk?.sequence, activeSequenceAtBookmark)
        XCTAssertEqual(currentSnapshot.activeChunk?.endSample, 7)
        XCTAssertFalse(try XCTUnwrap(currentSnapshot.activeChunk).finalized)
        XCTAssertEqual(
            currentSnapshot.chunks.count,
            frozenSnapshot.chunks.count,
            "reading a bookmark window must not rotate the active canonical chunk"
        )
    }

    private func pcm16LE(_ samples: [Int16]) -> Data {
        samples.reduce(into: Data()) { data, sample in
            var value = sample.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-window-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
