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
        case .recognizerUnavailable(let l): return "Speech recognizer unavailable for locale \(l)."
        case .onDeviceUnavailable(let l):   return "No on-device speech model for \(l) — enable Dictation in System Settings."
        case .notAuthorized:                return "No permission for speech recognition."
        case .empty:                        return "Empty recognition result."
        case .lowConfidence:                return "Low recognition confidence (likely noise) — skipped."
        case .timedOut:                     return "Recognition timed out."
        case .failed(let m):                return "Recognition error: \(m)"
        }
    }
    /// Short type for health/UI (to distinguish a config problem from a transient one).
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

/// Swappable transcription backend (plan: light default + an MLX Quality mode later behind this protocol).
protocol TranscriptionBackend: Sendable {
    var engineName: String { get }
    /// Tries the locales and returns the result with the best language match (auto-detect). timeout — the cap
    /// on recognizing a single locale (protection against a hung on-device engine).
    func transcribe(fileURL: URL, localeIdentifiers: [String],
                    minConfidence: Float, timeout: TimeInterval) async throws -> Transcript
    func unload() async
}

/// On-device Apple Speech. 100% local (requiresOnDeviceRecognition=true). File mode (URL request) —
/// for VAD segments. Recognizers are cached per locale; unloading — TranscriptionService on idle.
actor SFSpeechBackend: TranscriptionBackend {
    nonisolated let engineName = "sfspeech"
    private var recognizers: [String: SFSpeechRecognizer] = [:]

    func transcribe(fileURL: URL, localeIdentifiers: [String],
                    minConfidence: Float, timeout: TimeInterval) async throws -> Transcript {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw TranscriptionError.notAuthorized }

        // We run the file through the locales and pick by LANGUAGE MATCH (NLLanguageRecognizer), NOT by
        // confidence: on-device SFSpeech routinely returns confidence 0 on correct text — you can't use it
        // to compare locales or to filter (otherwise we'd lose everything). We use confidence only as a
        // secondary signal to filter obvious noise, and only when it's actually > 0.
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
                // short-circuit: language matched and (no confidence OR it's above threshold) → don't run the second locale.
                if match, (r.hasConfidence ? r.confidence : 1) >= minConfidence { break }
            } catch {
                lastFail = (error as? TranscriptionError) ?? .failed("\(error)")
            }
        }

        guard !candidates.isEmpty else {
            // onDeviceUnavailable — only if ALL locales really have no on-device model (honest health).
            if unavailableCount == localeIdentifiers.count, unavailableCount > 0 {
                throw TranscriptionError.onDeviceUnavailable(localeIdentifiers.joined(separator: ","))
            }
            throw lastFail ?? TranscriptionError.empty
        }

        let best = Self.pickBest(candidates)
        // We apply the filter gate ONLY when confidence is real (>0); on unknown we don't drop.
        if let s = best.score, s < minConfidence { throw TranscriptionError.lowConfidence }
        return Transcript(text: best.text, language: best.locale, engine: engineName)
    }

    func unload() { recognizers.removeAll() }

    // MARK: candidate selection

    private struct Candidate { let text: String; let score: Float?; let locale: String; let langMatch: Bool }

    /// Whether the recognized language matches the recognizer's locale ("ru-RU" → "ru").
    static func languageMatches(_ text: String, locale: String) -> Bool {
        guard let lang = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue else { return false }
        return lang.lowercased().hasPrefix(String(locale.prefix(2)).lowercased())
    }

    /// Among those matching by language (or all, if none matched): max confidence, on unknown — the longest.
    private static func pickBest(_ c: [Candidate]) -> Candidate {
        let matched = c.filter { $0.langMatch }
        let pool = matched.isEmpty ? c : matched
        return pool.max { a, b in
            switch (a.score, b.score) {
            case let (sa?, sb?): return sa < sb
            case (nil, _?):      return true       // b has a score, a doesn't → b is better
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

    // MARK: recognition with a timeout

    private struct Recognized: Sendable { let text: String; let confidence: Float; let hasConfidence: Bool }

    /// Recognizes one file with a time cap. We hold the continuation in a box — it's resolved EITHER by the
    /// handler (final/error) OR by timeoutTask (after cancelling the SFSpeech task), exactly once. Without a
    /// timeout a hung on-device engine would block the shared queue of both legs forever.
    private func recognizeOnce(_ rec: SFSpeechRecognizer, _ req: SFSpeechURLRecognitionRequest,
                               timeout: TimeInterval) async throws -> Recognized {
        let box = ContinuationBox<Recognized>()
        let taskBox = SpeechTaskBox()
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled {
                taskBox.cancel()                                   // interrupt SFSpeech (handler with error/cancel)
                box.resumeThrowing(TranscriptionError.timedOut)    // and resolve ourselves — no hang
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

/// One-shot resolution of a continuation from several sources (handler / timeout). Thread-safe.
private final class ContinuationBox<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Error>?
    private let lock = NSLock()
    func set(_ c: CheckedContinuation<T, Error>) { lock.lock(); cont = c; lock.unlock() }
    func resumeReturning(_ v: T) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(returning: v) }
    func resumeThrowing(_ e: Error) { lock.lock(); let c = cont; cont = nil; lock.unlock(); c?.resume(throwing: e) }
}

/// Holds the SFSpeechRecognitionTask so it can be cancelled on timeout (non-Sendable → @unchecked).
private final class SpeechTaskBox: @unchecked Sendable {
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    func set(_ t: SFSpeechRecognitionTask) { lock.lock(); task = t; lock.unlock() }
    func cancel() { lock.lock(); let t = task; task = nil; lock.unlock(); t?.cancel() }
}
