import Foundation

enum BrowserSnapshotLimits {
    static let maximumPayloadBytes = 256 * 1_024
    static let maximumTextCharacters = 40_000
    static let maximumFrames = 32
    static let maximumClockSkew: TimeInterval = 30
    static let freshnessInterval: TimeInterval = 5
}

struct BrowserFrameSnapshot: Codable, Sendable, Equatable {
    let frameId: Int
    let parentFrameId: Int?
    let documentId: String
    let url: String
    let text: String
}

struct BrowserPageSnapshot: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let capturedAtMs: Int64
    let browserInstanceId: String
    let tabId: Int
    let windowId: Int
    let documentId: String
    let url: String
    let title: String
    let contentHash: String
    let active: Bool
    let windowFocused: Bool
    let pixelOnly: Bool
    let frames: [BrowserFrameSnapshot]

    var capturedAt: Date {
        Date(timeIntervalSince1970: TimeInterval(capturedAtMs) / 1_000)
    }

    var combinedText: String {
        frames
            .sorted { $0.frameId < $1.frameId }
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct BrowserPageHeartbeat: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let capturedAtMs: Int64
    let browserInstanceId: String
    let tabId: Int
    let windowId: Int
    let documentId: String
    let url: String
    let title: String
    let contentHash: String
    let active: Bool
    let windowFocused: Bool
}

enum BrowserSnapshotValidationError: Error, Sendable, Equatable {
    case payloadTooLarge
    case malformedJSON
    case unknownOrMissingFields
    case unsupportedVersion
    case invalidTimestamp
    case invalidIdentifier
    case invalidURL
    case invalidHash
    case tooManyFrames
    case tooMuchText
}

enum BrowserSnapshotDecoder {
    private static let pageKeys: Set<String> = [
        "schemaVersion", "capturedAtMs", "browserInstanceId", "tabId", "windowId",
        "documentId", "url", "title", "contentHash", "active", "windowFocused",
        "pixelOnly", "frames",
    ]
    private static let frameKeys: Set<String> = [
        "frameId", "parentFrameId", "documentId", "url", "text",
    ]

    static func decode(_ data: Data, now: Date = Date()) throws -> BrowserPageSnapshot {
        guard data.count <= BrowserSnapshotLimits.maximumPayloadBytes else {
            throw BrowserSnapshotValidationError.payloadTooLarge
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == pageKeys,
              let rawFrames = dictionary["frames"] as? [[String: Any]],
              rawFrames.allSatisfy({ Set($0.keys) == frameKeys }) else {
            throw BrowserSnapshotValidationError.unknownOrMissingFields
        }

        let snapshot: BrowserPageSnapshot
        do {
            snapshot = try JSONDecoder().decode(BrowserPageSnapshot.self, from: data)
        } catch {
            throw BrowserSnapshotValidationError.malformedJSON
        }

        guard snapshot.schemaVersion == 1 else {
            throw BrowserSnapshotValidationError.unsupportedVersion
        }
        guard abs(snapshot.capturedAt.timeIntervalSince(now)) <= BrowserSnapshotLimits.maximumClockSkew else {
            throw BrowserSnapshotValidationError.invalidTimestamp
        }
        guard isIdentifier(snapshot.browserInstanceId, maximum: 128),
              isIdentifier(snapshot.documentId, maximum: 256),
              snapshot.tabId >= 0,
              snapshot.windowId >= 0 else {
            throw BrowserSnapshotValidationError.invalidIdentifier
        }
        guard isPageURL(snapshot.url), snapshot.title.count <= 2_048 else {
            throw BrowserSnapshotValidationError.invalidURL
        }
        guard isHash(snapshot.contentHash) else {
            throw BrowserSnapshotValidationError.invalidHash
        }
        guard !snapshot.frames.isEmpty,
              snapshot.frames.count <= BrowserSnapshotLimits.maximumFrames else {
            throw BrowserSnapshotValidationError.tooManyFrames
        }
        guard snapshot.frames.allSatisfy({
            $0.frameId >= 0
                && ($0.parentFrameId == nil || $0.parentFrameId! >= 0)
                && isIdentifier($0.documentId, maximum: 256)
                && isFrameURL($0.url)
        }) else {
            throw BrowserSnapshotValidationError.invalidIdentifier
        }
        guard snapshot.frames.contains(where: {
            $0.frameId == 0 && $0.documentId == snapshot.documentId && $0.url == snapshot.url
        }) else {
            throw BrowserSnapshotValidationError.invalidIdentifier
        }
        guard snapshot.combinedText.count <= BrowserSnapshotLimits.maximumTextCharacters else {
            throw BrowserSnapshotValidationError.tooMuchText
        }
        return snapshot
    }

    static func isIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty
            && value.count <= maximum
            && value.allSatisfy { $0.isLetter || $0.isNumber || "-_.:".contains($0) }
    }

    static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    static func isPageURL(_ value: String) -> Bool {
        guard value.utf8.count <= 8_192,
              let scheme = URL(string: value)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func isFrameURL(_ value: String) -> Bool {
        value == "about:blank" || isPageURL(value)
    }
}

enum BrowserHeartbeatDecoder {
    static let maximumPayloadBytes = 8 * 1_024
    private static let keys: Set<String> = [
        "schemaVersion", "capturedAtMs", "browserInstanceId", "tabId", "windowId",
        "documentId", "url", "title", "contentHash", "active", "windowFocused",
    ]

    static func decode(_ data: Data, now: Date = Date()) throws -> BrowserPageHeartbeat {
        guard data.count <= maximumPayloadBytes else {
            throw BrowserSnapshotValidationError.payloadTooLarge
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == keys else {
            throw BrowserSnapshotValidationError.unknownOrMissingFields
        }
        let heartbeat: BrowserPageHeartbeat
        do {
            heartbeat = try JSONDecoder().decode(BrowserPageHeartbeat.self, from: data)
        } catch {
            throw BrowserSnapshotValidationError.malformedJSON
        }
        guard heartbeat.schemaVersion == 1 else {
            throw BrowserSnapshotValidationError.unsupportedVersion
        }
        let capturedAt = Date(timeIntervalSince1970: TimeInterval(heartbeat.capturedAtMs) / 1_000)
        guard abs(capturedAt.timeIntervalSince(now)) <= BrowserSnapshotLimits.maximumClockSkew else {
            throw BrowserSnapshotValidationError.invalidTimestamp
        }
        guard heartbeat.tabId >= 0,
              heartbeat.windowId >= 0,
              BrowserSnapshotDecoder.isIdentifier(heartbeat.browserInstanceId, maximum: 128),
              BrowserSnapshotDecoder.isIdentifier(heartbeat.documentId, maximum: 256) else {
            throw BrowserSnapshotValidationError.invalidIdentifier
        }
        guard BrowserSnapshotDecoder.isPageURL(heartbeat.url), heartbeat.title.count <= 2_048 else {
            throw BrowserSnapshotValidationError.invalidURL
        }
        guard BrowserSnapshotDecoder.isHash(heartbeat.contentHash) else {
            throw BrowserSnapshotValidationError.invalidHash
        }
        return heartbeat
    }
}

enum BrowserIngestAuthorization {
    static func allows(
        hostHeader: String?,
        authorizationHeader: String?,
        browserToken: String
    ) -> Bool {
        APILocalAuthorization.allows(
            hostHeader: hostHeader,
            authorizationHeader: authorizationHeader,
            token: browserToken
        )
    }
}

enum BrowserSnapshotIngestResult: Sendable, Equatable {
    case accepted
    case duplicate
    case ignoredInactive
}

enum BrowserConnectionStatus: String, Sendable, Equatable {
    case connected
    case stale
    case disconnected
}

enum BrowserIngestHTTPPolicy {
    static func statusCode(
        authorized: Bool,
        bodyWithinLimit: Bool,
        validPayload: Bool,
        capturing: Bool,
        activeFocused: Bool
    ) -> Int {
        guard authorized else { return 401 }
        guard bodyWithinLimit else { return 413 }
        guard validPayload, activeFocused else { return 422 }
        _ = capturing // accepted paused responses deliberately use the same code
        return 202
    }
}

struct BrowserPageContent: Sendable, Equatable {
    let capturedAt: Date
    let title: String
    let url: String
    let contentHash: String
    let text: String
    let requiresOCR: Bool
}

actor BrowserContentStore {
    private struct Entry: Sendable {
        let snapshot: BrowserPageSnapshot
        var receivedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var bundleAssociations: [String: String] = [:]
    private var lastSeenAt: Date?

    func ingest(_ snapshot: BrowserPageSnapshot, now: Date = Date()) -> BrowserSnapshotIngestResult {
        guard snapshot.active, snapshot.windowFocused else { return .ignoredInactive }
        lastSeenAt = now

        if var existing = entries[snapshot.browserInstanceId],
           existing.snapshot.documentId == snapshot.documentId,
           existing.snapshot.contentHash == snapshot.contentHash {
            existing.receivedAt = now
            entries[snapshot.browserInstanceId] = existing
            return .duplicate
        }

        entries[snapshot.browserInstanceId] = Entry(snapshot: snapshot, receivedAt: now)
        if entries.count > 8,
           let oldest = entries.min(by: { $0.value.receivedAt < $1.value.receivedAt })?.key {
            entries[oldest] = nil
            bundleAssociations = bundleAssociations.filter { $0.value != oldest }
        }
        return .accepted
    }

    func match(
        bundleID: String,
        windowTitle: String?,
        browserURL: String?,
        now: Date = Date()
    ) -> BrowserPageContent? {
        guard BrowserCapturePolicy.isChromiumBrowser(bundleID) else { return nil }
        let fresh = entries.filter {
            now.timeIntervalSince($0.value.receivedAt) <= BrowserSnapshotLimits.freshnessInterval
        }
        let matches: (Entry) -> Bool = { entry in
            Self.titlesMatch(windowTitle, entry.snapshot.title)
                || Self.urlsMatch(browserURL, entry.snapshot.url)
        }

        if let instanceID = bundleAssociations[bundleID],
           let entry = fresh[instanceID], matches(entry) {
            return Self.content(entry.snapshot)
        }

        let candidates = fresh.values.filter(matches)
        guard candidates.count == 1, let candidate = candidates.first else {
            bundleAssociations[bundleID] = nil
            return nil
        }
        bundleAssociations[bundleID] = candidate.snapshot.browserInstanceId
        return Self.content(candidate.snapshot)
    }

    func heartbeat(_ heartbeat: BrowserPageHeartbeat, now: Date = Date()) -> Bool {
        guard heartbeat.active,
              heartbeat.windowFocused,
              var entry = entries[heartbeat.browserInstanceId],
              entry.snapshot.tabId == heartbeat.tabId,
              entry.snapshot.windowId == heartbeat.windowId,
              entry.snapshot.documentId == heartbeat.documentId,
              entry.snapshot.url == heartbeat.url,
              entry.snapshot.contentHash == heartbeat.contentHash else { return false }
        entry.receivedAt = now
        entries[heartbeat.browserInstanceId] = entry
        lastSeenAt = now
        return true
    }

    func status(now: Date = Date()) -> BrowserConnectionStatus {
        guard let lastSeenAt else { return .disconnected }
        let age = now.timeIntervalSince(lastSeenAt)
        if age <= 10 { return .connected }
        if age <= 60 { return .stale }
        return .disconnected
    }

    func clear() {
        entries.removeAll()
        bundleAssociations.removeAll()
        lastSeenAt = nil
    }

    private static func content(_ snapshot: BrowserPageSnapshot) -> BrowserPageContent {
        BrowserPageContent(
            capturedAt: snapshot.capturedAt,
            title: snapshot.title,
            url: snapshot.url,
            contentHash: snapshot.contentHash,
            text: snapshot.combinedText,
            requiresOCR: snapshot.pixelOnly
        )
    }

    private static func titlesMatch(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        let a = normalizedTitle(lhs)
        let b = normalizedTitle(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    private static func normalizedTitle(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for suffix in [
            " — dia", " - dia", " | dia", " — google chrome", " - google chrome",
            " — microsoft edge", " - microsoft edge", " — brave", " - brave",
        ] where result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func urlsMatch(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        func normalized(_ value: String) -> String {
            var components = URLComponents(string: value)
            components?.fragment = nil
            return (components?.string ?? value).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return normalized(lhs) == normalized(rhs)
    }
}
