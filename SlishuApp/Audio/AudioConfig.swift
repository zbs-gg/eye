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
    var localeIdentifier = "ru-RU"          // primary (Никита русскоязычный); multi-locale — follow-up
    var minTranscriptConfidence: Float = 0.3 // ниже → вероятно чужой язык/шум, не засоряем FTS
}
