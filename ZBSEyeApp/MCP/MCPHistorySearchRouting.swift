import Foundation

enum MCPHistorySearchSource: Sendable, Equatable {
    case guiHybrid
    case helperFTS
}

struct MCPHistorySearchResolution: Sendable {
    let results: [SearchResult]
    let source: MCPHistorySearchSource
    let semanticMode: SearchSemanticMode
}

enum MCPHistorySearchRoutingError: Error, Equatable {
    case fallbackUnavailable
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidPayload
}

/// Keeps MCP's public search contract hybrid without starting a second model
/// runtime. A healthy GUI owns semantic search; the helper reads FTS directly
/// only when the GUI is absent.
struct MCPHistorySearchCoordinator: Sendable {
    typealias GUISearch = @Sendable (String, SearchFilters) async throws -> SearchExecution?
    typealias FallbackSearch = @Sendable (String, SearchFilters) async throws -> SearchExecution

    private let guiSearch: GUISearch
    private let fallbackSearch: FallbackSearch

    init(
        guiSearch: @escaping GUISearch,
        fallbackSearch: @escaping FallbackSearch
    ) {
        self.guiSearch = guiSearch
        self.fallbackSearch = fallbackSearch
    }

    func search(query: String, filters: SearchFilters) async throws -> MCPHistorySearchResolution {
        if let execution = try await guiSearch(query, filters) {
            return MCPHistorySearchResolution(
                results: execution.results,
                source: .guiHybrid,
                semanticMode: execution.semanticMode
            )
        }
        let execution = try await fallbackSearch(query, filters)
        return MCPHistorySearchResolution(
            results: execution.results,
            source: .helperFTS,
            semanticMode: execution.semanticMode
        )
    }
}

struct MCPGUIHistorySearchHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}

/// Typed adapter for the existing authenticated `/v1/search` contract.
/// The public REST payload is unchanged; this helper only decodes it back into
/// the internal search model used by MCP formatting.
struct MCPGUIHistorySearchClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> MCPGUIHistorySearchHTTPResponse

    private struct Response: Decodable {
        let semanticMode: String
        let semanticFallbackReason: String?
        let results: [Hit]
    }

    private struct Hit: Decodable {
        struct App: Decodable {
            let bundleId: String?
            let name: String?
        }

        let id: Int64
        let kind: String
        let ts: Int64
        let endTs: Int64?
        let app: App
        let windowTitle: String?
        let browserUrl: String?
        let snippet: String
    }

    private let transport: Transport

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    func search(
        port: Int,
        token: String,
        query: String,
        filters: SearchFilters
    ) async throws -> SearchExecution {
        var components = URLComponents(string: "http://127.0.0.1:\(port)/v1/search")!
        var items = [URLQueryItem(name: "q", value: query)]
        if let from = filters.from {
            items.append(URLQueryItem(name: "from", value: String(msFromDate(from))))
        }
        if let to = filters.to {
            items.append(URLQueryItem(name: "to", value: String(msFromDate(to))))
        }
        if let app = filters.app, !app.isEmpty {
            items.append(URLQueryItem(name: "app", value: app))
        }
        if let kind = filters.kind {
            items.append(URLQueryItem(name: "kind", value: kind.rawValue))
        }
        items.append(URLQueryItem(name: "limit", value: String(filters.limit)))
        items.append(URLQueryItem(name: "offset", value: String(filters.offset)))
        components.queryItems = items
        guard let url = components.url else {
            throw MCPHistorySearchRoutingError.invalidHTTPResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MCPHistorySearchRoutingError.httpStatus(response.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(Response.self, from: response.data) else {
            throw MCPHistorySearchRoutingError.invalidPayload
        }
        let semanticMode: SearchSemanticMode
        switch payload.semanticMode {
        case "hybrid":
            semanticMode = .hybrid
        case "embeddingUnavailable":
            semanticMode = .embeddingUnavailable
        case "ftsOnly":
            guard let rawReason = payload.semanticFallbackReason,
                  let reason = SemanticQueryFallbackReason(rawValue: rawReason) else {
                throw MCPHistorySearchRoutingError.invalidPayload
            }
            semanticMode = .ftsOnly(reason)
        default:
            throw MCPHistorySearchRoutingError.invalidPayload
        }
        let results = try payload.results.map { hit in
            guard let kind = SearchKind(rawValue: hit.kind) else {
                throw MCPHistorySearchRoutingError.invalidPayload
            }
            return SearchResult(
                id: hit.id,
                kind: kind,
                ts: dateFromMs(hit.ts),
                endTs: hit.endTs.map(dateFromMs),
                bundleId: hit.app.bundleId,
                appName: hit.app.name,
                windowTitle: hit.windowTitle,
                browserURL: hit.browserUrl,
                snippet: hit.snippet,
                relativePath: nil
            )
        }
        return SearchExecution(results: results, semanticMode: semanticMode)
    }
}
