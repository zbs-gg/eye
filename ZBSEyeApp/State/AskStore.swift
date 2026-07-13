import Foundation
import Observation

/// Main-actor state for Ask. Generation belongs to the process-wide router;
/// the store owns only user-visible request identity and refuses to paint a
/// completion after clear, a newer request, or a selection/authorization change.
@MainActor
@Observable
final class AskStore {
    struct Message: Identifiable, Sendable {
        enum Role: Sendable, Equatable { case user, assistant }

        let id = UUID()
        let role: Role
        var text: String
        var sources: [SearchResult] = []
        var truncated = false
        var contextTruncated = false
        var provenance: AIExecutionProvenance?
        var scope: AskScopeSnapshot?
    }

    private(set) var messages: [Message] = []
    var input: String = ""
    private(set) var busy = false

    @ObservationIgnored private let service: any AskAnswering
    @ObservationIgnored private let readiness: any AskReadinessProviding
    @ObservationIgnored private let workspace: WorkspaceStore?
    @ObservationIgnored private let onQuestionSent: @MainActor @Sendable () -> Void
    @ObservationIgnored private var activeRequestID: UUID?
    @ObservationIgnored private var activeTask: Task<Void, Never>?

    init(
        service: any AskAnswering,
        readiness: any AskReadinessProviding,
        workspace: WorkspaceStore? = nil,
        onQuestionSent: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.service = service
        self.readiness = readiness
        self.workspace = workspace
        self.onQuestionSent = onQuestionSent
    }

    /// Consumer-scoped readiness. Reading this property never loads a model or
    /// dispatches generation.
    var llmReady: Bool { readiness.currentAskExecutionContext() != nil }

    var canSend: Bool {
        !busy && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Compatibility-only stores without a workspace retain legacy all-history.
    /// The application always injects its single WorkspaceStore.
    var currentScope: AskScopeSnapshot {
        workspace?.captureAskScope() ?? .allHistory
    }

    /// Truthful copy for the currently authorized Ask selection. Cloud is
    /// described as cloud even if another provider happened to be local before.
    var executionDisclosure: String {
        guard let execution = readiness.currentAskExecutionContext() else {
            return String(localized: "Add AI before asking your history.")
        }
        if execution.executedLocally {
            return String(localized: "Answers with \(execution.selection.modelID) stay on this Mac.")
        }
        let recipient = execution.recipientDisclosure ?? execution.selection.providerID
        return String(localized: "History excerpts are sent to \(recipient) for answers from \(execution.selection.modelID).")
    }

    func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !question.isEmpty else { return }
        let scope = currentScope

        if let egg = Self.easterEgg(question) {
            input = ""
            messages.append(Message(role: .user, text: question, scope: scope))
            messages.append(Message(role: .assistant, text: egg, scope: scope))
            onQuestionSent()
            return
        }
        guard let execution = readiness.currentAskExecutionContext() else {
            // U4 presents Add AI from this state. Keep both the draft and the
            // workspace scope untouched while setup opens or is dismissed.
            return
        }

        input = ""
        messages.append(Message(role: .user, text: question, scope: scope))
        onQuestionSent()
        let requestID = UUID()
        activeRequestID = requestID
        busy = true
        let service = self.service
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activeRequestID == requestID {
                    self.activeRequestID = nil
                    self.activeTask = nil
                    self.busy = false
                }
            }

            do {
                let answer = try await service.answer(
                    question: question,
                    scope: scope,
                    execution: execution,
                    requestID: requestID,
                    limits: .default
                )
                guard self.mayPaint(requestID: requestID, execution: execution) else {
                    return
                }
                if let provenance = answer.provenance,
                   !Self.provenance(provenance, matches: execution) {
                    return
                }
                self.messages.append(Message(
                    role: .assistant,
                    text: answer.text,
                    sources: answer.sources,
                    truncated: answer.truncated,
                    contextTruncated: answer.contextTruncated,
                    provenance: answer.provenance,
                    scope: scope
                ))
            } catch is CancellationError {
                return
            } catch {
                guard self.mayPaint(requestID: requestID, execution: execution) else {
                    return
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "The selected model could not answer.")
                self.messages.append(Message(
                    role: .assistant,
                    text: String(localized: "⚠️ \(message)"),
                    scope: scope
                ))
            }
        }
    }

    func clear() {
        activeRequestID = nil
        activeTask?.cancel()
        activeTask = nil
        busy = false
        messages.removeAll()
    }

    /// Retrying is a new explicit send, so it intentionally captures the scope
    /// currently visible in the workspace rather than the previous snapshot.
    func retryLastQuestion() {
        guard !busy,
              let question = messages.last(where: { $0.role == .user })?.text
        else { return }
        input = question
        send()
    }

    private func mayPaint(
        requestID: UUID,
        execution: AskExecutionContext
    ) -> Bool {
        guard activeRequestID == requestID,
              let current = readiness.currentAskExecutionContext() else {
            return false
        }
        return current == execution
    }

    private static func provenance(
        _ provenance: AIExecutionProvenance,
        matches execution: AskExecutionContext
    ) -> Bool {
        provenance.providerID == execution.selection.providerID
            && provenance.modelID == execution.selection.modelID
            && provenance.executedLocally == execution.executedLocally
    }

    private static func easterEgg(_ question: String) -> String? {
        let normalized = question.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: " ?!.,…")
        )
        switch normalized {
        case "cock-a-doodle-doo", "cluck-cluck":
            return String(localized: "Cluck-cluck 🥚 You found the easter egg. I see everything — but only for you. 👁")
        case "who are you", "who're you":
            return String(localized: "I'm the Eye. Capture and memory stay on this Mac. For generated answers I use the model you chose; a cloud provider receives excerpts only after your explicit consent. 👁")
        case "are you watching me", "you're watching me", "you're a spy", "are you spying on me":
            return String(localized: "Capture and stored memory stay on this Mac for you. Ask shows exactly which selected model generated an answer and whether consented excerpts went to cloud. 👁")
        case "42", "the meaning of life", "what is the meaning of life":
            return String(localized: "The answer is somewhere in your history. Ask more specifically 👁")
        case "👁", "eye", "blink":
            return String(localized: "👁 … 👁 (blinked)")
        case "i love you", "love you":
            return String(localized: "And I remember you. Every moment. 👁")
        default:
            return nil
        }
    }
}
