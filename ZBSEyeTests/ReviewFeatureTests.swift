import XCTest

final class ReviewFeatureTests: XCTestCase {
    func testLegacyEnabledScheduleSeedsCursorInsteadOfCatchingUp() {
        let migrated = ReviewSchedulePreferenceMigration.resolve(
            explicitReviewEnabled: nil,
            legacyEnabled: true,
            lastAutoDone: nil,
            latestDueKey: "2026-08-13"
        )
        XCTAssertEqual(
            migrated,
            .init(
                enabled: true,
                shouldPersistEnabled: true,
                seededLastAutoDone: "2026-08-13"
            )
        )

        let explicit = ReviewSchedulePreferenceMigration.resolve(
            explicitReviewEnabled: false,
            legacyEnabled: true,
            lastAutoDone: nil,
            latestDueKey: "2026-08-13"
        )
        XCTAssertEqual(
            explicit,
            .init(enabled: false, shouldPersistEnabled: false, seededLastAutoDone: nil)
        )
    }

    func testReviewInheritsSubscriptionPairButRejectsAPIKeyPair() {
        let codex = AIProviderSettings(
            active: AIProvider.codex.rawValue,
            activeModelID: "gpt-5.4-mini"
        )
        XCTAssertEqual(
            codex.selectionSnapshot(for: .manualSummary)?.modelID,
            "gpt-5.4-mini"
        )

        let openAI = AIProviderSettings(
            active: AIProvider.openai.rawValue,
            activeModelID: "gpt-5.4-mini"
        )
        XCTAssertNil(openAI.selectionSnapshot(for: .manualSummary))
        XCTAssertNotNil(openAI.selectionSnapshot(for: .ask))
    }

    func testReviewOverrideDoesNotChangeMainPair() {
        var settings = AIProviderSettings(
            active: AIProvider.codex.rawValue,
            activeModelID: "gpt-5.6-luna"
        )
        XCTAssertTrue(settings.setReviewSelection(ReviewModelSelection(
            providerID: AIProvider.claudeCode.rawValue,
            modelID: "claude-haiku-4-5-20251001"
        )))
        XCTAssertEqual(settings.selectionSnapshot?.modelID, "gpt-5.6-luna")
        XCTAssertEqual(
            settings.selectionSnapshot(for: .manualSummary)?.providerID,
            AIProvider.claudeCode.rawValue
        )
        XCTAssertEqual(settings.selectionSnapshot(for: .ask)?.modelID, "gpt-5.6-luna")
    }

    func testSchemaV2DecodesWithoutReviewOverride() throws {
        let data = Data("""
        {
          "schemaVersion": 2,
          "active": "codex",
          "activeModelID": "gpt-5.4-mini",
          "models": {"codex":"gpt-5.4-mini"},
          "endpoints": {},
          "cloudConsent": {},
          "processingDisabledByUser": false,
          "selectionRevision": 0,
          "authorizationEpoch": 0,
          "consentGrants": {}
        }
        """.utf8)
        let settings = try JSONDecoder().decode(AIProviderSettings.self, from: data)
        XCTAssertNil(settings.reviewSelection)
        XCTAssertEqual(settings.schemaVersion, 3)
    }

    func testCodexMiniCreditCalculationUsesVersionedRates() {
        let billing = ReviewRateCard.billing(
            providerID: AIProvider.codex.rawValue,
            modelID: "gpt-5.4-mini",
            usage: LLMUsage(
                inputTokens: 2_000,
                cachedInputTokens: 1_000,
                outputTokens: 500
            )
        )
        XCTAssertEqual(billing?.amount ?? -1, 0.077125, accuracy: 0.0000001)
        XCTAssertEqual(billing?.rateCardDate, ReviewRateCard.version)
        XCTAssertNil(ReviewRateCard.billing(
            providerID: AIProvider.claudeCode.rawValue,
            modelID: "claude-haiku-4-5-20251001",
            usage: LLMUsage(inputTokens: 2_000, outputTokens: 500)
        ))
        XCTAssertNil(ReviewRateCard.billing(
            providerID: AIProvider.codex.rawValue,
            modelID: "unknown-subscription-model",
            usage: LLMUsage(inputTokens: 2_000, outputTokens: 500)
        ))
    }

    func testFridayScheduleAndWeekdayCatchUpUseOnlyLatestDuePeriod() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 10, hour: 9
        ))) // Monday

        let weekly = try XCTUnwrap(ReviewSchedulePolicy.latestDuePeriod(
            now: now,
            frequency: .weekly,
            hour: 18,
            weeklyWeekday: 6,
            calendar: calendar
        ))
        XCTAssertEqual(calendar.component(.weekday, from: weekly.end.addingTimeInterval(-1)), 6)
        XCTAssertEqual(weekly.kind, .week)
        XCTAssertEqual(
            DailySummaryService.periodKey(weekly, calendar: calendar),
            "2026-08-01--2026-08-07-7d"
        )

        let weekday = try XCTUnwrap(ReviewSchedulePolicy.latestDuePeriod(
            now: now,
            frequency: .weekdays,
            hour: 18,
            weeklyWeekday: 6,
            calendar: calendar
        ))
        XCTAssertEqual(calendar.component(.weekday, from: weekday.start), 6)
        XCTAssertEqual(weekday.kind, .day)
        XCTAssertEqual(DailySummaryService.periodKey(weekday, calendar: calendar), "2026-08-07")
    }

    func testPeriodKeysUseTheSchedulingCalendarTimeZone() throws {
        var bangkok = Calendar(identifier: .gregorian)
        bangkok.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        let bangkokEnd = try XCTUnwrap(bangkok.date(from: DateComponents(
            year: 2026, month: 8, day: 7, hour: 18
        )))
        let bangkokPeriod = ReviewPeriod.ending(at: bangkokEnd, kind: .week, calendar: bangkok)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let utcEnd = try XCTUnwrap(utc.date(from: DateComponents(
            year: 2026, month: 8, day: 7, hour: 18
        )))
        let utcPeriod = ReviewPeriod.ending(at: utcEnd, kind: .week, calendar: utc)

        XCTAssertEqual(
            DailySummaryService.periodKey(bangkokPeriod, calendar: bangkok),
            "2026-08-01--2026-08-07-7d"
        )
        XCTAssertEqual(
            DailySummaryService.periodKey(utcPeriod, calendar: utc),
            "2026-08-01--2026-08-07-7d"
        )
    }

    func testDailyScheduleUsesCalendarDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))

        let afterSpringChange = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 9, hour: 10
        )))
        let springPeriod = try XCTUnwrap(ReviewSchedulePolicy.latestDuePeriod(
            now: afterSpringChange,
            frequency: .daily,
            hour: 18,
            weeklyWeekday: 6,
            calendar: calendar
        ))
        XCTAssertEqual(springPeriod.end.timeIntervalSince(springPeriod.start), 23 * 60 * 60)

        let afterFallChange = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 2, hour: 10
        )))
        let fallPeriod = try XCTUnwrap(ReviewSchedulePolicy.latestDuePeriod(
            now: afterFallChange,
            frequency: .daily,
            hour: 18,
            weeklyWeekday: 6,
            calendar: calendar
        ))
        XCTAssertEqual(fallPeriod.end.timeIntervalSince(fallPeriod.start), 25 * 60 * 60)
    }

    func testReviewPeriodIdentityIsStableAcrossReruns() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 9, hour: 9
        )))
        let evening = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 9, hour: 22
        )))
        XCTAssertEqual(
            ReviewPeriod.ending(at: morning, kind: .day, calendar: calendar),
            ReviewPeriod.ending(at: evening, kind: .day, calendar: calendar)
        )
    }

    func testReviewProviderExcerptRemovesLocalPathsButKeepsWebURLs() {
        let source = "open /Users/nik/private/plan.md and file:///tmp/secret.txt, then https://zbs.gg/review"
        let clean = DailySummaryService.egressText(source)
        XCTAssertFalse(clean.contains("/Users/nik"))
        XCTAssertFalse(clean.contains("file:///tmp"))
        XCTAssertTrue(clean.contains("https://zbs.gg/review"))
    }

    func testSavedReviewReplacesSamePeriodAndPrivacyDeleteRemovesOverlap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        let storage = try StorageManager(mediaDirectory: root.appendingPathComponent("media"))
        let writer = IngestService(db: database, storage: storage)
        let repository = ReviewSummaryRepository(db: database)
        let period = ReviewPeriod.ending(at: Date(), kind: .day)

        func summary(id: String, markdown: String) -> ReviewSummary {
            ReviewSummary(
                id: id,
                period: period,
                generatedAt: Date(),
                markdown: markdown,
                sessions: 3,
                totalCaptures: 42,
                provenance: AIExecutionProvenance(
                    providerID: AIProvider.codex.rawValue,
                    modelID: "gpt-5.4-mini",
                    executedLocally: false,
                    generatedAt: Date(),
                    brokerUpstream: "OpenAI via Codex login"
                ),
                promptVersion: "review-v1",
                usage: LLMUsage(inputTokens: 100, outputTokens: 20),
                billing: nil,
                sourceTruncated: false,
                contextTruncated: false,
                outputTruncated: false,
                coverageIncomplete: false,
                trigger: .manual
            )
        }

        try await writer.saveReviewSummary(summary(id: "first", markdown: "first"))
        try await writer.saveReviewSummary(summary(id: "second", markdown: "second"))
        let replaced = try await repository.summary(for: period)
        XCTAssertEqual(replaced?.id, "second")
        XCTAssertEqual(replaced?.markdown, "second")

        try await writer.deleteReviewSummaries(
            overlappingFromMs: period.startMs,
            toMs: period.endMs
        )
        let deleted = try await repository.summary(for: period)
        XCTAssertNil(deleted)
    }
}
