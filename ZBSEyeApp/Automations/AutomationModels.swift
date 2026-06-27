import Foundation

/// Shared types of the automation layer (Step 9): connection config, automation safety limits,
/// intermediate daily-summary data, audit record. Everything is Sendable — it travels between the
/// @MainActor store, the actor service, and the network without sharing mutable state.

// MARK: connections

/// Local LLM over the OpenAI-compatible `/chat/completions` (Ollama, LM Studio, mlx_lm.server,
/// llama.cpp server). One interface for all of them — they differ only in baseURL/port and model name.
/// NO cloud egress: the default is hard-pinned to 127.0.0.1.
struct LLMConfig: Codable, Sendable, Equatable {
    var baseURL: String
    var model: String

    static let `default` = LLMConfig(baseURL: "http://127.0.0.1:11434/v1", model: "llama3.2")

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// baseURL with the scheme appended if the user entered "localhost:11434" / "127.0.0.1:11434" without http://
    /// (that's how Ollama/LM Studio display them — without a scheme URL.host = nil and the checks/endpoint broke).
    var normalizedBaseURL: String {
        let b = baseURL.trimmingCharacters(in: .whitespaces)
        if b.isEmpty || b.contains("://") { return b }
        return "http://" + b
    }

    /// Only localhost is allowed in v1 (privacy — private history must not leak to the cloud).
    /// host lowercased — DNS is case-insensitive (LOCALHOST → localhost).
    var isLocalOnly: Bool {
        guard let host = URL(string: normalizedBaseURL)?.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host)
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
    let outputTruncated: Bool   // the model hit maxOutputTokens (finish_reason=length) → the summary is incomplete
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
}

// MARK: errors

enum AutomationError: LocalizedError {
    case noLLM
    case nonLocalLLM(String)
    case noDestination
    case noData(day: Date)
    case llm(String)
    case write(String)

    var errorDescription: String? {
        switch self {
        case .noLLM:
            return "Local LLM is not configured. Open \"Connections\" and specify an endpoint + model."
        case .nonLocalLLM(let host):
            return "Endpoint \"\(host)\" is not local. In v1 only 127.0.0.1/localhost is allowed — private history does not leave for the cloud."
        case .noDestination:
            return "No folder selected for writing. Open \"Connections\" → \"Destination\"."
        case .noData(let day):
            let f = DateFormatter(); f.dateStyle = .medium; f.locale = Locale(identifier: "en_US")
            return "No recorded activity for \(f.string(from: day))."
        case .llm(let m):
            return "Local model error: \(m)"
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
