import Foundation
import AVFoundation

/// Потребитель кадров микрофона (actor): VAD-сегментация → запись m4a → ingest audio_capture → очередь
/// транскрипции. Вся обработка сэмплов и запись файлов — вне main. Наружу отдаёт лишь факт «сегмент закрыт».
actor AudioPipeline {
    private let storage: StorageManager
    private let ingest: IngestService
    private let transcription: TranscriptionService
    private let config: AudioConfig

    private var segmenter: VADSegmenter
    private var accumulator: [Float] = []
    private var segmentStart: Date?
    private var sampleRate: Double = 48_000
    private var seq: Int64 = 0

    init(storage: StorageManager, ingest: IngestService,
         transcription: TranscriptionService, config: AudioConfig) {
        self.storage = storage
        self.ingest = ingest
        self.transcription = transcription
        self.config = config
        self.segmenter = VADSegmenter(config: config)
    }

    func reset() {
        accumulator.removeAll()
        segmentStart = nil
        segmenter = VADSegmenter(config: config)
    }

    /// Скармливает кадр. Возвращает true, если этим кадром закрылся сегмент (для счётчика активности).
    @discardableResult
    func feed(_ frame: AudioFrame) async -> Bool {
        sampleRate = frame.sampleRate
        let frameSec = Double(frame.samples.count) / max(1, frame.sampleRate)
        switch segmenter.feed(rms: frame.rms, frameSec: frameSec) {
        case .ignore:
            return false
        case .append:
            if accumulator.isEmpty { segmentStart = frame.ts }
            accumulator.append(contentsOf: frame.samples)
            return false
        case .flush:
            if accumulator.isEmpty { segmentStart = frame.ts }
            accumulator.append(contentsOf: frame.samples)
            await closeSegment()
            return true
        case .discard:
            accumulator.removeAll(); segmentStart = nil
            return false
        }
    }

    /// Закрыть текущий накопленный сегмент на стопе записи (если в нём была речь).
    func flushFinal() async {
        if segmenter.finishPending(), !accumulator.isEmpty { await closeSegment() }
        accumulator.removeAll(); segmentStart = nil
    }

    private func closeSegment() async {
        defer { accumulator.removeAll(); segmentStart = nil }
        guard !accumulator.isEmpty else { return }
        let durationSec = Double(accumulator.count) / max(1, sampleRate)
        let ts = segmentStart ?? Date()
        seq &+= 1
        let rel = "audio_\(Int64(ts.timeIntervalSince1970 * 1000))_\(seq).m4a"
        let url = storage.url(forRelative: rel)
        do {
            let bytes = try Self.writeM4A(samples: accumulator, sampleRate: sampleRate, to: url)
            let audioId = try await ingest.ingest(AudioCaptureRecord(
                timestamp: ts, relativePath: rel, durationSec: durationSec, channel: "mic", bytes: bytes))
            await transcription.enqueue(AudioSegment(audioId: audioId, fileURL: url,
                                                     ts: ts, durationSec: durationSec))
        } catch {
            try? FileManager.default.removeItem(at: url)   // файл-сирота не оставляем
        }
    }

    /// Моно-AAC m4a из float-сэмплов (AVAudioFile конвертит float32 → AAC). Возвращает размер файла.
    private static func writeM4A(samples: [Float], sampleRate: Double, to url: URL) throws -> Int {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw TranscriptionError.failed("audio buffer alloc")
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        // Внутренний scope: AVAudioFile деинициализируется ДО чтения размера — AAC-энкодер сбрасывает
        // хвост и финализирует контейнер (moov) в deinit, иначе .fileSizeKey недосчитывает байты.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buf)
        }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
