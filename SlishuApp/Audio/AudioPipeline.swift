import Foundation
import AVFoundation

/// Потребитель кадров микрофона (actor): VAD-сегментация → запись m4a → ingest audio_capture → очередь
/// транскрипции. Вся обработка сэмплов и запись файлов — вне main. Наружу отдаёт лишь факт «сегмент закрыт».
actor AudioPipeline {
    private let storage: StorageManager
    private let ingest: IngestService
    private let transcription: TranscriptionService
    private let config: AudioConfig
    private let channel: String     // "mic" | "system" — пишется в audio_captures и в имя файла

    private var segmenter: VADSegmenter
    private var accumulator: [Float] = []
    private var segmentStart: Date?
    private var sampleRate: Double = 48_000
    private var seq: Int64 = 0

    init(storage: StorageManager, ingest: IngestService,
         transcription: TranscriptionService, config: AudioConfig, channel: String) {
        self.storage = storage
        self.ingest = ingest
        self.transcription = transcription
        self.config = config
        self.channel = channel
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
        // channel в имени — иначе mic и system пайплайны могут столкнуться на одинаковых ms+seq.
        let rel = "audio_\(channel)_\(Int64(ts.timeIntervalSince1970 * 1000))_\(seq).m4a"
        let url = storage.url(forRelative: rel)
        do {
            let bytes = try Self.writeM4A(samples: accumulator, sampleRate: sampleRate,
                                          targetRate: config.targetSampleRate, to: url)
            // 0 → nil: иначе IngestService не возьмёт fallback re-stat и retention недосчитает размер.
            let audioId = try await ingest.ingest(AudioCaptureRecord(
                timestamp: ts, relativePath: rel, durationSec: durationSec, channel: channel,
                bytes: bytes > 0 ? bytes : nil))
            await transcription.enqueue(AudioSegment(audioId: audioId, fileURL: url,
                                                     ts: ts, durationSec: durationSec, channel: channel))
        } catch {
            Log.audio.error("segment write/ingest failed (\(self.channel, privacy: .public)): \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: url)   // файл-сирота не оставляем
        }
    }

    /// Моно-AAC m4a из float-сэмплов, с даунсэмплом до targetRate (речь → ×3 легче). Возвращает размер.
    private static func writeM4A(samples: [Float], sampleRate: Double,
                                targetRate: Double, to url: URL) throws -> Int {
        // Ресэмпл (с анти-алиасингом) только вниз; если источник уже ≤ цели — пишем как есть.
        let (out, outRate) = (sampleRate > targetRate)
            ? resample(samples, from: sampleRate, to: targetRate)
            : (samples, sampleRate)

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate,
                                      channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(out.count)) else {
            throw TranscriptionError.failed("audio buffer alloc")
        }
        buf.frameLength = AVAudioFrameCount(out.count)
        out.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: out.count)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outRate,
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

    /// Одношаговый ресэмпл моно-float через AVAudioConverter (анти-алиасинг). При сбое — без ресэмпла.
    private static func resample(_ samples: [Float], from inRate: Double, to outRate: Double) -> ([Float], Double) {
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inRate, channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return (samples, inRate)
        }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        let outCap = AVAudioFrameCount(Double(samples.count) * outRate / inRate) + 16
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap) else { return (samples, inRate) }
        // AVAudioConverterInputBlock считается @Sendable; AVAudioConverter зовёт его синхронно (гонки нет),
        // поэтому держим вход+флаг в @unchecked Sendable-холдере, чтобы не ловить ложные warning'и.
        let input = ConverterInput(inBuf)
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
            if input.fed { outStatus.pointee = .noDataNow; return nil }
            input.fed = true; outStatus.pointee = .haveData; return input.buffer
        }
        guard status != .error, err == nil, outBuf.frameLength > 0, let ch = outBuf.floatChannelData else {
            return (samples, inRate)
        }
        return (Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength))), outRate)
    }
}

/// Носитель входного буфера для одношагового AVAudioConverter (блок синхронный → @unchecked безопасен).
private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var fed = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
