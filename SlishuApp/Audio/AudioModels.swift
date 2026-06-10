import Foundation

/// Sendable-значения аудио-пайплайна. Не-Sendable (AVAudioPCMBuffer/AVAudioEngine) живут внутри своих
/// доменов; наружу пересекают только эти типы.

/// Один кадр из микрофонного tap'а: моно-сэмплы (нормализованный float) + RMS-энергия для VAD.
struct AudioFrame: Sendable {
    let samples: [Float]
    let rms: Float
    let sampleRate: Double
    let ts: Date
}

/// Завершённый сегмент речи: файл уже записан и строка audio_captures вставлена — готов к транскрипции.
struct AudioSegment: Sendable {
    let audioId: Int64
    let fileURL: URL
    let ts: Date
    let durationSec: Double
}

/// Результат backend-транскрипции.
struct Transcript: Sendable {
    let text: String
    let language: String
    let engine: String
}

/// Здоровье транскрипции для UI: сколько распознано/провалено/дропнуто + тип последней ошибки
/// (главное — отличить «нет on-device модели/нет прав» от транзиентных провалов).
struct TranscriptionHealth: Sendable, Equatable {
    var transcribed = 0
    var failed = 0
    var dropped = 0
    var lastErrorKind: String?   // "onDeviceUnavailable" | "notAuthorized" | "recognizerUnavailable" | nil
}

/// Sendable-вход для IngestService (транскрипт привязан к audioId). ts — момент сегмента
/// (для bucket_month семантического вектора).
struct TranscriptionRecord: Sendable {
    let audioId: Int64
    let ts: Date
    let text: String
    let language: String
    let engine: String
    let startOffset: Double?
    let endOffset: Double?
    init(audioId: Int64, ts: Date, text: String, language: String, engine: String,
         startOffset: Double? = nil, endOffset: Double? = nil) {
        self.audioId = audioId; self.ts = ts; self.text = text; self.language = language
        self.engine = engine; self.startOffset = startOffset; self.endOffset = endOffset
    }
}
