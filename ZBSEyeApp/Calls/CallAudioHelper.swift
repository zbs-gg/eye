import Foundation
import ServiceManagement

@objc protocol CallAudioHelperXPCProtocol {
    func request(_ request: Data, reply: @escaping (Data) -> Void)
}

enum CallAudioHelperSecurity {
    static let machServiceName = "gg.zbs.eye.call-audio"
    static let plistName = "gg.zbs.eye.call-audio.plist"
    static let helperFlag = "--call-audio-helper"
    static let signingRequirement = "anchor apple generic and identifier \"gg.zbs.eye\" and certificate leaf[subject.OU] = \"44N4NZ86S5\""
}

private enum CallAudioHelperAction: String, Codable, Sendable {
    case status
    case start
    case freeze
    case finish
    case abort
}

private struct CallAudioHelperRequest: Codable, Sendable {
    let action: CallAudioHelperAction
    var callID: Int64?
    var requestedMe: Bool?
    var requestedSystem: Bool?
    var startedAtMs: Int64?
    var mediaGeneration: Int?
    var targetMe: Int64?
    var targetSystem: Int64?
    var barrierMilliseconds: Int?
}

struct CallAudioHelperSessionDTO: Codable, Sendable {
    let callID: Int64
    let requestedMe: Bool
    let requestedSystem: Bool
    let actualMe: Bool
    let actualSystem: Bool
    let startedAtMs: Int64
    let mediaGeneration: Int
    let baselineMe: Int64?
    let baselineSystem: Int64?
    let acceptedMe: Int64?
    let acceptedSystem: Int64?
}

fileprivate struct CallAudioHelperPersistentSession: Codable, Sendable {
    let callID: Int64
    let requestedMe: Bool
    let requestedSystem: Bool
    let startedAtMs: Int64
    let mediaGeneration: Int
}

struct CallAudioHelperStateStore: Sendable {
    let dataRoot: URL

    private var url: URL {
        StorageLocation.callHelperRoot(under: dataRoot)
            .appendingPathComponent("active-audio-session.json")
    }

    var hasActiveDescriptor: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    var activeCallID: Int64? {
        try? load()?.callID
    }

    fileprivate func load() throws -> CallAudioHelperPersistentSession? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(
            CallAudioHelperPersistentSession.self,
            from: Data(contentsOf: url)
        )
    }

    fileprivate func save(_ state: CallAudioHelperPersistentSession) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(state)
        // This descriptor contains only opaque IDs and booleans. It must stay
        // readable if launchd revives the audio owner while the Mac is locked.
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    fileprivate func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct CallAudioHelperCoverageDTO: Codable, Sendable {
    let meEndSample: Int64?
    let systemEndSample: Int64?
    let meGap: Bool
    let systemGap: Bool
}

private struct CallAudioHelperResponse: Codable, Sendable {
    let ok: Bool
    let errorCode: String?
    let session: CallAudioHelperSessionDTO?
    let coverage: CallAudioHelperCoverageDTO?

    static func failure(_ code: String) -> Self {
        Self(ok: false, errorCode: code, session: nil, coverage: nil)
    }
}

enum CallAudioHelperInstaller {
    static func ensureRegistered(activeSession: Bool) throws -> Bool {
        let service = SMAppService.agent(plistName: CallAudioHelperSecurity.plistName)
        let currentBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        let registeredBuildKey = "zbseye.calls.audioHelperRegisteredBuild"
        let registeredBuild = UserDefaults.standard.string(forKey: registeredBuildKey)

        if service.status == .enabled, registeredBuild == currentBuild { return true }
        if service.status == .requiresApproval { return false }

        // Never unregister the exact process protecting a live Call. The next
        // idle launch updates the launchd registration to the new app build.
        if service.status == .enabled, activeSession { return true }
        if service.status == .enabled {
            try service.unregister()
        }
        do {
            try service.register()
        } catch {
            if service.status != .enabled { throw error }
        }
        guard service.status == .enabled else { return false }
        UserDefaults.standard.set(currentBuild, forKey: registeredBuildKey)
        return true
    }
}

final class CallAudioHelperClient: @unchecked Sendable {
    private final class PendingResponse: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CallAudioHelperResponse, Error>?

        init(_ continuation: CheckedContinuation<CallAudioHelperResponse, Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<CallAudioHelperResponse, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return }
            pending.resume(with: result)
        }
    }

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    deinit { invalidate() }

    func status() async -> CallAudioHelperSessionDTO? {
        let response = try? await send(
            CallAudioHelperRequest(action: .status)
        )
        return response?.ok == true ? response?.session : nil
    }

    func startSession(
        _ request: CallAudioSessionStartRequest
    ) async throws -> CallAudioSessionControl? {
        let response: CallAudioHelperResponse
        do {
            response = try await send(
                CallAudioHelperRequest(
                    action: .start,
                    callID: request.callID,
                    requestedMe: request.requested.me,
                    requestedSystem: request.requested.system,
                    startedAtMs: request.startedAtMs,
                    mediaGeneration: request.mediaGeneration,
                    barrierMilliseconds: Self.milliseconds(request.barrierTimeout)
                )
            )
        } catch {
            // A helper may have made audio physical just before its XPC reply
            // was interrupted. Reattach instead of starting a second owner or
            // deleting the Call that now contains authoritative PCM.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(200))
                if let recovered = await status(), recovered.callID == request.callID {
                    return attachToActiveSession(
                        recovered,
                        barrierTimeout: request.barrierTimeout
                    )
                }
            }
            throw error
        }
        guard response.ok, let session = response.session else { return nil }
        let baselines = AudioIngressTargets(
            me: session.baselineMe,
            system: session.baselineSystem
        )
        let actual = CallSourceSelection(
            me: session.actualMe,
            system: session.actualSystem
        )
        guard !actual.isEmpty else { return nil }
        return CallAudioSessionControl(
            baselines: baselines,
            actual: actual,
            acceptedTargets: { [weak self] in
                guard let state = await self?.status(), state.callID == session.callID else {
                    return AudioIngressTargets(me: nil, system: nil)
                }
                return AudioIngressTargets(me: state.acceptedMe, system: state.acceptedSystem)
            },
            freezeCoverage: { [weak self] targets in
                guard let self else { throw CallAudioHelperClientError.unavailable }
                return try await self.coverage(
                    action: .freeze,
                    callID: session.callID,
                    targets: targets,
                    barrierMilliseconds: Self.milliseconds(request.barrierTimeout)
                )
            },
            finishAndStop: { [weak self] in
                guard let self else { throw CallAudioHelperClientError.unavailable }
                return try await self.coverage(
                    action: .finish,
                    callID: session.callID,
                    targets: nil,
                    barrierMilliseconds: Self.milliseconds(request.barrierTimeout)
                )
            },
            abort: { [weak self] in
                _ = try? await self?.send(
                    CallAudioHelperRequest(action: .abort, callID: session.callID)
                )
            }
        )
    }

    func attachToActiveSession(
        _ state: CallAudioHelperSessionDTO,
        barrierTimeout: Duration = .seconds(2)
    ) -> CallAudioSessionControl {
        let request = CallAudioSessionStartRequest(
            callID: state.callID,
            requested: CallSourceSelection(
                me: state.requestedMe,
                system: state.requestedSystem
            ),
            startedAtMs: state.startedAtMs,
            mediaGeneration: state.mediaGeneration,
            startAdmissionLease: .unscoped,
            barrierTimeout: barrierTimeout
        )
        let baselines = AudioIngressTargets(me: state.baselineMe, system: state.baselineSystem)
        return CallAudioSessionControl(
            baselines: baselines,
            actual: CallSourceSelection(me: state.actualMe, system: state.actualSystem),
            acceptedTargets: { [weak self] in
                guard let fresh = await self?.status(), fresh.callID == state.callID else {
                    return AudioIngressTargets(me: nil, system: nil)
                }
                return AudioIngressTargets(me: fresh.acceptedMe, system: fresh.acceptedSystem)
            },
            freezeCoverage: { [weak self] targets in
                guard let self else { throw CallAudioHelperClientError.unavailable }
                return try await self.coverage(
                    action: .freeze,
                    callID: state.callID,
                    targets: targets,
                    barrierMilliseconds: Self.milliseconds(barrierTimeout)
                )
            },
            finishAndStop: { [weak self] in
                guard let self else { throw CallAudioHelperClientError.unavailable }
                return try await self.coverage(
                    action: .finish,
                    callID: state.callID,
                    targets: nil,
                    barrierMilliseconds: Self.milliseconds(barrierTimeout)
                )
            },
            abort: { [weak self] in
                _ = try? await self?.send(
                    CallAudioHelperRequest(action: .abort, callID: request.callID)
                )
            }
        )
    }

    func invalidate() {
        lock.lock()
        let old = connection
        connection = nil
        lock.unlock()
        old?.invalidate()
    }

    private func coverage(
        action: CallAudioHelperAction,
        callID: Int64,
        targets: AudioIngressTargets?,
        barrierMilliseconds: Int
    ) async throws -> CallSpoolCoverage {
        let response = try await send(
            CallAudioHelperRequest(
                action: action,
                callID: callID,
                targetMe: targets?.me,
                targetSystem: targets?.system,
                barrierMilliseconds: barrierMilliseconds
            )
        )
        guard response.ok, let value = response.coverage else {
            throw CallAudioHelperClientError.remote(response.errorCode ?? "helper_failed")
        }
        return CallSpoolCoverage(
            meEndSample: value.meEndSample,
            systemEndSample: value.systemEndSample,
            meGap: value.meGap,
            systemGap: value.systemGap
        )
    }

    private func send(_ request: CallAudioHelperRequest) async throws -> CallAudioHelperResponse {
        let payload = try JSONEncoder().encode(request)
        let connection = currentConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let pending = PendingResponse(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                pending.resume(.failure(error))
            }
            guard let remote = proxy as? CallAudioHelperXPCProtocol else {
                pending.resume(.failure(CallAudioHelperClientError.unavailable))
                return
            }
            remote.request(payload) { data in
                do {
                    pending.resume(.success(try JSONDecoder().decode(
                            CallAudioHelperResponse.self,
                            from: data
                        )))
                } catch {
                    pending.resume(.failure(error))
                }
            }
        }
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        if let connection {
            lock.unlock()
            return connection
        }
        let next = NSXPCConnection(
            machServiceName: CallAudioHelperSecurity.machServiceName,
            options: []
        )
        next.remoteObjectInterface = NSXPCInterface(
            with: CallAudioHelperXPCProtocol.self
        )
        next.setCodeSigningRequirement(CallAudioHelperSecurity.signingRequirement)
        next.invalidationHandler = { [weak self, weak next] in
            guard let self, let next else { return }
            self.lock.lock()
            if self.connection === next { self.connection = nil }
            self.lock.unlock()
        }
        connection = next
        lock.unlock()
        next.activate()
        return next
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return max(1, Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000))
    }
}

enum CallAudioHelperClientError: Error {
    case unavailable
    case remote(String)
}

final class CallAudioHelperCommand: NSObject, NSXPCListenerDelegate, CallAudioHelperXPCProtocol {
    private final class Reply: @unchecked Sendable {
        let body: (Data) -> Void
        init(_ body: @escaping (Data) -> Void) { self.body = body }
        func send(_ data: Data) { body(data) }
    }

    private let runtime: CallAudioHelperRuntime
    private let listener: NSXPCListener

    @MainActor
    override init() {
        runtime = CallAudioHelperRuntime()
        listener = NSXPCListener(
            machServiceName: CallAudioHelperSecurity.machServiceName
        )
        super.init()
        listener.delegate = self
        listener.setConnectionCodeSigningRequirement(
            CallAudioHelperSecurity.signingRequirement
        )
    }

    @MainActor
    func run() async {
        guard await runtime.restoreIfNeeded() else {
            // KeepAlive/SuccessfulExit=false asks launchd to retry after a
            // transient unavailable disk, database lock, or audio device.
            exit(1)
        }
        listener.activate()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(
            with: CallAudioHelperXPCProtocol.self
        )
        newConnection.exportedObject = self
        newConnection.activate()
        return true
    }

    func request(_ request: Data, reply: @escaping (Data) -> Void) {
        let reply = Reply(reply)
        Task { @MainActor [runtime] in
            let response: CallAudioHelperResponse
            do {
                let decoded = try JSONDecoder().decode(
                    CallAudioHelperRequest.self,
                    from: request
                )
                response = try await runtime.handle(decoded)
            } catch {
                response = .failure("invalid_request")
            }
            let payload = (try? JSONEncoder().encode(response))
                ?? Data("{\"ok\":false,\"errorCode\":\"encode_failed\"}".utf8)
            reply.send(payload)
            if let idleToken = runtime.idleExitToken() {
                Task { @MainActor [runtime] in
                    try? await Task.sleep(for: .seconds(5))
                    if runtime.shouldExitIdle(token: idleToken) { exit(0) }
                }
            }
        }
    }
}

@MainActor
private final class CallAudioHelperRuntime {
    private struct ActiveSession {
        let callID: Int64
        let requested: CallSourceSelection
        var actual: CallSourceSelection
        let startedAtMs: Int64
        let mediaGeneration: Int
        let baselines: AudioIngressTargets
        let spool: CallAudioSpoolSession
        var microphone: AudioCaptureEngine?
        var system: SystemAudioCaptureEngine?
        var microphoneTask: Task<Void, Never>?
        var systemTask: Task<Void, Never>?
    }

    private var active: ActiveSession?
    private var restartingMicrophone = false
    private var restartingSystem = false
    private var lifecycleGeneration: UInt64 = 0

    func idleExitToken() -> UInt64? {
        active == nil ? lifecycleGeneration : nil
    }

    func shouldExitIdle(token: UInt64) -> Bool {
        active == nil && lifecycleGeneration == token
    }

    func restoreIfNeeded() async -> Bool {
        do {
            let dataRoot = try StorageLocation.requireAvailableDataRoot()
            let store = CallAudioHelperStateStore(dataRoot: dataRoot)
            let saved: CallAudioHelperPersistentSession?
            do {
                saved = try store.load()
            } catch is DecodingError {
                store.remove()
                return true
            }
            guard let saved else { return true }
            let database = try ZBSEyeDatabase(
                path: ZBSEyeDatabase.defaultURL().path,
                runMigrations: false
            )
            let repository = CallRepository(database: database)
            guard try await repository.activeCallResumeState(id: saved.callID) != nil else {
                store.remove()
                return true
            }
            let mediaRoot = dataRoot.appendingPathComponent("media", isDirectory: true)
            try await CallRecoveryService(
                repository: repository,
                mediaRoot: mediaRoot
            ).recoverAudioChunks(callID: saved.callID)
            let resumePoint = try await repository.audioResumePoint(callID: saved.callID)
            let response = try await start(
                CallAudioHelperRequest(
                    action: .start,
                    callID: saved.callID,
                    requestedMe: saved.requestedMe,
                    requestedSystem: saved.requestedSystem,
                    startedAtMs: saved.startedAtMs,
                    mediaGeneration: saved.mediaGeneration
                ),
                resumePoint: resumePoint,
                persistState: false
            )
            guard response.ok else { return false }
            let resumedAtMs = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            for (source, enabled, endMs) in [
                (CallAudioSource.me, saved.requestedMe, resumePoint.meEndMs),
                (.system, saved.requestedSystem, resumePoint.systemEndMs),
            ] where enabled {
                let startMs = min(endMs ?? resumedAtMs - 1, resumedAtMs - 1)
                try await repository.recordSourceGap(
                    callID: saved.callID,
                    mediaGeneration: saved.mediaGeneration,
                    source: source,
                    startMs: startMs,
                    endMs: resumedAtMs,
                    reason: "audio_helper_restart",
                    nowMs: resumedAtMs
                )
            }
            return true
        } catch {
            // Preserve the descriptor. launchd may retry after a transient
            // device or external-volume failure; the GUI still reports a gap.
            return false
        }
    }

    func handle(_ request: CallAudioHelperRequest) async throws -> CallAudioHelperResponse {
        switch request.action {
        case .status:
            return CallAudioHelperResponse(
                ok: true,
                errorCode: nil,
                session: active.map(sessionDTO),
                coverage: nil
            )
        case .start:
            return try await start(request)
        case .freeze:
            return try await freeze(request)
        case .finish:
            return try await finish(request, abort: false)
        case .abort:
            return try await finish(request, abort: true)
        }
    }

    private func start(
        _ request: CallAudioHelperRequest,
        resumePoint: CallRepository.AudioResumePoint? = nil,
        persistState: Bool = true
    ) async throws -> CallAudioHelperResponse {
        guard active == nil,
              let callID = request.callID,
              let startedAtMs = request.startedAtMs,
              let mediaGeneration = request.mediaGeneration else {
            return .failure("session_busy_or_invalid")
        }
        let requested = CallSourceSelection(
            me: request.requestedMe == true,
            system: request.requestedSystem == true
        )
        guard !requested.isEmpty else { return .failure("no_requested_source") }
        let dataRoot = try StorageLocation.requireAvailableDataRoot()
        let database = try ZBSEyeDatabase(
            path: ZBSEyeDatabase.defaultURL().path,
            runMigrations: false
        )
        let repository = CallRepository(database: database)
        let stateStore = CallAudioHelperStateStore(dataRoot: dataRoot)
        if persistState {
            try stateStore.save(
                CallAudioHelperPersistentSession(
                    callID: callID,
                    requestedMe: requested.me,
                    requestedSystem: requested.system,
                    startedAtMs: startedAtMs,
                    mediaGeneration: mediaGeneration
                )
            )
        }
        let baselines = AudioIngressTargets(me: nil, system: nil)
        let spool = try CallAudioSpoolSession(
            root: dataRoot.appendingPathComponent("media", isDirectory: true),
            callID: callID,
            requested: requested,
            baselines: baselines,
            startedAtMs: startedAtMs,
            repository: repository,
            mediaGeneration: mediaGeneration,
            resumePoint: resumePoint
        )
        let config = AudioConfig()
        var microphone: AudioCaptureEngine?
        var microphoneTask: Task<Void, Never>?
        var system: SystemAudioCaptureEngine?
        var systemTask: Task<Void, Never>?
        var actual = CallSourceSelection.none

        if requested.me {
            let engine = AudioCaptureEngine(config: config)
            microphone = engine
            engine.onConfigurationChange = { [weak self] in
                Task { @MainActor in
                    await self?.restartSource(.me, callID: callID)
                }
            }
            if let stream = try? engine.start() {
                actual = CallSourceSelection(me: true, system: actual.system)
                microphoneTask = Task {
                    for await frame in stream { _ = await spool.consume(frame) }
                }
            }
        }
        if requested.system {
            let engine = SystemAudioCaptureEngine(config: config)
            system = engine
            engine.onStreamStopped = { [weak self] in
                Task { @MainActor in
                    await self?.restartSource(.system, callID: callID)
                }
            }
            if let stream = try? await engine.start() {
                actual = CallSourceSelection(me: actual.me, system: true)
                systemTask = Task {
                    for await frame in stream { _ = await spool.consume(frame) }
                }
            }
        }
        guard !actual.isEmpty else {
            microphone?.stop()
            _ = await system?.stopAndDrain(timeout: .seconds(5))
            await spool.closeAdmission()
            if persistState { stateStore.remove() }
            return .failure("no_available_source")
        }
        await spool.setOwnedSources(requested)
        let session = ActiveSession(
            callID: callID,
            requested: requested,
            actual: actual,
            startedAtMs: startedAtMs,
            mediaGeneration: mediaGeneration,
            baselines: baselines,
            spool: spool,
            microphone: microphone,
            system: system,
            microphoneTask: microphoneTask,
            systemTask: systemTask
        )
        active = session
        lifecycleGeneration &+= 1
        if requested.me, !actual.me {
            Task { @MainActor [weak self] in
                await self?.restartSource(.me, callID: callID)
            }
        }
        if requested.system, !actual.system {
            Task { @MainActor [weak self] in
                await self?.restartSource(.system, callID: callID)
            }
        }
        return CallAudioHelperResponse(
            ok: true,
            errorCode: nil,
            session: sessionDTO(session),
            coverage: nil
        )
    }

    private func freeze(
        _ request: CallAudioHelperRequest
    ) async throws -> CallAudioHelperResponse {
        guard let active, request.callID == active.callID else {
            return .failure("session_not_found")
        }
        let targets = AudioIngressTargets(
            me: request.targetMe,
            system: request.targetSystem
        )
        try await recordEngineGaps(active)
        let timeout = Duration.milliseconds(request.barrierMilliseconds ?? 2_000)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline,
              !(await active.spool.hasCoverage(
                targets: targets,
                baselines: active.baselines
              )) {
            try? await Task.sleep(for: .milliseconds(10))
            try await recordEngineGaps(active)
        }
        let coverage = try await active.spool.flush(
            targets: targets,
            baselines: active.baselines
        )
        return response(coverage)
    }

    private func finish(
        _ request: CallAudioHelperRequest,
        abort: Bool
    ) async throws -> CallAudioHelperResponse {
        guard let active, request.callID == active.callID else {
            return .failure("session_not_found")
        }
        if let dataRoot = try? StorageLocation.requireAvailableDataRoot() {
            CallAudioHelperStateStore(dataRoot: dataRoot).remove()
        }
        self.active = nil
        lifecycleGeneration &+= 1
        restartingMicrophone = false
        restartingSystem = false
        await active.spool.closeAdmission()
        active.microphone?.stop()
        _ = await active.system?.stopAndDrain(timeout: .seconds(5))
        await active.microphoneTask?.value
        await active.systemTask?.value
        try await recordEngineGaps(active)
        if abort {
            return CallAudioHelperResponse(ok: true, errorCode: nil, session: nil, coverage: nil)
        }
        return response(try await active.spool.finish())
    }

    private func recordEngineGaps(_ session: ActiveSession) async throws {
        var gaps: [AudioIngressGap] = []
        gaps.append(contentsOf: session.microphone?.drainIngressGaps() ?? [])
        gaps.append(contentsOf: session.system?.drainIngressGaps() ?? [])
        try await session.spool.record(gaps: gaps)
    }

    private func restartSource(_ source: CallAudioSource, callID: Int64) async {
        guard let current = active, current.callID == callID else { return }
        switch source {
        case .me:
            guard !restartingMicrophone else { return }
            restartingMicrophone = true
        case .system:
            guard !restartingSystem else { return }
            restartingSystem = true
        }
        defer {
            switch source {
            case .me: restartingMicrophone = false
            case .system: restartingSystem = false
            }
        }

        let failedAtMs = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        try? await current.spool.record(gaps: [
            AudioIngressGap(
                source: source,
                epoch: -1,
                firstIngressSequence: 0,
                lastIngressSequence: 0,
                reason: .sourceUnavailable,
                startMs: failedAtMs,
                endMs: failedAtMs + 1
            ),
        ])

        var delay: Duration = .seconds(1)
        while let live = active, live.callID == callID, !Task.isCancelled {
            try? await Task.sleep(for: delay)
            guard var session = active, session.callID == callID else { return }
            switch source {
            case .me:
                let engine = session.microphone ?? AudioCaptureEngine(config: AudioConfig())
                engine.onConfigurationChange = { [weak self] in
                    Task { @MainActor in
                        await self?.restartSource(.me, callID: callID)
                    }
                }
                if let stream = try? engine.start() {
                    let spool = session.spool
                    session.microphone = engine
                    session.microphoneTask = Task {
                        for await frame in stream {
                            _ = await spool.consume(frame)
                        }
                    }
                    session.actual = CallSourceSelection(
                        me: true,
                        system: session.actual.system
                    )
                    active = session
                    return
                }
            case .system:
                let engine = session.system ?? SystemAudioCaptureEngine(config: AudioConfig())
                engine.onStreamStopped = { [weak self] in
                    Task { @MainActor in
                        await self?.restartSource(.system, callID: callID)
                    }
                }
                if let stream = try? await engine.start() {
                    let spool = session.spool
                    session.system = engine
                    session.systemTask = Task {
                        for await frame in stream {
                            _ = await spool.consume(frame)
                        }
                    }
                    session.actual = CallSourceSelection(
                        me: session.actual.me,
                        system: true
                    )
                    active = session
                    return
                }
            }
            delay = min(delay * 2, .seconds(10))
        }
    }

    private func sessionDTO(_ session: ActiveSession) -> CallAudioHelperSessionDTO {
        CallAudioHelperSessionDTO(
            callID: session.callID,
            requestedMe: session.requested.me,
            requestedSystem: session.requested.system,
            actualMe: session.actual.me,
            actualSystem: session.actual.system,
            startedAtMs: session.startedAtMs,
            mediaGeneration: session.mediaGeneration,
            baselineMe: session.baselines.me,
            baselineSystem: session.baselines.system,
            acceptedMe: session.microphone?.latestAcceptedIngressSequence,
            acceptedSystem: session.system?.latestAcceptedIngressSequence
        )
    }

    private func response(_ coverage: CallSpoolCoverage) -> CallAudioHelperResponse {
        CallAudioHelperResponse(
            ok: true,
            errorCode: nil,
            session: nil,
            coverage: CallAudioHelperCoverageDTO(
                meEndSample: coverage.meEndSample,
                systemEndSample: coverage.systemEndSample,
                meGap: coverage.meGap,
                systemGap: coverage.systemGap
            )
        )
    }
}
