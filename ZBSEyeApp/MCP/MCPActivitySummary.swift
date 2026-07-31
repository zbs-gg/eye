import CryptoKit
import Foundation

enum MCPActivitySummaryError: LocalizedError, Equatable {
    case invalidTime(field: String)
    case invalidRange
    case invalidLimit
    case invalidCursor
    case captureLimitExceeded

    var errorDescription: String? {
        switch self {
        case .invalidTime(let field):
            "\(field) must be epoch-ms or timezone-aware ISO8601."
        case .invalidRange:
            "from must be earlier than or equal to to."
        case .invalidLimit:
            "limit must be a positive integer."
        case .invalidCursor:
            "cursor is invalid or does not match this query."
        case .captureLimitExceeded:
            "requested range contains too many captures; use a smaller time window."
        }
    }
}

struct MCPActivitySummaryRequest: Sendable, Equatable {
    static let defaultLimit = 12
    static let maximumLimit = 24

    let fromMs: Int64
    let toMs: Int64
    let limit: Int
    let hasExplicitLimit: Bool
    let cursor: String?

    static func parse(
        from: String,
        to: String,
        limit: Int?,
        cursor: String?
    ) throws -> Self {
        guard let fromMs = MCPActivitySummaryTime.parse(from) else {
            throw MCPActivitySummaryError.invalidTime(field: "from")
        }
        guard let toMs = MCPActivitySummaryTime.parse(to) else {
            throw MCPActivitySummaryError.invalidTime(field: "to")
        }
        guard fromMs <= toMs else { throw MCPActivitySummaryError.invalidRange }
        if let limit, limit <= 0 { throw MCPActivitySummaryError.invalidLimit }
        return Self(
            fromMs: fromMs,
            toMs: toMs,
            limit: min(limit ?? defaultLimit, maximumLimit),
            hasExplicitLimit: limit != nil,
            cursor: cursor
        )
    }
}

protocol MCPActivitySummaryCaptureProviding: Sendable {
    func captures(
        fromMs: Int64,
        toMs: Int64,
        snapshotMaxCaptureID: Int64,
        limit: Int
    ) async throws -> [CaptureLite]
}

extension DayActivityRepository: MCPActivitySummaryCaptureProviding {}

actor MCPActivitySummaryService {
    private static let maximumTopApps = 12

    private let provider: any MCPActivitySummaryCaptureProviding
    private let profile: MCPAccessProfile
    private let serverVersion: String
    private let cursorCodec: MCPActivitySummaryCursorCodec
    private let maximumCaptures: Int

    init(
        provider: any MCPActivitySummaryCaptureProviding,
        profile: MCPAccessProfile,
        serverVersion: String,
        cursorSecret: Data? = nil,
        maximumCaptures: Int = 50_000
    ) {
        self.provider = provider
        self.profile = profile
        self.serverVersion = serverVersion
        cursorCodec = MCPActivitySummaryCursorCodec(secret: cursorSecret)
        self.maximumCaptures = maximumCaptures
    }

    func render(_ request: MCPActivitySummaryRequest) async throws -> String {
        let decodedCursor: MCPActivitySummaryCursor?
        if let cursor = request.cursor {
            let decoded = try cursorCodec.decode(cursor)
            guard decoded.fromMs == request.fromMs,
                  decoded.toMs == request.toMs,
                  (!request.hasExplicitLimit || decoded.limit == request.limit),
                  decoded.profile == profile.rawValue else {
                throw MCPActivitySummaryError.invalidCursor
            }
            decodedCursor = decoded
        } else {
            decodedCursor = nil
        }

        let fetched = try await provider.captures(
            fromMs: request.fromMs,
            toMs: request.toMs,
            snapshotMaxCaptureID: decodedCursor?.snapshotMaxCaptureID ?? Int64.max,
            limit: maximumCaptures + 1
        )
        guard fetched.count <= maximumCaptures else {
            throw MCPActivitySummaryError.captureLimitExceeded
        }
        let cursorState = decodedCursor ?? MCPActivitySummaryCursor(
            schemaVersion: 1,
            fromMs: request.fromMs,
            toMs: request.toMs,
            limit: request.limit,
            profile: profile.rawValue,
            snapshotMaxCaptureID: fetched.map(\.id).max() ?? 0,
            snapshotCaptureCount: nil,
            nextSessionIndex: 0
        )
        if let snapshotCaptureCount = cursorState.snapshotCaptureCount,
           snapshotCaptureCount != fetched.count {
            throw MCPActivitySummaryError.invalidCursor
        }

        let captures = SystemAppFilter.userCaptures(
            fetched
        ).sorted { lhs, rhs in
            lhs.ts == rhs.ts ? lhs.id < rhs.id : lhs.ts < rhs.ts
        }
        let sessions = Self.activitySessions(from: captures)
        let pageLimit = decodedCursor?.limit ?? request.limit
        guard cursorState.nextSessionIndex >= 0,
              cursorState.nextSessionIndex <= sessions.count else {
            throw MCPActivitySummaryError.invalidCursor
        }
        let pageEnd = min(
            sessions.count,
            cursorState.nextSessionIndex + pageLimit
        )
        let page = Array(sessions[cursorState.nextSessionIndex..<pageEnd])
        let truncated = pageEnd < sessions.count
        let nextCursor: String? = if truncated {
            try cursorCodec.encode(MCPActivitySummaryCursor(
                schemaVersion: 1,
                fromMs: request.fromMs,
                toMs: request.toMs,
                limit: pageLimit,
                profile: profile.rawValue,
                snapshotMaxCaptureID: cursorState.snapshotMaxCaptureID,
                snapshotCaptureCount: fetched.count,
                nextSessionIndex: pageEnd
            ))
        } else {
            nil
        }

        let observedRange = captures.first.flatMap { first in
            captures.last.map { last in
                MCPActivitySummaryRange(fromMs: first.ts, toMs: last.ts)
            }
        }
        let envelope = MCPActivitySummaryEnvelope(
            schemaVersion: 1,
            server: .init(
                name: "zbseye",
                version: serverVersion,
                profile: profile.rawValue
            ),
            requestedRange: .init(fromMs: request.fromMs, toMs: request.toMs),
            observedRange: observedRange,
            newestCaptureAt: captures.last.map { MCPActivitySummaryTime.iso($0.ts) },
            captureCount: captures.count,
            topApps: Self.topApps(from: captures),
            sessions: page,
            truncated: truncated,
            nextCursor: nextCursor
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(envelope), as: UTF8.self)
    }

    private static func activitySessions(
        from captures: [CaptureLite]
    ) -> [MCPActivitySummarySession] {
        let segmented = DayActivityRepository.sessions(
            captures,
            grouping: .appOnly,
            gapMs: 180 * 1_000,
            excludeSystem: false
        )
        var sanitizedAppNames: [String: String] = [:]
        let scenes = segmented.map { segment -> ActivityScene in
            let first = segment.first
            let representative = segment.rep
            let rawAppName = first.appName ?? first.bundleId ?? "App"
            let appName: String
            if let cached = sanitizedAppNames[rawAppName] {
                appName = cached
            } else {
                appName = MCPActivitySummaryLabel.safeAppName(rawAppName)
                sanitizedAppNames[rawAppName] = appName
            }
            let topic = MCPActivitySummaryLabel.safeTopic(
                appName: appName,
                bundleID: representative.bundleId ?? first.bundleId,
                windowTitle: representative.windowTitle ?? first.windowTitle,
                browserURL: representative.browserUrl ?? first.browserUrl
            )
            return ActivityScene(
                id: "\(first.appId.map(String.init) ?? "noapp")-\(first.ts)-\(first.id)",
                captureIds: Set(segment.captureIds),
                appId: first.appId,
                bundleId: first.bundleId,
                appName: appName,
                repWindowTitle: topic,
                browserURL: nil,
                startTs: dateFromMs(segment.startMs),
                endTs: dateFromMs(segment.endMs),
                durationSec: max(1, Double(segment.durationMs) / 1_000),
                frameCount: segment.count,
                summary: appName,
                isSystem: false
            )
        }
        let blocks = ActivityBlockBuilder.blocks(from: scenes)
        var blockIndexByCaptureID: [Int64: Int] = [:]
        for (blockIndex, block) in blocks.enumerated() {
            for scene in block.scenes {
                for captureID in scene.captureIds {
                    blockIndexByCaptureID[captureID] = blockIndex
                }
            }
        }
        var capturesByBlock = Array(repeating: [CaptureLite](), count: blocks.count)
        for capture in captures {
            if let blockIndex = blockIndexByCaptureID[capture.id] {
                capturesByBlock[blockIndex].append(capture)
            }
        }
        return zip(blocks, capturesByBlock).compactMap { block, blockCaptures in
            guard !blockCaptures.isEmpty else { return nil }
            let representative = blockCaptures[blockCaptures.count / 2]
            return MCPActivitySummarySession(
                startAt: MCPActivitySummaryTime.iso(msFromDate(block.startTs)),
                endAt: MCPActivitySummaryTime.iso(msFromDate(block.endTs)),
                durationMs: Int64((block.durationSec * 1_000).rounded()),
                frameCount: block.frameCount,
                topApps: Array(block.topApps.prefix(3).map(\.name)),
                label: MCPActivitySummaryLabel.safeOutput(block.heuristicLabel),
                representativeFrameID: representative.id
            )
        }
    }

    private static func topApps(
        from captures: [CaptureLite]
    ) -> [MCPActivitySummaryTopApp] {
        struct Key: Hashable {
            let name: String
            let bundleID: String?
        }
        struct Aggregate {
            var frameCount = 0
            var activeDurationMs: Int64 = 0
        }
        var aggregates: [Key: Aggregate] = [:]
        var sanitizedAppNames: [String: String] = [:]
        for (index, capture) in captures.enumerated() {
            let rawAppName = capture.appName ?? capture.bundleId ?? "App"
            let appName: String
            if let cached = sanitizedAppNames[rawAppName] {
                appName = cached
            } else {
                appName = MCPActivitySummaryLabel.safeAppName(rawAppName)
                sanitizedAppNames[rawAppName] = appName
            }
            let key = Key(
                name: appName,
                bundleID: capture.bundleId
            )
            aggregates[key, default: Aggregate()].frameCount += 1
            if index + 1 < captures.count {
                let delta = max(0, captures[index + 1].ts - capture.ts)
                aggregates[key, default: Aggregate()].activeDurationMs += min(
                    delta,
                    120 * 1_000
                )
            }
        }
        let ranked = aggregates.map { key, value in
            MCPActivitySummaryTopApp(
                name: key.name,
                bundleID: key.bundleID,
                frameCount: value.frameCount,
                activeDurationMs: value.activeDurationMs
            )
        }.sorted { lhs, rhs in
            if lhs.activeDurationMs != rhs.activeDurationMs {
                return lhs.activeDurationMs > rhs.activeDurationMs
            }
            if lhs.frameCount != rhs.frameCount {
                return lhs.frameCount > rhs.frameCount
            }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return (lhs.bundleID ?? "") < (rhs.bundleID ?? "")
        }
        return Array(ranked.prefix(maximumTopApps))
    }
}

private struct MCPActivitySummaryEnvelope: Encodable {
    let schemaVersion: Int
    let server: MCPActivitySummaryServer
    let requestedRange: MCPActivitySummaryRange
    let observedRange: MCPActivitySummaryRange?
    let newestCaptureAt: String?
    let captureCount: Int
    let topApps: [MCPActivitySummaryTopApp]
    let sessions: [MCPActivitySummarySession]
    let truncated: Bool
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case server
        case requestedRange = "requested_range"
        case observedRange = "observed_range"
        case newestCaptureAt = "newest_capture_at"
        case captureCount = "capture_count"
        case topApps = "top_apps"
        case sessions
        case truncated
        case nextCursor = "next_cursor"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(server, forKey: .server)
        try container.encode(requestedRange, forKey: .requestedRange)
        try container.encode(observedRange, forKey: .observedRange)
        try container.encode(newestCaptureAt, forKey: .newestCaptureAt)
        try container.encode(captureCount, forKey: .captureCount)
        try container.encode(topApps, forKey: .topApps)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(truncated, forKey: .truncated)
        try container.encode(nextCursor, forKey: .nextCursor)
    }
}

private struct MCPActivitySummaryServer: Encodable {
    let name: String
    let version: String
    let profile: String
}

private struct MCPActivitySummaryRange: Encodable {
    let fromMs: Int64
    let toMs: Int64

    enum CodingKeys: String, CodingKey {
        case fromMs = "from_ms"
        case toMs = "to_ms"
        case fromISO = "from_iso"
        case toISO = "to_iso"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fromMs, forKey: .fromMs)
        try container.encode(toMs, forKey: .toMs)
        try container.encode(MCPActivitySummaryTime.iso(fromMs), forKey: .fromISO)
        try container.encode(MCPActivitySummaryTime.iso(toMs), forKey: .toISO)
    }
}

private struct MCPActivitySummaryTopApp: Encodable {
    let name: String
    let bundleID: String?
    let frameCount: Int
    let activeDurationMs: Int64

    enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
        case frameCount = "frame_count"
        case activeDurationMs = "active_duration_ms"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(frameCount, forKey: .frameCount)
        try container.encode(activeDurationMs, forKey: .activeDurationMs)
    }
}

private struct MCPActivitySummarySession: Encodable {
    let startAt: String
    let endAt: String
    let durationMs: Int64
    let frameCount: Int
    let topApps: [String]
    let label: String
    let representativeFrameID: Int64

    enum CodingKeys: String, CodingKey {
        case startAt = "start_at"
        case endAt = "end_at"
        case durationMs = "duration_ms"
        case frameCount = "frame_count"
        case topApps = "top_apps"
        case label
        case representativeFrameID = "representative_frame_id"
    }
}

private struct MCPActivitySummaryCursor: Codable {
    let schemaVersion: Int
    let fromMs: Int64
    let toMs: Int64
    let limit: Int
    let profile: String
    let snapshotMaxCaptureID: Int64
    let snapshotCaptureCount: Int?
    let nextSessionIndex: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fromMs = "from_ms"
        case toMs = "to_ms"
        case limit
        case profile
        case snapshotMaxCaptureID = "snapshot_max_capture_id"
        case snapshotCaptureCount = "snapshot_capture_count"
        case nextSessionIndex = "next_session_index"
    }
}

private struct MCPActivitySummaryCursorCodec: Sendable {
    private let key: SymmetricKey

    init(secret: Data?) {
        key = secret.map(SymmetricKey.init(data:)) ?? SymmetricKey(size: .bits256)
    }

    func encode(_ cursor: MCPActivitySummaryCursor) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(cursor)
        let authenticationCode = Data(HMAC<SHA256>.authenticationCode(
            for: payload,
            using: key
        ))
        return Self.base64URL(payload) + "." + Self.base64URL(authenticationCode)
    }

    func decode(_ token: String) throws -> MCPActivitySummaryCursor {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let payload = Self.data(base64URL: String(pieces[0])),
              let authenticationCode = Self.data(base64URL: String(pieces[1])),
              HMAC<SHA256>.isValidAuthenticationCode(
                  authenticationCode,
                  authenticating: payload,
                  using: key
              ),
              let cursor = try? JSONDecoder().decode(
                  MCPActivitySummaryCursor.self,
                  from: payload
              ),
              cursor.schemaVersion == 1,
              cursor.snapshotMaxCaptureID >= 0,
              cursor.snapshotCaptureCount.map({ $0 >= 0 }) ?? true,
              cursor.nextSessionIndex >= 0 else {
            throw MCPActivitySummaryError.invalidCursor
        }
        return cursor
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func data(base64URL: String) -> Data? {
        var value = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: value)
    }
}

private enum MCPActivitySummaryTime {
    static func parse(_ raw: String) -> Int64? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let milliseconds = Int64(value) { return milliseconds }
        guard value.range(
            of: #"(?:Z|[+-]\d{2}:\d{2})$"#,
            options: .regularExpression
        ) != nil else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = fractional.date(from: value) ?? plain.date(from: value) else {
            return nil
        }
        return Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    static func iso(_ milliseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: dateFromMs(milliseconds))
    }
}

enum MCPActivitySummaryLabel {
    private static let fileURLRegex = compile(#"(?i)\bfile://[^\s]+"#)
    private static let httpURLRegex = compile(#"(?i)https?://[^\s]+"#)
    private static let fixedReplacements: [(NSRegularExpression, String)] = [
        (compile(#"(?i)\b(?:[A-Z0-9_.-]*(?:api[_-]?key|token|secret|password|passwd)|bearer|authorization)\s*[:=]\s*(?:['\"])?[^\s,;'\"]+"#), "[secret]"),
        (compile(#"(?i)\b(?:sk-[A-Z0-9_-]{8,}|gh[pousr]_[A-Z0-9_]{8,}|xox[baprs]-[A-Z0-9-]{8,}|AKIA[A-Z0-9]{16})\b"#), "[secret]"),
        (compile(#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#), "[private]"),
    ]

    private static func compile(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid activity-summary redaction pattern")
        }
        return regex
    }

    static func safeAppName(_ raw: String) -> String {
        let clean = safeOutput(raw)
        return clean.isEmpty ? "App" : String(clean.prefix(64))
    }

    static func safeTopic(
        appName: String,
        bundleID: String?,
        windowTitle: String?,
        browserURL: String?
    ) -> String? {
        if let browserURL,
           let host = DayActivityRepository.hostFromURL(browserURL) {
            return host
        }
        guard let windowTitle else { return nil }
        var clean = safeOutput(windowTitle)
        clean = DayActivityRepository.cleanPageTitle(clean)
        guard !clean.isEmpty, clean != appName, clean != bundleID else { return nil }
        return String(clean.prefix(80))
    }

    static func safeOutput(_ raw: String) -> String {
        var value = raw
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        value = replacingMatches(
            in: value,
            regex: fileURLRegex,
            with: "[path]"
        )
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in httpURLRegex.matches(in: value, range: range).reversed() {
            guard let swiftRange = Range(match.range, in: value) else { continue }
            let matched = String(value[swiftRange])
            let replacement = DayActivityRepository.hostFromURL(matched) ?? "web link"
            value.replaceSubrange(swiftRange, with: replacement)
        }
        if value.contains("/") || value.contains("\\") {
            value = "[path]"
        }
        for (regex, replacement) in fixedReplacements {
            value = replacingMatches(in: value, regex: regex, with: replacement)
        }
        value = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(value.prefix(120))
    }

    private static func replacingMatches(
        in value: String,
        regex: NSRegularExpression,
        with replacement: String
    ) -> String {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        )
    }
}
