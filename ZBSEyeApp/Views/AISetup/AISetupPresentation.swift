import Foundation
import Observation

enum AISetupPath: String, Sendable, CaseIterable, Identifiable {
    case onThisMac
    case accountOrCode
    case apiProvider

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onThisMac: return String(localized: "On this Mac")
        case .accountOrCode: return String(localized: "Account or Code")
        case .apiProvider: return String(localized: "API Provider")
        }
    }
}

enum AISetupOrigin: Sendable, Equatable {
    case ask
    case settings

    var consentConsumers: Set<AIConsumer> {
        switch self {
        case .ask: return [.ask]
        case .settings: return Set(AIConsumer.allCases.filter { !$0.isAutomatic })
        }
    }
}

struct AISetupOperationToken: Sendable, Equatable {
    fileprivate let sessionID: UUID
    fileprivate let revision: UInt64
}

/// One app-lifetime presentation owner. Opening the sheet is pure state: all
/// discovery, auth, and catalog work begins only after a provider action.
@MainActor
@Observable
final class AISetupPresentation {
    private(set) var isPresented = false
    private(set) var sessionID: UUID?
    private(set) var origin: AISetupOrigin?
    var selectedPath: AISetupPath = .onThisMac {
        didSet {
            guard selectedPath != oldValue else { return }
            selectedProvider = nil
        }
    }
    var selectedProvider: AIProvider?
    private(set) var activationError: String?

    @ObservationIgnored private var ephemeralTask: Task<Void, Never>?
    @ObservationIgnored private var operationRevision: UInt64 = 0

    static func providers(for path: AISetupPath) -> [AIProvider] {
        switch path {
        case .onThisMac:
            return [.zbsEyeLocal, .ollama, .lmstudio, .custom]
        case .accountOrCode:
            return [.codex, .claudeCode]
        case .apiProvider:
            return [.openrouter, .anthropic, .moonshot, .zai, .xiaomi, .openai, .customAPI]
        }
    }

    static func activeLabel(provider: AIProvider?, modelID: String?) -> String {
        guard let provider,
              let modelID,
              !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "AI Off")
        }
        return "\(provider.displayName) · \(modelID)"
    }

    var hasEphemeralWork: Bool { ephemeralTask != nil }

    @discardableResult
    func present(origin requestedOrigin: AISetupOrigin) -> UUID {
        if isPresented, let sessionID { return sessionID }
        let id = UUID()
        sessionID = id
        origin = requestedOrigin
        selectedPath = .onThisMac
        selectedProvider = nil
        activationError = nil
        isPresented = true
        return id
    }

    func dismiss(sessionID expectedSessionID: UUID? = nil) {
        guard isPresented,
              expectedSessionID == nil || expectedSessionID == sessionID else { return }
        operationRevision &+= 1
        ephemeralTask?.cancel()
        ephemeralTask = nil
        isPresented = false
        sessionID = nil
        origin = nil
        selectedProvider = nil
        activationError = nil
    }

    func beginEphemeralOperation(sessionID expectedSessionID: UUID) -> AISetupOperationToken? {
        guard isPresented, sessionID == expectedSessionID else { return nil }
        operationRevision &+= 1
        ephemeralTask?.cancel()
        ephemeralTask = nil
        return AISetupOperationToken(
            sessionID: expectedSessionID,
            revision: operationRevision
        )
    }

    func mayComplete(_ token: AISetupOperationToken) -> Bool {
        isPresented
            && sessionID == token.sessionID
            && operationRevision == token.revision
            && !Task.isCancelled
    }

    func runEphemeral(
        sessionID expectedSessionID: UUID,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        guard let token = beginEphemeralOperation(sessionID: expectedSessionID) else { return }
        ephemeralTask = Task { @MainActor [weak self] in
            await operation()
            guard let self, self.mayComplete(token) else { return }
            self.ephemeralTask = nil
        }
    }

    func setActivationError(_ message: String?) {
        activationError = message
    }
}

extension AISetupPresentation {
    static func modelShortName(_ modelID: String, provider: AIProvider) -> String {
        if provider == .zbsEyeLocal,
           modelID == BuiltInModelManifest.regular.id {
            return BuiltInModelManifest.regular.displayName
        }
        if provider == .claudeCode,
           modelID == AIProvider.claudeCodeDefaultModel {
            return String(localized: "Provider default")
        }
        let component = modelID.split(separator: "/").last.map(String.init) ?? modelID
        return component.isEmpty ? modelID : component
    }
}
