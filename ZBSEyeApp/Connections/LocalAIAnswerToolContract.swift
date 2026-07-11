import Foundation
import MLXLMCommon

enum LocalAIAnswerToolContractError: Error, LocalizedError, Equatable {
    case wrongFunction
    case invalidArguments
    case invalidStatus
    case invalidSearchSuggestion

    var errorDescription: String? {
        switch self {
        case .wrongFunction: "The local model returned the wrong structured-output function."
        case .invalidArguments: "The local model returned invalid structured-output arguments."
        case .invalidStatus: "The local model returned a status invalid for this consumer."
        case .invalidSearchSuggestion: "The local model returned an unsafe search suggestion."
        }
    }
}

/// A no-side-effect function-call channel for local-model output. The function
/// is never dispatched. Its only purpose is to make Qwen's native tool-call
/// template produce typed fields that are validated before deterministic UI
/// rendering.
enum LocalAIAnswerToolContract {
    static let functionName = "emit_zbs_eye_answer"

    private static let allowedKeys: Set<String> = [
        "status",
        "item1_text", "item1_sources",
        "item2_text", "item2_sources",
        "item3_text", "item3_sources",
        "next_search",
    ]

    static let schema: ToolSpec = [
        "type": "function",
        "function": [
            "name": functionName,
            "description": "Return the final grounded answer. This function has no side effects.",
            "parameters": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "status": [
                        "type": "string",
                        "enum": ["supported", "uncertain", "not_found", "conflict", "insufficient"],
                    ] as [String: any Sendable],
                    "item1_text": ["type": "string"] as [String: any Sendable],
                    "item1_sources": sourceArraySchema,
                    "item2_text": ["type": "string"] as [String: any Sendable],
                    "item2_sources": sourceArraySchema,
                    "item3_text": ["type": "string"] as [String: any Sendable],
                    "item3_sources": sourceArraySchema,
                    "next_search": ["type": "string"] as [String: any Sendable],
                ] as [String: any Sendable],
                "required": ["status", "item1_text", "item1_sources"],
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    /// The legacy full schema above is retained so historical qualification
    /// protocols remain byte-for-byte reproducible. Production uses this
    /// purpose-specific schema so the model cannot be invited to populate
    /// fields that the strict parser would reject for the active consumer.
    static func schema(for purpose: LocalAIOutputPurpose) -> ToolSpec {
        let statuses: [String]
        let itemCount: Int
        let includesSearchSuggestion: Bool
        switch purpose {
        case .ask:
            statuses = ["supported", "uncertain", "not_found"]
            itemCount = 2
            includesSearchSuggestion = true
        case .insights:
            statuses = ["supported", "conflict", "insufficient"]
            itemCount = 3
            includesSearchSuggestion = false
        case .summary, .label:
            statuses = ["supported"]
            itemCount = 1
            includesSearchSuggestion = false
        }

        var properties: [String: any Sendable] = [
            "status": [
                "type": "string",
                "enum": statuses,
            ] as [String: any Sendable],
        ]
        for index in 1...itemCount {
            properties["item\(index)_text"] = ["type": "string"] as [String: any Sendable]
            properties["item\(index)_sources"] = sourceArraySchema
        }
        if includesSearchSuggestion {
            properties["next_search"] = ["type": "string"] as [String: any Sendable]
        }

        return [
            "type": "function",
            "function": [
                "name": functionName,
                "description": "Return the final grounded answer. This function has no side effects.",
                "parameters": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": properties,
                    "required": ["status", "item1_text", "item1_sources"],
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    }

    static func parse(
        _ call: ToolCall,
        purpose: LocalAIOutputPurpose,
        allowedSources: Set<String>
    ) throws -> LocalAIOutputEnvelope {
        guard call.function.name == functionName else {
            throw LocalAIAnswerToolContractError.wrongFunction
        }
        let arguments = call.function.arguments
        guard Set(arguments.keys).isSubset(of: allowedKeys),
              case .string(let rawStatus)? = arguments["status"],
              let status = LocalAIOutputStatus(rawValue: rawStatus),
              arguments["item1_text"] != nil,
              arguments["item1_sources"] != nil else {
            throw LocalAIAnswerToolContractError.invalidArguments
        }

        try LocalAIOutputParser.validateSourceVocabulary(allowedSources, purpose: purpose)
        let slots = try (1...3).map { index -> Slot in
            let textKey = "item\(index)_text"
            let sourcesKey = "item\(index)_sources"
            let text = try optionalString(arguments[textKey]) ?? ""
            let sources = try sourceArray(
                arguments[sourcesKey],
                purpose: purpose,
                allowedSources: allowedSources
            )
            if !text.isEmpty {
                try LocalAIOutputParser.validateText(text, purpose: purpose)
            }
            return Slot(text: text, sources: sources)
        }
        let nextSearch = try optionalString(arguments["next_search"])
            .flatMap { $0.isEmpty ? nil : $0 }
        if let nextSearch {
            do {
                try LocalAIOutputParser.validateText(nextSearch)
            } catch {
                throw LocalAIAnswerToolContractError.invalidSearchSuggestion
            }
        }

        switch (purpose, status) {
        case (.ask, .supported), (.ask, .uncertain):
            let parsedItems = slots.compactMap(\.item)
            guard (1...2).contains(parsedItems.count),
                  parsedItems.allSatisfy({ !$0.sources.isEmpty }),
                  slots.filter({ $0.text.isEmpty }).allSatisfy({ $0.sources.isEmpty }) else {
                throw LocalAIAnswerToolContractError.invalidArguments
            }
            return LocalAIOutputEnvelope(status: status, items: parsedItems)

        case (.ask, .notFound):
            guard let nextSearch else {
                throw LocalAIAnswerToolContractError.invalidSearchSuggestion
            }
            let searchBody = try canonicalSearchSuggestion(nextSearch)
            return LocalAIOutputEnvelope(status: status, items: [], nextSearch: searchBody)

        case (.insights, .supported):
            let parsedItems = slots.compactMap(\.item)
            let usedSources = parsedItems.flatMap(\.sources)
            guard (2...3).contains(parsedItems.count),
                  parsedItems.allSatisfy({ $0.sources.count == 1 }),
                  slots.filter({ $0.text.isEmpty }).allSatisfy({ $0.sources.isEmpty }),
                  Set(usedSources).count == usedSources.count,
                  Set(usedSources) == allowedSources else {
                throw LocalAIAnswerToolContractError.invalidArguments
            }
            return LocalAIOutputEnvelope(status: status, items: parsedItems)

        case (.insights, .conflict):
            let parsedItems = slots.compactMap(\.item)
            let usedSources = parsedItems.flatMap(\.sources)
            guard (1...2).contains(parsedItems.count),
                  parsedItems.allSatisfy({ !$0.sources.isEmpty }),
                  slots.filter({ $0.text.isEmpty }).allSatisfy({ $0.sources.isEmpty }),
                  Set(usedSources).count == usedSources.count,
                  Set(usedSources) == allowedSources else {
                throw LocalAIAnswerToolContractError.invalidArguments
            }
            return LocalAIOutputEnvelope(status: status, items: parsedItems)

        case (.insights, .insufficient):
            guard slots[0].text.isEmpty,
                  slots[0].sources == [LocalAISourceID.totalCaptures],
                  slots.dropFirst().allSatisfy({ $0.text.isEmpty && $0.sources.isEmpty }) else {
                throw LocalAIAnswerToolContractError.invalidArguments
            }
            return LocalAIOutputEnvelope(status: status, items: [])

        case (.summary, .supported), (.label, .supported):
            let parsedItems = slots.compactMap(\.item)
            guard parsedItems.count == 1,
                  !parsedItems[0].sources.isEmpty,
                  Set(parsedItems[0].sources).isSubset(of: allowedSources),
                  slots.dropFirst().allSatisfy({
                      $0.text.isEmpty && $0.sources.isEmpty
                  }) else {
                throw LocalAIAnswerToolContractError.invalidArguments
            }
            return LocalAIOutputEnvelope(status: status, items: parsedItems)

        default:
            throw LocalAIAnswerToolContractError.invalidStatus
        }
    }

    private static var sourceArraySchema: [String: any Sendable] {
        [
            "type": "array",
            "items": ["type": "string"] as [String: any Sendable],
        ]
    }

    private struct Slot {
        let text: String
        let sources: [String]

        var item: LocalAIOutputItem? {
            text.isEmpty ? nil : LocalAIOutputItem(text: text, sources: sources)
        }
    }

    private static func optionalString(_ value: JSONValue?) throws -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else {
            throw LocalAIAnswerToolContractError.invalidArguments
        }
        return string
    }

    private static func sourceArray(
        _ value: JSONValue?,
        purpose: LocalAIOutputPurpose,
        allowedSources: Set<String>
    ) throws -> [String] {
        guard let value else { return [] }
        if case .string("") = value { return [] }
        guard case .array(let values) = value else {
            throw LocalAIAnswerToolContractError.invalidArguments
        }
        let sources = try values.map { value -> String in
            let raw: String
            switch value {
            case .string(let string): raw = string
            case .int(let number) where purpose == .ask: raw = String(number)
            case .bool(true) where purpose == .ask: raw = "1"
            default:
                throw LocalAIAnswerToolContractError.invalidArguments
            }
            if allowedSources.contains(raw) { return raw }
            if purpose == .ask {
                let candidate = "[\(raw)]"
                if raw.range(of: #"^\d+$"#, options: .regularExpression) != nil,
                   allowedSources.contains(candidate) {
                    return candidate
                }
            }
            throw LocalAIOutputContractError.invalidSource
        }
        guard Set(sources).count == sources.count else {
            throw LocalAIOutputContractError.invalidSource
        }
        return sources
    }

    private static func canonicalSearchSuggestion(_ suggestion: String) throws -> String {
        do {
            try LocalAIOutputParser.validateText(suggestion)
        } catch {
            throw LocalAIAnswerToolContractError.invalidSearchSuggestion
        }
        guard suggestion.range(of: #"\d"#, options: .regularExpression) == nil else {
            throw LocalAIAnswerToolContractError.invalidSearchSuggestion
        }
        let normalized = suggestion.lowercased()
        let body: String
        if normalized.hasPrefix("try ") {
            body = String(suggestion.dropFirst("try ".count))
        } else if normalized.hasPrefix("попробуйте ") {
            body = String(suggestion.dropFirst("попробуйте ".count))
        } else {
            throw LocalAIAnswerToolContractError.invalidSearchSuggestion
        }
        do {
            try LocalAIOutputParser.validateText(body)
        } catch {
            throw LocalAIAnswerToolContractError.invalidSearchSuggestion
        }
        return body
    }
}
