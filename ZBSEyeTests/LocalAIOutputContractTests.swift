import Foundation
import XCTest

final class LocalAIOutputContractTests: XCTestCase {
    func testAskSupportedAnswerParsesAndRendersCitationsDeterministically() throws {
        let raw = #"{"status":"supported","items":[{"text":"The review is Friday at 14:00.","sources":["[2]","[1]"]}]}"#

        let envelope = try LocalAIOutputParser.parse(
            raw,
            purpose: .ask,
            allowedSources: ["[1]", "[2]"]
        )

        XCTAssertEqual(envelope.status, .supported)
        XCTAssertEqual(envelope.items.count, 1)
        XCTAssertEqual(
            LocalAIOutputRenderer.render(envelope, purpose: .ask),
            "The review is Friday at 14:00. [1] [2]"
        )
    }

    func testInsightsAnswerKeepsSourcesInternalAndRendersOneLinePerItem() throws {
        let raw = #"{"status":"supported","items":[{"text":"Xcode led with 116 minutes.","sources":["top_app"]},{"text":"There were 7 context switches.","sources":["context_switches"]}]}"#

        let envelope = try LocalAIOutputParser.parse(
            raw,
            purpose: .insights,
            allowedSources: ["top_app", "context_switches"]
        )

        XCTAssertEqual(
            LocalAIOutputRenderer.render(envelope, purpose: .insights),
            "Xcode led with 116 minutes.\nThere were 7 context switches."
        )
    }

    func testRejectsProseMarkdownAndTrailingObjectsWithoutRepair() {
        let valid = #"{"status":"not_found","items":[{"text":"I did not find that.","sources":[]}]}"#
        for raw in [
            "Answer: \(valid)",
            "```json\n\(valid)\n```",
            "\(valid) trailing",
            "\(valid) \(valid)",
        ] {
            XCTAssertThrowsError(
                try LocalAIOutputParser.parse(raw, purpose: .ask, allowedSources: [])
            )
        }
    }

    func testRejectsUnknownFieldsAndMalformedSchema() {
        let unknownEnvelope = #"{"status":"not_found","items":[{"text":"Not found.","sources":[]}],"explanation":"extra"}"#
        let unknownItem = #"{"status":"not_found","items":[{"text":"Not found.","sources":[],"confidence":1}]}"#
        let missingItems = #"{"status":"not_found"}"#

        for raw in [unknownEnvelope, unknownItem, missingItems] {
            XCTAssertThrowsError(
                try LocalAIOutputParser.parse(raw, purpose: .ask, allowedSources: [])
            )
        }
    }

    func testRejectsInventedDuplicateAndInlineSources() {
        let invented = #"{"status":"supported","items":[{"text":"Done.","sources":["[9]"]}]}"#
        let duplicate = #"{"status":"supported","items":[{"text":"Done.","sources":["[1]","[1]"]}]}"#
        let inline = #"{"status":"supported","items":[{"text":"Done [1].","sources":["[1]"]}]}"#

        for raw in [invented, duplicate, inline] {
            XCTAssertThrowsError(
                try LocalAIOutputParser.parse(raw, purpose: .ask, allowedSources: ["[1]"])
            )
        }
    }

    func testRejectsWrongStatusForConsumerAndMissingGrounding() {
        let askConflict = #"{"status":"conflict","items":[{"text":"The dates conflict.","sources":["[1]"]}]}"#
        let ungroundedAsk = #"{"status":"supported","items":[{"text":"It is done.","sources":[]}] }"#
        let insightNotFound = #"{"status":"not_found","items":[{"text":"Not found.","sources":[]}]}"#

        XCTAssertThrowsError(
            try LocalAIOutputParser.parse(askConflict, purpose: .ask, allowedSources: ["[1]"])
        )
        XCTAssertThrowsError(
            try LocalAIOutputParser.parse(ungroundedAsk, purpose: .ask, allowedSources: ["[1]"])
        )
        XCTAssertThrowsError(
            try LocalAIOutputParser.parse(insightNotFound, purpose: .insights, allowedSources: [])
        )
    }

    func testAbsenceAndInsufficientAnswersHaveOneBoundedItem() throws {
        let notFound = #"{"status":"not_found","items":[{"text":"I did not find that. Try searching for the airport transfer page.","sources":[]}]}"#
        let insufficient = #"{"status":"insufficient","items":[{"text":"There is not enough data for a reliable insight.","sources":["total_captures"]}]}"#

        XCTAssertNoThrow(
            try LocalAIOutputParser.parse(notFound, purpose: .ask, allowedSources: [])
        )
        XCTAssertNoThrow(
            try LocalAIOutputParser.parse(
                insufficient,
                purpose: .insights,
                allowedSources: ["total_captures"]
            )
        )

        let twoAbsenceItems = #"{"status":"not_found","items":[{"text":"Not found.","sources":[]},{"text":"Try again.","sources":[]}]}"#
        XCTAssertThrowsError(
            try LocalAIOutputParser.parse(twoAbsenceItems, purpose: .ask, allowedSources: [])
        )
    }

    func testRejectsUnsafeOrUnboundedText() {
        let newline = #"{"status":"supported","items":[{"text":"Line one.\nLine two.","sources":["[1]"]}]}"#
        let url = #"{"status":"supported","items":[{"text":"Open https://example.com.","sources":["[1]"]}]}"#
        let bullet = #"{"status":"supported","items":[{"text":"- A result.","sources":["[1]"]}]}"#
        let longText = String(repeating: "a", count: 241)
        let oversized = #"{"status":"supported","items":[{"text":"\#(longText)","sources":["[1]"]}]}"#

        for raw in [newline, url, bullet, oversized] {
            XCTAssertThrowsError(
                try LocalAIOutputParser.parse(raw, purpose: .ask, allowedSources: ["[1]"])
            )
        }
    }

    func testSummaryAllowsBoundedMarkdownWhileLabelStaysOneLine() throws {
        let markdown = """
        ## Что делал
        - Собрал общий router
        - Проверил тесты
        """
        let summaryRaw = try XCTUnwrap(String(
            data: JSONEncoder().encode(LocalAIOutputEnvelope(
                status: .supported,
                items: [.init(text: markdown, sources: ["slice:0", "slice:1"])]
            )),
            encoding: .utf8
        ))
        let summary = try LocalAIOutputParser.parse(
            summaryRaw,
            purpose: .summary,
            allowedSources: ["slice:0", "slice:1"]
        )
        XCTAssertEqual(
            LocalAIOutputRenderer.render(summary, purpose: .summary, language: .ru),
            markdown
        )

        let labelRaw = #"{"status":"supported","items":[{"text":"Работа над ZBS Eye в Xcode","sources":["activity_block"]}]}"#
        let label = try LocalAIOutputParser.parse(
            labelRaw,
            purpose: .label,
            allowedSources: ["activity_block"]
        )
        XCTAssertEqual(
            LocalAIOutputRenderer.render(label, purpose: .label, language: .ru),
            "Работа над ZBS Eye в Xcode"
        )

        let multilineLabel = #"{"status":"supported","items":[{"text":"Line one.\nLine two.","sources":["activity_block"]}]}"#
        XCTAssertThrowsError(
            try LocalAIOutputParser.parse(
                multilineLabel,
                purpose: .label,
                allowedSources: ["activity_block"]
            )
        )
    }
}
