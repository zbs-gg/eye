import Foundation
import XCTest

final class ActivityDaySummaryServiceTests: XCTestCase {
    func testPrepareUsesExplicitDSTDayRangeAndFiltersSystemProtectedAndPrivateFields() async throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8,
            hour: 12
        )))
        let start = calendar.startOfDay(for: day)
        let provider = SummaryCaptureFixture([
            capture(1, at: start.addingTimeInterval(60), app: "loginwindow",
                    bundle: "com.apple.loginwindow", title: "Authentication"),
            capture(2, at: start.addingTimeInterval(120), app: "Dock",
                    bundle: "com.apple.dock", title: "Recent apps"),
            capture(3, at: start.addingTimeInterval(180), app: "Safari",
                    bundle: "com.apple.Safari", title: "Private tab",
                    url: "https://github.com/zbs-gg/eye?token=secret"),
            capture(4, at: start.addingTimeInterval(240), app: "Xcode",
                    bundle: "com.apple.dt.Xcode", title: "/Users/nik/private.swift"),
            capture(5, at: start.addingTimeInterval(300), app: "Terminal",
                    bundle: "com.apple.Terminal", title: "Deploy token=super-secret"),
        ])
        let service = ActivityDaySummaryService(
            provider: provider,
            generator: SummaryGeneratorFixture()
        )

        let input = try await service.prepare(day: day, timeZone: timeZone)
        let recordedRange = await provider.lastRange()
        let range = try XCTUnwrap(recordedRange)

        XCTAssertEqual(input.dayKey, "2026-03-08")
        XCTAssertEqual(input.sourceStartMs, msFromDate(start))
        XCTAssertEqual(input.sourceEndMs - input.sourceStartMs, 23 * 60 * 60 * 1_000)
        XCTAssertEqual(range.fromMs, input.sourceStartMs)
        XCTAssertEqual(range.toMs, input.sourceEndMs - 1)
        XCTAssertEqual(input.sourceCount, 3)
        XCTAssertEqual(input.fragments.count, 3)

        let prompt = input.fragments.map(\.text).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("github.com"))
        XCTAssertTrue(prompt.contains("[path]"))
        XCTAssertTrue(prompt.contains("[secret]"))
        for forbidden in [
            "loginwindow", "Dock", "https://", "/Users/", "token=secret", "super-secret",
        ] {
            XCTAssertFalse(prompt.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
    }

    func testPrepareKeepsOneBoundedRequestWorthOfLongestSessions() async throws {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        var captures: [CaptureLite] = []
        for index in 0..<40 {
            captures.append(capture(
                Int64(index + 1),
                at: day.addingTimeInterval(Double(index * 600)),
                app: "App\(index)",
                bundle: "com.example.app\(index)",
                title: "Task \(index)"
            ))
        }
        let service = ActivityDaySummaryService(
            provider: SummaryCaptureFixture(captures),
            generator: SummaryGeneratorFixture()
        )

        let input = try await service.prepare(day: day, timeZone: timeZone)

        XCTAssertEqual(input.fragments.count, 24)
        XCTAssertEqual(Set(input.fragments.map(\.sourceID)).count, 24)
        XCTAssertTrue(input.fragments.allSatisfy { $0.text.count <= 240 })
    }

    func testGenerateMakesOneActivitySummaryRequestAndReturnsSafePlainBullets() async throws {
        let generator = SummaryGeneratorFixture(output: [
            "- Worked on github.com",
            "- Reviewed token=super-secret",
            "- Edited release notes",
        ].joined(separator: "\n"))
        let service = ActivityDaySummaryService(
            provider: SummaryCaptureFixture([]),
            generator: generator
        )
        let input = summaryInput(dayKey: "2026-08-08", fingerprint: "a")
        let execution = summaryExecution()

        let result = try await service.generate(
            input: input,
            execution: execution,
            requestID: UUID()
        )
        let plans = await generator.plans()

        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].consumer, .activitySummary)
        XCTAssertEqual(plans[0].priority, .explicitInsight)
        XCTAssertEqual(plans[0].fragments, input.fragments)
        XCTAssertEqual(result.bullets.count, 3)
        XCTAssertTrue(result.bullets[0].contains("github.com"))
        XCTAssertTrue(result.bullets[1].contains("[secret]"))
        XCTAssertFalse(result.summary.contains("super-secret"))
    }

    func testGenerateRejectsSyntacticallyValidButTruncatedOutput() async throws {
        let generator = SummaryGeneratorFixture(
            output: "- One\n- Two\n- Three",
            outputTruncated: true
        )
        let service = ActivityDaySummaryService(
            provider: SummaryCaptureFixture([]),
            generator: generator
        )

        do {
            _ = try await service.generate(
                input: summaryInput(dayKey: "2026-08-08", fingerprint: "truncated"),
                execution: summaryExecution(),
                requestID: UUID()
            )
            XCTFail("Expected a length-truncated model response to be rejected")
        } catch {
            XCTAssertEqual(error as? ActivityDaySummaryError, .invalidOutput)
        }
    }

    func testSafeBulletsRejectsAnythingExceptThreeToSixExactBulletLines() {
        XCTAssertThrowsError(try ActivityDaySummaryService.safeBullets("- One\n- Two"))
        XCTAssertThrowsError(try ActivityDaySummaryService.safeBullets(
            "Heading\n- One\n- Two\n- Three"
        ))
        XCTAssertNoThrow(try ActivityDaySummaryService.safeBullets(
            "- One\n- Two\n- Three\n- Four\n- Five\n- Six"
        ))
    }

}

@MainActor
final class ActivityDaySummaryStoreTests: XCTestCase {
    func testNoAuthorizedRouteShowsUnavailableWithoutGeneration() async {
        let service = SummaryServiceFixture()
        let store = ActivityDaySummaryStore(
            service: service,
            cache: SummaryCacheFixture(),
            readiness: SummaryReadinessFixture(nil),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        await store.load(day: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(store.phase, .unavailable)
        XCTAssertNil(store.content)
        let generated = await service.generationCount()
        XCTAssertEqual(generated, 0)
    }

    func testMissingCacheAutoGeneratesThenCurrentDayThrottleAndManualRefreshBypass() async throws {
        let clock = SummaryTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let service = SummaryServiceFixture()
        let cache = SummaryCacheFixture()
        let execution = summaryExecution()
        let store = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: SummaryReadinessFixture(execution),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            now: { clock.value }
        )
        let day = clock.value

        await store.load(day: day)
        XCTAssertEqual(store.phase, .cached)
        XCTAssertEqual(store.content?.bullets, ["Task 2027-01-15 A", "Task 2027-01-15 B", "Task 2027-01-15 C"])
        var generated = await service.generationCount()
        let cached = try await cache.snapshot(dayKey: "2027-01-15").entry
        XCTAssertEqual(generated, 1)
        XCTAssertNotNil(cached)

        await service.setFingerprint("changed")
        clock.advance(by: 10 * 60)
        await store.load(day: day)
        XCTAssertEqual(store.phase, .cached)
        generated = await service.generationCount()
        XCTAssertEqual(generated, 1)

        await store.refresh()
        XCTAssertEqual(store.phase, .cached)
        generated = await service.generationCount()
        XCTAssertEqual(generated, 2)
    }

    func testRuntimeTimeZoneChangeUsesOneSnapshotForVisibleDayAndSourceRange() async throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let honolulu = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = utc
        let now = try XCTUnwrap(utcCalendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 8,
            hour: 12
        )))
        let selectedBeforeChange = utcCalendar.startOfDay(for: now)
        var honoluluCalendar = Calendar(identifier: .gregorian)
        honoluluCalendar.timeZone = honolulu
        let expectedStart = honoluluCalendar.startOfDay(for: selectedBeforeChange)
        let expectedEnd = try XCTUnwrap(
            honoluluCalendar.date(byAdding: .day, value: 1, to: expectedStart)
        )
        let captureProvider = SummaryCaptureFixture([
            capture(
                1,
                at: expectedStart.addingTimeInterval(60 * 60),
                app: "Xcode",
                bundle: "com.apple.dt.Xcode",
                title: "ZBS Eye"
            ),
        ])
        let service = ActivityDaySummaryService(
            provider: captureProvider,
            generator: SummaryGeneratorFixture()
        )
        let cache = SummaryCacheFixture()
        let timeZones = SummaryTimeZoneSource(utc)
        let store = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: SummaryReadinessFixture(summaryExecution()),
            timeZoneProvider: { timeZones.snapshot() },
            now: { now }
        )
        XCTAssertEqual(timeZones.readCount, 1)

        timeZones.update(honolulu)
        await store.load(day: selectedBeforeChange)

        let recordedRange = await captureProvider.lastRange()
        let range = try XCTUnwrap(recordedRange)
        let dayKey = ActivityDaySummaryDayKey.make(
            for: expectedStart,
            timeZone: honolulu
        )
        let persisted = try await cache.snapshot(dayKey: dayKey).entry
        XCTAssertEqual(timeZones.readCount, 2)
        XCTAssertEqual(store.selectedDay, expectedStart)
        XCTAssertTrue(honoluluCalendar.isDate(
            store.selectedDay,
            inSameDayAs: selectedBeforeChange
        ))
        XCTAssertEqual(range.fromMs, msFromDate(expectedStart))
        XCTAssertEqual(range.toMs, msFromDate(expectedEnd) - 1)
        XCTAssertEqual(persisted?.dayKey, dayKey)
        XCTAssertEqual(persisted?.sourceStartMs, msFromDate(expectedStart))
        XCTAssertEqual(persisted?.sourceEndMs, msFromDate(expectedEnd))
    }

    func testSameDayKeyAfterTimeZoneChangeRegeneratesForNewDayBoundaries() async throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let bangkok = try XCTUnwrap(TimeZone(identifier: "Asia/Bangkok"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let initialNow = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 8,
            hour: 12
        )))
        let clock = SummaryTestClock(initialNow)
        let timeZones = SummaryTimeZoneSource(utc)
        let service = SummaryServiceFixture()
        let cache = SummaryCacheFixture()
        let store = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: SummaryReadinessFixture(summaryExecution()),
            timeZoneProvider: { timeZones.snapshot() },
            now: { clock.value }
        )

        await store.load(day: clock.value)
        let utcSnapshot = try await cache.snapshot(dayKey: "2026-08-08")
        let utcEntry = try XCTUnwrap(utcSnapshot.entry)

        timeZones.update(bangkok)
        clock.advance(by: 10 * 60)
        await store.load(day: clock.value)

        let bangkokSnapshot = try await cache.snapshot(dayKey: "2026-08-08")
        let bangkokEntry = try XCTUnwrap(bangkokSnapshot.entry)
        let generated = await service.generationCount()
        XCTAssertEqual(generated, 2)
        XCTAssertNotEqual(bangkokEntry.sourceStartMs, utcEntry.sourceStartMs)
        XCTAssertNotEqual(bangkokEntry.sourceEndMs, utcEntry.sourceEndMs)
        XCTAssertEqual(bangkokEntry.sourceStartMs, msFromDate(store.selectedDay))
        XCTAssertEqual(timeZones.readCount, 3)
    }

    func testLateOldDayCannotReplaceTheNewSelectedDay() async {
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let second = first.addingTimeInterval(86_400)
        let service = SummaryServiceFixture(slowDayKey: "2027-01-15")
        let cache = SummaryCacheFixture()
        let store = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: SummaryReadinessFixture(summaryExecution()),
            timeZone: timeZone,
            now: { second }
        )

        let oldLoad = Task { await store.load(day: first) }
        await Task.yield()
        await store.load(day: second)
        await oldLoad.value

        XCTAssertEqual(
            ActivityDaySummaryDayKey.make(for: store.selectedDay, timeZone: timeZone),
            "2027-01-16"
        )
        XCTAssertEqual(
            store.content?.bullets,
            ["Task 2027-01-16 A", "Task 2027-01-16 B", "Task 2027-01-16 C"]
        )
        XCTAssertEqual(store.phase, .cached)
    }

    func testDifferentRouteCacheIsNotShownOrAllowedToThrottleNewRoute() async throws {
        let clock = SummaryTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let service = SummaryServiceFixture()
        let cache = SummaryCacheFixture()
        let firstRoute = summaryExecution()
        let readiness = SummaryReadinessFixture(firstRoute)
        let store = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: readiness,
            timeZone: timeZone,
            now: { clock.value }
        )
        await store.load(day: clock.value)
        XCTAssertEqual(store.content?.providerID, AIProvider.ollama.rawValue)

        let secondRoute = summaryExecution(
            provider: .lmstudio,
            modelID: "second-local-model"
        )
        readiness.update(secondRoute)
        clock.advance(by: 10 * 60)
        await store.load(day: clock.value)

        XCTAssertEqual(store.phase, .cached)
        XCTAssertEqual(store.content?.providerID, AIProvider.lmstudio.rawValue)
        XCTAssertEqual(store.content?.modelID, "second-local-model")
        let generated = await service.generationCount()
        XCTAssertEqual(generated, 2)
        let persisted = try await cache.snapshot(dayKey: "2027-01-15").entry
        XCTAssertEqual(persisted?.providerID, AIProvider.lmstudio.rawValue)
    }

    func testSameCustomAPIModelAtNewRecipientRegeneratesAndNamesOnlySafeOrigin() async throws {
        let clock = SummaryTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let service = SummaryServiceFixture()
        let cache = SummaryCacheFixture()
        let recipientA = try XCTUnwrap(AIProvider.customAPI.egressDestination(
            for: "https://summary-user:super-secret@summary-a.example:8443/private/v1?token=leak"
        ))
        let recipientB = try XCTUnwrap(AIProvider.customAPI.egressDestination(
            for: "https://summary-b.example/v1/another-private-path"
        ))
        let readiness = SummaryReadinessFixture(summaryExecution(
            provider: .customAPI,
            modelID: "cheap-model",
            recipientDisclosure: recipientA
        ))
        let store = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: readiness,
            timeZone: timeZone,
            now: { clock.value }
        )

        await store.load(day: clock.value)

        XCTAssertEqual(store.content?.recipientDisclosure, recipientA)
        XCTAssertEqual(
            store.provenanceLabel,
            "Generated with Custom API at https://summary-a.example:8443 · cheap-model"
        )
        XCTAssertFalse(store.provenanceLabel?.contains("super-secret") == true)
        XCTAssertFalse(store.provenanceLabel?.contains("private") == true)

        readiness.update(summaryExecution(
            provider: .customAPI,
            modelID: "cheap-model",
            recipientDisclosure: recipientB
        ))
        clock.advance(by: 10 * 60)
        await store.load(day: clock.value)

        XCTAssertEqual(store.phase, .cached)
        XCTAssertEqual(store.content?.recipientDisclosure, recipientB)
        XCTAssertEqual(
            store.provenanceLabel,
            "Generated with Custom API at https://summary-b.example · cheap-model"
        )
        let generated = await service.generationCount()
        XCTAssertEqual(generated, 2)
        let persisted = try await cache.snapshot(dayKey: "2027-01-15").entry
        XCTAssertEqual(persisted?.recipientDisclosure, recipientB)
    }

    func testSameCustomAPIHostAndModelAtNewPathRegeneratesWithoutDisclosingPath() async throws {
        let clock = SummaryTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let service = SummaryServiceFixture()
        let cache = SummaryCacheFixture()
        let recipient = "Custom API at https://summary.example"
        let disclosure = "https://summary.example"
        let execution = summaryExecution(
            provider: .customAPI,
            modelID: "cheap-model",
            recipientDisclosure: recipient
        )
        let readiness = SummaryReadinessFixture(
            execution: execution,
            routeIdentity: summaryRouteIdentity(
                provider: .customAPI,
                modelID: "cheap-model",
                recipientDisclosure: recipient,
                endpointDisclosure: disclosure,
                endpointIdentity: "sha256:tenant-a"
            )
        )
        let store = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: readiness,
            timeZone: timeZone,
            now: { clock.value }
        )

        await store.load(day: clock.value)
        readiness.update(
            execution,
            routeIdentity: summaryRouteIdentity(
                provider: .customAPI,
                modelID: "cheap-model",
                recipientDisclosure: recipient,
                endpointDisclosure: disclosure,
                endpointIdentity: "sha256:tenant-b"
            )
        )
        clock.advance(by: 10 * 60)
        await store.load(day: clock.value)

        let generated = await service.generationCount()
        XCTAssertEqual(generated, 2)
        XCTAssertEqual(store.content?.endpointDisclosure, disclosure)
        XCTAssertEqual(
            store.provenanceLabel,
            "Generated with Custom API at https://summary.example · cheap-model"
        )
        XCTAssertFalse(store.provenanceLabel?.contains("tenant-a") == true)
        XCTAssertFalse(store.provenanceLabel?.contains("tenant-b") == true)
        let persisted = try await cache.snapshot(dayKey: "2027-01-15").entry
        XCTAssertEqual(persisted?.endpointDisclosure, disclosure)
        XCTAssertEqual(persisted?.endpointIdentity, "sha256:tenant-b")
    }

    func testSameLocalProviderHostAndModelAtNewPathRegeneratesWithoutDisclosingPath() async throws {
        let clock = SummaryTestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let service = SummaryServiceFixture()
        let cache = SummaryCacheFixture()
        let execution = summaryExecution(provider: .custom, modelID: "same-model")
        let endpointDisclosure = "http://127.0.0.1:8080"
        let endpointA = "sha256:local-path-a"
        let endpointB = "sha256:local-path-b"
        let readiness = SummaryReadinessFixture(
            execution: execution,
            routeIdentity: summaryRouteIdentity(
                provider: .custom,
                modelID: "same-model",
                endpointDisclosure: endpointDisclosure,
                endpointIdentity: endpointA
            )
        )
        let store = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: readiness,
            timeZone: timeZone,
            now: { clock.value }
        )

        await store.load(day: clock.value)
        XCTAssertEqual(store.content?.endpointDisclosure, endpointDisclosure)
        XCTAssertEqual(
            store.provenanceLabel,
            "Generated on this Mac via http://127.0.0.1:8080 · same-model"
        )

        readiness.update(
            execution,
            routeIdentity: summaryRouteIdentity(
                provider: .custom,
                modelID: "same-model",
                endpointDisclosure: endpointDisclosure,
                endpointIdentity: endpointB
            )
        )
        clock.advance(by: 10 * 60)
        await store.load(day: clock.value)

        let generated = await service.generationCount()
        XCTAssertEqual(generated, 2)
        XCTAssertFalse(store.provenanceLabel?.contains("local-path") == true)
        let persisted = try await cache.snapshot(dayKey: "2027-01-15").entry
        XCTAssertEqual(persisted?.endpointDisclosure, endpointDisclosure)
        XCTAssertEqual(persisted?.endpointIdentity, endpointB)
    }

    func testDurableCacheSurvivesTemporaryOfflineButStaleAndDisabledStatesStayHonest() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let service = SummaryServiceFixture()
        let cache = SummaryCacheFixture()
        let execution = summaryExecution()
        let routeIdentity = summaryRouteIdentity()
        let online = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: SummaryReadinessFixture(
                execution: execution,
                routeIdentity: routeIdentity
            ),
            timeZone: timeZone,
            now: { now }
        )
        await online.load(day: now)

        let offlineReadiness = SummaryReadinessFixture(
            execution: nil,
            routeIdentity: routeIdentity
        )
        let offline = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: offlineReadiness,
            timeZone: timeZone,
            now: { now }
        )
        await offline.load(day: now)

        XCTAssertEqual(offline.phase, .cached)
        XCTAssertNotNil(offline.content)
        var generated = await service.generationCount()
        XCTAssertEqual(generated, 1)

        await service.setFingerprint("changed-while-offline")
        await offline.load(day: now)

        XCTAssertEqual(offline.phase, .unavailable)
        XCTAssertNotNil(offline.content)
        generated = await service.generationCount()
        XCTAssertEqual(generated, 1)

        let disabled = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: SummaryReadinessFixture(nil),
            timeZone: timeZone,
            now: { now }
        )
        await disabled.load(day: now)
        XCTAssertEqual(disabled.phase, .unavailable)
        XCTAssertNil(disabled.content)
    }

    func testPrivacySuspensionDrainsPreparationAndBlocksNewLoad() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = SummaryServiceFixture(slowDayKey: "2027-01-15")
        let cache = SummaryCacheFixture()
        let store = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: SummaryReadinessFixture(summaryExecution()),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            now: { now }
        )

        let load = Task { await store.load(day: now) }
        while await service.preparationCount() == 0 { await Task.yield() }
        await store.suspendAndDrainForPrivacyMutation()
        await load.value
        await store.load(day: now)

        var generationCount = await service.generationCount()
        var replacementCount = await cache.replacementCount()
        XCTAssertEqual(generationCount, 0)
        XCTAssertEqual(replacementCount, 0)
        XCTAssertNil(store.content)
        XCTAssertEqual(store.phase, .idle)

        store.resumeAfterPrivacyMutation()
        await store.load(day: now)
        generationCount = await service.generationCount()
        replacementCount = await cache.replacementCount()
        XCTAssertEqual(generationCount, 1)
        XCTAssertEqual(replacementCount, 1)
    }

    func testRejectedConditionalCacheWriteDiscardsGeneratedContentWithoutError() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = SummaryServiceFixture()
        let cache = SummaryCacheFixture(rejectReplacements: true)
        let store = ActivityDaySummaryStore(
            service: service,
            cache: cache,
            readiness: SummaryReadinessFixture(summaryExecution()),
            timeZone: TimeZone(secondsFromGMT: 0)!,
            now: { now }
        )

        await store.load(day: now)

        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.content)
        XCTAssertNil(store.errorText)
        let generationCount = await service.generationCount()
        XCTAssertEqual(generationCount, 1)
    }

    func testPresentationCopyCoversUnavailableLoadingUpdatingAndNoActivity() {
        XCTAssertEqual(ActivityDaySummaryPresentation.title, "What I did")
        XCTAssertEqual(
            ActivityDaySummaryPresentation.unavailable,
            "Choose an Activity summary model in Settings → AI, or retry after it reconnects."
        )
        XCTAssertEqual(
            ActivityDaySummaryPresentation.unavailableMessage(hasContent: true),
            "This recap is out of date. Reconnect the Activity summary model to update it."
        )
        XCTAssertEqual(
            ActivityDaySummaryPresentation.unavailableMessage(hasContent: false),
            "Choose an Activity summary model in Settings → AI, or retry after it reconnects."
        )
        XCTAssertEqual(ActivityDaySummaryPresentation.loading, "Summarizing this day…")
        XCTAssertEqual(ActivityDaySummaryPresentation.updating, "Updating…")
        XCTAssertEqual(ActivityDaySummaryPresentation.noActivity, "There is no activity to summarize for this day.")
        XCTAssertEqual(ActivityDaySummaryPresentation.refresh, "Refresh")
        XCTAssertEqual(ActivityDaySummaryPresentation.retry, "Retry")
    }

    func testActivitySummaryProductStringsHaveRussianTranslations() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ZBSEyeApp/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let requiredKeys = [
            "%@ · Activity summaries on",
            "%@ — Recommended",
            "Activity summaries",
            "Activity summaries are configured separately in Settings.",
            "Activity summaries are off",
            "Activity summaries are off for now, but Eye couldn't confirm the saved setting. Turn them off again after restarting.",
            "Activity summaries · %@",
            "Add or check a provider…",
            "AI is off, but Eye couldn't confirm the saved setting. Turn it off again after restarting.",
            "AI is off for now, but Eye couldn't confirm the saved setting. Turn it off again after restarting.",
            "Change model…",
            "Choose an Activity summary model in Settings → AI, or retry after it reconnects.",
            "Choose model…",
            "Connect and check a provider above before choosing an Activity summary model.",
            "Couldn't confirm that AI was turned on. Processing remains off; try again.",
            "Eye couldn't confirm the saved Activity summaries setting. Try again.",
            "Eye couldn't confirm the saved AI setting. Try again.",
            "Eye couldn't confirm the saved Primary AI setting. Try again.",
            "Generated on this Mac via %@ · %@",
            "Generated on this Mac · %@",
            "Generated with %@%@ · %@",
            "No activity was recorded for this day.",
            "Primary AI",
            "Primary AI is off",
            "Primary AI is off for now, but Eye couldn't confirm the saved setting. Turn it off again after restarting.",
            "Refresh",
            "Show a factual 3–6 item recap at the top of Activities. This can use a separate model without changing Ask.",
            "Summarizing this day…",
            "That model is no longer available. Check the provider and try again.",
            "The model did not return a factual 3–6 item summary.",
            "The summary could not be generated.",
            "There is no activity to summarize for this day.",
            "This recap is out of date. Reconnect the Activity summary model to update it.",
            "Turn Activity summaries off",
            "Turn primary AI off",
            "Updating…",
            "What I did",
            "ZBS Eye will automatically send only the bounded text excerpts needed for %@ to %@. Raw screenshots, audio, full URLs, and file paths are not sent.",
            "activity summaries",
            "the selected cloud provider",
        ]

        for key in requiredKeys {
            let entry = try XCTUnwrap(
                strings[key] as? [String: Any],
                "Missing catalog entry: \(key)"
            )
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any], key
            )
            let russian = try XCTUnwrap(localizations["ru"] as? [String: Any], key)
            let unit = try XCTUnwrap(russian["stringUnit"] as? [String: Any], key)
            XCTAssertEqual(unit["state"] as? String, "translated", key)
            XCTAssertFalse((unit["value"] as? String ?? "").isEmpty, key)
        }
    }
}

private actor SummaryCaptureFixture: ActivityDaySummaryCaptureProviding {
    private let rows: [CaptureLite]
    private var range: (fromMs: Int64, toMs: Int64)?

    init(_ rows: [CaptureLite]) { self.rows = rows }

    func captures(fromMs: Int64, toMs: Int64) async throws -> [CaptureLite] {
        range = (fromMs, toMs)
        return rows.filter { $0.ts >= fromMs && $0.ts <= toMs }
    }

    func lastRange() -> (fromMs: Int64, toMs: Int64)? { range }
}

private actor SummaryGeneratorFixture: AIConsumerGenerating {
    private let output: String
    private let outputTruncated: Bool
    private var recordedPlans: [AIConsumerGenerationPlan] = []

    init(
        output: String = "- One\n- Two\n- Three",
        outputTruncated: Bool = false
    ) {
        self.output = output
        self.outputTruncated = outputTruncated
    }

    func generate(
        plan: AIConsumerGenerationPlan,
        execution: AIConsumerExecutionContext,
        requestID: UUID
    ) async throws -> AIConsumerGenerationResult {
        recordedPlans.append(plan)
        return AIConsumerGenerationResult(
            content: output,
            outputTruncated: outputTruncated,
            contextTruncated: false,
            includedSourceIDs: plan.fragments.map(\.sourceID),
            provenance: AIExecutionProvenance(
                providerID: execution.selection.providerID,
                modelID: execution.selection.modelID,
                executedLocally: execution.executedLocally,
                generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                brokerUpstream: nil
            ),
            promptVersion: plan.promptVersion
        )
    }

    func plans() -> [AIConsumerGenerationPlan] { recordedPlans }
}

private actor SummaryServiceFixture: ActivityDaySummaryServicing {
    private var fingerprint = "initial"
    private var generated = 0
    private var prepared = 0
    private let slowDayKey: String?

    init(slowDayKey: String? = nil) { self.slowDayKey = slowDayKey }

    func prepare(day: Date, timeZone: TimeZone) async throws -> ActivityDaySummaryInput {
        prepared += 1
        let dayKey = ActivityDaySummaryDayKey.make(for: day, timeZone: timeZone)
        if dayKey == slowDayKey {
            try await Task.sleep(for: .milliseconds(150))
        }
        return summaryInput(dayKey: dayKey, fingerprint: fingerprint, day: day)
    }

    func generate(
        input: ActivityDaySummaryInput,
        execution: AIConsumerExecutionContext,
        requestID: UUID
    ) async throws -> ActivityDaySummaryGenerated {
        generated += 1
        let bullets = [
            "Task \(input.dayKey) A",
            "Task \(input.dayKey) B",
            "Task \(input.dayKey) C",
        ]
        return ActivityDaySummaryGenerated(
            summary: bullets.map { "- \($0)" }.joined(separator: "\n"),
            bullets: bullets,
            provenance: AIExecutionProvenance(
                providerID: execution.selection.providerID,
                modelID: execution.selection.modelID,
                executedLocally: execution.executedLocally,
                generatedAt: Date(),
                brokerUpstream: nil
            ),
            promptVersion: AIConsumerPromptFactory.activitySummaryVersion
        )
    }

    func setFingerprint(_ value: String) { fingerprint = value }
    func preparationCount() -> Int { prepared }
    func generationCount() -> Int { generated }
}

private actor SummaryCacheFixture: ActivityDaySummaryCaching {
    private var entries: [String: ActivityDaySummaryCacheEntry] = [:]
    private var replacements = 0
    private var invalidationEpoch: Int64 = 0
    private let rejectReplacements: Bool

    init(rejectReplacements: Bool = false) {
        self.rejectReplacements = rejectReplacements
    }

    func snapshot(dayKey: String) async throws -> ActivityDaySummaryCacheSnapshot {
        ActivityDaySummaryCacheSnapshot(
            entry: entries[dayKey],
            invalidationEpoch: invalidationEpoch
        )
    }

    func replace(
        _ entry: ActivityDaySummaryCacheEntry,
        expectedInvalidationEpoch: Int64
    ) async throws -> Bool {
        guard !rejectReplacements else { return false }
        guard expectedInvalidationEpoch == invalidationEpoch else { return false }
        replacements += 1
        entries[entry.dayKey] = entry
        return true
    }

    func invalidate() { invalidationEpoch += 1 }
    func replacementCount() -> Int { replacements }
}

@MainActor
private final class SummaryReadinessFixture: AIConsumerReadinessProviding {
    private var execution: AIConsumerExecutionContext?
    private var routeIdentity: ActivitySummaryRouteIdentity?

    init(_ execution: AIConsumerExecutionContext?) {
        self.execution = execution
        routeIdentity = execution.map(Self.routeIdentity(from:))
    }

    init(
        execution: AIConsumerExecutionContext?,
        routeIdentity: ActivitySummaryRouteIdentity?
    ) {
        self.execution = execution
        self.routeIdentity = routeIdentity
    }

    func update(_ execution: AIConsumerExecutionContext?) {
        self.execution = execution
        routeIdentity = execution.map(Self.routeIdentity(from:))
    }

    func update(
        _ execution: AIConsumerExecutionContext?,
        routeIdentity: ActivitySummaryRouteIdentity?
    ) {
        self.execution = execution
        self.routeIdentity = routeIdentity
    }

    func currentExecutionContext(for consumer: AIConsumer) -> AIConsumerExecutionContext? {
        consumer == .activitySummary ? execution : nil
    }

    func activitySummaryRouteIdentity() -> ActivitySummaryRouteIdentity? {
        routeIdentity
    }

    private static func routeIdentity(
        from execution: AIConsumerExecutionContext
    ) -> ActivitySummaryRouteIdentity {
        ActivitySummaryRouteIdentity(
            providerID: execution.selection.providerID,
            modelID: execution.selection.modelID,
            executedLocally: execution.executedLocally,
            recipientDisclosure: execution.recipientDisclosure,
            endpointDisclosure: nil,
            endpointIdentity: nil
        )
    }
}

private final class SummaryTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }

    var value: Date { lock.withLock { date } }
    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

private final class SummaryTimeZoneSource: @unchecked Sendable {
    private let lock = NSLock()
    private var timeZone: TimeZone
    private var reads = 0

    init(_ timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    func snapshot() -> TimeZone {
        lock.withLock {
            reads += 1
            return timeZone
        }
    }

    func update(_ timeZone: TimeZone) {
        lock.withLock { self.timeZone = timeZone }
    }

    var readCount: Int { lock.withLock { reads } }
}

private func summaryExecution(
    provider: AIProvider = .ollama,
    modelID: String = "qwen-local",
    recipientDisclosure: String? = nil
) -> AIConsumerExecutionContext {
    AIConsumerExecutionContext(
        selection: ProviderSelectionSnapshot(
            providerID: provider.rawValue,
            modelID: modelID,
            selectionRevision: SelectionRevision(rawValue: 1),
            authorizationEpoch: AuthorizationEpoch(rawValue: 1)
        ),
        contextTokenCeiling: 4_096,
        executedLocally: !provider.isCloud,
        recipientDisclosure: recipientDisclosure
    )
}

private func summaryRouteIdentity(
    provider: AIProvider = .ollama,
    modelID: String = "qwen-local",
    recipientDisclosure: String? = nil,
    endpointDisclosure: String? = nil,
    endpointIdentity: String? = nil
) -> ActivitySummaryRouteIdentity {
    ActivitySummaryRouteIdentity(
        providerID: provider.rawValue,
        modelID: modelID,
        executedLocally: !provider.isCloud,
        recipientDisclosure: recipientDisclosure,
        endpointDisclosure: endpointDisclosure,
        endpointIdentity: endpointIdentity
    )
}

private func summaryInput(
    dayKey: String,
    fingerprint: String,
    day: Date = Date(timeIntervalSince1970: 1_800_000_000)
) -> ActivityDaySummaryInput {
    ActivityDaySummaryInput(
        day: day,
        dayKey: dayKey,
        inputFingerprint: fingerprint,
        sourceStartMs: msFromDate(day),
        sourceEndMs: msFromDate(day.addingTimeInterval(86_400)),
        sourceCount: 3,
        language: .en,
        fragments: [
            .init(sourceID: "session:0", text: "[09:00–10:00] Xcode — ZBS Eye"),
            .init(sourceID: "session:1", text: "[10:00–11:00] Safari — github.com"),
            .init(sourceID: "session:2", text: "[11:00–12:00] Terminal — Tests"),
        ]
    )
}

private func capture(
    _ id: Int64,
    at date: Date,
    app: String,
    bundle: String,
    title: String?,
    url: String? = nil
) -> CaptureLite {
    CaptureLite(
        id: id,
        ts: msFromDate(date),
        appId: id,
        appName: app,
        bundleId: bundle,
        windowTitle: title,
        browserUrl: url
    )
}
