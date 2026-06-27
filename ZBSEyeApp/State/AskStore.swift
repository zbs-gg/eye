import Foundation
import Observation

/// UI state for the "Ask" section (@MainActor @Observable): the conversation feed + input. The RAG answer itself is
/// computed by AskService (actor); the store only orchestrates (the gate "is a local LLM configured", busy, errors) and
/// holds the messages for the feed. No egress — the localhost gate lives inside AskService/LocalLLMClient.
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

    /// Whether a local LLM is configured (otherwise the section shows a hint instead of the input).
    var llmReady: Bool { connections.llm.isConfigured && connections.llm.isLocalOnly }
    var canSend: Bool { !busy && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !q.isEmpty else { return }
        input = ""
        messages.append(Message(role: .user, text: q))
        AchievementCounters.bump(.questions)                // achievements "First question"/"Interrogator"
        if let egg = Self.easterEgg(q) {                    // 🥚 easter egg: the Eye's personality, works even without an LLM
            messages.append(Message(role: .assistant, text: egg))
            return
        }
        guard llmReady else {                               // a real question without an LLM → friendly hint
            messages.append(Message(role: .assistant, text: "To answer from your history I need a local "
                + "LLM (Ollama / LM Studio / mlx_lm.server) — set an endpoint in Connections. Everything stays on-device, no cloud. 👁"))
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

    /// 🥚 Easter eggs — NARROW triggers, so they don't intercept real questions. An Eye with character, and
    /// every reply quietly restates the product's point: "I see only for you, I send nothing anywhere".
    private static func easterEgg(_ q: String) -> String? {
        let s = q.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ?!.,…"))
        switch s {
        case "cock-a-doodle-doo", "cluck-cluck":
            return "Cluck-cluck 🥚 You found the easter egg. I see everything — but only for you. 👁"
        case "who are you", "who're you":
            return "I'm the Eye. Your memory on this Mac. I have no hands, no cloud, and nowhere to send anything — so everything I see stays only with you. 👁"
        case "are you watching me", "you're watching me", "you're a spy", "are you spying on me":
            return "Surveillance is when someone watches FOR someone else. I watch ONLY for you and report to no one: zero outbound, check it in Little Snitch. 👁"
        case "42", "the meaning of life", "what is the meaning of life":
            return "The answer is somewhere in your history. Ask more specifically 👁"
        case "👁", "eye", "blink":
            return "👁 … 👁 (blinked)"
        case "i love you", "love you":
            return "And I remember you. Every moment. 👁"
        default:
            return nil
        }
    }
}
