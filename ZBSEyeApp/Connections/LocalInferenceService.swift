import Foundation
import MLXLMCommon

struct LocalRuntimeGenerationRequest: Sendable, Equatable {
    let systemPrompt: String
    let userPrompt: String
    let maximumOutputTokens: Int
    let temperature: Double
    let topP: Double
    let outputContract: LocalAIOutputContractRequest
}

struct LocalRuntimeGenerationOutput: Sendable {
    let textChunks: [String]
    let toolCalls: [ToolCall]
    let generatedTokenCount: Int
    let reachedTokenLimit: Bool
}

enum LocalRuntimeDrainOutcome: Sendable, Equatable {
    case stopped
    case timedOut
    case unhealthy(String)

    var isConfirmedStopped: Bool {
        if case .stopped = self { return true }
        return false
    }
}

enum LocalRuntimeTaskWaitOutcome: Sendable, Equatable {
    case completed
    case timedOut
    case cancelled
}

private actor LocalRuntimeTaskDeadlineResult {
    private var outcome: LocalRuntimeTaskWaitOutcome?
    private var waiters: [CheckedContinuation<LocalRuntimeTaskWaitOutcome, Never>] = []

    func resolve(_ outcome: LocalRuntimeTaskWaitOutcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: outcome) }
    }

    func value() async -> LocalRuntimeTaskWaitOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

enum LocalRuntimeTaskDeadline {
    nonisolated static func wait<Success, Failure>(
        for task: Task<Success, Failure>,
        timeout: Duration
    ) async -> LocalRuntimeTaskWaitOutcome where Failure: Error {
        let result = LocalRuntimeTaskDeadlineResult()
        let completion = Task {
            _ = await task.result
            await result.resolve(.completed)
        }
        let deadline = Task {
            guard timeout > .zero else {
                await result.resolve(.timedOut)
                return
            }
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await result.resolve(.timedOut)
        }
        let outcome = await withTaskCancellationHandler {
            await result.value()
        } onCancel: {
            Task { await result.resolve(.cancelled) }
        }
        deadline.cancel()
        completion.cancel()
        return outcome
    }
}

protocol LocalInferenceRuntimeDriving: Sendable {
    func load(directory: URL, manifest: BuiltInModelManifest) async throws
    func warmUp() async throws
    func preparedInputTokenCount(for request: LocalRuntimeGenerationRequest) async throws -> Int
    func generate(_ request: LocalRuntimeGenerationRequest) async throws -> LocalRuntimeGenerationOutput
    func cancelAndDrain(timeout: Duration) async -> LocalRuntimeDrainOutcome
    func unload(timeout: Duration) async -> LocalRuntimeDrainOutcome
}

enum LocalInferenceError: Error, LocalizedError, Sendable, Equatable {
    case unrecognizedManifest
    case invalidInstallationPath
    case staleSelection
    case missingOutputContract
    case contextLimitExceeded
    case generationBusy
    case runtimeUnavailable
    case invalidOutput
    case timedOut
    case runtimeDrainUnconfirmed
    case unexpectedInstallation

    var errorDescription: String? {
        switch self {
        case .unrecognizedManifest:
            "The selected built-in model is not a product manifest."
        case .invalidInstallationPath:
            "The built-in model directory is not a verified installation payload."
        case .staleSelection:
            "The selected provider/model no longer matches the loaded local runtime."
        case .missingOutputContract:
            "The local request is missing its structured-output authority."
        case .contextLimitExceeded:
            "The prompt and output budget exceed the local model context limit."
        case .generationBusy:
            "The process-wide local generation worker is already reserved."
        case .runtimeUnavailable:
            "The verified local model could not be loaded or used."
        case .invalidOutput:
            "The local model returned output outside the native tool contract."
        case .timedOut:
            "The local generation timed out and was drained."
        case .runtimeDrainUnconfirmed:
            "The local runtime did not confirm that its resources were released."
        case .unexpectedInstallation:
            "The runtime drainer was asked to unload a different installation."
        }
    }
}

struct LocalInferenceSnapshot: Sendable, Equatable {
    let state: RuntimeState
    let loadedModelID: String?
    let loadedManifestFingerprintSHA256: String?
    let loadedDirectory: URL?
    let activeRequestID: UUID?
}

/// The sole in-process adapter for `ZBS Eye Local`. It owns one retained
/// runtime driver, one generation reservation, and the truthful process-local
/// lifecycle state. The router still owns global request precedence; this
/// actor is the final fail-closed boundary around the MLX worker itself.
actor LocalInferenceService: LLMAdapter {
    typealias Now = @Sendable () -> Date

    private struct LoadedRuntime: Sendable {
        let directory: URL
        let manifest: BuiltInModelManifest
        let installation: BuiltInModelInstallation
    }

    private enum CancellationReason: Sendable {
        case caller
        case timeout
        case runtimeDrain
        case memoryPressure
    }

    private struct ActiveGeneration {
        let requestID: UUID
        let task: Task<LocalRuntimeGenerationOutput, any Error>
        let computeLease: AIComputeLease
        var cancellationReason: CancellationReason?
        var runtimeDrainTask: Task<LocalRuntimeDrainOutcome, Never>?
        var cleanupTask: Task<Void, Never>?
    }

    private struct GenerationReservation {
        let requestID: UUID
        let admissionTask: Task<AIComputeLease, any Error>
        var computeLease: AIComputeLease?
        var preparationTask: Task<Int, any Error>?
        var requiresColdLoad = false
        var cancellationReason: CancellationReason?
        var cleanupTask: Task<Void, Never>?
    }

    private static let contextSafetyTokens = 64

    private let driver: any LocalInferenceRuntimeDriving
    private let computeCoordinator: AIComputeCoordinator
    private let idleUnloadDelay: Duration
    private let drainAcknowledgementTimeout: Duration
    private let now: Now

    private var loaded: LoadedRuntime?
    private var runtimeState: RuntimeState = .unloaded
    private var driverIsLoaded = false
    private var acceptingGeneration = false
    private var lifecycleEpoch: UInt64 = 0
    private var runtimeLoadID: UUID?
    private var reservation: GenerationReservation?
    private var active: ActiveGeneration?
    private var idleUnloadTask: Task<Void, Never>?
    private var runtimeReleaseTask: Task<LocalRuntimeDrainOutcome, Never>?
    private var idleEpoch: UInt64 = 0

    init(
        driver: any LocalInferenceRuntimeDriving,
        computeCoordinator: AIComputeCoordinator,
        idleUnloadDelay: Duration = .seconds(120),
        now: @escaping Now = Date.init,
        drainAcknowledgementTimeout: Duration = .seconds(5)
    ) {
        self.driver = driver
        self.computeCoordinator = computeCoordinator
        self.idleUnloadDelay = max(.milliseconds(1), idleUnloadDelay)
        self.drainAcknowledgementTimeout = max(.milliseconds(1), drainAcknowledgementTimeout)
        self.now = now
    }

    nonisolated func candidateLoader() -> BuiltInModelManager.CandidateLoader {
        { [self] directory, manifest in
            try await loadVerified(directory: directory, manifest: manifest)
        }
    }

    nonisolated func runtimeDrainer() -> BuiltInModelManager.RuntimeDrainer {
        { [self] installation in
            try await drainAndUnload(expectedInstallation: installation)
        }
    }

    func loadVerified(
        directory: URL,
        manifest: BuiltInModelManifest
    ) async throws {
        guard BuiltInModelManifest.all.contains(manifest) else {
            throw LocalInferenceError.unrecognizedManifest
        }
        let next = try Self.loadedRuntime(directory: directory, manifest: manifest)
        guard runtimeLoadID == nil else {
            throw LocalInferenceError.runtimeUnavailable
        }
        let loadID = UUID()
        let loadEpoch = lifecycleEpoch
        runtimeLoadID = loadID
        defer {
            if runtimeLoadID == loadID { runtimeLoadID = nil }
        }
        cancelIdleUnload()
        acceptingGeneration = false
        try await drainGeneration(reason: .runtimeDrain)
        try requireLifecycleEpoch(loadEpoch)

        if loaded?.installation == next.installation,
           loaded?.manifest == next.manifest,
           driverIsLoaded,
           runtimeState == .ready(next.installation) {
            acceptingGeneration = true
            scheduleIdleUnload()
            return
        }

        let previous = loaded
        let computeLease: AIComputeLease
        do {
            let acquired = try await computeCoordinator.acquireGeneration()
            guard lifecycleEpoch == loadEpoch else {
                await acquired.release()
                throw CancellationError()
            }
            computeLease = acquired
        } catch {
            acceptingGeneration = driverIsLoaded && loaded != nil
            if lifecycleEpoch != loadEpoch || error is CancellationError {
                throw CancellationError()
            }
            throw LocalInferenceError.runtimeUnavailable
        }
        if driverIsLoaded {
            guard await unloadDriverWithDeadline().isConfirmedStopped else {
                markRuntimeUnhealthy()
                await computeLease.release()
                throw LocalInferenceError.runtimeDrainUnconfirmed
            }
            driverIsLoaded = false
            try requireLifecycleEpoch(loadEpoch)
        }
        runtimeState = .loading(next.installation)
        do {
            try await driver.load(directory: next.directory, manifest: next.manifest)
            try requireLifecycleEpoch(loadEpoch)
            driverIsLoaded = true
            try await driver.warmUp()
            try requireLifecycleEpoch(loadEpoch)
            loaded = next
            runtimeState = .ready(next.installation)
            acceptingGeneration = true
            await computeLease.release()
            scheduleIdleUnload()
        } catch {
            if lifecycleEpoch != loadEpoch || error is CancellationError {
                await discardInvalidatedRuntimeLoad()
                await computeLease.release()
                throw CancellationError()
            }
            guard await unloadDriverWithDeadline().isConfirmedStopped else {
                markRuntimeUnhealthy()
                await computeLease.release()
                throw LocalInferenceError.runtimeDrainUnconfirmed
            }
            driverIsLoaded = false
            if let previous {
                do {
                    try await driver.load(
                        directory: previous.directory,
                        manifest: previous.manifest
                    )
                    try requireLifecycleEpoch(loadEpoch)
                    driverIsLoaded = true
                    try await driver.warmUp()
                    try requireLifecycleEpoch(loadEpoch)
                    loaded = previous
                    runtimeState = .ready(previous.installation)
                    acceptingGeneration = true
                    scheduleIdleUnload()
                } catch {
                    if lifecycleEpoch != loadEpoch || error is CancellationError {
                        await discardInvalidatedRuntimeLoad()
                        await computeLease.release()
                        throw CancellationError()
                    }
                    loaded = previous
                    if await unloadDriverWithDeadline().isConfirmedStopped {
                        driverIsLoaded = false
                        runtimeState = .failed(
                            installation: previous.installation,
                            reason: "runtime restore failed"
                        )
                    } else {
                        markRuntimeUnhealthy()
                    }
                }
            } else {
                loaded = nil
                runtimeState = .failed(
                    installation: next.installation,
                    reason: "runtime load failed"
                )
            }
            await computeLease.release()
            throw LocalInferenceError.runtimeUnavailable
        }
    }

    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        guard let outputContract = request.localOutputContract,
              !outputContract.allowedSources.isEmpty else {
            throw LocalInferenceError.missingOutputContract
        }
        guard request.maximumOutputTokens > 0,
              request.timeout > .zero else {
            throw LocalInferenceError.contextLimitExceeded
        }
        guard reservation == nil, active == nil else {
            throw LocalInferenceError.generationBusy
        }
        guard acceptingGeneration, let selectedRuntime = loaded else {
            throw LocalInferenceError.runtimeUnavailable
        }
        try Self.validate(selection: selection, against: selectedRuntime)

        let rawPromptBytes = request.systemPrompt.utf8.count + request.userPrompt.utf8.count
        guard rawPromptBytes <= selectedRuntime.manifest.generation.contextTokenCeiling * 16 else {
            throw LocalInferenceError.contextLimitExceeded
        }

        let runtimeRequest = LocalRuntimeGenerationRequest(
            systemPrompt: request.systemPrompt,
            userPrompt: request.userPrompt,
            maximumOutputTokens: request.maximumOutputTokens,
            temperature: selectedRuntime.manifest.generation.temperature,
            topP: selectedRuntime.manifest.generation.topP,
            outputContract: outputContract
        )

        let requestDeadline = ContinuousClock().now.advanced(by: request.timeout)
        cancelIdleUnload()
        let admissionTask = Task {
            try await computeCoordinator.acquireGeneration()
        }
        reservation = GenerationReservation(
            requestID: request.id,
            admissionTask: admissionTask,
            computeLease: nil,
            preparationTask: nil
        )
        let computeLease: AIComputeLease
        switch await LocalRuntimeTaskDeadline.wait(
            for: admissionTask,
            timeout: Self.remaining(until: requestDeadline)
        ) {
        case .timedOut:
            beginReservationCancellation(requestID: request.id, reason: .timeout)
            throw LocalInferenceError.timedOut
        case .cancelled:
            beginReservationCancellation(requestID: request.id, reason: .caller)
            throw CancellationError()
        case .completed:
            do {
                computeLease = try await admissionTask.value
            } catch {
                if reservation?.requestID == request.id,
                   reservation?.cancellationReason != nil {
                    throw CancellationError()
                }
                await finishPreActiveRequest(
                    requestID: request.id,
                    computeLease: nil
                )
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        }

        do {
            guard reservation?.requestID == request.id,
                  reservation?.cancellationReason == nil else {
                throw CancellationError()
            }
            reservation?.computeLease = computeLease
            guard acceptingGeneration,
                  loaded?.installation == selectedRuntime.installation else {
                throw LocalInferenceError.staleSelection
            }
            try Task.checkCancellation()
            let requiresColdLoad = !driverIsLoaded
            if requiresColdLoad {
                runtimeState = .loading(selectedRuntime.installation)
            }
            reservation?.requiresColdLoad = requiresColdLoad
            let preparationTask = Task { [driver] in
                if requiresColdLoad {
                    try await driver.load(
                        directory: selectedRuntime.directory,
                        manifest: selectedRuntime.manifest
                    )
                    try await driver.warmUp()
                }
                try Task.checkCancellation()
                return try await driver.preparedInputTokenCount(for: runtimeRequest)
            }
            reservation?.preparationTask = preparationTask
            let preparedTokens: Int
            switch await LocalRuntimeTaskDeadline.wait(
                for: preparationTask,
                timeout: Self.remaining(until: requestDeadline)
            ) {
            case .timedOut:
                beginReservationCancellation(requestID: request.id, reason: .timeout)
                throw LocalInferenceError.timedOut
            case .cancelled:
                beginReservationCancellation(requestID: request.id, reason: .caller)
                throw CancellationError()
            case .completed:
                do {
                    preparedTokens = try await preparationTask.value
                } catch {
                    if reservation?.requestID == request.id,
                       reservation?.cancellationReason != nil {
                        throw error
                    }
                    if requiresColdLoad {
                        guard await unloadDriverWithDeadline().isConfirmedStopped else {
                            markRuntimeUnhealthy()
                            throw LocalInferenceError.runtimeDrainUnconfirmed
                        }
                        driverIsLoaded = false
                        runtimeState = .unloaded
                    }
                    if error is CancellationError || Task.isCancelled {
                        throw CancellationError()
                    }
                    throw LocalInferenceError.runtimeUnavailable
                }
            }
            guard reservation?.requestID == request.id,
                  reservation?.cancellationReason == nil,
                  acceptingGeneration,
                  loaded?.installation == selectedRuntime.installation else {
                if requiresColdLoad {
                    guard await unloadDriverWithDeadline().isConfirmedStopped else {
                        markRuntimeUnhealthy()
                        throw LocalInferenceError.runtimeDrainUnconfirmed
                    }
                    driverIsLoaded = false
                    runtimeState = .unloaded
                }
                throw CancellationError()
            }
            if requiresColdLoad {
                driverIsLoaded = true
                runtimeState = .ready(selectedRuntime.installation)
            }
            guard preparedTokens > 0,
                  preparedTokens
                    + request.maximumOutputTokens
                    + Self.contextSafetyTokens
                    <= selectedRuntime.manifest.generation.contextTokenCeiling else {
                throw LocalInferenceError.contextLimitExceeded
            }
            try Task.checkCancellation()

            let task = Task {
                try await driver.generate(runtimeRequest)
            }
            active = ActiveGeneration(
                requestID: request.id,
                task: task,
                computeLease: computeLease,
                cancellationReason: nil,
                runtimeDrainTask: nil,
                cleanupTask: nil
            )
            reservation = nil
            runtimeState = .generating(selectedRuntime.installation)
            let requestID = request.id

            let generated: LocalRuntimeGenerationOutput
            switch await LocalRuntimeTaskDeadline.wait(
                for: task,
                timeout: Self.remaining(until: requestDeadline)
            ) {
            case .timedOut:
                beginActiveCancellation(requestID: requestID, reason: .timeout)
                throw LocalInferenceError.timedOut
            case .cancelled:
                beginActiveCancellation(requestID: requestID, reason: .caller)
                throw CancellationError()
            case .completed:
                break
            }
            do {
                generated = try await task.value
                try Task.checkCancellation()
                if active?.requestID == requestID,
                   active?.cancellationReason != nil {
                    throw CancellationError()
                }
            } catch {
                let reason = active?.requestID == requestID
                    ? active?.cancellationReason
                    : nil
                await finishGeneration(requestID: requestID)
                switch reason {
                case .timeout:
                    throw LocalInferenceError.timedOut
                case .caller, .runtimeDrain, .memoryPressure:
                    throw CancellationError()
                case nil:
                    if Task.isCancelled { throw CancellationError() }
                    throw LocalInferenceError.runtimeUnavailable
                }
            }

            let response: LLMResponse
            do {
                response = try Self.validatedResponse(
                    generated,
                    request: request,
                    selection: selection,
                    now: now()
                )
            } catch {
                await finishGeneration(requestID: requestID)
                throw error
            }
            await finishGeneration(requestID: requestID)
            return response
        } catch {
            if active?.requestID == request.id {
                if active?.cancellationReason == nil {
                    beginActiveCancellation(requestID: request.id, reason: .caller)
                }
            } else if reservation?.requestID == request.id,
                      reservation?.cancellationReason == nil {
                await finishPreActiveRequest(
                    requestID: request.id,
                    computeLease: computeLease
                )
            }
            throw error
        }
    }

    func handleMemoryPressure() async {
        acceptingGeneration = false
        cancelIdleUnload()
        lifecycleEpoch &+= 1
        let hadRuntimeLoad = runtimeLoadID != nil
        do {
            try await drainGeneration(reason: .memoryPressure)
            guard await unloadDriverWithDeadline().isConfirmedStopped else {
                markRuntimeUnhealthy()
                return
            }
            if hadRuntimeLoad {
                guard try await waitForRuntimeLoadDrain(timeout: drainAcknowledgementTimeout),
                      await unloadDriverWithDeadline().isConfirmedStopped else {
                    markRuntimeUnhealthy()
                    return
                }
            }
        } catch {
            markRuntimeUnhealthy()
            return
        }
        driverIsLoaded = false
        runtimeState = .unloaded
        acceptingGeneration = loaded != nil
    }

    func snapshot() -> LocalInferenceSnapshot {
        LocalInferenceSnapshot(
            state: runtimeState,
            loadedModelID: loaded?.manifest.id,
            loadedManifestFingerprintSHA256:
                loaded?.manifest.aggregateFingerprintSHA256,
            loadedDirectory: loaded?.directory,
            activeRequestID: active?.requestID ?? reservation?.requestID
        )
    }

    private func drainAndUnload(
        expectedInstallation: BuiltInModelInstallation?
    ) async throws {
        acceptingGeneration = false
        cancelIdleUnload()
        if let expectedInstallation,
           let loaded,
           loaded.installation != expectedInstallation {
            throw LocalInferenceError.unexpectedInstallation
        }
        lifecycleEpoch &+= 1
        let hadRuntimeLoad = runtimeLoadID != nil
        try await drainGeneration(reason: .runtimeDrain)
        guard await unloadDriverWithDeadline().isConfirmedStopped else {
            markRuntimeUnhealthy()
            throw LocalInferenceError.runtimeDrainUnconfirmed
        }
        if hadRuntimeLoad {
            guard try await waitForRuntimeLoadDrain(timeout: drainAcknowledgementTimeout) else {
                markRuntimeUnhealthy()
                throw LocalInferenceError.runtimeDrainUnconfirmed
            }
            // A load can finish publishing its container after the first unload
            // returned. Drop that final ownership before acknowledging release.
            guard await unloadDriverWithDeadline().isConfirmedStopped else {
                markRuntimeUnhealthy()
                throw LocalInferenceError.runtimeDrainUnconfirmed
            }
        }
        driverIsLoaded = false
        loaded = nil
        runtimeState = .unloaded
    }

    private func drainGeneration(reason: CancellationReason) async throws {
        if let reservation {
            beginReservationCancellation(
                requestID: reservation.requestID,
                reason: reason
            )
        }
        if let active {
            beginActiveCancellation(requestID: active.requestID, reason: reason)
        }
        guard reservation != nil || active != nil else { return }
        guard try await waitForGenerationDrain(timeout: drainAcknowledgementTimeout) else {
            markRuntimeUnhealthy()
            throw LocalInferenceError.runtimeDrainUnconfirmed
        }
    }

    private func waitForGenerationDrain(timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while reservation != nil || active != nil {
            try Task.checkCancellation()
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func waitForRuntimeLoadDrain(timeout: Duration) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while runtimeLoadID != nil {
            try Task.checkCancellation()
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func beginActiveCancellation(
        requestID: UUID,
        reason: CancellationReason
    ) {
        guard var current = active,
              current.requestID == requestID else { return }
        if current.cancellationReason == nil {
            current.cancellationReason = reason
        }
        current.task.cancel()
        guard current.cleanupTask == nil else {
            active = current
            return
        }

        let driver = self.driver
        let timeout = drainAcknowledgementTimeout
        let generationTask = current.task
        let runtimeDrainTask = Task {
            await driver.cancelAndDrain(timeout: timeout)
        }
        current.runtimeDrainTask = runtimeDrainTask
        active = current

        let cleanupTask = Task {
            let bounded = await LocalRuntimeTaskDeadline.wait(
                for: runtimeDrainTask,
                timeout: timeout
            )
            let firstOutcome: LocalRuntimeDrainOutcome
            switch bounded {
            case .completed:
                firstOutcome = await runtimeDrainTask.value
            case .timedOut:
                self.markRuntimeUnhealthy()
                firstOutcome = await runtimeDrainTask.value
            case .cancelled:
                self.markRuntimeUnhealthy()
                firstOutcome = await runtimeDrainTask.value
            }
            if !firstOutcome.isConfirmedStopped {
                self.markRuntimeUnhealthy()
            }

            _ = await generationTask.result
            if firstOutcome.isConfirmedStopped {
                await self.finishGeneration(requestID: requestID)
                return
            }

            let retry = await driver.cancelAndDrain(timeout: timeout)
            if retry.isConfirmedStopped {
                await self.finishGeneration(requestID: requestID)
            } else {
                self.markRuntimeUnhealthy()
            }
        }
        active?.cleanupTask = cleanupTask
    }

    private func finishGeneration(requestID: UUID) async {
        guard let finished = active,
              finished.requestID == requestID else { return }
        active = nil
        // Once a drain missed its acknowledgement deadline, eventual producer
        // completion does not retroactively prove that the runtime stayed
        // healthy throughout the gap. Only an explicit unload/reload may clear
        // this failure; never turn it back into ready from cleanup.
        if case .failed = runtimeState {
            // Preserve the fail-closed state.
        } else if let loaded {
            runtimeState = driverIsLoaded ? .ready(loaded.installation) : .unloaded
        } else {
            runtimeState = .unloaded
        }
        await finished.computeLease.release()
        if driverIsLoaded, acceptingGeneration {
            scheduleIdleUnload()
        }
    }

    private func clearReservation(_ requestID: UUID) {
        guard reservation?.requestID == requestID else { return }
        reservation = nil
    }

    private func finishPreActiveRequest(
        requestID: UUID,
        computeLease: AIComputeLease?
    ) async {
        clearReservation(requestID)
        await computeLease?.release()
        rearmIdleUnloadIfReady()
    }

    private func rearmIdleUnloadIfReady() {
        guard reservation == nil,
              active == nil,
              driverIsLoaded,
              acceptingGeneration else { return }
        scheduleIdleUnload()
    }

    private func beginReservationCancellation(
        requestID: UUID,
        reason: CancellationReason
    ) {
        guard var pending = reservation,
              pending.requestID == requestID else { return }
        if pending.cancellationReason == nil {
            pending.cancellationReason = reason
        }
        pending.admissionTask.cancel()
        pending.preparationTask?.cancel()
        guard pending.cleanupTask == nil else {
            reservation = pending
            return
        }

        let admissionTask = pending.admissionTask
        let preparationTask = pending.preparationTask
        let retainedLease = pending.computeLease
        let requiresColdLoad = pending.requiresColdLoad
        let cleanupTask = Task {
            let admissionResult = await admissionTask.result
            if let preparationTask {
                _ = await preparationTask.result
            }
            let admittedLease: AIComputeLease?
            if let retainedLease {
                admittedLease = retainedLease
            } else if case .success(let lease) = admissionResult {
                admittedLease = lease
            } else {
                admittedLease = nil
            }
            await self.finishCancelledReservation(
                requestID: requestID,
                computeLease: admittedLease,
                requiresColdLoad: requiresColdLoad
            )
        }
        pending.cleanupTask = cleanupTask
        reservation = pending
    }

    private func finishCancelledReservation(
        requestID: UUID,
        computeLease: AIComputeLease?,
        requiresColdLoad: Bool
    ) async {
        guard reservation?.requestID == requestID else {
            await computeLease?.release()
            return
        }
        if requiresColdLoad {
            let outcome = await unloadDriverWithDeadline()
            if outcome.isConfirmedStopped {
                driverIsLoaded = false
                runtimeState = .unloaded
            } else {
                markRuntimeUnhealthy()
            }
        }
        reservation = nil
        await computeLease?.release()
        rearmIdleUnloadIfReady()
    }

    private func unloadDriverWithDeadline() async -> LocalRuntimeDrainOutcome {
        let operation: Task<LocalRuntimeDrainOutcome, Never>
        if let runtimeReleaseTask {
            operation = runtimeReleaseTask
        } else {
            operation = Task {
                await driver.unload(timeout: drainAcknowledgementTimeout)
            }
            runtimeReleaseTask = operation
        }

        switch await LocalRuntimeTaskDeadline.wait(
            for: operation,
            timeout: drainAcknowledgementTimeout
        ) {
        case .completed:
            let outcome = await operation.value
            runtimeReleaseTask = nil
            return outcome
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .unhealthy("runtime unload acknowledgement was cancelled")
        }
    }

    private func discardInvalidatedRuntimeLoad() async {
        var outcome = await unloadDriverWithDeadline()
        if !outcome.isConfirmedStopped {
            // The barrier may have observed the first driver's own timeout just
            // before a late warm-up released its producer. Retry once now that
            // the invalidated load has returned and no longer owns local work.
            outcome = await unloadDriverWithDeadline()
        }
        if outcome.isConfirmedStopped {
            driverIsLoaded = false
            if case .failed = runtimeState {
                // Preserve the barrier's fail-closed result for UI/recovery.
            } else {
                runtimeState = .unloaded
            }
        } else {
            markRuntimeUnhealthy()
        }
    }

    private func markRuntimeUnhealthy() {
        acceptingGeneration = false
        runtimeState = .failed(
            installation: loaded?.installation,
            reason: "runtime drain unconfirmed"
        )
    }

    private func requireLifecycleEpoch(_ expected: UInt64) throws {
        guard lifecycleEpoch == expected else { throw CancellationError() }
    }

    private func cancelIdleUnload() {
        idleEpoch &+= 1
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func scheduleIdleUnload() {
        cancelIdleUnload()
        let epoch = idleEpoch
        let delay = idleUnloadDelay
        idleUnloadTask = Task {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self.unloadIfIdle(epoch: epoch)
        }
    }

    private func unloadIfIdle(epoch: UInt64) async {
        guard epoch == idleEpoch,
              reservation == nil,
              active == nil,
              driverIsLoaded else { return }
        guard await unloadDriverWithDeadline().isConfirmedStopped else {
            markRuntimeUnhealthy()
            idleUnloadTask = nil
            return
        }
        driverIsLoaded = false
        runtimeState = .unloaded
        idleUnloadTask = nil
    }

    private nonisolated static func remaining(
        until deadline: ContinuousClock.Instant
    ) -> Duration {
        max(.zero, ContinuousClock().now.duration(to: deadline))
    }

    private nonisolated static func loadedRuntime(
        directory: URL,
        manifest: BuiltInModelManifest
    ) throws -> LoadedRuntime {
        let directory = directory.standardizedFileURL
        guard directory.isFileURL,
              directory.lastPathComponent == "payload" else {
            throw LocalInferenceError.invalidInstallationPath
        }
        let wrapper = directory.deletingLastPathComponent()
        let installedRoot = wrapper.deletingLastPathComponent()
        guard installedRoot.lastPathComponent == "installed",
              let installationID = UUID(uuidString: wrapper.lastPathComponent) else {
            throw LocalInferenceError.invalidInstallationPath
        }
        let artifact = BuiltInModelArtifact(
            modelID: manifest.id,
            artifactVersion: manifest.artifactVersion,
            manifestFingerprintSHA256: manifest.aggregateFingerprintSHA256
        )
        guard let installation = BuiltInModelInstallation(
            artifact: artifact,
            installationID: installationID,
            relativeDirectory: "installed/\(installationID.uuidString.lowercased())/payload"
        ) else {
            throw LocalInferenceError.invalidInstallationPath
        }
        return LoadedRuntime(
            directory: directory,
            manifest: manifest,
            installation: installation
        )
    }

    private nonisolated static func validate(
        selection: ProviderSelectionSnapshot,
        against runtime: LoadedRuntime
    ) throws {
        guard selection.providerID == AIProvider.zbsEyeLocal.rawValue,
              selection.modelID == runtime.manifest.id,
              runtime.installation.artifact.manifestFingerprintSHA256
                == runtime.manifest.aggregateFingerprintSHA256 else {
            throw LocalInferenceError.staleSelection
        }
    }

    private nonisolated static func validatedResponse(
        _ generated: LocalRuntimeGenerationOutput,
        request: LLMRequest,
        selection: ProviderSelectionSnapshot,
        now: Date
    ) throws -> LLMResponse {
        guard let contract = request.localOutputContract,
              generated.textChunks.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              generated.toolCalls.count == 1,
              generated.generatedTokenCount >= 0 else {
            throw LocalInferenceError.invalidOutput
        }
        let envelope: LocalAIOutputEnvelope
        do {
            envelope = try LocalAIAnswerToolContract.parse(
                generated.toolCalls[0],
                purpose: contract.purpose,
                allowedSources: contract.allowedSources
            )
        } catch {
            throw LocalInferenceError.invalidOutput
        }
        let content = LocalAIOutputRenderer.render(
            envelope,
            purpose: contract.purpose,
            language: contract.language
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw LocalInferenceError.invalidOutput }
        return LLMResponse(
            content: content,
            truncated: generated.reachedTokenLimit,
            provenance: AIExecutionProvenance(
                providerID: selection.providerID,
                modelID: selection.modelID,
                executedLocally: true,
                generatedAt: now,
                brokerUpstream: nil
            )
        )
    }
}
