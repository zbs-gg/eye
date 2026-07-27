import Foundation
import Observation

@MainActor
@Observable
final class WhisperModelSettingsStore {
    private(set) var snapshot = WhisperModelSnapshot.absent(
        expectedBytes: WhisperModelManifest.largeV3Turbo.expectedBytes
    )
    private(set) var handySnapshot = HandySpeechModelSnapshot.checking
    private(set) var busy = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var modelStore: WhisperModelStore?
    @ObservationIgnored private var handyModelStore: HandySpeechModelStore?
    @ObservationIgnored private var suspendWorker: @Sendable () async -> Void = {}
    @ObservationIgnored private var resumeWorker: @Sendable () async -> Void = {}

    func attach(
        _ modelStore: WhisperModelStore,
        handyModelStore: HandySpeechModelStore? = nil,
        suspendWorker: @escaping @Sendable () async -> Void = {},
        resumeWorker: @escaping @Sendable () async -> Void = {}
    ) {
        self.modelStore = modelStore
        self.handyModelStore = handyModelStore
        self.suspendWorker = suspendWorker
        self.resumeWorker = resumeWorker
    }

    func refresh() async {
        guard let modelStore else { return }
        async let local = modelStore.refresh()
        if let handyModelStore {
            async let external = handyModelStore.refresh()
            snapshot = await local
            handySnapshot = await external
        } else {
            snapshot = await local
            handySnapshot = .unavailable
        }
    }

    var effectiveState: WhisperModelLifecycleState {
        if snapshot.state == .ready || handySnapshot.state == .ready { return .ready }
        if snapshot.state == .absent, handySnapshot.state == .checking { return .verifying }
        return snapshot.state
    }

    var usesHandy: Bool {
        snapshot.state != .ready && handySnapshot.state == .ready
    }

    var effectiveModelName: String? {
        usesHandy ? handySnapshot.backend?.displayName : nil
    }

    func install() {
        guard !busy, let modelStore else { return }
        busy = true
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.snapshot = await modelStore.snapshot()
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer {
                poller.cancel()
                busy = false
            }
            do {
                snapshot = try await modelStore.install()
            } catch {
                snapshot = await modelStore.snapshot()
                errorMessage = error.localizedDescription
            }
        }
    }

    func remove() {
        guard !busy, let modelStore else { return }
        busy = true
        errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { busy = false }
            await suspendWorker()
            defer { Task { await resumeWorker() } }
            do {
                snapshot = try await modelStore.remove()
            } catch {
                snapshot = await modelStore.snapshot()
                errorMessage = error.localizedDescription
            }
        }
    }
}
