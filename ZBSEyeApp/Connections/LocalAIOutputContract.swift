import Foundation

enum LocalAIOutputPurpose: String, Codable, Sendable, Equatable {
    case ask
    case insights
    case summary
    case label
}

enum LocalAIOutputLanguage: String, Codable, Sendable, Equatable {
    case en
    case ru
}

/// Trusted metadata supplied by the consumer alongside its prompt. The local
/// runtime validates the model's native tool call against this exact source
/// vocabulary; it never reconstructs authority by scraping prompt text.
struct LocalAIOutputContractRequest: Sendable, Equatable {
    let purpose: LocalAIOutputPurpose
    let language: LocalAIOutputLanguage
    let allowedSources: Set<String>
}

enum LocalAIOutputStatus: String, Codable, Sendable {
    case supported
    case uncertain
    case notFound = "not_found"
    case conflict
    case insufficient
}

struct LocalAIOutputItem: Codable, Sendable, Equatable {
    let text: String
    let sources: [String]
}

struct LocalAIOutputEnvelope: Codable, Sendable, Equatable {
    let status: LocalAIOutputStatus
    let items: [LocalAIOutputItem]
    let nextSearch: String?

    init(
        status: LocalAIOutputStatus,
        items: [LocalAIOutputItem],
        nextSearch: String? = nil
    ) {
        self.status = status
        self.items = items
        self.nextSearch = nextSearch
    }

    private enum CodingKeys: String, CodingKey {
        case status, items
        case nextSearch = "next_search"
    }
}

enum LocalAIOutputContractError: Error, LocalizedError, Equatable {
    case invalidJSON
    case invalidSchema
    case unsupportedStatus
    case invalidItemCount
    case invalidText
    case invalidSource
    case missingGrounding

    var errorDescription: String? {
        switch self {
        case .invalidJSON: "The local model returned invalid JSON."
        case .invalidSchema: "The local model returned an unsupported JSON shape."
        case .unsupportedStatus: "The local model returned a status not valid for this request."
        case .invalidItemCount: "The local model returned the wrong number of answer items."
        case .invalidText: "The local model returned unsafe or oversized answer text."
        case .invalidSource: "The local model referenced an unavailable source."
        case .missingGrounding: "The local model returned a factual item without a source."
        }
    }
}

/// Strict boundary between untrusted model output and user-visible text.
/// The parser never repairs prose, Markdown, unknown fields, or invented source
/// identifiers. Rendering happens only after this validation succeeds.
enum LocalAIOutputParser {
    private static let maximumPayloadBytes = 16 * 1_024
    private static let maximumTextScalars = 240

    static func parse(
        _ raw: String,
        purpose: LocalAIOutputPurpose,
        allowedSources: Set<String>
    ) throws -> LocalAIOutputEnvelope {
        guard raw.utf8.count <= maximumPayloadBytes else {
            throw LocalAIOutputContractError.invalidJSON
        }
        let json = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard json.first == "{", json.last == "}", let data = json.data(using: .utf8) else {
            throw LocalAIOutputContractError.invalidJSON
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LocalAIOutputContractError.invalidJSON
        }
        guard let dictionary = object as? [String: Any],
              [Set(["status", "items"]), Set(["status", "items", "next_search"])]
                .contains(Set(dictionary.keys)),
              let rawItems = dictionary["items"] as? [[String: Any]],
              rawItems.allSatisfy({ Set($0.keys) == ["text", "sources"] }) else {
            throw LocalAIOutputContractError.invalidSchema
        }

        let envelope: LocalAIOutputEnvelope
        do {
            envelope = try JSONDecoder().decode(LocalAIOutputEnvelope.self, from: data)
        } catch {
            throw LocalAIOutputContractError.invalidSchema
        }

        try validateSourceVocabulary(allowedSources, purpose: purpose)
        try validate(envelope, purpose: purpose, allowedSources: allowedSources)
        return envelope
    }

    private static func validate(
        _ envelope: LocalAIOutputEnvelope,
        purpose: LocalAIOutputPurpose,
        allowedSources: Set<String>
    ) throws {
        let countRange: ClosedRange<Int>
        switch (purpose, envelope.status) {
        case (.ask, .supported), (.ask, .uncertain):
            countRange = 1...2
        case (.ask, .notFound):
            countRange = 1...1
        case (.insights, .supported):
            countRange = 1...3
        case (.insights, .conflict):
            countRange = 1...2
        case (.insights, .insufficient):
            countRange = 1...1
        case (.summary, .supported), (.label, .supported):
            countRange = 1...1
        default:
            throw LocalAIOutputContractError.unsupportedStatus
        }
        guard countRange.contains(envelope.items.count) else {
            throw LocalAIOutputContractError.invalidItemCount
        }

        for item in envelope.items {
            try validateText(item.text, purpose: purpose)
            guard Set(item.sources).count == item.sources.count,
                  Set(item.sources).isSubset(of: allowedSources) else {
                throw LocalAIOutputContractError.invalidSource
            }
            if purpose == .ask,
               item.text.range(of: #"\[\d+\]"#, options: .regularExpression) != nil {
                throw LocalAIOutputContractError.invalidSource
            }
        }

        switch (purpose, envelope.status) {
        case (.ask, .notFound):
            guard envelope.items.allSatisfy({ $0.sources.isEmpty }) else {
                throw LocalAIOutputContractError.invalidSource
            }
        case (.ask, .supported), (.ask, .uncertain),
             (.insights, .supported), (.insights, .conflict),
             (.insights, .insufficient), (.summary, .supported),
             (.label, .supported):
            guard envelope.items.allSatisfy({ !$0.sources.isEmpty }) else {
                throw LocalAIOutputContractError.missingGrounding
            }
        default:
            throw LocalAIOutputContractError.unsupportedStatus
        }
    }

    static func validateText(_ text: String) throws {
        try validateText(text, purpose: .ask)
    }

    static func validateText(
        _ text: String,
        purpose: LocalAIOutputPurpose
    ) throws {
        if purpose == .summary {
            let forbiddenControls = CharacterSet.controlCharacters.subtracting(
                CharacterSet(charactersIn: "\n\t")
            )
            guard !text.isEmpty,
                  text == text.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.unicodeScalars.count <= 12_000,
                  text.rangeOfCharacter(from: forbiddenControls) == nil else {
                throw LocalAIOutputContractError.invalidText
            }
            return
        }

        let scalarLimit = purpose == .label ? 100 : maximumTextScalars
        guard !text.isEmpty,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              text.unicodeScalars.count <= scalarLimit,
              text.rangeOfCharacter(from: .controlCharacters) == nil,
              text.range(of: #"(?i)https?://"#, options: .regularExpression) == nil,
              text.range(of: #"^(?:\d+[.)]|[-*•])\s+"#, options: .regularExpression) == nil else {
            throw LocalAIOutputContractError.invalidText
        }
    }

    static func validateSourceVocabulary(
        _ sources: Set<String>,
        purpose: LocalAIOutputPurpose
    ) throws {
        let pattern = purpose == .ask ? #"^\[\d+\]$"# : #"^[a-z][a-z0-9_]*(?::\d+)?$"#
        guard sources.allSatisfy({ source in
            source.range(of: pattern, options: .regularExpression) != nil
        }) else {
            throw LocalAIOutputContractError.invalidSource
        }
    }
}

enum LocalAIOutputRenderer {
    static func render(
        _ envelope: LocalAIOutputEnvelope,
        purpose: LocalAIOutputPurpose,
        language: LocalAIOutputLanguage = .en
    ) -> String {
        switch purpose {
        case .ask:
            let facts = envelope.items.map { item in
                let citations = item.sources.sorted(by: citationOrder).joined(separator: " ")
                return citations.isEmpty ? item.text : "\(item.text) \(citations)"
            }.joined(separator: " ")
            switch envelope.status {
            case .supported:
                return facts
            case .uncertain:
                let prefix = language == .ru
                    ? "История не подтверждает завершение действия."
                    : "The history does not confirm that the action was completed."
                return facts.isEmpty ? prefix : "\(prefix) \(facts)"
            case .notFound:
                let prefix = language == .ru
                    ? "В переданной истории это не найдено."
                    : "I did not find that in the supplied history."
                if let nextSearch = envelope.nextSearch, !nextSearch.isEmpty {
                    let searchPrefix = language == .ru ? "Попробуйте" : "Try"
                    return "\(prefix) \(searchPrefix) \(nextSearch)"
                }
                return facts.isEmpty ? prefix : "\(prefix) \(facts)"
            case .conflict, .insufficient:
                return ""
            }
        case .insights:
            switch envelope.status {
            case .supported:
                return envelope.items.map(\.text).joined(separator: "\n")
            case .conflict:
                let prefix = language == .ru ? "Источники противоречат друг другу:" : "The sources conflict:"
                let facts = envelope.items.map(\.text).joined(separator: "; ")
                return facts.isEmpty ? prefix : "\(prefix) \(facts)"
            case .insufficient:
                return language == .ru
                    ? "Недостаточно данных для надёжного вывода."
                    : "There is not enough data for a reliable insight."
            case .uncertain, .notFound:
                return ""
            }
        case .summary, .label:
            guard envelope.status == .supported else { return "" }
            return envelope.items.first?.text ?? ""
        }
    }

    private static func citationOrder(_ lhs: String, _ rhs: String) -> Bool {
        func number(_ value: String) -> Int? {
            Int(value.dropFirst().dropLast())
        }
        if let left = number(lhs), let right = number(rhs) { return left < right }
        return lhs < rhs
    }
}
