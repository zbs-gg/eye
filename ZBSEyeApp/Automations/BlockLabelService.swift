import Foundation

/// Optional LLM one-liner for an activity block — "Working on ZBS Eye: Xcode, GitHub, docs".
/// Follows the CartographerService pattern: router authorization gate, bounded JSON-encoded data inside
/// an explicit untrusted-data frame, plus sanitized and capped output. JSON escaping is defense in depth,
/// not a claim that arbitrary prompt injection is structurally impossible.
/// The heuristic label always exists — any failure here just means the UI keeps the heuristic
/// (graceful fallback, no error surface).
actor BlockLabelService {
    static let promptVersion = AIConsumerPromptFactory.blockLabelVersion

    struct GeneratedLabel: Sendable, Equatable {
        let text: String
        let provenance: AIExecutionProvenance
        let promptVersion: String
    }

    private let generator: any AIConsumerGenerating
    /// Cache per block-content+model: a re-render / repeat visit never re-asks the model. The value is
    /// optional — a stored `nil` is a NEGATIVE cache entry (the call errored or the output sanitized to
    /// empty), so a bad block isn't re-sent to the local model on every Activities re-appearance.
    /// Session-lifetime is enough — labels are cosmetic and cheap to lose on relaunch.
    private var cache: [GeneratedLabelCacheIdentity: GeneratedLabel?] = [:]

    init(generator: any AIConsumerGenerating) { self.generator = generator }

    /// Key = block's epoch-ms range + model id + a fingerprint of its apps and topics. The ms range is
    /// absolute (globally unique across days, so no day prefix is needed); the model id + content
    /// fingerprint invalidate a stale one-liner when the user switches models or the block's interior
    /// changes (a new app/topic mid-range) even if its start/end don't shift.
    private static func blockFingerprint(block: ActivityBlock) -> String {
        let apps = block.topApps.prefix(4)
            .map { "\($0.name):\(Int($0.seconds))" }.joined(separator: ",")
        let topics = block.scenes.compactMap { ActivityBlockBuilder.topic(of: $0) }.joined(separator: ",")
        return "\(msFromDate(block.startTs))-\(msFromDate(block.endTs))|\(apps)|\(topics)"
    }

    /// One-liner for a block, or nil (LLM not configured / non-local / bad output) → keep heuristic.
    /// `day` is accepted for the caller's clarity but does not enter the (globally unique) cache key.
    func label(day: Date, block: ActivityBlock, execution: AIConsumerExecutionContext,
               requestID: UUID = UUID(),
               safety: AutomationSafety = .default) async -> GeneratedLabel? {
        let key = GeneratedLabelCacheIdentity(
            selection: execution.selection,
            promptVersion: Self.promptVersion,
            blockFingerprint: Self.blockFingerprint(block: block)
        )
        if let hit = cache[key] { return hit }   // hit = a label OR a cached miss (nil) — never re-ask this session
        let plan = Self.generationPlan(block, safety: safety)
        guard let out = try? await generator.generate(
            plan: plan,
            execution: execution,
            requestID: requestID
        ), let line = Self.sanitize(out.content) else {
            cache.updateValue(nil, forKey: key)   // negative cache (subscript = nil would REMOVE the key)
            return nil
        }
        let generated = GeneratedLabel(
            text: line,
            provenance: out.provenance,
            promptVersion: out.promptVersion
        )
        cache[key] = generated
        return generated
    }

    // MARK: - prompt (screen-derived data ONLY as JSON values)

    static func generationPlan(
        _ block: ActivityBlock,
        safety: AutomationSafety
    ) -> AIConsumerGenerationPlan {
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX"); tf.dateFormat = "HH:mm"

        // Same injection fence as Cartographer: everything screen-derived is encoded as JSON values
        // and truncated — an app/page could have named itself with an injection.
        struct PromptApp: Encodable { let app: String; let minutes: Int }
        struct PromptData: Encodable {
            let start: String; let end: String
            let apps: [PromptApp]; let topics: [String]
        }
        let topics = Array(block.scenes.compactMap { ActivityBlockBuilder.topic(of: $0) }
            .reduce(into: [String]()) { acc, t in if !acc.contains(t) { acc.append(t) } }
            .prefix(6))
        let data = PromptData(
            start: tf.string(from: block.startTs), end: tf.string(from: block.endTs),
            apps: block.topApps.prefix(4).map {
                PromptApp(app: CartographerService.clean($0.name, cap: 80),
                          minutes: max(1, Int($0.seconds / 60)))
            },
            topics: topics.map { CartographerService.clean($0, cap: 80) })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let json = (try? enc.encode(data)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let language = LocalAIContextPolicy.outputLanguage(
            for: block.topApps.map(\.name) + topics
        )
        return AIConsumerPromptFactory.generatedLabel(
            serializedBlock: json,
            language: language,
            maximumFragmentCharacters: max(600, safety.maxSampleChars * 3),
            timeout: .seconds(safety.requestTimeout)
        )
    }

    // MARK: - post-LLM guardrail

    /// First non-empty line, bullets/quotes stripped, md/bare links removed (anti-exfil, same policy
    /// as CartographerService.sanitizeOutput), length-capped. nil → caller keeps the heuristic label.
    static func sanitize(_ raw: String) -> String? {
        let imgLink = #"!?\[([^\]]*)\]\([^)]*\)"#
        let bareURL = #"\bhttps?://\S+"#
        guard var s = raw.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        for p in [#"^\d+[\.\)]\s+"#, #"^[•\-\*]\s+"#] {
            if let r = s.range(of: p, options: .regularExpression) { s = String(s[r.upperBound...]) }
        }
        s = s.replacingOccurrences(of: imgLink, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: bareURL, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«» ").union(.whitespaces))
        guard !s.isEmpty else { return nil }
        return String(s.prefix(100))
    }
}
