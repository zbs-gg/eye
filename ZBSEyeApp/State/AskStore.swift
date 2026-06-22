import Foundation
import Observation

/// UI-состояние раздела «Спроси» (@MainActor @Observable): лента диалога + ввод. Сам RAG-ответ считает
/// AskService (actor); стор только оркеструет (гейт «настроена ли локальная LLM», busy, ошибки) и держит
/// сообщения для ленты. Никакого egress — гейт на localhost внутри AskService/LocalLLMClient.
@MainActor
@Observable
final class AskStore {
    struct Message: Identifiable, Sendable {
        enum Role: Sendable { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        var sources: [SearchResult] = []
        var truncated = false
    }

    private(set) var messages: [Message] = []
    var input: String = ""
    private(set) var busy = false

    @ObservationIgnored private let service: AskService
    @ObservationIgnored private let connections: ConnectionStore

    init(service: AskService, connections: ConnectionStore) {
        self.service = service
        self.connections = connections
    }

    /// Настроена ли локальная LLM (иначе раздел показывает подсказку вместо ввода).
    var llmReady: Bool { connections.llm.isConfigured && connections.llm.isLocalOnly }
    var canSend: Bool { !busy && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !q.isEmpty else { return }
        input = ""
        messages.append(Message(role: .user, text: q))
        busy = true
        let llm = connections.llm
        Task {
            defer { busy = false }
            do {
                let a = try await service.answer(question: q, llm: llm)
                messages.append(Message(role: .assistant, text: a.text,
                                        sources: a.sources, truncated: a.truncated))
            } catch {
                let msg = (error as? AutomationError)?.errorDescription ?? error.localizedDescription
                messages.append(Message(role: .assistant, text: "⚠️ \(msg)"))
            }
        }
    }

    func clear() { messages.removeAll() }
}
