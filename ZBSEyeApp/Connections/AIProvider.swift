import Foundation

/// The AI providers that can process history excerpts (Ask / Daily Insights / day summary).
/// Local-first, bring-your-own-AI: local providers (LM Studio, Ollama, any OpenAI-compatible
/// localhost server) are the default and the privacy story. Cloud providers are an EXPLICIT
/// opt-in — excerpts of screen history leave the Mac only after per-provider consent.
/// Capture/index/storage never leave the device regardless of the choice made here.
enum AIProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case lmstudio
    case ollama
    case custom       // any OpenAI-compatible localhost server (mlx_lm.server, llama.cpp, …); also the legacy-config migration target
    case claudeCode   // the user's already-authenticated Claude Code CLI, run as a local subprocess — no API key
    case openrouter
    case anthropic
    case openai

    var id: String { rawValue }

    /// Proper nouns — not localized on purpose.
    var displayName: String {
        switch self {
        case .lmstudio:   return "LM Studio"
        case .ollama:     return "Ollama"
        case .custom:     return "Custom (localhost)"
        case .claudeCode: return "Claude Code"
        case .openrouter: return "OpenRouter"
        case .anthropic:  return "Anthropic"
        case .openai:     return "OpenAI"
        }
    }

    /// Cloud = "excerpts of history may leave this Mac" ⇒ the consent gate applies. Claude Code runs a
    /// LOCAL subprocess, but that subprocess egresses to Anthropic via the user's Claude Code login, so
    /// it still counts as cloud for consent purposes.
    var isCloud: Bool {
        switch self {
        case .lmstudio, .ollama, .custom:                     return false
        case .claudeCode, .openrouter, .anthropic, .openai:   return true
        }
    }

    /// Providers invoked as a local CLI subprocess instead of an HTTP request. They have no API host to
    /// pin, no endpoint to validate and no API key — but (see isCloud) may still egress via the CLI.
    var isSubprocess: Bool { self == .claudeCode }

    /// Whether the provider authenticates with a pasted API key (Keychain). Claude Code and local
    /// providers do not — Claude Code reuses the CLI's own login; local servers need no secret.
    var usesAPIKey: Bool { keychainAccount != nil }

    /// Wire protocol: everything speaks OpenAI-style `/chat/completions` except Anthropic (`/v1/messages`).
    enum Wire: Sendable { case openAICompatible, anthropicMessages }
    var wire: Wire { self == .anthropic ? .anthropicMessages : .openAICompatible }

    /// Cloud endpoints are FIXED (that's the egress pin); local ones are defaults the user may override.
    /// Claude Code has no HTTP endpoint at all — the CLI handles its own transport.
    var defaultBaseURL: String {
        switch self {
        case .lmstudio:   return "http://127.0.0.1:1234/v1"
        case .ollama:     return "http://127.0.0.1:11434/v1"
        case .custom:     return ""
        case .claudeCode: return ""
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .anthropic:  return "https://api.anthropic.com/v1"
        case .openai:     return "https://api.openai.com/v1"
        }
    }

    /// The ONE remote host a consented cloud provider is allowed to reach. nil for local providers AND
    /// for Claude Code (the app makes no HTTP request — the CLI does, over its own pinned transport).
    var apiHost: String? {
        switch self {
        case .lmstudio, .ollama, .custom, .claudeCode: return nil
        case .openrouter: return "openrouter.ai"
        case .anthropic:  return "api.anthropic.com"
        case .openai:     return "api.openai.com"
        }
    }

    /// Keychain account for the API key (KeychainStore.service is shared). Local providers and Claude
    /// Code (which reuses the CLI login) keep no secrets here.
    var keychainAccount: String? {
        switch self {
        case .lmstudio, .ollama, .custom, .claudeCode: return nil
        case .openrouter: return "llm.openrouter"
        case .anthropic:  return "llm.anthropic"
        case .openai:     return "llm.openai"
        }
    }

    /// Where the user gets an API key ("Get a key…" button).
    var keyConsoleURL: URL? {
        switch self {
        case .lmstudio, .ollama, .custom, .claudeCode: return nil
        case .openrouter: return URL(string: "https://openrouter.ai/keys")
        case .anthropic:  return URL(string: "https://console.anthropic.com/settings/keys")
        case .openai:     return URL(string: "https://platform.openai.com/api-keys")
        }
    }

    /// Anthropic `/v1/models` needs a valid key and may fail — a static fallback keeps the Picker usable.
    static let anthropicFallbackModels = ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5-20251001"]

    /// Preset `--model` ids for the Claude Code provider (its `-p` mode takes no live model list).
    /// "default" is a sentinel that means "omit --model" — use whatever the CLI is configured to use.
    static let claudeCodeDefaultModel = "default"
    static let claudeCodeModels = ["default", "claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5-20251001"]

    /// OpenAI `/v1/models` lists embeddings/whisper/tts too — keep only chat-capable families (gpt-*, o1/o3/o4…).
    static func isChatCapableOpenAIModel(_ id: String) -> Bool {
        if id.hasPrefix("gpt-") { return true }
        return id.range(of: #"^o\d"#, options: .regularExpression) != nil
    }
}

/// Persisted AI-provider state (UserDefaults "zbseye.ai.provider", JSON). Keys are provider rawValues —
/// stable across app versions and tolerant of unknown values. API keys are NOT here (Keychain only).
struct AIProviderSettings: Codable, Sendable, Equatable {
    /// Exactly one active processing model across all providers (nil = none: Ask/Insights degrade honestly).
    var active: String?
    /// Selected model per provider — switching providers doesn't lose each card's choice.
    var models: [String: String] = [:]
    /// Endpoint overrides for LOCAL providers only (custom lives here; cloud endpoints are pinned).
    var endpoints: [String: String] = [:]
    /// Per-provider cloud consent: "excerpts of screen history may leave this Mac to <provider>".
    var cloudConsent: [String: Bool] = [:]

    var activeProvider: AIProvider? { active.flatMap(AIProvider.init(rawValue:)) }
}
