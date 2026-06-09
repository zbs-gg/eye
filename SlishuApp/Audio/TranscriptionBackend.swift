import Foundation
import Speech
import NaturalLanguage

enum TranscriptionError: LocalizedError {
    case recognizerUnavailable(String)
    case onDeviceUnavailable(String)
    case notAuthorized
    case empty
    case lowConfidence
    case timedOut
    case failed(String)
    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable(let l): return "Распознаватель речи недоступен для локали \(l)."
        case .onDeviceUnavailable(let l):   return "Нет on-device модели речи для \(l) — включи диктовку в Системных настройках."
        case .notAuthorized:                return "Нет разрешения на распознавание речи."
        case .empty:                        return "Пустой результат распознавания."
        case .lowConfidence:                return "Низкая уверенность распознавания (вероятно шум) — пропущено."
        case .timedOut:                     return "Таймаут распознавания."
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
        case .timedOut:              return "timedOut"
        case .failed:                return "failed"
        }
    }
}

/// Сменный backend транскрипции (план: light default + MLX Quality mode позже за этим протоколом).
protocol TranscriptionBackend: Sendable {
    var engineName: String { get }
    /// Пробует локали, возвращает результат с лучшим совпадением языка (auto-detect). timeout — потолок
    /// на распознавание одной локали (защита от зависшего on-device движка).
    func transcribe(fileURL: URL, localeIdentifiers: [String],
                    minConfidence: Float, timeout: TimeInterval) async throws -> Transcript
    func unload() async
}

/// On-device Apple Speech. 100% локально (requiresOnDeviceRecognition=true). Файл-режим (URL request) —
/// под VAD-сегменты. Распознаватели кэшируются по локали; выгрузка — TranscriptionService по idle.
actor SFSpeechBackend: TranscriptionBackend {
    nonisolated let engineName = "sfspeech"
    private var recognizers: [String: SFSpeechRecognizer] = [:]

    func transcribe(fileURL: URL, localeIdentifiers: [String],
                    minConfidence: Float, timeout: TimeInterval) async throws -> Transcript {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw TranscriptionError.notAuthorized }

        // Прогоняем файл через локали и выбираем по СОВПАДЕНИЮ ЯЗЫКА (NLLanguageRecognizer), а НЕ по
        // confidence: on-device SFSpeech сплошь и рядом отдаёт confidence 0 на верном тексте — по нему
        // нельзя ни сравнивать локали, ни отсеивать (иначе теряли бы всё). confidence используем только
        // как вторичный сигнал отсева явного шума, и только когда он реально > 0.
        var candidates: [Candidate] = []
        var unavailableCount = 0
        var lastFail: TranscriptionError?

        for id in localeIdentifiers {
            guard let rec = try? recognizer(id), rec.isAvailable else {
                lastFail = .recognizerUnavailable(id); continue
            }
            guard rec.supportsOnDeviceRecognition else {
                unavailableCount += 1; lastFail = .onDeviceUnavailable(id); continue
            }
            let req = SFSpeechURLRecognitionRequest(url: fileURL)
            req.requiresOnDeviceRecognition = true
            req.shouldReportPartialResults = false
            do {
                let r = try await recognizeOnce(rec, req, timeout: timeout)
                let trimmed = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let match = Self.languageMatches(trimmed, locale: id)
                candidates.append(Candidate(text: trimmed, score: r.hasConfidence ? r.confidence : nil,
                                            locale: id, langMatch: match))
                // short-circuit: язык совпал и (нет confidence ИЛИ он выше порога) → вторую локаль не гоняем.
                if match, (r.hasConfidence ? r.confidence : 1) >= minConfidence { break }
            } catch {
                lastFail = (error as? TranscriptionError) ?? .failed("\(error)")
            }
        }

        guard !candidates.isEmpty else {
            // onDeviceUnavailable — только если ВСЕ локали реально без on-device модели (честный health).
            if unavailableCount == localeIdentifiers.count, unavailableCount > 0 {
                throw TranscriptionError.onDeviceUnavailable(localeIdentifiers.joined(separator: ","))
            }
            throw lastFail ?? TranscriptionError.empty
        }

        let best = Self.pickBest(candidates)
        // Гейт отсева применяем ТОЛЬКО при реальном confidence (>0); при unknown не дропаем.
        if let s = best.score, s < minConfidence { throw TranscriptionError.lowConfidence }
        return Transcript(text: best.text, language: best.locale, engine: engineName)
    }

    func unload() { recognizers.removeAll() }

    // MARK: выбор кандидата

    private struct Candidate { let text: String; let score: Float?; let locale: String; let langMatch: Bool }

    /// Совпадает ли распознанный язык с локалью распознавателя («ru-RU» → "ru").
    static func languageMatches(_ text: String, locale: String) -> Bool {
        guard let lang = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue else { return false }
        return lang.lowercased().hasPrefix(String(locale.prefix(2)).lowercased())
    }

    /// Среди совпавших по языку (или всех, если ни один не совпал): макс confidence, при unknown — длиннейший.
    private static func pickBest(_ c: [Candidate]) -> Candidate {
        let matched = c.filter { $0.langMatch }
        let pool = matched.isEmpty ? c : matched
        return pool.max { a, b in
            switch (a.score, b.score) {
            case let (sa?, sb?): return sa < sb
            case (nil, _?):      return true       // у b есть score, у a нет → b лучше
            case (_?, nil):      return false
            case (nil, nil):     return a.text.count < b.text.count
            }
        }!
    }

    private func recognizer(_ id: String) throws -> SFSpeechRecognizer {
        if let r = recognizers[id] { return r }
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: id)) else {
            throw TranscriptionError.recognizerUnavailable(id)
        }
        recognizers[id] = r
        return r
    }

    // MARK: распознавание с таймаутом

    private struct Recognized: Sendable { let text: String; let confidence: Float; let hasConfidence: Bool }

    /// Распознаёт один файл с потолком по времени. Континюэйшн держим в боксе — резолвит ЛИБО handler
    /// (final/error), ЛИБО timeoutTask (после отмены SFSpeech-task), ровно один раз. Без таймаута зависший
    /// on-device движок заблокировал бы общую очередь обоих легов навсегда.
    private func recognizeOnce(_ rec: SFSpeechRecognizer, _ req: SFSpeechURLRecognitionRequest,
                               timeout: TimeInterval) async throws -> Recognized {
        let box = ContinuationBox<Recognized>()
        let taskBox = SpeechTaskBox()
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled {
                taskBox.cancel()                                   // прерываем SFSpeech (handler с error/cancel)
                box.resumeThrowing(TranscriptionError.timedOut)    // и сами резолвим — без зависания
            }
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Recognized, Error>) in
            box.set(cont)
            let t = rec.recognitionTask(with: req) { result, error in
                if let error {
                    box.resumeThrowing(TranscriptionError.failed(error.localizedDescription)); return
                }
                guard let result, result.isFinal else { return }
                let confs = result.bestTranscription.segments.map(\.confidence)
                box.resumeReturning(Recognized(
                    text: result.bestTranscription.formattedString,
                    confidence: confs.isEmpty ? 0 : confs.reduce(0, +) / Float(confs.count),
                    hasConfidence: confs.contains { $0 > 0 }))
            }
            taskBox.set(t)
        }
    }
}

/// Одноразовый резолв континюэйшна из нескольких источников (handler / timeout). Потокобезопасен.
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    func set(_ c: CheckedContinuation<T, Error>) { lock.lock(); cont = c; lock.unlock() }
    func resumeReturning(_ v: T) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(returning: v) }
    func resumeThrowing(_ e: Error) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(throwing: e) }
}

/// Держит SFSpeechRecognitionTask, чтобы отменить его по таймауту (non-Sendable → @unchecked).
private final class SpeechTaskBox: @unchecked Sendable {
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    func set(_ t: SFSpeechRecognitionTask) { lock.lock(); task = t; lock.unlock() }
    func cancel() { lock.lock(); let t = task; task = nil; lock.unlock(); t?.cancel() }
}
