import Foundation

/// Чистый VAD/сегментатор (без I/O — тестируется изолированно). По энергии кадров решает: копить ли
/// сэмплы в текущий сегмент и когда его закрыть. Тишину ДО начала речи отбрасываем (не пишем пустые
/// сегменты); музыку/фон режет порог энергии; затяжная тишина закрывает сегмент.
struct VADSegmenter: Sendable {
    /// Что делать потребителю с текущим кадром:
    /// - ignore: тишина до речи — кадр НЕ копить;
    /// - append: докопить кадр в сегмент;
    /// - flush: докопить кадр и ЗАКРЫТЬ сегмент (речи накоплено достаточно → отдать на транскрипцию);
    /// - discard: закрыть и ВЫБРОСИТЬ накопленное (речь оказалась слишком короткой).
    enum Action: Equatable { case ignore, append, flush, discard }

    var energyThreshold: Float
    var minSpeechSec: Double
    var silenceHangoverSec: Double
    var maxSegmentSec: Double

    private var inSpeech = false
    private var speechSec = 0.0     // суммарно «голосовых» секунд в сегменте
    private var silenceSec = 0.0    // тишины подряд с последнего голоса
    private var segSec = 0.0        // полная длина сегмента

    init(config: AudioConfig) {
        energyThreshold = config.vadEnergyThreshold
        minSpeechSec = config.minSpeechSec
        silenceHangoverSec = config.silenceHangoverSec
        maxSegmentSec = config.maxSegmentSec
    }

    mutating func feed(rms: Float, frameSec: Double) -> Action {
        let voiced = rms >= energyThreshold
        if !inSpeech {
            guard voiced else { return .ignore }
            inSpeech = true; speechSec = frameSec; silenceSec = 0; segSec = frameSec
            return .append
        }
        segSec += frameSec
        if voiced { speechSec += frameSec; silenceSec = 0 } else { silenceSec += frameSec }

        if silenceSec >= silenceHangoverSec {
            let enough = speechSec >= minSpeechSec
            reset()
            return enough ? .flush : .discard
        }
        if segSec >= maxSegmentSec { reset(); return .flush }
        return .append
    }

    /// Принудительно закрыть текущий сегмент (на стопе записи). Возвращает true, если было что отдавать.
    mutating func finishPending() -> Bool {
        let had = inSpeech && speechSec >= minSpeechSec
        reset()
        return had
    }

    private mutating func reset() { inSpeech = false; speechSec = 0; silenceSec = 0; segSec = 0 }
}
