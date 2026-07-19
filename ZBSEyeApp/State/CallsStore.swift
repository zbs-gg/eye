import Foundation
import Observation

protocol CallLibraryQuerying: Sendable {
    func listCalls(
        query: String?,
        limit: Int,
        offset: Int
    ) async throws -> CallEvidenceListPage
}

extension CallEvidenceQueryService: CallLibraryQuerying {
    func listCalls(
        query: String?,
        limit: Int,
        offset: Int
    ) async throws -> CallEvidenceListPage {
        try await listCalls(
            query: query,
            fromMs: nil,
            toMs: nil,
            limit: limit,
            offset: offset
        )
    }
}

enum CallsStorePhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(String)
}

/// Persistent state for the Calls workspace. The store outlives mode switches,
/// so a user can inspect Timeline or Ask without losing their call search or place.
@MainActor
@Observable
final class CallsStore {
    static let pageSize = 25

    var query = "" {
        didSet {
            if query != oldValue { requestGeneration &+= 1 }
        }
    }
    private(set) var calls: [CallEvidenceSummary] = []
    private(set) var phase: CallsStorePhase = .idle
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    private(set) var selectedCallID: Int64?

    @ObservationIgnored private let service: any CallLibraryQuerying
    @ObservationIgnored private var nextOffset: Int?
    @ObservationIgnored private var requestGeneration: UInt64 = 0

    init(service: any CallLibraryQuerying) {
        self.service = service
    }

    func reload() async {
        requestGeneration &+= 1
        let generation = requestGeneration
        let submittedQuery = normalizedQuery
        phase = .loading
        do {
            let page = try await service.listCalls(
                query: submittedQuery,
                limit: Self.pageSize,
                offset: 0
            )
            guard generation == requestGeneration else { return }
            calls = page.calls
            hasMore = page.hasMore
            nextOffset = page.nextOffset
            phase = .ready
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            calls = []
            hasMore = false
            nextOffset = nil
            phase = .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, let nextOffset else { return }
        isLoadingMore = true
        let generation = requestGeneration
        let submittedQuery = normalizedQuery
        defer {
            if generation == requestGeneration { isLoadingMore = false }
        }
        do {
            let page = try await service.listCalls(
                query: submittedQuery,
                limit: Self.pageSize,
                offset: nextOffset
            )
            guard generation == requestGeneration else { return }
            var known = Set(calls.map(\.callId))
            calls.append(contentsOf: page.calls.filter { known.insert($0.callId).inserted })
            hasMore = page.hasMore
            self.nextOffset = page.nextOffset
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    func open(_ call: CallEvidenceSummary) {
        selectedCallID = CallEvidenceIdentifier.parseCall(call.callId)
    }

    func closeDetail() {
        selectedCallID = nil
    }

    func clearSearch() {
        query = ""
    }

    private var normalizedQuery: String? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
