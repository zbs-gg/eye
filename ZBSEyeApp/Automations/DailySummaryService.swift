import Foundation

/// Engine for the single v1 automation: "day summary". Three stages — collect (history from the DB → compact
/// sessions) → summarize (the active processing model from "AI Models") → write (Markdown into a
/// folder/Obsidian). Actor: all DB, network, and file work is isolated; only Sendable crosses out.
/// Egress crosses the process-wide LLMRouter with a consumer-scoped authorization snapshot; preview is
/// mandatory before write (see DaySummaryStore) — protection from prompt injection out of private history.
/// Delegates day aggregation to the shared DayActivityRepository (one scan + segmentation + batch text).
actor DailySummaryService {
    static let promptVersion = AIConsumerPromptFactory.dailySummaryVersion

    private let repo: DayActivityRepository
    private let generator: any AIConsumerGenerating

    init(repo: DayActivityRepository, generator: any AIConsumerGenerating) {
        self.repo = repo
        self.generator = generator
    }

    // MARK: stage 1 — collect

    /// Day frames → sessions (consecutive frames of one app/window, 5-min pause tolerance). We pick the
    /// longest maxInputSlices, and for each take the longest text block as a representative sample.
    func collect(day: Date, safety: AutomationSafety) async throws -> CollectedDay {
        let start = Calendar.current.startOfDay(for: day)
        let caps = try await repo.captures(forDay: day)
        guard !caps.isEmpty else { throw AutomationError.noData(day: day) }

        // app+window sessions (5-min pause tolerance); top by duration (ties broken by frame count),
        // then back into chronological order for the prompt.
        // excludeSystem: false — the daily summary written to the vault is out of the Activities/usage-stats
        // scope; keep prior behaviour so a long lock-screen session isn't silently dropped from the summary.
        let sessions = DayActivityRepository.sessions(caps, grouping: .appAndWindow, gapMs: 5 * 60 * 1000,
                                                      excludeSystem: false)
        let totalSlices = sessions.count
        let chosen = sessions
            .sorted { ($0.durationMs, $0.count) > ($1.durationMs, $1.count) }
            .prefix(safety.maxInputSlices)
            .sorted { $0.startMs < $1.startMs }

        // Text of the representative frames of the chosen sessions — in ONE batch query (no N+1). Frames are
        // taken strictly from the session itself (app+window+ts already accounted for by segmentation) — foreign text won't leak.
        let candidateIds = chosen.flatMap { $0.sampledCaptureIds(max: 120) }
        let textByCapture = try await repo.batchText(captureIds: candidateIds)

        let slices: [DaySlice] = chosen.map { s in
            let best = s.captureIds.compactMap { textByCapture[$0] }.max(by: { $0.count < $1.count }) ?? ""
            return DaySlice(
                start: dateFromMs(s.startMs), end: dateFromMs(s.endMs),
                app: s.first.appName ?? "—", window: s.first.windowTitle, url: s.first.browserUrl,
                sample: Self.clean(best, cap: safety.maxSampleChars), captures: s.count)
        }
        return CollectedDay(day: start, slices: slices, totalCaptures: caps.count, totalSlices: totalSlices)
    }

    // MARK: stage 2 — summarize (= preview)

    /// collect + LLM. Does NOT write — this is a preview. Writes audit("preview").
    func preview(
        day: Date,
        execution: AIConsumerExecutionContext,
        consumer: AIConsumer,
        requestID: UUID = UUID(),
        safety: AutomationSafety
    ) async throws -> SummaryPreview {
        let collected = try await collect(day: day, safety: safety)
        let plan = Self.generationPlan(collected, consumer: consumer, safety: safety)
        do {
            let out = try await generator.generate(
                plan: plan,
                execution: execution,
                requestID: requestID
            )
            let trimmed = out.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let outputChannel = AIProvider(
                rawValue: execution.selection.providerID
            )?.outputChannel ?? .visibleText
            let modelPrompt = plan.modelFacingPrompt(
                for: outputChannel,
                allowedSourceIDs: out.includedSourceIDs
            )
            let preview = SummaryPreview(
                day: collected.day, markdown: trimmed, sessions: collected.slices.count,
                totalCaptures: collected.totalCaptures, model: out.provenance.modelID,
                promptChars: (modelPrompt?.system.count ?? plan.systemPrompt.count)
                    + plan.userPreamble.count
                    + (modelPrompt?.userPostamble.count ?? plan.userPostamble.count)
                    + plan.fragments.reduce(0) { $0 + $1.text.count },
                truncated: collected.truncated || out.contextTruncated,
                contextTruncated: out.contextTruncated,
                outputTruncated: out.outputTruncated,
                provenance: out.provenance,
                promptVersion: out.promptVersion)
            await audit(AuditEntry(at: Date(), automation: "daily-summary", day: Self.ymd(collected.day),
                                   action: "preview", model: out.provenance.modelID, sessions: preview.sessions,
                                   captures: preview.totalCaptures, outputChars: trimmed.count,
                                   destPath: nil, ok: true, error: nil,
                                   providerID: out.provenance.providerID,
                                   executedLocally: out.provenance.executedLocally,
                                   promptVersion: out.promptVersion,
                                   brokerUpstream: out.provenance.brokerUpstream))
            return preview
        } catch {
            await audit(AuditEntry(at: Date(), automation: "daily-summary", day: Self.ymd(collected.day),
                                   action: "preview", model: execution.selection.modelID,
                                   sessions: collected.slices.count,
                                   captures: collected.totalCaptures, outputChars: 0, destPath: nil,
                                   ok: false, error: (error as? AutomationError)?.errorDescription ?? error.localizedDescription,
                                   providerID: execution.selection.providerID,
                                   executedLocally: execution.executedLocally,
                                   promptVersion: Self.promptVersion))
            throw error
        }
    }

    // MARK: stage 3 — write

    /// Writes the preview to `<destination>/<subfolder>/YYYY-MM-DD.md` (idempotent: same day = overwrite).
    /// destinationURL is already resolved from a bookmark on @MainActor (Sendable URL).
    func write(preview: SummaryPreview, destinationURL: URL, subfolder: String) async throws -> WriteResult {
        // Subfolder sanitization: a free-form TextField could contain "../../" and write the private
        // summary OUTSIDE the chosen folder. We build the folder only from clean segments, ".." is forbidden.
        let segments = subfolder.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !segments.contains("..") else { throw AutomationError.write("The subfolder contains an invalid path (\"..\").") }
        var folder = destinationURL
        for seg in segments { folder.appendPathComponent(seg, isDirectory: true) }

        let name = Self.ymd(preview.day) + ".md"
        let fileURL = folder.appendingPathComponent(name)

        // Belt-and-suspenders: the final path must lie INSIDE the chosen folder.
        let base = destinationURL.standardizedFileURL.path
        let basePrefix = base.hasSuffix("/") ? base : base + "/"
        guard fileURL.standardizedFileURL.path.hasPrefix(basePrefix) else {
            throw AutomationError.write("The target path is outside the chosen folder.")
        }

        // Model output is untrusted even after a structured local response:
        // cloud/process providers can return plain text, and Obsidian renders
        // both Markdown image embeds and raw HTML with autoloading attributes.
        let safeMarkdown = AutomationMarkdownSafety.modelOutput(preview.markdown)
        let content = Self.fileHeader(preview) + safeMarkdown + "\n"

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let existed = FileManager.default.fileExists(atPath: fileURL.path)
            try Data(content.utf8).write(to: fileURL, options: .atomic)
            await audit(AuditEntry(at: Date(), automation: "daily-summary", day: Self.ymd(preview.day),
                                   action: "write", model: preview.model, sessions: preview.sessions,
                                   captures: preview.totalCaptures, outputChars: preview.markdown.count,
                                   destPath: fileURL.path, ok: true, error: nil,
                                   providerID: preview.provenance.providerID,
                                   executedLocally: preview.provenance.executedLocally,
                                   promptVersion: preview.promptVersion,
                                   brokerUpstream: preview.provenance.brokerUpstream))
            return WriteResult(path: fileURL.path, bytes: content.utf8.count, overwritten: existed)
        } catch {
            await audit(AuditEntry(at: Date(), automation: "daily-summary", day: Self.ymd(preview.day),
                                   action: "write", model: preview.model, sessions: preview.sessions,
                                   captures: preview.totalCaptures, outputChars: preview.markdown.count,
                                   destPath: fileURL.path, ok: false, error: error.localizedDescription,
                                   providerID: preview.provenance.providerID,
                                   executedLocally: preview.provenance.executedLocally,
                                   promptVersion: preview.promptVersion,
                                   brokerUpstream: preview.provenance.brokerUpstream))
            throw AutomationError.write(error.localizedDescription)
        }
    }

    // MARK: audit

    func recentAudit(limit: Int = 20) async -> [AuditEntry] {
        guard let url = try? ZBSEyeSupport.auditLogURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        let entries = text.split(separator: "\n").compactMap { line -> AuditEntry? in
            try? dec.decode(AuditEntry.self, from: Data(line.utf8))
        }
        return Array(entries.suffix(limit).reversed())
    }

    private func audit(_ entry: AuditEntry) async {
        guard let url = try? ZBSEyeSupport.auditLogURL(), let line = try? JSONEncoder().encode(entry) else { return }
        var data = line
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)   // file doesn't exist yet — create it
        }
    }

    // MARK: prompt + formatting

    static func generationPlan(
        _ c: CollectedDay,
        consumer: AIConsumer,
        safety: AutomationSafety
    ) -> AIConsumerGenerationPlan {
        let tf = DateFormatter(); tf.locale = Locale(identifier: "en_US"); tf.dateFormat = "HH:mm"
        let dayF = DateFormatter(); dayF.locale = Locale(identifier: "en_US"); dayF.dateFormat = "EEEE, d MMMM yyyy"

        let fragments: [AIConsumerPromptFragment] = c.slices.enumerated().map { index, s in
            var head = "[\(tf.string(from: s.start))–\(tf.string(from: s.end))] \(s.app)"
            // window/url from foreign apps/tabs is a potential injection carrier; inside the fence,
            // but truncated like sample (length cap + collapsing) to limit the payload.
            if let w = s.window, !w.isEmpty { head += " — \(clean(w, cap: 200))" }
            if let u = s.url, !u.isEmpty { head += " (\(clean(u, cap: 300)))" }
            if !s.sample.isEmpty { head += " — \(s.sample)" }
            return AIConsumerPromptFragment(sourceID: "slice:\(index)", text: head)
        }
        let language = LocalAIContextPolicy.outputLanguage(for: c.slices.flatMap {
            [$0.app, $0.window ?? "", $0.sample]
        })
        let countLine = c.truncated
            ? "Sessions: \(c.slices.count) (the longest; total for the day — \(c.totalSlices)), frames: \(c.totalCaptures)"
            : "Sessions: \(c.slices.count), frames: \(c.totalCaptures)"
        return AIConsumerPromptFactory.dailySummary(
            consumer: consumer,
            language: language,
            dateLine: dayF.string(from: c.day),
            countLine: countLine,
            fragments: fragments,
            maximumFragmentCharacters: max(800, safety.maxSampleChars + 600),
            maximumOutputTokens: safety.maxOutputTokens,
            timeout: .seconds(safety.requestTimeout)
        )
    }

    static func fileHeader(_ p: SummaryPreview) -> String {
        let dayF = DateFormatter(); dayF.locale = Locale(identifier: "en_US"); dayF.dateStyle = .full
        let nowF = DateFormatter(); nowF.locale = Locale(identifier: "en_US"); nowF.dateFormat = "d MMM yyyy, HH:mm"
        let providerID = AutomationMarkdownSafety.inlineMetadata(
            p.provenance.providerID
        )
        let model = AutomationMarkdownSafety.inlineMetadata(p.model)
        let promptVersion = AutomationMarkdownSafety.inlineMetadata(p.promptVersion)
        let whereText = p.provenance.executedLocally
            ? "generated on this Mac"
            : "generated with \(providerID)"
        let upstream = p.provenance.brokerUpstream.map {
            " → \(AutomationMarkdownSafety.inlineMetadata($0))"
        } ?? ""
        return "# ZBS Eye — day summary\n\n> \(dayF.string(from: p.day))  \n> _\(whereText)\(upstream) · \(model) · \(promptVersion) · \(nowF.string(from: Date()))_\n\n"
    }

    /// Collapses whitespace/newlines into a single space and cuts to cap — a compact sample for the prompt.
    static func clean(_ s: String, cap: Int) -> String {
        let collapsed = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(collapsed.prefix(cap))
    }

    /// Fixed YYYY-MM-DD (POSIX locale) — the file name and the idempotency key.
    static func ymd(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
