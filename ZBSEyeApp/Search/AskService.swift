import Foundation
import GRDB

/// «Спроси свою память» (actor): retrieval-augmented ответ ПОЛНОСТЬЮ на устройстве. Берёт вопрос →
/// гибридный поиск (FTS+semantic, cross-lingual) по истории экрана и разговоров → собирает
/// пронумерованный контекст с датами/источниками → локальная LLM отвечает СТРОГО по контексту с
/// ссылками [n]. Никакого egress: та же локальная-only LLM, что и у автоматизаций (AutomationError
/// гейтит не-localhost). Источники возвращаем наружу — клик ведёт в таймлайн к моменту.
actor AskService {
    private let search: SearchService
    private let client: LocalLLMClient
    private let db: ZBSEyeDatabase

    init(search: SearchService, client: LocalLLMClient, db: ZBSEyeDatabase) {
        self.search = search
        self.client = client
        self.db = db
    }

    struct Answer: Sendable {
        let text: String
        let truncated: Bool          // модель упёрлась в maxOutputTokens — ответ неполный
        let sources: [SearchResult]  // что попало в контекст (для ссылок [n] и перехода в таймлайн)
    }

    /// Один вопрос → ответ. Бросает AutomationError (.noLLM/.nonLocalLLM/.llm) — UI их показывает как есть.
    func answer(question: String, llm: LLMConfig,
                safety: AutomationSafety = .default) async throws -> Answer {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Answer(text: "", truncated: false, sources: []) }
        guard llm.isConfigured else { throw AutomationError.noLLM }
        guard llm.isLocalOnly else { throw AutomationError.nonLocalLLM(URL(string: llm.normalizedBaseURL)?.host ?? llm.baseURL) }

        // Окно retrieval: десяток лучших хитов — достаточно для ответа, помещается в контекст модели.
        let hits = try await search.search(query: q, filters: SearchFilters(limit: 10))
        guard !hits.isEmpty else {
            return Answer(text: "В истории не нашлось ничего по этому запросу. Попробуй переформулировать — "
                          + "поиск понимает и смысл (cross-lingual), не только точные слова.",
                          truncated: false, sources: [])
        }

        // Контекст: фуллер-текст каждого источника (не 12-словный сниппет) с датой и источником, усечён.
        let excerpts = try await excerpts(for: hits, maxChars: safety.maxSampleChars)
        let context = excerpts.enumerated().map { i, e in "[\(i + 1)] \(e)" }.joined(separator: "\n")

        let system = """
        Ты — ассистент памяти ZBS Eye. Отвечай на вопрос пользователя, опираясь ТОЛЬКО на приведённые \
        фрагменты его собственной истории экрана и разговоров. Фрагменты помечены [n] с датой и источником. \
        Ссылайся на номера [n], которые подтверждают ответ. Если во фрагментах нет ответа — честно скажи, \
        что не нашёл, и предложи уточнить запрос. Ничего не выдумывай. Отвечай кратко и по делу, на языке вопроса.
        """
        let user = "Вопрос: \(q)\n\nФрагменты истории (от самого релевантного):\n\(context)"

        let out = try await client.chat(llm, system: system, user: user,
                                         maxTokens: safety.maxOutputTokens, timeout: safety.requestTimeout)
        return Answer(text: out.content.trimmingCharacters(in: .whitespacesAndNewlines),
                      truncated: out.truncated, sources: hits)
    }

    /// Для каждого хита — строка «дата · источник — текст». Текст: фуллер-выборка из БД (экран —
    /// склейка text_blocks; аудио — транскрипт), усечённая до maxChars. Источник недоступен → сниппет.
    private func excerpts(for hits: [SearchResult], maxChars: Int) async throws -> [String] {
        try await db.pool.read { dbc in
            // df локально внутри @Sendable-замыкания (DateFormatter не Sendable — нельзя захватывать снаружи).
            let df = DateFormatter()
            df.locale = Locale(identifier: "ru_RU")
            df.dateFormat = "d MMM, HH:mm"
            return hits.map { r in
                let when = df.string(from: r.ts)
                let label: String
                let raw: String
                switch r.kind {
                case .screen:
                    let app = r.appName ?? r.bundleId ?? "экран"
                    label = [app, r.windowTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
                    raw = (try? String.fetchOne(dbc, sql:
                        "SELECT group_concat(text, ' ') FROM text_blocks WHERE captureId = ?",
                        arguments: [r.id])) ?? r.snippet
                case .audio:
                    label = r.appName ?? "Аудио"   // у аудио-результата appName уже = лейбл канала (я/собеседник)
                    raw = (try? String.fetchOne(dbc, sql:
                        "SELECT group_concat(text, ' ') FROM transcriptions WHERE audioId = ?",
                        arguments: [r.id])) ?? r.snippet
                }
                let text = Self.clean(raw, maxChars: maxChars)
                return "\(when) · \(label.isEmpty ? "—" : label) — \(text)"
            }
        }
    }

    /// Нормализуем выборку под контекст: схлопываем пробелы/переводы строк, усечение по словам.
    private static func clean(_ s: String, maxChars: Int) -> String {
        let collapsed = s.split(whereSeparator: { $0 == "\n" || $0 == "\t" || $0 == " " })
            .joined(separator: " ")
        guard collapsed.count > maxChars else { return collapsed }
        return String(collapsed.prefix(maxChars)) + "…"
    }
}
