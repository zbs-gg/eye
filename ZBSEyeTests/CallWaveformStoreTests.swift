import XCTest

final class CallWaveformStoreTests: XCTestCase {
    func testWaveformReadsBoundedPeaksAndPreservesSilence() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbs-eye-waveform-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let root = try SecureCallSpoolRoot(root: rootURL)
        let relative = "media/calls/1/g0/mic/chunk.pcm"
        let (_, handle) = try root.createWritableFile(relativePath: relative)
        var pcm = Data(count: 16_000 * 2)
        for sample in 8_000..<16_000 {
            let value = Int16(20_000).littleEndian
            withUnsafeBytes(of: value) { bytes in
                pcm.replaceSubrange((sample * 2)..<(sample * 2 + 2), with: bytes)
            }
        }
        try handle.write(contentsOf: pcm)
        try handle.close()

        let waveform = try CallWaveformStore.samples(
            chunks: [
                CallPlaybackChunk(
                    relativePath: relative,
                    startSample: 0,
                    endSample: 16_000,
                    bytes: Int64(pcm.count)
                ),
            ],
            durationSeconds: 1,
            binCount: 32,
            root: root
        )

        XCTAssertEqual(waveform.count, 32)
        XCTAssertTrue(waveform.prefix(12).allSatisfy { $0 == 0 })
        XCTAssertTrue(waveform.suffix(12).allSatisfy { $0 > 0.5 })
    }

    func testWaveformReturnsEmptyWithoutAudio() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbs-eye-waveform-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        XCTAssertEqual(
            try CallWaveformStore.samples(
                chunks: [],
                durationSeconds: 120,
                binCount: 320,
                root: SecureCallSpoolRoot(root: rootURL)
            ),
            []
        )
    }
}
