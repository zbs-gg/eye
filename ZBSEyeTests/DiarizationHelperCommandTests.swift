import Foundation
import XCTest

final class DiarizationHelperCommandTests: XCTestCase {
    func testPCMSourceReadsChunksAndZeroFillsHonestGaps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiarizationPCMTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let firstURL = root.appendingPathComponent("first.pcm")
        let secondURL = root.appendingPathComponent("second.pcm")
        try pcm([Int16.min, -16_384, 0, 16_384]).write(to: firstURL)
        try pcm([8_192, Int16.max]).write(to: secondURL)

        let source = try DiarizationPCMSampleSource(
            root: root,
            ranges: [
                .init(
                    source: .system,
                    relativePath: "first.pcm",
                    offsetBytes: 0,
                    lengthBytes: 8,
                    sampleRate: 16_000,
                    startSample: 0
                ),
                .init(
                    source: .system,
                    relativePath: "second.pcm",
                    offsetBytes: 0,
                    lengthBytes: 4,
                    sampleRate: 16_000,
                    startSample: 6
                ),
            ]
        )
        XCTAssertEqual(source.sampleCount, 8)

        var actual = [Float](repeating: -9, count: 8)
        try actual.withUnsafeMutableBufferPointer { buffer in
            try source.copySamples(into: buffer.baseAddress!, offset: 0, count: buffer.count)
        }
        XCTAssertEqual(actual[0], -1, accuracy: 0.0001)
        XCTAssertEqual(actual[1], -0.5, accuracy: 0.0001)
        XCTAssertEqual(actual[2], 0, accuracy: 0.0001)
        XCTAssertEqual(actual[3], 0.5, accuracy: 0.0001)
        XCTAssertEqual(actual[4], 0, accuracy: 0.0001)
        XCTAssertEqual(actual[5], 0, accuracy: 0.0001)
        XCTAssertEqual(actual[6], 0.25, accuracy: 0.0001)
        XCTAssertEqual(actual[7], Float(Int16.max) / 32_768, accuracy: 0.0001)
    }

    func testResultContractContainsNoVoiceprintOrEmbeddingPayload() throws {
        let result = DiarizationHelperResult(
            formatVersion: 1,
            jobID: UUID().uuidString.lowercased(),
            callID: 7,
            callGeneration: 2,
            packageVersion: "0.15.5",
            modelRevision: "revision",
            segments: [
                .init(
                    source: .system,
                    clusterKey: "system:S1",
                    startSeconds: 1,
                    endSeconds: 2,
                    quality: 0.9
                ),
            ]
        )

        let encoded = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("embedding"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("voiceprint"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("fingerprint"))
        XCTAssertTrue(json.contains("system:S1"))
    }

    func testPCMSourceRejectsOverlappingRanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiarizationPCMTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try pcm([1, 2, 3, 4]).write(to: root.appendingPathComponent("audio.pcm"))

        XCTAssertThrowsError(try DiarizationPCMSampleSource(
            root: root,
            ranges: [
                .init(
                    source: .me,
                    relativePath: "audio.pcm",
                    offsetBytes: 0,
                    lengthBytes: 8,
                    sampleRate: 16_000,
                    startSample: 0
                ),
                .init(
                    source: .me,
                    relativePath: "audio.pcm",
                    offsetBytes: 0,
                    lengthBytes: 4,
                    sampleRate: 16_000,
                    startSample: 3
                ),
            ]
        ))
    }

    private func pcm(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
