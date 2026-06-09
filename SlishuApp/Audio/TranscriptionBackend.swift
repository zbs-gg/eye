import Foundation
import Speech
import NaturalLanguage

enum TranscriptionError: LocalizedError {
    case recognizerUnavailable(String)
    case onDeviceUnavailable(String)
    case notAuthorized
    case empty
    case lowConfidence
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable(let l): return "Распознаватель речи недоступен для локали \(l)."
        case .onDeviceUnavailable(let l):   return "Нет on-device модели речи для \(l) — включи диктовку в Системных настройках."
        case .notAuthorized:                return "Нет разрешения на распознавание речи."
        case .empty:                        return "Пустой результат распознавания."
        case .lowConfidence:                return "Низкая уверенность распознавания (вероятно чужой язык/шум) — пропущено."
        case .failed(let m):                return "Ошибка распознавания: \(m)"
        }
    }
    /// Короткий тип для health/UI (отличить конфиг-проблему от транзиента).
    var kind: String {
        switch self {
        case .recognizerUnavailable: return "recognizerUnavailable"
        case .onDeviceUnavailable:   return "onDeviceUnavailable"
        case .notAuthorized:         return "notAuthorized"
        case .empty:                 return "empty"
        case .lowConfidence:         return "lowConfidence"
        case .failed:                return "failed"
        }
    }
}

/// Сменный backend транскрипции (план: light default + MLX Quality mode позже за этим протоколом).
protocol TranscriptionBackend: Sendable {
    var engineName: String { get }
    func transcribe(fileURL: URL, localeIdentifier: String, minConfidence: Float) async throws -> Transcript
    func unload() async
}

/// On-device Apple Speech. 100% локально (requiresOnDeviceRecognition=true). Файл-режим (URL request) —
/// под VAD-сегменты. Распознаватели кэшируются по локали; выгрузка — TranscriptionService по idle.
actor SFSpeechBackend: TranscriptionBackend {
    nonisolated let engineName = "sfspeech"
    private var recognizers: [String: SFSpeechRecognizer] = [:]

    func transcribe(fileURL: URL, localeIdentifier: String, minConfidence: Float) async throws -> Transcript {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw TranscriptionError.notAuthorized }
        let rec = try recognizer(localeIdentifier)
        guard rec.isAvailable else { throw TranscriptionError.recognizerUnavailable(localeIdentifier) }
        guard rec.supportsOnDeviceRecognition else { throw TranscriptionError.onDeviceUnavailable(localeIdentifier) }

        let req = SFSpeechURLRecognitionRequest(url: fileURL)
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false

        let r = try await recognizeOnce(rec, req)
        let trimmed = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionError.empty }
        // Конфиденс-гейт: на свежей речи чужого языка распознаватель уверенно выдаёт мусор —
        // отсекаем по средней уверенности сегментов, чтобы не засорять FTS.
        guard r.confidence >= minConfidence else { throw TranscriptionError.lowConfidence }
        // Честный язык вместо захардкоженного: что реально распознали.
        let lang = NLLanguageRecognizer.dominantLanguage(for: trimmed)?.rawValue ?? localeIdentifier
        return Transcript(text: trimmed, language: lang, engine: engineName)
    }

    func unload() { recognizers.removeAll() }

    private func recognizer(_ id: String) throws -> SFSpeechRecognizer {
        if let r = recognizers[id] { return r }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: id)) else {
            throw TranscriptionError.recognizerUnavailable(id)
        }
        recognizers[id] = r
        return r
    }

    /// Sendable-результат распознавания (SFTranscription не Sendable — извлекаем данные в handler'е).
    private struct Recognized: Sendable { let text: String; let confidence: Float }

    /// recognitionTask зовёт handler несколько раз — резолвим континюэйшн ровно один раз (ResumeBox).
    /// Инстанс-метод актора (не static): non-Sendable rec/req не покидают изоляцию актора.
    private func recognizeOnce(_ rec: SFSpeechRecognizer,
                               _ req: SFSpeechURLRecognitionRequest) async throws -> Recognized {
        let box = ResumeBox()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Recognized, Error>) in
            rec.recognitionTask(with: req) { result, error in
                if let error {
                    if box.claim() { cont.resume(throwing: TranscriptionError.failed(error.localizedDescription)) }
                    return
                }
                guard let result, result.isFinal else { return }
                if box.claim() {
                    let t = result.bestTranscription
                    let confs = t.segments.map(\.confidence)
                    // нет сегментной уверенности → не штрафуем (1.0), иначе средняя по сегментам
                    let avg = confs.isEmpty ? 1.0 : confs.reduce(0, +) / Float(confs.count)
                    cont.resume(returning: Recognized(text: t.formattedString, confidence: avg))
                }
            }
        }
    }
}

/// Одноразовый «замок» резолва континюэйшна (handler может прийти повторно после resume).
private final class ResumeBox: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true; return true
    }
}
