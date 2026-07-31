import Foundation

/// Type-safe DTOs for /v1 responses (Codable, snake-free camelCase). No hand-rolled JSON.
enum APIDTO {
    struct Health: Encodable {
        let status: String
        let version: String
        let capturing: Bool
        let proof: String?
        let captureState: String?
        // We don’t expose `port`: it’s already in the port file for our own use, and in the unauthenticated
        // /health it’s an extra information signal to an attacker (no need to scan). `capturing` is kept — MCP reads it.
    }
    struct AppRef: Encodable { let bundleId: String?; let name: String? }
    struct Media: Encodable {
        let frameUrl: String?
        var audioUrl: String? = nil        // kind=audio: m4a segment
        var transcriptUrl: String? = nil   // kind=audio: transcript text
        var callUrl: String? = nil         // kind=call: Call Envelope
    }
    struct SearchHit: Encodable {
        let id: Int64
        let kind: String          // screen | audio | call
        let ts: Int64             // epoch ms
        let endTs: Int64?
        let tsISO: String
        let app: AppRef
        let windowTitle: String?
        let browserUrl: String?
        let snippet: String
        let media: Media
    }
    struct SearchResponse: Encodable {
        let query: String
        let total: Int
        let limit: Int
        let offset: Int
        let semanticMode: String
        let semanticFallbackReason: String?
        let results: [SearchHit]
        let coverage: CaptureCoverageDisclosure?
    }
    struct Transcript: Encodable {
        let audioId: Int64
        let ts: Int64
        let tsISO: String
        let durationSec: Double
        let channel: String       // mic | system
        let speaker: String?      // me | other party
        let language: String?
        let text: String?         // nil = transcript not (yet) available
        let audioUrl: String
    }
    struct DensityBucketDTO: Encodable { let ts: Int64; let count: Int }
    struct TimelineResponse: Encodable {
        let from: Int64; let to: Int64; let bucketMs: Int64
        let buckets: [DensityBucketDTO]
        let coverage: CaptureCoverageDisclosure?
    }
    struct Frame: Encodable {
        let id: Int64
        let ts: Int64
        let tsISO: String
        let app: AppRef
        let windowTitle: String?
        let browserUrl: String?
        let axQuality: String?
        let text: String
        let media: Media
        let coverage: CaptureCoverageDisclosure?
    }
    struct Stats: Encodable {
        let frames: Int
        let textBlocks: Int
        let audioChunks: Int
        let transcriptions: Int
        let apps: Int
        let oldestTs: Int64?
        let newestTs: Int64?
        let mediaBytes: Int64
    }
    struct ErrorBody: Encodable { let code: String; let message: String }
    struct ErrorResponse: Encodable { let error: ErrorBody }
}

/// Shared localhost + Bearer policy. Keeping it independent from FlyingFox
/// makes the exact boundary fixture-testable while every server route still
/// calls the same function.
enum APILocalAuthorization {
    static func allows(hostHeader: String?, authorizationHeader: String?, token: String) -> Bool {
        guard let hostHeader else { return false }
        let host: String
        if hostHeader == "::1" {
            host = hostHeader
        } else if hostHeader.hasPrefix("["), let closing = hostHeader.firstIndex(of: "]") {
            host = String(hostHeader[...closing])
        } else {
            host = hostHeader.split(separator: ":").first.map(String.init) ?? hostHeader
        }
        guard host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" else {
            return false
        }
        return authorizationHeader == "Bearer \(token)"
    }
}

/// Resolves only database-owned relative media references inside the current
/// StorageLocation media directory. Caller-supplied paths never reach disk.
enum ManagedMediaResolver {
    static func url(relativePath: String, mediaRoot: URL) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.contains(".."),
              !relativePath.hasPrefix("/") else { return nil }
        let base = mediaRoot.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard Array(target.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents else {
            return nil
        }
        return target
    }
}

func isoFromMs(_ ms: Int64) -> String {
    Date(timeIntervalSince1970: Double(ms) / 1000).ISO8601Format()
}
