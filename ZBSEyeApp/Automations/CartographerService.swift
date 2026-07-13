import Foundation

/// "Cartographer" — AI advisor: looks at the day's activity → produces 2-3 concrete observations/tips.
/// Pattern: like DailySummaryService, but without the write stage — all the value is in the insight lines.
/// Egress: every generation crosses the process-wide LLMRouter with an exact consumer-scoped
/// selection/authorization snapshot. If no model is active — a friendly hint, no attempt, no crash. Delegates day
/// aggregation to the shared DayActivityRepository.
///
/// Privacy/injection: the screen is untrusted input. The context policy promotes a bounded trusted
/// fact ledger, excludes instruction-like samples, and the LLM output is sanitized afterwards (no md images/links,
/// length/line-count cap). Each run writes an audit with no content.
actor CartographerService {
    static let promptVersion = AIConsumerPromptFactory.dailyInsightsVersion

    private let repo: DayActivityRepository
    private let generator: any AIConsumerGenerating
    private let auditWriter: AutomationAuditWriter

    init(
        repo: DayActivityRepository,
        generator: any AIConsumerGenerating,
        auditWriter: AutomationAuditWriter = AutomationAuditWriter()
    ) {
        self.repo = repo
        self.generator = generator
        self.auditWriter = auditWriter
    }

    // MARK: — data

    /// Collection result: top apps by time + number of context switches.
    struct DayActivity: Sendable {
        struct AppUsage: Sendable {
            let app: String
            let minutes: Int
            let captures: Int
        }
        let day: Date
        let topApps: [AppUsage]          // top-8 by real active time
        let contextSwitches: Int          // app/window switches over the day
        let totalCaptures: Int
        /// Key text fragments (one per top-5 session) — for topical advice.
        let textSamples: [String]
    }

    /// Collects the day's activity via DayActivityRepository (one scan + clean aggregations). Time is
    /// by ts deltas (not frame count: capture interval floats active≈3s/idle≈60s/bursts/dedup).
    func collect(day: Date, safety: AutomationSafety = .default) async throws -> DayActivity {
        let start = Calendar.current.startOfDay(for: day)
        let caps = try await repo.captures(forDay: day)
        guard !caps.isEmpty else { throw AutomationError.noData(day: start) }

        // Active time per site-aware group (browsers split per site, not lumped as one "app"). For
        // browsers that hide the URL from AX (Dia/Arc), recover the real host from imported browser
        // history near each frame's timestamp — so they split by site, not by page title.
        let hostOverrides = (try? await repo.browserHostOverrides(caps)) ?? [:]
        let usage = DayActivityRepository.appSiteActiveMs(caps, activeGapCapMs: 120 * 1000, hosts: hostOverrides)
        let rankedApps = usage.ms.sorted { $0.value > $1.value }.prefix(8)
        let topApps: [DayActivity.AppUsage] = rankedApps.map { entry in
            DayActivity.AppUsage(app: usage.label[entry.key] ?? "—",
                                 minutes: max(1, Int(entry.value / 60000)),
                                 captures: usage.count[entry.key] ?? 0)
        }

        let switches = DayActivityRepository.contextSwitches(caps)

        // Text samples: top-5 sessions (app+window) by frame count → batch text over their frames.
        // excludeSystem: false — Daily Insights is out of the Activities/usage-stats scope; keep prior
        // behaviour so a long lock-screen stretch isn't silently dropped from the model's input.
        let sessions = DayActivityRepository.sessions(caps, grouping: .appAndWindow, gapMs: 5 * 60 * 1000,
                                                      excludeSystem: false)
        let topSessions = sessions.sorted { $0.count > $1.count }.prefix(5)
        let candidateIds = topSessions.flatMap { $0.sampledCaptureIds(max: 80) }
        let textByCapture = try await repo.batchText(captureIds: candidateIds)
        let textSamples: [String] = topSessions.compactMap { s in
            guard let best = s.captureIds.compactMap({ textByCapture[$0] }).max(by: { $0.count < $1.count }),
                  !best.isEmpty else { return nil }
            return Self.clean(best, cap: safety.maxSampleChars)
        }

        return DayActivity(day: start, topApps: topApps, contextSwitches: switches,
                           totalCaptures: caps.count, textSamples: textSamples)
    }

    /// Lighter collection for the on-device heuristic card: top apps + context switches + counts, WITHOUT
    /// the textSamples work (session grouping + per-frame text batch fetch + sanitize) that only the LLM
    /// prompt consumes. The heuristic card never displays textSamples, so skip that whole extra scan.
    func collectSummary(day: Date) async throws -> DayActivity {
        let start = Calendar.current.startOfDay(for: day)
        let caps = try await repo.captures(forDay: day)
        guard !caps.isEmpty else { throw AutomationError.noData(day: start) }

        let hostOverrides = (try? await repo.browserHostOverrides(caps)) ?? [:]
        let usage = DayActivityRepository.appSiteActiveMs(caps, activeGapCapMs: 120 * 1000, hosts: hostOverrides)
        let rankedApps = usage.ms.sorted { $0.value > $1.value }.prefix(8)
        let topApps: [DayActivity.AppUsage] = rankedApps.map { entry in
            DayActivity.AppUsage(app: usage.label[entry.key] ?? "—",
                                 minutes: max(1, Int(entry.value / 60000)),
                                 captures: usage.count[entry.key] ?? 0)
        }
        let switches = DayActivityRepository.contextSwitches(caps)
        return DayActivity(day: start, topApps: topApps, contextSwitches: switches,
                           totalCaptures: caps.count, textSamples: [])
    }

    // MARK: — insight generation

    struct Insights: Sendable {
        let lines: [String]          // 2-3 insights, each on its own line
        let model: String
        let activity: DayActivity
        let truncated: Bool
        let contextTruncated: Bool
        let provenance: AIExecutionProvenance
        let promptVersion: String
    }

    /// Collect + router → insights. Writes an identity-bearing audit without prompt content.
    func generate(day: Date, execution: AIConsumerExecutionContext,
                  requestID: UUID = UUID(),
                  safety: AutomationSafety = .default) async throws -> Insights {
        let activity = try await collect(day: day, safety: safety)
        let plan = Self.generationPlan(activity, safety: safety)
        do {
            let out = try await generator.generate(
                plan: plan,
                execution: execution,
                requestID: requestID
            )
            let lines = Self.sanitizeOutput(out.content)
            guard !lines.isEmpty else { throw AIConsumerGenerationError.generationFailed }
            await audit(day: activity.day, execution: execution,
                        provenance: out.provenance, captures: activity.totalCaptures,
                        sessions: activity.topApps.count, outputChars: lines.joined().count,
                        ok: true, error: nil)
            return Insights(
                lines: lines,
                model: out.provenance.modelID,
                activity: activity,
                truncated: out.outputTruncated,
                contextTruncated: out.contextTruncated,
                provenance: out.provenance,
                promptVersion: out.promptVersion
            )
        } catch {
            await audit(day: activity.day, execution: execution,
                        provenance: nil, captures: activity.totalCaptures,
                        sessions: activity.topApps.count, outputChars: 0, ok: false,
                        error: (error as? AutomationError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    // MARK: — prompt (bounded trusted fact ledger)

    static func generationPlan(
        _ activity: DayActivity,
        safety: AutomationSafety
    ) -> AIConsumerGenerationPlan {
        let apps = activity.topApps.map {
            LocalAIActivityApp(name: clean($0.app, cap: 80), minutes: $0.minutes, captures: $0.captures)
        }
        let hints = LocalAIContextPolicy.insightsHints(
            totalCaptures: activity.totalCaptures,
            contextSwitches: activity.contextSwitches,
            apps: apps,
            textSamples: activity.textSamples.map { clean($0, cap: safety.maxSampleChars) }
        )
        let language = LocalAIContextPolicy.outputLanguage(
            for: activity.topApps.map(\.app) + activity.textSamples
        )
        return AIConsumerPromptFactory.dailyInsights(
            hints: hints,
            language: language,
            maximumSampleCharacters: safety.maxSampleChars,
            timeout: .seconds(safety.requestTimeout)
        )
    }

    // MARK: — post-LLM guardrail

    /// Clean the model output: strip numbering/bullets, cut md images/links (anti-exfil/anti-click),
    /// cap line length and line count. A screen injection can't exfiltrate data over the network, but it could
    /// render a harmful/false "instruction" — we don't let that through.
    static func sanitizeOutput(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgLink = #"!?\[([^\]]*)\]\([^)]*\)"#       // ![alt](url) / [text](url) → keep only the text
        let bareURL = #"\bhttps?://\S+"#                 // bare links → label
        return trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line -> String in
                var s = line
                // leading bullets "1. "/"2) "/"• "/"- "/"* "
                for p in [#"^\d+[\.\)]\s+"#, #"^[•\-\*]\s+"#] {
                    if let r = s.range(of: p, options: .regularExpression) { s = String(s[r.upperBound...]) }
                }
                s = s.replacingOccurrences(of: imgLink, with: "$1", options: .regularExpression)
                s = s.replacingOccurrences(of: bareURL, with: "[link removed]", options: .regularExpression)
                return String(s.prefix(240))
            }
            .filter { !$0.isEmpty }
            .prefix(3)                                   // at most 3 insights
            .map { $0 }
    }

    // MARK: — audit (no content)

    private func audit(day: Date, execution: AIConsumerExecutionContext,
                       provenance: AIExecutionProvenance?, captures: Int, sessions: Int,
                       outputChars: Int, ok: Bool, error: String?) async {
        let entry = AuditEntry(at: Date(), automation: "cartographer", day: Self.ymd(day),
                               action: "insights", model: provenance?.modelID ?? execution.selection.modelID,
                               sessions: sessions, captures: captures,
                               outputChars: outputChars, destPath: nil, ok: ok, error: error,
                               providerID: provenance?.providerID ?? execution.selection.providerID,
                               executedLocally: provenance?.executedLocally ?? execution.executedLocally,
                               promptVersion: Self.promptVersion,
                               brokerUpstream: provenance?.brokerUpstream)
        try? await auditWriter.append(entry)
    }

    // MARK: — helpers

    /// Collapses whitespace/newlines into a single space and cuts to cap — a compact safe sample.
    static func clean(_ s: String, cap: Int) -> String {
        let collapsed = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(collapsed.prefix(cap))
    }

    static func ymd(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
