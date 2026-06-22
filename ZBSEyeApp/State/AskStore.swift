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
        if let egg = Self.easterEgg(q) {                    // 🥚 пасхалка: личность Глаза, без LLM
            messages.append(Message(role: .assistant, text: egg))
            return
        }
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

    /// 🥚 Пасхалки — УЗКИЕ триггеры, чтобы не перехватывать реальные вопросы. Глаз с характером, и
    /// каждый ответ тихо напоминает суть продукта: «вижу только для тебя, никуда не отправляю».
    private static func easterEgg(_ q: String) -> String? {
        let s = q.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ?!.,…"))
        switch s {
        case "кукареку", "ко-ко-ко":
            return "Ко-ко-ко 🥚 Пасхалку нашёл. Я всё вижу — но только для тебя. 👁"
        case "кто ты", "ты кто", "who are you":
            return "Я — Глаз. Твоя память на этом Mac. У меня нет рук, нет облака и некуда что-то отправить — поэтому всё, что я вижу, остаётся только у тебя. 👁"
        case "ты следишь за мной", "ты за мной следишь", "ты шпион", "ты шпионишь":
            return "Слежка — это когда смотрят ЗА тебя для кого-то ещё. Я смотрю ТОЛЬКО для тебя и никому не докладываю: ноль исходящих, проверь в Little Snitch. 👁"
        case "42", "смысл жизни", "в чём смысл жизни":
            return "Ответ — где-то в твоей истории. Спроси конкретнее 👁"
        case "👁", "глаз", "моргни":
            return "👁 … 👁 (моргнул)"
        case "люблю тебя", "i love you":
            return "И я тебя помню. Каждый момент. 👁"
        default:
            return nil
        }
    }
}
