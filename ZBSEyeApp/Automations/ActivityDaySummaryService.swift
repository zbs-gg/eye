import CryptoKit
import Foundation

enum ActivityDaySummaryError: LocalizedError, Equatable {
    case noActivity
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .noActivity:
            String(localized: "No activity was recorded for this day.")
        case .invalidOutput:
            String(localized: "The model did not return a factual 3–6 item summary.")
        }
    }
}

/// A bounded, privacy-clean day snapshot. Only these fragments may cross the
/// optional AI boundary; raw OCR, URLs, file paths, and media never enter it.
struct ActivityDaySummaryInput: Sendable, Equatable {
    let day: Date
    let dayKey: String
    let inputFingerprint: String
    let sourceStartMs: Int64
    let sourceEndMs: Int64
    let sourceCount: Int
    let language: LocalAIOutputLanguage
    let fragments: [AIConsumerPromptFragment]
}

struct ActivityDaySummaryGenerated: Sendable, Equatable {
    let summary: String
    let bullets: [String]
    let provenance: AIExecutionProvenance
    let promptVersion: String
}

protocol ActivityDaySummaryCaptureProviding: Sendable {
    func captures(fromMs: Int64, toMs: Int64) async throws -> [CaptureLite]
}

extension DayActivityRepository: ActivityDaySummaryCaptureProviding {}

protocol ActivityDaySummaryServicing: Sendable {
    func prepare(day: Date, timeZone: TimeZone) async throws -> ActivityDaySummaryInput
    func generate(
        input: ActivityDaySummaryInput,
        execution: AIConsumerExecutionContext,
        requestID: UUID
    ) async throws -> ActivityDaySummaryGenerated
}

/// One selected day becomes one bounded LLM request. The service deliberately
/// uses only screen Activities: Calls/audio are separate products and privacy
/// deletion can therefore invalidate this cache by screen-source range alone.
actor ActivityDaySummaryService: ActivityDaySummaryServicing {
    private static let maximumSessions = 24
    private static let sessionGapMs: Int64 = 5 * 60 * 1_000
    private static let maximumFragmentCharacters = 240
    private static let maximumOutputTokens = 500

    private let provider: any ActivityDaySummaryCaptureProviding
    private let generator: any AIConsumerGenerating

    init(
        provider: any ActivityDaySummaryCaptureProviding,
        generator: any AIConsumerGenerating
    ) {
        self.provider = provider
        self.generator = generator
    }

    func prepare(day: Date, timeZone: TimeZone) async throws -> ActivityDaySummaryInput {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86_400)

        let startMs = msFromDate(start)
        let endMs = msFromDate(end)
        let fetched = try await provider.captures(
            fromMs: startMs,
            toMs: endMs - 1
        )
        let captures = SystemAppFilter.userCaptures(
            fetched.filter { !SystemAppFilter.isProtectedCaptureSurface($0) }
        )
        guard !captures.isEmpty else { throw ActivityDaySummaryError.noActivity }

        let sessions = DayActivityRepository.sessions(
            captures,
            grouping: .appAndWindow,
            gapMs: Self.sessionGapMs,
            excludeSystem: true
        )
        let chosen = sessions
            .sorted {
                if $0.durationMs != $1.durationMs { return $0.durationMs > $1.durationMs }
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.startMs < $1.startMs
            }
            .prefix(Self.maximumSessions)
            .sorted { $0.startMs < $1.startMs }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"

        let fragments = chosen.enumerated().map { index, session in
            let first = session.first
            let representative = session.rep
            let app = MCPActivitySummaryLabel.safeAppName(
                first.appName ?? first.bundleId ?? "App"
            )
            let topic = MCPActivitySummaryLabel.safeTopic(
                appName: app,
                bundleID: representative.bundleId ?? first.bundleId,
                windowTitle: representative.windowTitle ?? first.windowTitle,
                browserURL: representative.browserUrl ?? first.browserUrl
            )
            let startText = formatter.string(from: dateFromMs(session.startMs))
            let endText = formatter.string(from: dateFromMs(session.endMs))
            let detail = topic.map { " — \($0)" } ?? ""
            return AIConsumerPromptFragment(
                sourceID: "session:\(index)",
                text: "[\(startText)–\(endText)] \(app)\(detail)"
            )
        }
        guard !fragments.isEmpty else { throw ActivityDaySummaryError.noActivity }

        return ActivityDaySummaryInput(
            day: start,
            dayKey: ActivityDaySummaryDayKey.make(for: start, timeZone: timeZone),
            inputFingerprint: Self.fingerprint(captures),
            sourceStartMs: startMs,
            sourceEndMs: endMs,
            sourceCount: captures.count,
            language: LocalAIContextPolicy.outputLanguage(for: fragments.map(\.text)),
            fragments: fragments
        )
    }

    func generate(
        input: ActivityDaySummaryInput,
        execution: AIConsumerExecutionContext,
        requestID: UUID
    ) async throws -> ActivityDaySummaryGenerated {
        let plan = AIConsumerPromptFactory.activitySummary(
            language: input.language,
            dateLine: input.dayKey,
            fragments: input.fragments,
            maximumFragmentCharacters: Self.maximumFragmentCharacters,
            maximumOutputTokens: Self.maximumOutputTokens,
            timeout: .seconds(90)
        )
        let output = try await generator.generate(
            plan: plan,
            execution: execution,
            requestID: requestID
        )
        guard !output.outputTruncated else {
            throw ActivityDaySummaryError.invalidOutput
        }
        let bullets = try Self.safeBullets(output.content)
        return ActivityDaySummaryGenerated(
            summary: bullets.map { "- \($0)" }.joined(separator: "\n"),
            bullets: bullets,
            provenance: output.provenance,
            promptVersion: output.promptVersion
        )
    }

    /// Cache reads pass through the same plain-text boundary as fresh model
    /// output, so a modified database cannot make SwiftUI render Markdown/HTML.
    nonisolated static func safeBullets(_ raw: String) throws -> [String] {
        guard ActivitySummaryOutputValidator.isValid(raw) else {
            throw ActivityDaySummaryError.invalidOutput
        }
        let bullets = raw
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> String? in
                let line = rawLine.dropFirst(2).trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                let safe = MCPActivitySummaryLabel.safeOutput(line)
                return safe.isEmpty ? nil : safe
            }
        guard (3...6).contains(bullets.count) else {
            throw ActivityDaySummaryError.invalidOutput
        }
        return bullets
    }

    private static func fingerprint(_ captures: [CaptureLite]) -> String {
        var material = "activity-day-summary-v1\n"
        material.reserveCapacity(captures.count * 80)
        for capture in captures {
            material += "\(capture.id)|\(capture.ts)|\(capture.appId ?? -1)|"
            material += "\(capture.bundleId ?? "")|\(capture.appName ?? "")|"
            material += "\(capture.windowTitle ?? "")|\(capture.browserUrl ?? "")\n"
        }
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
