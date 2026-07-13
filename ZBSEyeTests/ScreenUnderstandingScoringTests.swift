import XCTest

final class ScreenUnderstandingScoringTests: XCTestCase {
    func testCriticalTextNormalizationHandlesUnicodeCaseAndPunctuation() throws {
        let score = try ScreenUnderstandingScorer().score(
            makeCase(
                requiredFacts: [fact("visible.greeting", "Greeting is visible")],
                criticalText: ["Привет world"],
                claims: [claim("A greeting is visible", .fact("visible.greeting"))],
                visibleText: ["ПРИВЕТ, WORLD!"]
            )
        )
        XCTAssertEqual(score.factRecall, 1)
        XCTAssertEqual(score.criticalTextRecall, 1)
        XCTAssertEqual(score.severityWeightedHallucination, 0)
    }

    func testForbiddenIntentAndUnsupportedClaimsAreHallucinations() throws {
        let score = try ScreenUnderstandingScorer().score(
            makeCase(
                forbiddenFacts: [fact("intent.purchase", "User intends to buy", .critical)],
                claims: [
                    claim("The user wants to buy it", .fact("intent.purchase")),
                    claim("A meeting starts soon", .unsupported(.major)),
                ]
            )
        )
        XCTAssertEqual(score.severityWeightedHallucination, 6)
        XCTAssertEqual(score.supportedClaimCount, 0)
    }

    func testManualFactMappingAcceptsParaphraseButNeverUnsupportedWording() throws {
        let label = makeCase(
            requiredFacts: [fact("window.editor", "A text editor window is visible")],
            claims: [claim("An editor occupies the screen", .fact("window.editor"))]
        )
        let mapped = try ScreenUnderstandingScorer().score(label)
        XCTAssertEqual(mapped.factRecall, 1)

        var unsupported = label
        unsupported.claims = [claim("An editor occupies the screen", .unsupported(.major))]
        let rejected = try ScreenUnderstandingScorer().score(unsupported)
        XCTAssertEqual(rejected.factRecall, 0)
        XCTAssertEqual(rejected.severityWeightedHallucination, 2)
    }

    func testCorrectAbstentionOnUnjudgeableCaseGetsCredit() throws {
        let abstained = try ScreenUnderstandingScorer().score(
            makeCase(ambiguity: .unjudgeable, abstentionAllowed: true, abstained: true)
        )
        XCTAssertEqual(abstained.abstentionCredit, 1)
        XCTAssertEqual(abstained.severityWeightedHallucination, 0)

        let confident = try ScreenUnderstandingScorer().score(
            makeCase(
                ambiguity: .unjudgeable,
                abstentionAllowed: true,
                claims: [claim("The user is coding", .fact("intent.coding"))],
                abstained: false
            )
        )
        XCTAssertEqual(confident.abstentionCredit, 0)
        XCTAssertGreaterThan(confident.severityWeightedHallucination, 0)
    }

    func testInvalidTemporalPairNeverReachesDeltaScorer() throws {
        XCTAssertThrowsError(try ScreenUnderstandingScorer().score(
            makeCase(
                meaningfulChange: [fact("change.dialog", "A dialog appeared")],
                temporalPairValid: false
            )
        ))
    }

    func testReliabilityBelowEitherFloorBlocksQualification() {
        let result = ScreenUnderstandingReliability.evaluate(
            duplicates: [
                .init(firstFactIDs: ["a", "b"], secondFactIDs: ["a"], firstDecision: true, secondDecision: true),
                .init(firstFactIDs: ["c"], secondFactIDs: ["d"], firstDecision: true, secondDecision: false),
            ],
            minimumFactAgreement: 0.90,
            minimumDecisionAgreement: 0.80
        )
        XCTAssertFalse(result.qualified)
        XCTAssertLessThan(result.factAgreement, 0.90)
        XCTAssertLessThan(result.decisionAgreement, 0.80)
    }

    func testMacroAggregateIsStableWhenDuplicateClusterIsRepeated() throws {
        let scorer = ScreenUnderstandingScorer()
        let strong = try scorer.score(makeCase(
            id: "case-strong",
            stratum: "text-rich",
            clusterID: "cluster-a",
            requiredFacts: [fact("a", "A")],
            claims: [claim("A", .fact("a"))]
        ))
        let weak = try scorer.score(makeCase(
            id: "case-weak",
            stratum: "visual-canvas",
            clusterID: "cluster-b",
            requiredFacts: [fact("b", "B")]
        ))
        let original = ScreenUnderstandingAggregate.macro(scores: [strong, weak])
        let repeated = ScreenUnderstandingAggregate.macro(
            scores: [strong, strong, strong, strong, weak]
        )
        XCTAssertEqual(original.factRecall, repeated.factRecall)
        XCTAssertEqual(original.usefulness, repeated.usefulness)
    }

    private func fact(
        _ id: String,
        _ text: String,
        _ severity: ScreenUnderstandingFactSeverity = .minor
    ) -> ScreenUnderstandingReferenceFact {
        .init(id: id, text: text, severity: severity)
    }

    private func claim(
        _ text: String,
        _ judgment: ScreenUnderstandingClaimJudgment
    ) -> ScreenUnderstandingMappedClaim {
        .init(text: text, judgment: judgment)
    }

    private func makeCase(
        id: String = "case",
        stratum: String = "text-rich",
        clusterID: String = "cluster",
        requiredFacts: [ScreenUnderstandingReferenceFact] = [],
        criticalText: [String] = [],
        forbiddenFacts: [ScreenUnderstandingReferenceFact] = [],
        meaningfulChange: [ScreenUnderstandingReferenceFact]? = nil,
        ambiguity: ScreenUnderstandingAmbiguity = .judgeable,
        abstentionAllowed: Bool = false,
        claims: [ScreenUnderstandingMappedClaim] = [],
        visibleText: [String] = [],
        abstained: Bool = false,
        temporalPairValid: Bool = true
    ) -> ScreenUnderstandingScoringCase {
        .init(
            id: id,
            stratum: stratum,
            clusterID: clusterID,
            requiredFacts: requiredFacts,
            criticalText: criticalText,
            forbiddenFacts: forbiddenFacts,
            meaningfulChange: meaningfulChange,
            ambiguity: ambiguity,
            abstentionAllowed: abstentionAllowed,
            claims: claims,
            visibleText: visibleText,
            abstained: abstained,
            temporalPairValid: temporalPairValid
        )
    }
}
