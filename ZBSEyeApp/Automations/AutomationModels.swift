import Foundation

struct ReviewSchedulePreferenceMigrationResult: Equatable {
    let enabled: Bool
    let shouldPersistEnabled: Bool
    let seededLastAutoDone: String?
}

enum ReviewSchedulePreferenceMigration {
    static func resolve(
        explicitReviewEnabled: Bool?,
        legacyEnabled: Bool,
        lastAutoDone: String?,
        latestDueKey: String?
    ) -> ReviewSchedulePreferenceMigrationResult {
        if let explicitReviewEnabled {
            return .init(
                enabled: explicitReviewEnabled,
                shouldPersistEnabled: false,
                seededLastAutoDone: nil
            )
        }
        return .init(
            enabled: legacyEnabled,
            shouldPersistEnabled: true,
            seededLastAutoDone: legacyEnabled && lastAutoDone == nil ? latestDueKey : nil
        )
    }
}

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

enum ReviewPeriodKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case day
    case week

    var id: String { rawValue }
    var displayName: String { self == .day ? "Day" : "7 days" }
}

struct ReviewPeriod: Codable, Sendable, Equatable, Hashable {
    let kind: ReviewPeriodKind
    let start: Date
    let end: Date

    static func ending(at date: Date, kind: ReviewPeriodKind, calendar: Calendar = .current) -> Self {
        let dayStart = calendar.startOfDay(for: date)
        let start = kind == .day
            ? dayStart
            : (calendar.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart)
        let naturalEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        return Self(kind: kind, start: start, end: naturalEnd)
    }

    var startMs: Int64 { msFromDate(start) }
    var endMs: Int64 { msFromDate(end) }
}

enum ReviewScheduleFrequency: String, Codable, Sendable, CaseIterable, Identifiable {
    case daily
    case weekdays
    case weekly

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .daily: "Every day"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        }
    }
}

enum ReviewSchedulePolicy {
    static func latestDuePeriod(
        now: Date,
        frequency: ReviewScheduleFrequency,
        hour: Int,
        weeklyWeekday: Int,
        calendar: Calendar = .current
    ) -> ReviewPeriod? {
        let safeHour = min(23, max(0, hour))
        var candidate = calendar.date(
            bySettingHour: safeHour, minute: 0, second: 0, of: now
        ) ?? now
        if candidate > now {
            candidate = calendar.date(byAdding: .day, value: -1, to: candidate) ?? candidate
        }
        switch frequency {
        case .daily:
            break
        case .weekdays:
            while !(2...6).contains(calendar.component(.weekday, from: candidate)) {
                candidate = calendar.date(byAdding: .day, value: -1, to: candidate) ?? candidate
            }
        case .weekly:
            let wanted = min(7, max(1, weeklyWeekday))
            while calendar.component(.weekday, from: candidate) != wanted {
                candidate = calendar.date(byAdding: .day, value: -1, to: candidate) ?? candidate
            }
        }
        return .ending(
            at: candidate,
            kind: frequency == .weekly ? .week : .day,
            calendar: calendar
        )
    }
}

enum ReviewTrigger: String, Codable, Sendable {
    case manual
    case scheduled
}

struct ReviewBilling: Codable, Sendable, Equatable {
    enum Unit: String, Codable, Sendable { case codexCredits }

    let amount: Double
    let unit: Unit
    let rateCardDate: String
}

/// Offline, versioned rate card. It never performs a pricing network request.
enum ReviewRateCard {
    static let version = "2026-08-09"

    private struct CodexRate {
        let input: Double
        let cachedInput: Double
        let output: Double
    }

    private static let codex: [String: CodexRate] = [
        "gpt-5.4-mini": CodexRate(input: 18.75, cachedInput: 1.875, output: 113),
        "gpt-5.6-luna": CodexRate(input: 25, cachedInput: 2.5, output: 150),
    ]

    static func billing(providerID: String, modelID: String, usage: LLMUsage?) -> ReviewBilling? {
        guard providerID == AIProvider.codex.rawValue,
              let usage, let rate = codex[modelID] else { return nil }
        let cached = usage.cachedInputTokens ?? 0
        // Provider input totals include the cached subset. Charge that subset
        // once at the cached rate instead of counting it twice.
        let uncached = max(0, (usage.inputTokens ?? cached) - cached)
        let credits = Double(uncached) * rate.input / 1_000_000
            + Double(cached) * rate.cachedInput / 1_000_000
            + Double(usage.outputTokens ?? 0) * rate.output / 1_000_000
        guard usage.hasMeasurement else { return nil }
        return ReviewBilling(amount: credits, unit: .codexCredits, rateCardDate: version)
    }
}

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

struct CollectedReview: Sendable {
    let period: ReviewPeriod
    let slices: [DaySlice]
    let totalCaptures: Int
    let totalSlices: Int
    let coverageIncomplete: Bool
    var truncated: Bool { totalSlices > slices.count }
}

/// Result of the summarize stage (without writing). This is the preview.
struct SummaryPreview: Sendable {
    let period: ReviewPeriod
    let markdown: String
    let sessions: Int
    let totalCaptures: Int
    let model: String
    let promptChars: Int
    let sourceTruncated: Bool   // source sessions were trimmed by maxInputSlices
    let contextTruncated: Bool  // selected-model context ceiling compacted the chosen slices further
    let outputTruncated: Bool   // the model hit maxOutputTokens (finish_reason=length) → the summary is incomplete
    let provenance: AIExecutionProvenance
    let promptVersion: String
    let usage: LLMUsage?
    let billing: ReviewBilling?
    let coverageIncomplete: Bool
    let trigger: ReviewTrigger

    var day: Date { period.start }
    var truncated: Bool { sourceTruncated || contextTruncated }

    init(
        period: ReviewPeriod,
        markdown: String,
        sessions: Int,
        totalCaptures: Int,
        model: String,
        promptChars: Int,
        sourceTruncated: Bool,
        contextTruncated: Bool,
        outputTruncated: Bool,
        provenance: AIExecutionProvenance,
        promptVersion: String,
        usage: LLMUsage?,
        billing: ReviewBilling?,
        coverageIncomplete: Bool,
        trigger: ReviewTrigger
    ) {
        self.period = period
        self.markdown = markdown
        self.sessions = sessions
        self.totalCaptures = totalCaptures
        self.model = model
        self.promptChars = promptChars
        self.sourceTruncated = sourceTruncated
        self.contextTruncated = contextTruncated
        self.outputTruncated = outputTruncated
        self.provenance = provenance
        self.promptVersion = promptVersion
        self.usage = usage
        self.billing = billing
        self.coverageIncomplete = coverageIncomplete
        self.trigger = trigger
    }

    init(saved summary: ReviewSummary) {
        period = summary.period
        markdown = summary.markdown
        sessions = summary.sessions
        totalCaptures = summary.totalCaptures
        model = summary.provenance.modelID
        promptChars = 0
        sourceTruncated = summary.sourceTruncated
        contextTruncated = summary.contextTruncated
        outputTruncated = summary.outputTruncated
        provenance = summary.provenance
        promptVersion = summary.promptVersion
        usage = summary.usage
        billing = summary.billing
        coverageIncomplete = summary.coverageIncomplete
        trigger = summary.trigger
    }
}

struct ReviewSummary: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let period: ReviewPeriod
    let generatedAt: Date
    let markdown: String
    let sessions: Int
    let totalCaptures: Int
    let provenance: AIExecutionProvenance
    let promptVersion: String
    let usage: LLMUsage?
    let billing: ReviewBilling?
    let sourceTruncated: Bool
    let contextTruncated: Bool
    let outputTruncated: Bool
    let coverageIncomplete: Bool
    let trigger: ReviewTrigger
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
    let usage: LLMUsage?
    let billing: ReviewBilling?

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
        brokerUpstream: String? = nil,
        usage: LLMUsage? = nil,
        billing: ReviewBilling? = nil
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
        self.usage = usage
        self.billing = billing
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
