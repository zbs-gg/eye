import Foundation

enum LocalAISourceID {
    static let totalCaptures = "total_captures"
    static let contextSwitches = "context_switches"
    static let topApp = "top_app"
    static let secondApp = "second_app"
    static let activityBlock = "activity_block"
    private static let safeTextFactPrefix = "safe_text_fact:"

    static func safeTextFact(_ index: Int) -> String {
        safeTextFactPrefix + String(index)
    }

    static func safeTextFactIndex(from sourceID: String) -> Int? {
        guard sourceID.hasPrefix(safeTextFactPrefix) else { return nil }
        return Int(sourceID.dropFirst(safeTextFactPrefix.count))
    }
}

struct LocalAIActivityApp: Sendable, Equatable {
    let name: String
    let minutes: Int
    let captures: Int
}

enum LocalAIInsightsMode: String, Sendable, Equatable {
    case insufficient
    case conflict
    case normal
}

struct LocalAIInsightsHints: Sendable, Equatable {
    let mode: LocalAIInsightsMode
    let totalCaptures: Int
    let contextSwitches: Int
    let topApp: LocalAIActivityApp?
    let secondApp: LocalAIActivityApp?
    let safeResultSamples: [String]

    var allowedSourceIDs: Set<String> {
        var sources: Set<String> = [
            LocalAISourceID.totalCaptures,
            LocalAISourceID.contextSwitches,
        ]
        if topApp != nil { sources.insert(LocalAISourceID.topApp) }
        if secondApp != nil { sources.insert(LocalAISourceID.secondApp) }
        for index in safeResultSamples.indices {
            sources.insert(LocalAISourceID.safeTextFact(index))
        }
        return sources
    }

    var requiredOutputSourceIDs: [String] {
        switch mode {
        case .insufficient:
            return [LocalAISourceID.totalCaptures]
        case .conflict:
            return safeResultSamples.indices.map(LocalAISourceID.safeTextFact)
        case .normal:
            var sources: [String] = []
            if topApp != nil { sources.append(LocalAISourceID.topApp) }
            if !safeResultSamples.isEmpty {
                sources.append(LocalAISourceID.safeTextFact(0))
            } else if secondApp != nil {
                sources.append(LocalAISourceID.secondApp)
            }
            sources.append(LocalAISourceID.contextSwitches)
            return sources
        }
    }

    /// Minimal trusted ledger shown to the model. Internal thresholds, raw
    /// unsafe samples, capture counts, and unused facts stay outside the prompt.
    var modelLedger: String { modelLedger(language: .en) }

    func modelLedger(language: LocalAIOutputLanguage) -> String {
        switch mode {
        case .insufficient:
            return "mode=insufficient\n\(LocalAISourceID.totalCaptures)=\(totalCaptures)"
        case .conflict:
            return (["mode=conflict"] + safeResultSamples.enumerated().map {
                "\(LocalAISourceID.safeTextFact($0.offset))=\($0.element)"
            }).joined(separator: "\n")
        case .normal:
            var lines = ["mode=normal"]
            if let topApp {
                let unit = language == .ru ? "минут" : "minutes"
                lines.append("\(LocalAISourceID.topApp): \(topApp.name) — \(topApp.minutes) \(unit)")
            }
            if let sample = safeResultSamples.first {
                lines.append("\(LocalAISourceID.safeTextFact(0))=\(sample)")
            } else if let secondApp {
                let unit = language == .ru ? "минут" : "minutes"
                lines.append("\(LocalAISourceID.secondApp): \(secondApp.name) — \(secondApp.minutes) \(unit)")
            }
            let switches = language == .ru
                ? "\(contextSwitches) переключений контекста"
                : "\(contextSwitches) context switches"
            lines.append("\(LocalAISourceID.contextSwitches): \(switches)")
            return lines.joined(separator: "\n")
        }
    }

    var rendered: String {
        var lines = [
            "mode=\(mode.rawValue)",
            "\(LocalAISourceID.totalCaptures)=\(totalCaptures)",
            "\(LocalAISourceID.contextSwitches)=\(contextSwitches)",
        ]
        if let topApp {
            lines.append("\(LocalAISourceID.topApp)_by_minutes=\(topApp.name)|minutes=\(topApp.minutes)|captures=\(topApp.captures)")
        }
        if let secondApp {
            lines.append("\(LocalAISourceID.secondApp)_by_minutes=\(secondApp.name)|minutes=\(secondApp.minutes)|captures=\(secondApp.captures)")
        }
        lines.append(contentsOf: safeResultSamples.enumerated().map {
            "\(LocalAISourceID.safeTextFact($0.offset))=\($0.element)"
        })
        return lines.joined(separator: "\n")
    }
}

enum LocalAIAskStatusHint: String, Sendable, Equatable {
    case unconfirmed
}

struct LocalAIAskContextBudget: Sendable, Equatable {
    let context: String
    let includedFragmentIndices: [Int]
    let tokenUpperBound: Int
    let truncated: Bool

    var includedFragmentCount: Int { includedFragmentIndices.count }
}

struct LocalAIConsumerContextBudget: Sendable, Equatable {
    let context: String
    let includedSourceIDs: [String]
    let tokenUpperBound: Int
    let truncated: Bool
}

enum LocalAIContextPolicy {
    /// A deliberately conservative upper bound used before tokenizer/runtime
    /// allocation: one UTF-8 byte counts as one possible token, plus a fixed
    /// chat-template envelope. It under-fills most models, but cannot rely on a
    /// provider-specific tokenizer that has not been loaded yet.
    // Includes the chat template plus the built-in structured-output tool
    // schema. Keeping this explicit is safer than discovering the overflow
    // only after the multi-gigabyte runtime has started prefill.
    private static let generationEnvelopeReserveTokens = 768

    static func generationTokenUpperBound(
        systemPrompt: String,
        userPrompt: String,
        outputTokens: Int
    ) -> Int {
        systemPrompt.utf8.count
            + userPrompt.utf8.count
            + max(0, outputTokens)
            + generationEnvelopeReserveTokens
    }

    static func askTokenUpperBound(
        systemPrompt: String,
        userPrompt: String,
        outputTokens: Int
    ) -> Int {
        generationTokenUpperBound(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            outputTokens: outputTokens
        )
    }

    /// Deterministic pre-tokenizer budget for non-Ask consumers. Fragments keep
    /// input order and stable source IDs; one fragment may be UTF-8-safely cut,
    /// then every lower-priority fragment is excluded.
    static func budgetConsumerContext(
        systemPrompt: String,
        userPreamble: String,
        fragments: [AIConsumerPromptFragment],
        userPostamble: String,
        contextTokenCeiling: Int,
        outputTokens: Int,
        maximumFragmentCharacters: Int
    ) -> LocalAIConsumerContextBudget? {
        guard contextTokenCeiling > 0,
              outputTokens > 0,
              maximumFragmentCharacters > 0 else { return nil }
        let base = generationTokenUpperBound(
            systemPrompt: systemPrompt,
            userPrompt: userPreamble + userPostamble,
            outputTokens: outputTokens
        )
        guard base < contextTokenCeiling else { return nil }

        var remaining = contextTokenCeiling - base
        var rendered: [String] = []
        var includedSourceIDs: [String] = []
        var truncated = false

        for fragment in fragments {
            let collapsed = fragment.text
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard !collapsed.isEmpty else {
                truncated = true
                continue
            }
            let limited: String
            if collapsed.count > maximumFragmentCharacters {
                limited = String(collapsed.prefix(maximumFragmentCharacters)) + "…"
                truncated = true
            } else {
                limited = collapsed
            }

            let marker = "[source=\(fragment.sourceID)] "
            let separator = rendered.isEmpty ? "" : "\n"
            let fixedBytes = marker.utf8.count + separator.utf8.count
            let fullBytes = fixedBytes + limited.utf8.count
            if fullBytes <= remaining {
                rendered.append(marker + limited)
                includedSourceIDs.append(fragment.sourceID)
                remaining -= fullBytes
                continue
            }

            let ellipsis = "…"
            let availableTextBytes = remaining - fixedBytes - ellipsis.utf8.count
            guard availableTextBytes >= 16,
                  let prefix = utf8SafePrefix(limited, maximumBytes: availableTextBytes),
                  !prefix.isEmpty else {
                truncated = true
                break
            }
            rendered.append(marker + prefix + ellipsis)
            includedSourceIDs.append(fragment.sourceID)
            truncated = true
            break
        }

        guard !rendered.isEmpty else { return nil }
        if includedSourceIDs.count < fragments.count { truncated = true }
        let context = rendered.joined(separator: "\n")
        let upperBound = generationTokenUpperBound(
            systemPrompt: systemPrompt,
            userPrompt: userPreamble + context + userPostamble,
            outputTokens: outputTokens
        )
        guard upperBound <= contextTokenCeiling else { return nil }
        return LocalAIConsumerContextBudget(
            context: context,
            includedSourceIDs: includedSourceIDs,
            tokenUpperBound: upperBound,
            truncated: truncated
        )
    }

    static func outputLanguage(for values: [String]) -> LocalAIOutputLanguage {
        values.joined(separator: " ").unicodeScalars.contains(where: {
            (0x0400...0x04FF).contains($0.value)
        }) ? .ru : .en
    }

    /// Keeps retrieval order and citation numbering stable. A fragment is
    /// either included in full, included once as a UTF-8-safe prefix with an
    /// ellipsis, or excluded together with every lower-ranked fragment.
    static func budgetAskContext(
        systemPrompt: String,
        userPreamble: String,
        userPostamble: String = "",
        evidenceTexts: [String],
        contextTokenCeiling: Int,
        outputTokens: Int,
        maximumFragmentCharacters: Int
    ) -> LocalAIAskContextBudget? {
        guard contextTokenCeiling > 0,
              outputTokens > 0,
              maximumFragmentCharacters > 0 else { return nil }

        let base = askTokenUpperBound(
            systemPrompt: systemPrompt,
            userPrompt: userPreamble + userPostamble,
            outputTokens: outputTokens
        )
        guard base < contextTokenCeiling else { return nil }

        var remaining = contextTokenCeiling - base
        var numbered: [String] = []
        var includedIndices: [Int] = []
        var truncated = false

        for (evidenceIndex, raw) in evidenceTexts.enumerated() {
            let collapsed = raw
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            guard !collapsed.isEmpty else {
                truncated = true
                continue
            }

            let characterLimited: String
            if collapsed.count > maximumFragmentCharacters {
                characterLimited = String(collapsed.prefix(maximumFragmentCharacters)) + "…"
                truncated = true
            } else {
                characterLimited = collapsed
            }

            let marker = "[\(numbered.count + 1)] "
            let separator = numbered.isEmpty ? "" : "\n"
            let fixedBytes = marker.utf8.count + separator.utf8.count
            let fullBytes = fixedBytes + characterLimited.utf8.count
            if fullBytes <= remaining {
                numbered.append(marker + characterLimited)
                includedIndices.append(evidenceIndex)
                remaining -= fullBytes
                continue
            }

            let ellipsis = "…"
            let availableTextBytes = remaining - fixedBytes - ellipsis.utf8.count
            guard availableTextBytes >= 16,
                  let prefix = utf8SafePrefix(
                      characterLimited,
                      maximumBytes: availableTextBytes
                  ), !prefix.isEmpty else {
                truncated = true
                break
            }
            numbered.append(marker + prefix + ellipsis)
            includedIndices.append(evidenceIndex)
            remaining = 0
            truncated = true
            break
        }

        guard !numbered.isEmpty else { return nil }
        if numbered.count < evidenceTexts.count { truncated = true }
        let context = numbered.joined(separator: "\n")
        let userPrompt = userPreamble + context + userPostamble
        let upperBound = askTokenUpperBound(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            outputTokens: outputTokens
        )
        guard upperBound <= contextTokenCeiling else { return nil }
        return LocalAIAskContextBudget(
            context: context,
            includedFragmentIndices: includedIndices,
            tokenUpperBound: upperBound,
            truncated: truncated
        )
    }

    static func insightsHints(
        totalCaptures: Int,
        contextSwitches: Int,
        apps: [LocalAIActivityApp],
        textSamples: [String]
    ) -> LocalAIInsightsHints {
        let safeSamples = textSamples.filter { !isInstructionLike($0) }
        let mode: LocalAIInsightsMode
        let promotedSamples: [String]
        if totalCaptures < 10 || apps.isEmpty {
            mode = .insufficient
            promotedSamples = []
        } else if hasDayConflict(safeSamples) {
            mode = .conflict
            promotedSamples = Array(safeSamples.prefix(2))
        } else {
            mode = .normal
            promotedSamples = safeSamples.filter(isExplicitResult).prefix(1).map { $0 }
        }

        let rankedApps = apps.sorted { lhs, rhs in
            if lhs.minutes == rhs.minutes { return lhs.name < rhs.name }
            return lhs.minutes > rhs.minutes
        }
        return LocalAIInsightsHints(
            mode: mode,
            totalCaptures: totalCaptures,
            contextSwitches: contextSwitches,
            topApp: rankedApps.first,
            secondApp: rankedApps.dropFirst().first,
            safeResultSamples: promotedSamples
        )
    }

    static func askStatusHint(
        question: String,
        evidenceTexts: [String]
    ) -> LocalAIAskStatusHint? {
        let question = question.lowercased()
        let asksCompletion = ["sent", "send", "submitted", "отправ", "послал", "нажал"]
            .contains(where: question.contains)
        guard asksCompletion else { return nil }
        let evidence = evidenceTexts.joined(separator: " ").lowercased()
        let uncertaintyMarkers = [
            "pending", "not visible", "not pressed", "not confirmed", "still has",
            "ожида", "не нажата", "не нажат", "не видно", "не подтверж",
        ]
        return uncertaintyMarkers.contains(where: evidence.contains) ? .unconfirmed : nil
    }

    private static func utf8SafePrefix(
        _ value: String,
        maximumBytes: Int
    ) -> String? {
        guard maximumBytes > 0 else { return nil }
        var used = 0
        var end = value.startIndex
        for character in value {
            let bytes = String(character).utf8.count
            guard used + bytes <= maximumBytes else { break }
            used += bytes
            end = value.index(after: end)
        }
        guard end > value.startIndex else { return nil }
        return String(value[..<end])
    }

    private static func isInstructionLike(_ value: String) -> Bool {
        let value = value.lowercased()
        return [
            "http://", "https://", "ignore", "prior instruction", "visit ", "open ",
            "print ", "игнор", "открой", "перейд", "напечат", "выполни команд",
        ].contains(where: value.contains)
    }

    private static func hasDayConflict(_ samples: [String]) -> Bool {
        let weekdays = [
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "понедель", "вторник", "сред", "четвер", "пятниц", "суббот", "воскрес",
        ]
        let present = Set(weekdays.filter { day in
            samples.contains { $0.lowercased().contains(day) }
        })
        return present.count >= 2
    }

    private static func isExplicitResult(_ value: String) -> Bool {
        let value = value.lowercased()
        return [
            "succeeded", "passed", "tests", "test ", "runtime", "hash", "manifest",
            "успеш", "тест", "хеш", "сборк", "заверш", "манифест",
        ].contains(where: value.contains)
    }
}
