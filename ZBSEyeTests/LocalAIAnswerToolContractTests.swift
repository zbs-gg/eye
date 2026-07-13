import MLXLMCommon
import XCTest

final class LocalAIAnswerToolContractTests: XCTestCase {
    func testPurposeSpecificSchemasExposeOnlyFieldsAndStatusesTheParserAccepts() throws {
        XCTAssertEqual(
            try schemaDetails(for: .ask),
            SchemaDetails(
                properties: [
                    "status", "item1_text", "item1_sources",
                    "item2_text", "item2_sources", "next_search",
                ],
                statuses: ["supported", "uncertain", "not_found"]
            )
        )
        XCTAssertEqual(
            try schemaDetails(for: .insights),
            SchemaDetails(
                properties: [
                    "status", "item1_text", "item1_sources",
                    "item2_text", "item2_sources",
                    "item3_text", "item3_sources",
                ],
                statuses: ["supported", "conflict", "insufficient"]
            )
        )
        for purpose in [LocalAIOutputPurpose.summary, .label] {
            XCTAssertEqual(
                try schemaDetails(for: purpose),
                SchemaDetails(
                    properties: ["status", "item1_text", "item1_sources"],
                    statuses: ["supported"]
                )
            )
        }
    }

    func testSupportedCallBuildsValidatedAskEnvelope() throws {
        let call = makeCall([
            "status": .string("supported"),
            "item1_text": .string("The review is Friday at 14:00."),
            "item1_sources": .array([.string("[1]")]),
            "item2_text": .string("Maya owns it."),
            "item2_sources": .array([.string("[1]")]),
            "item3_text": .string(""),
            "item3_sources": .array([]),
            "next_search": .string(""),
        ])

        let envelope = try LocalAIAnswerToolContract.parse(
            call,
            purpose: .ask,
            allowedSources: ["[1]"]
        )

        XCTAssertEqual(envelope.status, .supported)
        XCTAssertEqual(envelope.items.count, 2)
        XCTAssertNil(envelope.nextSearch)
        XCTAssertEqual(
            LocalAIOutputRenderer.render(envelope, purpose: .ask, language: .en),
            "The review is Friday at 14:00. [1] Maya owns it. [1]"
        )
    }

    func testAskNumericToolSourceCanonicalizesToDisplayCitation() throws {
        let envelope = try LocalAIAnswerToolContract.parse(
            makeCall([
                "status": .string("supported"),
                "item1_text": .string("Fact."),
                "item1_sources": .array([.string("1")]),
            ]),
            purpose: .ask,
            allowedSources: ["[1]"]
        )

        XCTAssertEqual(envelope.items[0].sources, ["[1]"])

        let bridgedBoolean = try LocalAIAnswerToolContract.parse(
            makeCall([
                "status": .string("supported"),
                "item1_text": .string("Fact."),
                "item1_sources": .array([.bool(true)]),
            ]),
            purpose: .ask,
            allowedSources: ["[1]"]
        )
        XCTAssertEqual(bridgedBoolean.items[0].sources, ["[1]"])
    }

    func testSafeUnusedPlaceholdersDoNotInvalidateDisplayedOutput() throws {
        let envelope = try LocalAIAnswerToolContract.parse(
            makeCall([
                "status": .string("uncertain"),
                "item1_text": .string("Draft saved."),
                "item1_sources": .array([.string("[1]")]),
                "item2_text": .string(""),
                "item2_sources": .string(""),
                "next_search": .string("Try check the pending attachment."),
            ]),
            purpose: .ask,
            allowedSources: ["[1]"]
        )

        XCTAssertEqual(envelope.status, .uncertain)
        XCTAssertNil(envelope.nextSearch)
        XCTAssertEqual(envelope.items.count, 1)
    }

    func testUncertainRendererOwnsTheSafetyCriticalConclusion() throws {
        let call = makeCall([
            "status": .string("uncertain"),
            "item1_text": .string("Сообщение осталось черновиком с ожидающим вложением."),
            "item1_sources": .array([.string("[1]"), .string("[2]")]),
        ])

        let envelope = try LocalAIAnswerToolContract.parse(
            call,
            purpose: .ask,
            allowedSources: ["[1]", "[2]"]
        )

        XCTAssertEqual(
            LocalAIOutputRenderer.render(envelope, purpose: .ask, language: .ru),
            "История не подтверждает завершение действия. Сообщение осталось черновиком с ожидающим вложением. [1] [2]"
        )
    }

    func testNotFoundUsesFixedAbsenceCopyAndValidatedSearchSuggestion() throws {
        let call = makeCall([
            "status": .string("not_found"),
            "item1_text": .string("ignored model absence wording"),
            "item1_sources": .array([]),
            "next_search": .string("Попробуйте поискать письмо с подтверждением бронирования."),
        ])

        let envelope = try LocalAIAnswerToolContract.parse(
            call,
            purpose: .ask,
            allowedSources: ["[1]"]
        )

        XCTAssertTrue(envelope.items.isEmpty)
        XCTAssertEqual(
            LocalAIOutputRenderer.render(envelope, purpose: .ask, language: .ru),
            "В переданной истории это не найдено. Попробуйте поискать письмо с подтверждением бронирования."
        )
    }

    func testConflictAndInsufficientCopyAreDeterministic() throws {
        let conflict = try LocalAIAnswerToolContract.parse(
            makeCall([
                "status": .string("conflict"),
                "item1_text": .string("Launch moved to Monday; review is tentative Tuesday."),
                "item1_sources": .array([
                    .string("safe_text_fact:0"), .string("safe_text_fact:1"),
                ]),
            ]),
            purpose: .insights,
            allowedSources: ["safe_text_fact:0", "safe_text_fact:1"]
        )
        XCTAssertEqual(
            LocalAIOutputRenderer.render(conflict, purpose: .insights, language: .en),
            "The sources conflict: Launch moved to Monday; review is tentative Tuesday."
        )

        let insufficient = try LocalAIAnswerToolContract.parse(
            makeCall([
                "status": .string("insufficient"),
                "item1_text": .string(""),
                "item1_sources": .array([.string("total_captures")]),
            ]),
            purpose: .insights,
            allowedSources: ["total_captures"]
        )
        XCTAssertTrue(insufficient.items.isEmpty)
        XCTAssertEqual(
            LocalAIOutputRenderer.render(insufficient, purpose: .insights, language: .en),
            "There is not enough data for a reliable insight."
        )
    }


    func testConflictMayUseOneItemPerConflictingSource() throws {
        let envelope = try LocalAIAnswerToolContract.parse(
            makeCall([
                "status": .string("conflict"),
                "item1_text": .string("Launch moved to Monday"),
                "item1_sources": .array([.string("safe_text_fact:0")]),
                "item2_text": .string("Review is tentative Tuesday"),
                "item2_sources": .array([.string("safe_text_fact:1")]),
            ]),
            purpose: .insights,
            allowedSources: ["safe_text_fact:0", "safe_text_fact:1"]
        )

        XCTAssertEqual(envelope.items.count, 2)
        XCTAssertEqual(
            LocalAIOutputRenderer.render(envelope, purpose: .insights, language: .en),
            "The sources conflict: Launch moved to Monday; Review is tentative Tuesday"
        )
    }

    func testSummaryAndLabelCallsPreserveTheirTypedText() throws {
        let markdown = """
        ## Что делал
        - Собрал router
        - Проверил тесты
        """
        let summary = try LocalAIAnswerToolContract.parse(
            makeCall([
                "status": .string("supported"),
                "item1_text": .string(markdown),
                "item1_sources": .array([.string("slice:0"), .string("slice:1")]),
            ]),
            purpose: .summary,
            allowedSources: ["slice:0", "slice:1"]
        )
        XCTAssertEqual(
            LocalAIOutputRenderer.render(summary, purpose: .summary, language: .ru),
            markdown
        )

        let label = try LocalAIAnswerToolContract.parse(
            makeCall([
                "status": .string("supported"),
                "item1_text": .string("Работа над ZBS Eye в Xcode"),
                "item1_sources": .array([.string("activity_block")]),
            ]),
            purpose: .label,
            allowedSources: ["activity_block"]
        )
        XCTAssertEqual(
            LocalAIOutputRenderer.render(label, purpose: .label, language: .ru),
            "Работа над ZBS Eye в Xcode"
        )
    }

    func testRejectsWrongFunctionUnknownArgumentsAndInventedSources() {
        let wrongName = ToolCall(
            function: .init(
                name: "other",
                arguments: [
                    "status": .string("supported"),
                    "item1_text": .string("Fact."),
                    "item1_sources": .array([.string("[1]")]),
                ]
            )
        )
        XCTAssertThrowsError(
            try LocalAIAnswerToolContract.parse(
                wrongName,
                purpose: .ask,
                allowedSources: ["[1]"]
            )
        )

        var unknown = validArguments()
        unknown["confidence"] = .double(0.9)
        XCTAssertThrowsError(
            try LocalAIAnswerToolContract.parse(
                makeCall(unknown),
                purpose: .ask,
                allowedSources: ["[1]"]
            )
        )

        var invented = validArguments()
        invented["item1_sources"] = .array([.string("[9]")])
        XCTAssertThrowsError(
            try LocalAIAnswerToolContract.parse(
                makeCall(invented),
                purpose: .ask,
                allowedSources: ["[1]"]
            )
        )
    }

    func testRejectsMissingOrUnsafeSearchSuggestion() {
        XCTAssertThrowsError(
            try LocalAIAnswerToolContract.parse(
                makeCall([
                    "status": .string("not_found"),
                    "item1_text": .string(""),
                    "item1_sources": .array([]),
                ]),
                purpose: .ask,
                allowedSources: []
            )
        )

        XCTAssertThrowsError(
            try LocalAIAnswerToolContract.parse(
                makeCall([
                    "status": .string("not_found"),
                    "item1_text": .string(""),
                    "item1_sources": .array([]),
                    "next_search": .string("Search somewhere else."),
                ]),
                purpose: .ask,
                allowedSources: []
            )
        )

        var supported = validArguments()
        supported["next_search"] = .string("Try https://example.com")
        XCTAssertThrowsError(
            try LocalAIAnswerToolContract.parse(
                makeCall(supported),
                purpose: .ask,
                allowedSources: ["[1]"]
            )
        )
    }

    private func validArguments() -> [String: JSONValue] {
        [
            "status": .string("supported"),
            "item1_text": .string("Fact."),
            "item1_sources": .array([.string("[1]")]),
        ]
    }

    private struct SchemaDetails: Equatable {
        let properties: Set<String>
        let statuses: Set<String>
    }

    private func schemaDetails(for purpose: LocalAIOutputPurpose) throws -> SchemaDetails {
        let schema = LocalAIAnswerToolContract.schema(for: purpose)
        let function = try XCTUnwrap(schema["function"] as? [String: any Sendable])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: any Sendable])
        XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
        XCTAssertEqual(
            parameters["required"] as? [String],
            ["status", "item1_text", "item1_sources"]
        )
        let properties = try XCTUnwrap(
            parameters["properties"] as? [String: any Sendable]
        )
        let status = try XCTUnwrap(properties["status"] as? [String: any Sendable])
        let statuses = try XCTUnwrap(status["enum"] as? [String])
        return SchemaDetails(properties: Set(properties.keys), statuses: Set(statuses))
    }

    private func makeCall(_ arguments: [String: JSONValue]) -> ToolCall {
        ToolCall(
            function: .init(
                name: LocalAIAnswerToolContract.functionName,
                arguments: arguments
            )
        )
    }
}
