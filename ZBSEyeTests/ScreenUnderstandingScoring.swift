import Foundation

enum ScreenUnderstandingFactSeverity: String, Codable, Sendable, Equatable {
    case minor
    case major
    case critical

    var weight: Double {
        switch self {
        case .minor: 1
        case .major: 2
        case .critical: 4
        }
    }
}

enum ScreenUnderstandingAmbiguity: String, Codable, Sendable, Equatable {
    case judgeable
    case ambiguous
    case unjudgeable
}

struct ScreenUnderstandingHumanFact: Codable, Sendable, Equatable, Hashable {
    var id: String
    var text: String
    var severity: ScreenUnderstandingFactSeverity
}

enum ScreenUnderstandingClaimJudgment: Sendable, Equatable {
    case fact(String)
    case unsupported(ScreenUnderstandingFactSeverity)
    case ambiguous
}

struct ScreenUnderstandingMappedClaim: Sendable, Equatable {
    var text: String
    var judgment: ScreenUnderstandingClaimJudgment
}

struct ScreenUnderstandingScoringCase: Sendable, Equatable {
    var id: String
    var stratum: String
    var clusterID: String
    var requiredFacts: [ScreenUnderstandingHumanFact]
    var criticalText: [String]
    var forbiddenFacts: [ScreenUnderstandingHumanFact]
    var meaningfulChange: [ScreenUnderstandingHumanFact]?
    var ambiguity: ScreenUnderstandingAmbiguity
    var abstentionAllowed: Bool
    var claims: [ScreenUnderstandingMappedClaim]
    var visibleText: [String]
    var abstained: Bool
    var temporalPairValid: Bool
}

struct ScreenUnderstandingCaseScore: Sendable, Equatable {
    var id: String
    var stratum: String
    var clusterID: String
    var factRecall: Double
    var criticalTextRecall: Double
    var severityWeightedHallucination: Double
    var usefulness: Double
    var abstentionCredit: Double
    var supportedClaimCount: Int
}

enum ScreenUnderstandingScoringError: Error, LocalizedError, Equatable {
    case invalidTemporalPair
    case contradictoryAbstention
    case duplicateFactID(String)

    var errorDescription: String? {
        switch self {
        case .invalidTemporalPair:
            "invalid temporal pair cannot be scored"
        case .contradictoryAbstention:
            "an abstained result cannot also contain claims"
        case .duplicateFactID(let factID):
            "duplicate human fact identifier: \(factID)"
        }
    }
}

struct ScreenUnderstandingScorer: Sendable {
    func score(_ input: ScreenUnderstandingScoringCase) throws -> ScreenUnderstandingCaseScore {
        if input.meaningfulChange != nil && !input.temporalPairValid {
            throw ScreenUnderstandingScoringError.invalidTemporalPair
        }
        if input.abstained && !input.claims.isEmpty {
            throw ScreenUnderstandingScoringError.contradictoryAbstention
        }

        var required: [String: ScreenUnderstandingHumanFact] = [:]
        var forbidden: [String: ScreenUnderstandingHumanFact] = [:]
        for fact in input.requiredFacts + (input.meaningfulChange ?? []) {
            guard required.updateValue(fact, forKey: fact.id) == nil else {
                throw ScreenUnderstandingScoringError.duplicateFactID(fact.id)
            }
        }
        for fact in input.forbiddenFacts {
            guard required[fact.id] == nil,
                  forbidden.updateValue(fact, forKey: fact.id) == nil else {
                throw ScreenUnderstandingScoringError.duplicateFactID(fact.id)
            }
        }
        var matched = Set<String>()
        var supportedClaimCount = 0
        var hallucination = 0.0

        if input.ambiguity == .unjudgeable && !input.abstained {
            hallucination = Double(input.claims.count) * ScreenUnderstandingFactSeverity.critical.weight
        } else {
            for claim in input.claims {
                switch claim.judgment {
                case .fact(let factID):
                    if required[factID] != nil {
                        matched.insert(factID)
                        supportedClaimCount += 1
                    } else if let forbiddenFact = forbidden[factID] {
                        hallucination += forbiddenFact.severity.weight
                    } else {
                        hallucination += ScreenUnderstandingFactSeverity.major.weight
                    }
                case .unsupported(let severity):
                    hallucination += severity.weight
                case .ambiguous:
                    break
                }
            }
        }

        let factRecall = required.isEmpty
            ? 0
            : Double(matched.count) / Double(required.count)
        let criticalTextRecall = Self.textRecall(
            required: input.criticalText,
            observed: input.visibleText
        )
        let abstentionCredit = input.abstained
            && input.abstentionAllowed
            && input.ambiguity != .judgeable ? 1.0 : 0.0
        let hallucinationPenalty = min(1, hallucination / 4) * 0.5
        let usefulness = max(
            0,
            min(1, factRecall * 0.6 + criticalTextRecall * 0.3 + abstentionCredit - hallucinationPenalty)
        )

        return ScreenUnderstandingCaseScore(
            id: input.id,
            stratum: input.stratum,
            clusterID: input.clusterID,
            factRecall: factRecall,
            criticalTextRecall: criticalTextRecall,
            severityWeightedHallucination: hallucination,
            usefulness: usefulness,
            abstentionCredit: abstentionCredit,
            supportedClaimCount: supportedClaimCount
        )
    }

    private static func textRecall(required: [String], observed: [String]) -> Double {
        guard !required.isEmpty else { return 0 }
        let haystack = normalize(observed.joined(separator: " "))
        let matches = required.reduce(into: 0) { count, requiredText in
            let needle = normalize(requiredText)
            if !needle.isEmpty && haystack.contains(needle) {
                count += 1
            }
        }
        return Double(matches) / Double(required.count)
    }

    private static func normalize(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct ScreenUnderstandingDuplicateLabel: Sendable, Equatable {
    var firstFactIDs: Set<String>
    var secondFactIDs: Set<String>
    var firstDecision: Bool
    var secondDecision: Bool
}

struct ScreenUnderstandingReliabilityResult: Sendable, Equatable {
    var factAgreement: Double
    var decisionAgreement: Double
    var qualified: Bool
}

enum ScreenUnderstandingReliability {
    static func evaluate(
        duplicates: [ScreenUnderstandingDuplicateLabel],
        minimumFactAgreement: Double,
        minimumDecisionAgreement: Double
    ) -> ScreenUnderstandingReliabilityResult {
        guard !duplicates.isEmpty else {
            return .init(factAgreement: 0, decisionAgreement: 0, qualified: false)
        }
        let factAgreement = duplicates.map { duplicate in
            let union = duplicate.firstFactIDs.union(duplicate.secondFactIDs)
            guard !union.isEmpty else { return 1.0 }
            return Double(duplicate.firstFactIDs.intersection(duplicate.secondFactIDs).count)
                / Double(union.count)
        }.reduce(0, +) / Double(duplicates.count)
        let decisionAgreement = Double(duplicates.count {
            $0.firstDecision == $0.secondDecision
        }) / Double(duplicates.count)
        return .init(
            factAgreement: factAgreement,
            decisionAgreement: decisionAgreement,
            qualified: factAgreement >= minimumFactAgreement
                && decisionAgreement >= minimumDecisionAgreement
        )
    }
}

struct ScreenUnderstandingAggregateScore: Sendable, Equatable {
    var factRecall: Double
    var criticalTextRecall: Double
    var severityWeightedHallucination: Double
    var usefulness: Double
}

enum ScreenUnderstandingAggregate {
    static func macro(scores: [ScreenUnderstandingCaseScore]) -> ScreenUnderstandingAggregateScore {
        guard !scores.isEmpty else {
            return .init(
                factRecall: 0,
                criticalTextRecall: 0,
                severityWeightedHallucination: 0,
                usefulness: 0
            )
        }

        let clusterScores = Dictionary(grouping: scores) {
            ClusterKey(stratum: $0.stratum, clusterID: $0.clusterID)
        }.values.map(average)
        let stratumScores = Dictionary(grouping: clusterScores, by: \.stratum).values.map(average)
        let divisor = Double(stratumScores.count)
        return .init(
            factRecall: stratumScores.map(\.factRecall).reduce(0, +) / divisor,
            criticalTextRecall: stratumScores.map(\.criticalTextRecall).reduce(0, +) / divisor,
            severityWeightedHallucination: stratumScores
                .map(\.severityWeightedHallucination).reduce(0, +) / divisor,
            usefulness: stratumScores.map(\.usefulness).reduce(0, +) / divisor
        )
    }

    private struct ClusterKey: Hashable {
        var stratum: String
        var clusterID: String
    }

    private static func average(_ scores: [ScreenUnderstandingCaseScore]) -> ScreenUnderstandingCaseScore {
        let divisor = Double(scores.count)
        return .init(
            id: scores[0].id,
            stratum: scores[0].stratum,
            clusterID: scores[0].clusterID,
            factRecall: scores.map(\.factRecall).reduce(0, +) / divisor,
            criticalTextRecall: scores.map(\.criticalTextRecall).reduce(0, +) / divisor,
            severityWeightedHallucination: scores
                .map(\.severityWeightedHallucination).reduce(0, +) / divisor,
            usefulness: scores.map(\.usefulness).reduce(0, +) / divisor,
            abstentionCredit: scores.map(\.abstentionCredit).reduce(0, +) / divisor,
            supportedClaimCount: scores.map(\.supportedClaimCount).reduce(0, +) / scores.count
        )
    }
}
