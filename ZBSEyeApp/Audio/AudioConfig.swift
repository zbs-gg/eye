import Foundation

/// Параметры аудио-захвата и транскрипции (DI, тестируемо). Slice 1: только микрофон, on-device SFSpeech.
/// Системный звук, 16k-даунсэмпл, multi-locale auto-detect, MLX Quality mode — follow-up.
struct AudioConfig: Sendable {
    var tapBufferSize: UInt32 = 4096        // ~85мс при 48к — гранулярность VAD-кадра
    var vadEnergyThreshold: Float = 0.012   // RMS на нормализованных float; ниже — тишина/фон
    var minSpeechSec: Double = 0.4          // короче — не сегмент (щелчки/шум)
    var silenceHangoverSec: Double = 0.7    // столько тишины подряд → закрыть сегмент
    var maxSegmentSec: Double = 28          // потолок длины сегмента (on-device speech любит короткие)
    var maxQueuedSegments = 240             // backpressure: при переполнении дропаем новые
    var idleUnloadSeconds: Double = 900     // 15 мин без работы → выгрузить распознаватель (RAM)
    var localeIdentifiers = ["ru-RU", "en-US"] // пробуем обе, берём с лучшей уверенностью (auto-detect)
    var minTranscriptConfidence: Float = 0.3 // ниже (если confidence реально >0) → шум, не засоряем FTS
    var targetSampleRate: Double = 16_000   // m4a даунсэмплим до 16к (речь, ×3 легче; SFSpeech и так 16к)
    var transcribeTimeoutSec: Double = 60   // потолок на распознавание одной локали (зависший on-device движок)
}
