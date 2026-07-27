import XCTest

final class HandySpeechBackendTests: XCTestCase {
    func testPrefersDownloadedTurboQ8TranscribeCppModel() {
        let models = [
            model("other/whisper-large-v3-turbo", name: "Turbo", downloaded: true),
            model("owner/whisper-large-v3-turbo-Q8_0.gguf", name: "Turbo Q8", downloaded: true),
            model("owner/whisper-large-v3-turbo-Q8_0-better.gguf", name: "Wrong engine", downloaded: true, engine: "Candle"),
            model("owner/whisper-large-v3-turbo-Q8_0-missing.gguf", name: "Missing", downloaded: false),
        ]

        XCTAssertEqual(
            HandySpeechModelProbe.preferredDownloadedModel(models)?.id,
            "owner/whisper-large-v3-turbo-Q8_0.gguf"
        )
    }

    func testRejectsCatalogWithoutDownloadedWhisperTranscribeCppModel() {
        XCTAssertNil(
            HandySpeechModelProbe.preferredDownloadedModel([
                model("owner/parakeet", name: "Parakeet", downloaded: true),
                model("owner/whisper", name: "Whisper", downloaded: false),
                model("owner/whisper", name: "Whisper", downloaded: true, engine: "Candle"),
            ])
        )
    }

    func testHandyWAVEnvelopeIsMono16KHzInt16PCM() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let wav = try HandyWhisperHelperProcessRunner.wavData(pcm: pcm, sampleRate: 16_000)

        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(littleEndianUInt32(wav, offset: 24), 16_000)
        XCTAssertEqual(littleEndianUInt16(wav, offset: 34), 16)
        XCTAssertEqual(littleEndianUInt32(wav, offset: 40), UInt32(pcm.count))
        XCTAssertEqual(Data(wav[44...]), pcm)
    }

    func testHandyWAVRejectsNonPCMAndWrongRate() {
        XCTAssertThrowsError(
            try HandyWhisperHelperProcessRunner.wavData(pcm: Data([0]), sampleRate: 16_000)
        )
        XCTAssertThrowsError(
            try HandyWhisperHelperProcessRunner.wavData(pcm: Data([0, 0]), sampleRate: 44_100)
        )
    }

    func testHandyBatchesContiguousChunksAtOneMinuteWithoutMixingSourcesOrGaps() throws {
        var ranges = (0..<7).map { index in
            audioRange(source: .me, startSample: Int64(index * 160_000))
        }
        ranges.append(audioRange(source: .system, startSample: 0))
        ranges.append(audioRange(source: .system, startSample: 320_000))

        let batches = try HandyWhisperHelperProcessRunner.plannedBatches(ranges)

        XCTAssertEqual(batches.map(\.source), [.me, .me, .system, .system])
        XCTAssertEqual(batches.map { $0.ranges.count }, [6, 1, 1, 1])
        XCTAssertEqual(batches[0].lengthBytes, HandyWhisperHelperProcessRunner.maximumBatchBytes)
    }

    func testHandyBatchPlannerRejectsUnmanagedInput() {
        XCTAssertThrowsError(
            try HandyWhisperHelperProcessRunner.plannedBatches([
                WhisperHelperAudioRange(
                    source: .me,
                    relativePath: "../private.pcm",
                    offsetBytes: 0,
                    lengthBytes: 320_000,
                    sampleRate: 16_000,
                    startSample: 0
                ),
            ])
        )
    }

    func testHandyBatchPlannerSplitsALargeManagedRange() throws {
        let length = HandyWhisperHelperProcessRunner.maximumBatchBytes * 2
        let batches = try HandyWhisperHelperProcessRunner.plannedBatches([
            WhisperHelperAudioRange(
                source: .me,
                relativePath: "media/calls/1/g0/large.pcm",
                offsetBytes: 100,
                lengthBytes: length,
                sampleRate: 16_000,
                startSample: 50
            ),
        ])

        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches.map(\.lengthBytes), [length / 2, length / 2])
        XCTAssertEqual(batches[1].ranges[0].offsetBytes, 100 + length / 2)
        XCTAssertEqual(batches[1].startSample, 50 + length / 4)
    }

    func testHandyDropsSilencePunctuationButKeepsUnicodeSpeech() {
        XCTAssertNil(HandyWhisperHelperProcessRunner.normalizedTranscript("  . …  \n"))
        XCTAssertEqual(
            HandyWhisperHelperProcessRunner.normalizedTranscript("  Да, слышно. \n"),
            "Да, слышно."
        )
    }

    private func model(
        _ id: String,
        name: String,
        downloaded: Bool,
        engine: String = "TranscribeCpp"
    ) -> HandySpeechModelProbe.ModelInfo {
        HandySpeechModelProbe.ModelInfo(
            id: id,
            name: name,
            isDownloaded: downloaded,
            engineType: engine
        )
    }

    private func audioRange(
        source: CallAudioSource,
        startSample: Int64
    ) -> WhisperHelperAudioRange {
        WhisperHelperAudioRange(
            source: source,
            relativePath: "media/calls/1/g0/audio.pcm",
            offsetBytes: 0,
            lengthBytes: 320_000,
            sampleRate: 16_000,
            startSample: startSample
        )
    }

    private func littleEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
