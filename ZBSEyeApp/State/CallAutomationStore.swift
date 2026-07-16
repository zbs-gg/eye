import AppKit
import Foundation
import Observation

enum CallAutomationPresentationPhase: Sendable, Equatable {
    case disabled
    case invalidDraft
    case ready
    case saving
    case testing
    case testSucceeded
    case testFailed
    case keychainUnavailable
    case suspended
    case blocked
    case failed
}

@MainActor
enum CallAutomationSecretPasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func copy(
        _ secret: String,
        to pasteboard: NSPasteboard = .general,
        clearAfter: Duration = .seconds(60)
    ) {
        let changeCount = write(secret, to: pasteboard)
        Task { @MainActor in
            try? await Task.sleep(for: clearAfter)
            guard !Task.isCancelled else { return }
            _ = clearIfUnchanged(pasteboard, expectedChangeCount: changeCount)
        }
    }

    @discardableResult
    static func write(_ secret: String, to pasteboard: NSPasteboard) -> Int {
        pasteboard.declareTypes([.string, concealedType, transientType], owner: nil)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
        pasteboard.setData(Data(), forType: transientType)
        return pasteboard.changeCount
    }

    @discardableResult
    static func clearIfUnchanged(
        _ pasteboard: NSPasteboard,
        expectedChangeCount: Int
    ) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        pasteboard.clearContents()
        return true
    }
}

/// Human-owned presentation state for the one local after-call receiver.
/// URL edits stay staged until an explicit save; network work remains in the dispatcher/transport.
@MainActor
@Observable
final class CallAutomationStore {
    private(set) var phase: CallAutomationPresentationPhase = .disabled
    private(set) var persistedEndpoint = ""
    var draftEndpoint = "" {
        didSet {
            guard !isBusy else { return }
            updateStablePhase()
        }
    }
    private(set) var isEnabled = false
    private(set) var pendingCount = 0
    private(set) var blockedCount = 0
    private(set) var endpointChangeConfirmationCount: Int?
    private(set) var statusCode: String?
    var isExpanded = false
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var activeOperations = 0
    @ObservationIgnored private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    @ObservationIgnored private let repository: CallAutomationRepository
    @ObservationIgnored private let transport: any CallAutomationTransport
    @ObservationIgnored private let dispatcher: CallAutomationDispatcher?
    @ObservationIgnored private let secretProvider: @MainActor () throws -> String
    @ObservationIgnored private let copyToPasteboard: @MainActor (String) -> Void

    init(
        repository: CallAutomationRepository,
        transport: any CallAutomationTransport,
        dispatcher: CallAutomationDispatcher? = nil,
        secretProvider: @escaping @MainActor () throws -> String = {
            try KeychainStore.callAutomationSigningSecret()
        },
        copyToPasteboard: @escaping @MainActor (String) -> Void = { secret in
            CallAutomationSecretPasteboard.copy(secret)
        }
    ) {
        self.repository = repository
        self.transport = transport
        self.dispatcher = dispatcher
        self.secretProvider = secretProvider
        self.copyToPasteboard = copyToPasteboard
    }

    var isBusy: Bool { phase == .saving || phase == .testing }
    var hasDraftChanges: Bool { draftEndpoint != persistedEndpoint }
    var canSave: Bool { hasDraftChanges && canonicalDraft != nil && !isBusy && !suspended }
    var canEnable: Bool { canonicalPersisted != nil && !isBusy && !suspended }

    func load() async {
        do {
            let config = try await repository.configuration()
            persistedEndpoint = config.endpointURL ?? ""
            draftEndpoint = persistedEndpoint
            isEnabled = config.enabled
            await refresh()
        } catch {
            statusCode = "configuration_unavailable"
            phase = .failed
        }
    }

    func refresh() async {
        do {
            let status = try await repository.status()
            isEnabled = status.enabled
            pendingCount = status.pendingCount
            blockedCount = status.blockedCount
            updateStablePhase()
        } catch {
            statusCode = "status_unavailable"
            phase = .failed
        }
    }

    func cancelDraft() {
        draftEndpoint = persistedEndpoint
        endpointChangeConfirmationCount = nil
        statusCode = nil
        updateStablePhase()
    }

    func saveReceiver() async {
        await saveReceiver(discardOldBacklog: false)
    }

    func confirmEndpointChange() async {
        await saveReceiver(discardOldBacklog: true)
    }

    func setEnabled(_ enabled: Bool) async {
        guard beginOperation() else { return }
        defer { finishOperation() }
        if enabled {
            guard canonicalPersisted != nil else {
                phase = .invalidDraft
                return
            }
            do {
                _ = try secretProvider()
            } catch {
                isEnabled = false
                statusCode = "signing_secret_unavailable"
                phase = .keychainUnavailable
                return
            }
        }
        do {
            try await repository.setEnabled(enabled, nowMs: Self.nowMs())
            isEnabled = enabled
            statusCode = nil
            if enabled { await dispatcher?.kick() }
            await refresh()
        } catch {
            statusCode = "configuration_unavailable"
            phase = .failed
        }
    }

    func testReceiver() async {
        guard let endpoint = canonicalPersisted else {
            phase = .invalidDraft
            return
        }
        guard beginOperation() else { return }
        defer { finishOperation() }
        phase = .testing
        statusCode = nil
        let result = await transport.test(
            endpoint: endpoint,
            eventID: UUID().uuidString.lowercased(),
            occurredAtMs: Self.nowMs()
        )
        switch result {
        case .delivered:
            phase = .testSucceeded
        case .retry(_, let errorCode):
            statusCode = errorCode
            phase = .testFailed
        case .blocked(_, let errorCode) where errorCode == "signing_secret_unavailable":
            statusCode = errorCode
            phase = .keychainUnavailable
        case .blocked(_, let errorCode):
            statusCode = errorCode
            phase = .testFailed
        }
    }

    func copySecret() {
        guard !isBusy, !suspended else { return }
        do {
            copyToPasteboard(try secretProvider())
            statusCode = "secret_copied"
            updateStablePhase()
        } catch {
            statusCode = "signing_secret_unavailable"
            phase = .keychainUnavailable
        }
    }

    func retryBlocked() async {
        guard beginOperation() else { return }
        defer { finishOperation() }
        do {
            _ = try await repository.retryAllBlocked(nowMs: Self.nowMs())
            await dispatcher?.kick()
            statusCode = nil
            await refresh()
        } catch {
            statusCode = "retry_unavailable"
            phase = .failed
        }
    }

    func suspendAndDrain() async {
        suspended = true
        phase = .suspended
        guard activeOperations > 0 else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    func resumeAfterSuspension() async {
        suspended = false
        await refresh()
    }

    private func saveReceiver(discardOldBacklog: Bool) async {
        guard !isBusy, let endpoint = canonicalDraft else {
            phase = .invalidDraft
            return
        }
        guard beginOperation() else { return }
        phase = .saving
        statusCode = nil
        if discardOldBacklog {
            await dispatcher?.suspendAndDrainForRelocation()
        }
        do {
            _ = try await repository.saveConfiguration(
                enabled: isEnabled,
                endpoint: endpoint,
                discardUndeliveredOnEndpointChange: discardOldBacklog,
                nowMs: Self.nowMs()
            )
            persistedEndpoint = endpoint.absoluteString
            draftEndpoint = persistedEndpoint
            endpointChangeConfirmationCount = nil
            await refresh()
        } catch CallAutomationRepositoryError.endpointChangeRequiresDiscard(let count) {
            endpointChangeConfirmationCount = count
            updateStablePhase()
        } catch {
            statusCode = "configuration_unavailable"
            phase = .failed
        }
        if discardOldBacklog {
            await dispatcher?.resumeAfterRelocation()
        }
        finishOperation()
    }

    private var canonicalDraft: URL? {
        try? CallAutomationEndpoint.canonicalURL(from: draftEndpoint)
    }

    private var canonicalPersisted: URL? {
        try? CallAutomationEndpoint.canonicalURL(from: persistedEndpoint)
    }

    private func updateStablePhase() {
        if suspended {
            phase = .suspended
        } else if hasDraftChanges, canonicalDraft == nil {
            phase = .invalidDraft
        } else if blockedCount > 0 {
            phase = .blocked
        } else {
            phase = isEnabled ? .ready : .disabled
        }
    }

    private func beginOperation() -> Bool {
        guard !isBusy, !suspended else { return false }
        activeOperations += 1
        return true
    }

    private func finishOperation() {
        activeOperations = max(0, activeOperations - 1)
        guard activeOperations == 0 else { return }
        if suspended { phase = .suspended }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    nonisolated private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}
