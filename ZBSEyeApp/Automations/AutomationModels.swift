import Foundation

/// Общие типы automation-слоя (Шаг 9): конфиг подключений, ограничения безопасности автоматизации,
/// промежуточные данные daily-summary, audit-запись. Всё Sendable — ходит между @MainActor-store,
/// actor-сервисом и сетью без шаринга мутабельного состояния.

// MARK: подключения

/// Локальная LLM по OpenAI-совместимому `/chat/completions` (Ollama, LM Studio, mlx_lm.server,
/// llama.cpp server). Один интерфейс на все — отличается только baseURL/портом и именем модели.
/// НИКАКОГО cloud-egress: дефолт жёстко на 127.0.0.1.
struct LLMConfig: Codable, Sendable, Equatable {
    var baseURL: String
    var model: String

    static let `default` = LLMConfig(baseURL: "http://127.0.0.1:11434/v1", model: "llama3.2")

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty &&
        !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// baseURL с дописанной схемой, если юзер ввёл «localhost:11434» / «127.0.0.1:11434» без http://
    /// (так их показывают Ollama/LM Studio — без схемы URL.host = nil и проверки/endpoint ломались).
    var normalizedBaseURL: String {
        let b = baseURL.trimmingCharacters(in: .whitespaces)
        if b.isEmpty || b.contains("://") { return b }
        return "http://" + b
    }

    /// Только localhost разрешён в v1 (приватность — приватная история не должна утечь в облако).
    /// host lowercased — DNS регистронезависим (LOCALHOST → localhost).
    var isLocalOnly: Bool {
        guard let host = URL(string: normalizedBaseURL)?.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host)
    }
}

/// Куда писать саммари: папка (security-scoped bookmark для устойчивости к переносу) + подпапка.
/// Obsidian vault — это та же папка; «Obsidian» и «файловый экспорт» в v1 — один механизм.
struct DestinationConfig: Codable, Sendable, Equatable {
    var bookmark: Data?
    var displayPath: String?
    var subfolder: String

    static let `default` = DestinationConfig(bookmark: nil, displayPath: nil, subfolder: "ZBS Eye")

    var isConfigured: Bool { bookmark != nil || displayPath != nil }
}

// MARK: ограничения безопасности автоматизации

/// Жёсткие caps: автоматизация читает приватную историю → LLM → запись. Ограничиваем вход (сколько сессий),
/// длину сэмпла, выход и таймаут. Защита от prompt-injection — delimiters + локальный-only egress +
/// обязательный preview перед первой записью (см. DaySummaryStore).
struct AutomationSafety: Sendable, Equatable {
    var maxInputSlices = 80
    var maxSampleChars = 360
    var maxOutputTokens = 800
    var requestTimeout: TimeInterval = 300   // локальная модель может холодно грузиться; stream:false = молчит до конца

    static let `default` = AutomationSafety()
}

// MARK: данные daily-summary

/// Одна «сессия» активности: подряд идущие кадры одного приложения/окна (с допуском на паузу).
struct DaySlice: Sendable, Equatable {
    let start: Date
    let end: Date
    let app: String
    let window: String?
    let url: String?
    let sample: String        // репрезентативный текст сессии (усечён до maxSampleChars)
    let captures: Int
}

/// Результат стадии collect: отобранные сессии дня + метаданные охвата.
struct CollectedDay: Sendable {
    let day: Date
    let slices: [DaySlice]
    let totalCaptures: Int
    let totalSlices: Int       // до отсечения по maxInputSlices
    var truncated: Bool { totalSlices > slices.count }
}

/// Результат стадии summarize (без записи). Это и есть preview.
struct SummaryPreview: Sendable {
    let day: Date
    let markdown: String
    let sessions: Int
    let totalCaptures: Int
    let model: String
    let promptChars: Int
    let truncated: Bool         // вход обрезан по maxInputSlices (длинный день)
    let outputTruncated: Bool   // модель упёрлась в maxOutputTokens (finish_reason=length) → конспект неполный
}

/// Результат стадии write.
struct WriteResult: Sendable {
    let path: String
    let bytes: Int
    let overwritten: Bool
}

// MARK: audit

/// Строка audit-лога (JSONL в Application Support/ZBS Eye/automation-audit.jsonl). Доказуемая история того,
/// что автоматизация читала/писала — требование плана (автоматизация касается приватных данных).
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

// MARK: ошибки

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
            return "Локальная LLM не настроена. Открой «Подключения» и укажи endpoint + модель."
        case .nonLocalLLM(let host):
            return "Endpoint «\(host)» не локальный. В v1 разрешён только 127.0.0.1/localhost — приватная история не уходит в облако."
        case .noDestination:
            return "Не выбрана папка для записи. Открой «Подключения» → «Назначение»."
        case .noData(let day):
            let f = DateFormatter(); f.dateStyle = .medium; f.locale = Locale(identifier: "ru_RU")
            return "За \(f.string(from: day)) нет записанной активности."
        case .llm(let m):
            return "Ошибка локальной модели: \(m)"
        case .write(let m):
            return "Не удалось записать файл: \(m)"
        }
    }
}

// MARK: расположение конфигов/лога

enum ZBSEyeSupport {
    /// Корень данных (та же папка, где zbseye.sqlite и media/) — через StorageLocation (учитывает relocate).
    static func directory() throws -> URL {
        StorageLocation.dataRoot()
    }

    static func auditLogURL() throws -> URL {
        try directory().appendingPathComponent("automation-audit.jsonl")
    }
}
