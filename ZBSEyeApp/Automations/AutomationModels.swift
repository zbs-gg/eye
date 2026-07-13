import Foundation

/// Shared types of the automation layer (Step 9): connection config, automation safety limits,
/// intermediate daily-summary data, audit record. Everything is Sendable — it travels between the
/// @MainActor store, the actor service, and the network without sharing mutable state.

// MARK: connections

/// Request config for the active AI provider (built by AIProviderStore, not persisted itself).
/// Egress is default-deny: local providers must resolve to localhost; a cloud provider is allowed
/// exactly ONE host — its official API host — and sends history excerpts only after explicit consent.
struct LLMConfig: Sendable, Equatable {
    var provider: AIProvider
    var baseURL: String
    var model: String
    /// Persisted per-provider consent snapshot ("excerpts may leave this Mac"). Meaningless for local providers.
    var cloudConsented: Bool = false

    var isConfigured: Bool {
        switch provider.wire {
        case .builtInMLX, .codexAppServer, .claudeCodeCLI:
            return !model.trimmingCharacters(in: .whitespaces).isEmpty
        case .openAICompatible, .anthropicMessages:
            break
        }
        return !baseURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// baseURL with the scheme appended if the user entered "localhost:11434" / "127.0.0.1:11434" without http://
    /// (that's how Ollama/LM Studio display them — without a scheme URL.host = nil and the checks/endpoint broke).
    var normalizedBaseURL: String {
        let b = baseURL.trimmingCharacters(in: .whitespaces)
        if b.isEmpty || b.contains("://") { return b }
        return "http://" + b
    }

    /// Localhost whitelist (privacy — a local provider must never point off-box).
    /// host lowercased — DNS is case-insensitive (LOCALHOST → localhost).
    var isLocalOnly: Bool {
        guard let host = URL(string: normalizedBaseURL)?.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host)
    }

    /// Local provider → localhost only; cloud provider → exactly its pinned API host over https.
    /// A subprocess provider (Claude Code) has no HTTP endpoint to pin — the CLI owns its transport.
    var isEndpointAllowed: Bool {
        switch provider.wire {
        case .builtInMLX, .codexAppServer, .claudeCodeCLI:
            return true
        case .openAICompatible, .anthropicMessages:
            break
        }
        guard let url = URL(string: normalizedBaseURL), let host = url.host?.lowercased() else { return false }
        if let pinned = provider.apiHost { return host == pinned && url.scheme == "https" }
        if provider == .customAPI {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return false
            }
            return components.scheme?.lowercased() == "https"
                && !host.isEmpty
                && components.user == nil
                && components.password == nil
                && components.query == nil
                && components.fragment == nil
                && !components.percentEncodedPath.lowercased().contains("%2e")
        }
        if provider == .custom {
            return ["127.0.0.1", "::1"].contains(host)
        }
        return isLocalOnly
    }

    /// The single egress gate every request and every service goes through.
    /// requireModel=false for `/models` probes (no model chosen yet); requireConsent=false likewise —
    /// listing models sends no history, actual chat (history excerpts) always requires consent.
    func validate(requireModel: Bool = true, requireConsent: Bool = true) throws {
        switch provider.wire {
        case .builtInMLX:
            guard !requireModel || isConfigured else { throw AutomationError.noLLM }
            return
        case .codexAppServer, .claudeCodeCLI:
            guard !requireModel || isConfigured else { throw AutomationError.noLLM }
            if requireConsent, !cloudConsented {
                throw AutomationError.cloudConsentRequired(provider.displayName)
            }
            return
        case .openAICompatible, .anthropicMessages:
            break
        }
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !requireModel || isConfigured else { throw AutomationError.noLLM }
        guard isEndpointAllowed else {
            throw AutomationError.nonLocalLLM(URL(string: normalizedBaseURL)?.host ?? baseURL)
        }
        if provider.isCloud, requireConsent, !cloudConsented {
            throw AutomationError.cloudConsentRequired(provider.displayName)
        }
    }
}

/// Where to write summaries: a folder (security-scoped bookmark for resilience against being moved) + subfolder.
/// An Obsidian vault is just the same folder; "Obsidian" and "file export" are one mechanism in v1.
struct DestinationConfig: Codable, Sendable, Equatable {
    var bookmark: Data?
    var displayPath: String?
    var subfolder: String

    static let `default` = DestinationConfig(bookmark: nil, displayPath: nil, subfolder: "ZBS Eye")

    var isConfigured: Bool { bookmark != nil || displayPath != nil }
}

// MARK: automation safety limits

/// Hard caps: automation reads private history → LLM → write. We limit the input (how many sessions),
/// the sample length, the output, and the timeout. Protection against prompt-injection — delimiters +
/// local-only egress + a mandatory preview before the first write (see DaySummaryStore).
struct AutomationSafety: Sendable, Equatable {
    var maxInputSlices = 80
    var maxSampleChars = 360
    var maxOutputTokens = 800
    var requestTimeout: TimeInterval = 300   // a local model may load cold; stream:false = silent until done

    static let `default` = AutomationSafety()
}

// MARK: daily-summary data

/// One activity "session": consecutive frames of the same app/window (with a tolerance for a pause).
struct DaySlice: Sendable, Equatable {
    let start: Date
    let end: Date
    let app: String
    let window: String?
    let url: String?
    let sample: String        // representative text of the session (truncated to maxSampleChars)
    let captures: Int
}

/// Result of the collect stage: the selected sessions of the day + coverage metadata.
struct CollectedDay: Sendable {
    let day: Date
    let slices: [DaySlice]
    let totalCaptures: Int
    let totalSlices: Int       // before being trimmed by maxInputSlices
    var truncated: Bool { totalSlices > slices.count }
}

/// Result of the summarize stage (without writing). This is the preview.
struct SummaryPreview: Sendable {
    let day: Date
    let markdown: String
    let sessions: Int
    let totalCaptures: Int
    let model: String
    let promptChars: Int
    let truncated: Bool         // input was trimmed by maxInputSlices (a long day)
    let contextTruncated: Bool  // selected-model context ceiling compacted the chosen slices further
    let outputTruncated: Bool   // the model hit maxOutputTokens (finish_reason=length) → the summary is incomplete
    let provenance: AIExecutionProvenance
    let promptVersion: String
}

/// Result of the write stage.
struct WriteResult: Sendable {
    let path: String
    let bytes: Int
    let overwritten: Bool
}

// MARK: audit

/// An audit-log row (JSONL in Application Support/ZBS Eye/automation-audit.jsonl). A provable record of what
/// the automation read/wrote — a requirement of the plan (automation touches private data).
struct AuditEntry: Codable, Sendable, Identifiable {
    var id: String { "\(at.timeIntervalSince1970)-\(action)" }
    let at: Date
    let automation: String
    let day: String           // YYYY-MM-DD
    let action: String        // "preview" | "write"
    let model: String
    let sessions: Int
    let captures: Int
    let outputChars: Int
    let destPath: String?
    let ok: Bool
    let error: String?
    let providerID: String?
    let executedLocally: Bool?
    let promptVersion: String?
    let brokerUpstream: String?

    init(
        at: Date,
        automation: String,
        day: String,
        action: String,
        model: String,
        sessions: Int,
        captures: Int,
        outputChars: Int,
        destPath: String?,
        ok: Bool,
        error: String?,
        providerID: String? = nil,
        executedLocally: Bool? = nil,
        promptVersion: String? = nil,
        brokerUpstream: String? = nil
    ) {
        self.at = at
        self.automation = automation
        self.day = day
        self.action = action
        self.model = model
        self.sessions = sessions
        self.captures = captures
        self.outputChars = outputChars
        self.destPath = destPath
        self.ok = ok
        self.error = error
        self.providerID = providerID
        self.executedLocally = executedLocally
        self.promptVersion = promptVersion
        self.brokerUpstream = brokerUpstream
    }
}

// MARK: errors

enum AutomationError: LocalizedError {
    case noLLM
    case nonLocalLLM(String)
    case cloudConsentRequired(String)
    case noAPIKey(String)
    case noDestination
    case noData(day: Date)
    case llm(String)
    case write(String)

    var errorDescription: String? {
        switch self {
        case .noLLM:
            return "AI is off. Add AI in Settings to generate a summary."
        case .nonLocalLLM(let host):
            return "Endpoint \"\(host)\" is not allowed. Local providers must stay on 127.0.0.1/localhost; a cloud provider is reachable only via its official API host."
        case .cloudConsentRequired(let name):
            return "\(name) is a cloud provider. Confirm in AI settings that text excerpts may be sent to it."
        case .noAPIKey(let name):
            return "\(name) needs an API key — add it in AI settings (stored in the Keychain)."
        case .noDestination:
            return "No folder selected for writing. Open \"Automations\" → \"Destination\"."
        case .noData(let day):
            let f = DateFormatter(); f.dateStyle = .medium; f.locale = Locale(identifier: "en_US")
            return "No recorded activity for \(f.string(from: day))."
        case .llm(let m):
            return "Model error: \(m)"
        case .write(let m):
            return "Failed to write the file: \(m)"
        }
    }
}

// MARK: location of configs/log

enum ZBSEyeSupport {
    /// Data root (the same folder where zbseye.sqlite and media/ live) — via StorageLocation (accounts for relocate).
    static func directory() throws -> URL {
        StorageLocation.dataRoot()
    }

    static func auditLogURL() throws -> URL {
        try directory().appendingPathComponent("automation-audit.jsonl")
    }
}
