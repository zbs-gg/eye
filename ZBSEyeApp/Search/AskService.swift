import Foundation
import GRDB

/// "Ask your memory" (actor): a retrieval-augmented answer ENTIRELY on-device. Takes a question →
/// hybrid search (FTS+semantic, cross-lingual) over screen and conversation history → assembles
/// numbered context with dates/sources → a local LLM answers STRICTLY from the context with
/// [n] citations. No egress: the same local-only LLM the automations use (AutomationError
/// gates non-localhost). Sources are returned to the caller — a click jumps to that moment in the timeline.
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
        let truncated: Bool          // model hit maxOutputTokens — answer is incomplete
        let sources: [SearchResult]  // what made it into the context (for [n] citations and jumping into the timeline)
    }

    /// One question → answer. Throws AutomationError (.noLLM/.nonLocalLLM/.llm) — the UI shows them as-is.
    func answer(question: String, llm: LLMConfig,
                safety: AutomationSafety = .default) async throws -> Answer {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return Answer(text: "", truncated: false, sources: []) }
        guard llm.isConfigured else { throw AutomationError.noLLM }
        guard llm.isLocalOnly else { throw AutomationError.nonLocalLLM(URL(string: llm.normalizedBaseURL)?.host ?? llm.baseURL) }

        // Retrieval window: the top dozen hits — enough to answer, fits in the model's context.
        let hits = try await search.search(query: q, filters: SearchFilters(limit: 10))
        guard !hits.isEmpty else {
            return Answer(text: "Nothing in your history matched this query. Try rephrasing it — "
                          + "search understands meaning too (cross-lingual), not just exact words.",
                          truncated: false, sources: [])
        }

        // Context: a fuller text of each source (not a 12-word snippet) with date and source, truncated.
        let excerpts = try await excerpts(for: hits, maxChars: safety.maxSampleChars)
        let context = excerpts.enumerated().map { i, e in "[\(i + 1)] \(e)" }.joined(separator: "\n")

        let system = """
        You are the ZBS Eye memory assistant. Answer the user's question relying ONLY on the provided \
        fragments of their own screen and conversation history. Fragments are marked [n] with date and source. \
        Cite the [n] numbers that support your answer. If the fragments contain no answer, honestly say \
        you didn't find it and suggest refining the query. Don't make anything up. Answer briefly and to the point, in the language of the question.
        """
        let user = "Question: \(q)\n\nHistory fragments (most relevant first):\n\(context)"

        let out = try await client.chat(llm, system: system, user: user,
                                         maxTokens: safety.maxOutputTokens, timeout: safety.requestTimeout)
        return Answer(text: out.content.trimmingCharacters(in: .whitespacesAndNewlines),
                      truncated: out.truncated, sources: hits)
    }

    /// For each hit — a "date · source — text" line. Text: a fuller selection from the DB (screen —
    /// concatenated text_blocks; audio — transcript), truncated to maxChars. Source unavailable → snippet.
    private func excerpts(for hits: [SearchResult], maxChars: Int) async throws -> [String] {
        try await db.pool.read { dbc in
            // df local inside the @Sendable closure (DateFormatter isn't Sendable — can't capture it from outside).
            let df = DateFormatter()
            df.locale = Locale(identifier: "ru_RU")
            df.dateFormat = "d MMM, HH:mm"
            return hits.map { r in
                let when = df.string(from: r.ts)
                let label: String
                let raw: String
                switch r.kind {
                case .screen:
                    let app = r.appName ?? r.bundleId ?? "screen"
                    label = [app, r.windowTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
                    raw = (try? String.fetchOne(dbc, sql:
                        "SELECT group_concat(text, ' ') FROM text_blocks WHERE captureId = ?",
                        arguments: [r.id])) ?? r.snippet
                case .audio:
                    label = r.appName ?? "Audio"   // for an audio result appName is already = channel label (me/other)
                    raw = (try? String.fetchOne(dbc, sql:
                        "SELECT group_concat(text, ' ') FROM transcriptions WHERE audioId = ?",
                        arguments: [r.id])) ?? r.snippet
                }
                let text = Self.clean(raw, maxChars: maxChars)
                return "\(when) · \(label.isEmpty ? "—" : label) — \(text)"
            }
        }
    }

    /// Normalize the selection for context: collapse spaces/newlines, truncate by words.
    private static func clean(_ s: String, maxChars: Int) -> String {
        let collapsed = s.split(whereSeparator: { $0 == "\n" || $0 == "\t" || $0 == " " })
            .joined(separator: " ")
        guard collapsed.count > maxChars else { return collapsed }
        return String(collapsed.prefix(maxChars)) + "…"
    }
}
