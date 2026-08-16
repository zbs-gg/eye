import Foundation
import CoreAudio
import AudioToolbox

struct SystemAudioCaptureStartCancelled: Error, Sendable, Equatable {
    let teardownOutcome: SystemAudioCaptureTeardownOutcome
}

/// Captures the outgoing system mix through a Core Audio process tap. Unlike
/// ScreenCaptureKit audio capture, this path owns no display or video stream,
/// so a Call cannot make native screenshots wait for Eye's hidden screen leg.
///
/// @unchecked Sendable: Core Audio invokes the IO block on `sampleQueue`.
/// Session admission and publisher state are protected by their own locks;
/// lifecycle fields remain isolated to MainActor.
final class SystemAudioCaptureEngine: @unchecked Sendable {
    private let config: AudioConfig
    private let lifecycle: SystemAudioCaptureLifecycle<SystemAudioTapSession>
    private let frameAdmission = SystemAudioFrameAdmission<
        SystemAudioTapSession,
        SystemAudioIngressSink
    >()
    private var session: SystemAudioTapSession?
    private var running = false
    private var epoch = -1
    private var nextIngressSequence: Int64 = 0
    private var lastAcceptedIngressSequence: Int64?
    private var completedGaps: [AudioIngressGap] = []
    private let sampleQueue = DispatchQueue(
        label: "com.zbseye.systemaudio.coreaudio-tap",
        qos: .userInitiated
    )

    /// The aggregate device or tap became unavailable mid-run. The feed is
    /// closed and AudioCoordinator may rebuild the complete tap session.
    var onStreamStopped: (@Sendable () -> Void)?

    @MainActor
    init(config: AudioConfig) {
        self.config = config
        self.lifecycle = SystemAudioCaptureLifecycle()
    }

    var latestAcceptedIngressSequence: Int64? {
        frameAdmission.currentSink()?.publisher.latestAcceptedIngressSequence
            ?? lastAcceptedIngressSequence
    }

    func drainIngressGaps() -> [AudioIngressGap] {
        let result = completedGaps
            + (frameAdmission.currentSink()?.publisher.drainGaps() ?? [])
        completedGaps.removeAll(keepingCapacity: true)
        return result
    }

    @MainActor
    func start() async throws -> AsyncStream<AudioFrame> {
        guard !running else {
            throw AudioEngineError.engineStartFailed("already running")
        }
        guard let startToken = await lifecycle.beginStart() else {
            throw AudioEngineError.engineStartFailed("already starting")
        }

        epoch += 1
        let sink = SystemAudioIngressSink(
            epoch: epoch,
            initialSequence: nextIngressSequence,
            capacity: config.ingressFrameCapacity
        )

        do {
            try Task.checkCancellation()
            guard lifecycle.isStartCurrent(startToken) else {
                throw SystemAudioCaptureStartInvalidated()
            }

            let session = try SystemAudioTapSession.create(
                sampleQueue: sampleQueue,
                receiveAudio: { [weak self] session, inputData, inputTime in
                    self?.receiveAudio(
                        session: session,
                        inputData: inputData,
                        inputTime: inputTime
                    )
                },
                becameUnavailable: { [weak self] session in
                    DispatchQueue.main.async {
                        self?.sessionBecameUnavailable(session)
                    }
                }
            )

            guard lifecycle.isStartCurrent(startToken), !Task.isCancelled else {
                sink.publisher.finish()
                return try await rejectCreatedSession(
                    session,
                    token: startToken
                )
            }

            do {
                try session.start()
            } catch {
                sink.publisher.finish()
                let teardown = await retainAndStopRejectedStart(
                    session,
                    token: startToken
                )
                if !teardown.isConfirmedStopped {
                    Log.audio.error("system_audio_failed_start_teardown_unconfirmed")
                }
                throw error
            }

            guard lifecycle.publishStarted(session, token: startToken) else {
                sink.publisher.finish()
                let teardown = await lifecycle.drain()
                throw SystemAudioCaptureStartCancelled(teardownOutcome: teardown)
            }

            self.session = session
            frameAdmission.open(session: session, sink: sink)
            running = true
            return sink.publisher.stream
        } catch let cancellation as SystemAudioCaptureStartCancelled {
            lifecycle.failStart(token: startToken)
            throw cancellation
        } catch is CancellationError {
            lifecycle.failStart(token: startToken)
            sink.publisher.finish()
            throw CancellationError()
        } catch {
            lifecycle.failStart(token: startToken)
            sink.publisher.finish()
            throw AudioEngineError.engineStartFailed(error.localizedDescription)
        }
    }

    /// Starts teardown synchronously and returns the task that owns the exact
    /// tap + aggregate device until Core Audio has accepted their destruction.
    @MainActor
    @discardableResult
    func stop() -> Task<SystemAudioCaptureTeardownOutcome, Never>? {
        running = false
        if let sink = frameAdmission.close() {
            archive(sink)
            sink.publisher.finish()
        }
        session = nil
        return lifecycle.beginStop { session in
            await session.stopAndDestroy()
        }
    }

    @MainActor
    func stopAndDrain(
        timeout: Duration? = nil
    ) async -> SystemAudioCaptureTeardownOutcome {
        let teardown = stop()
        if let teardown, let timeout {
            return await SystemAudioTeardownDeadline.wait(
                for: teardown,
                timeout: timeout
            )
        }
        return await lifecycle.drain()
    }

    private func receiveAudio(
        session: SystemAudioTapSession,
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard let sink = frameAdmission.sink(for: session),
              let payload = SystemAudioTapPCM.decode(
                inputData: inputData,
                format: session.format
              ) else { return }
        session.observeDecodedBuffer(peak: payload.peak, rms: payload.rms)

        let timestamp = inputTime.pointee
        let hasHostTime = timestamp.mFlags.contains(.hostTimeValid)
        let callbackHostTime = AudioGetCurrentHostTime()
        let sourceHostTime = hasHostTime ? timestamp.mHostTime : callbackHostTime
        let normalizedHostTimeNs = sink.normalizedHostTimeNs(
            Int64(AudioConvertHostTimeToNanos(sourceHostTime))
        )
        let callbackHostTimeNs = Int64(
            AudioConvertHostTimeToNanos(callbackHostTime)
        )
        let hasSampleTime = timestamp.mFlags.contains(.sampleTimeValid)

        _ = sink.publisher.yield(
            samples: payload.samples,
            rms: payload.rms,
            captureSampleRate: session.format.mSampleRate,
            sourceSampleTime: hasSampleTime ? Int64(timestamp.mSampleTime) : nil,
            normalizedHostTimeNs: normalizedHostTimeNs,
            capturedAt: AudioHostClockWallMapper.date(
                for: normalizedHostTimeNs,
                callbackHostTimeNs: callbackHostTimeNs,
                callbackWallDate: Date()
            ),
            provenance: hasHostTime ? .coreAudioTap : .callbackFallback
        )
    }

    @MainActor
    private func sessionBecameUnavailable(_ unavailable: SystemAudioTapSession) {
        guard running, session === unavailable else { return }
        let teardown = stop()
        Task { @MainActor [weak self] in
            _ = await teardown?.value
            self?.onStreamStopped?()
        }
    }

    @MainActor
    private func rejectCreatedSession(
        _ session: SystemAudioTapSession,
        token: SystemAudioCaptureLifecycle<SystemAudioTapSession>.StartToken
    ) async throws -> AsyncStream<AudioFrame> {
        let teardown = await retainAndStopRejectedStart(session, token: token)
        throw SystemAudioCaptureStartCancelled(teardownOutcome: teardown)
    }

    @MainActor
    private func retainAndStopRejectedStart(
        _ session: SystemAudioTapSession,
        token: SystemAudioCaptureLifecycle<SystemAudioTapSession>.StartToken
    ) async -> SystemAudioCaptureTeardownOutcome {
        if lifecycle.publishStarted(session, token: token) {
            _ = lifecycle.beginStop { ownedSession in
                await ownedSession.stopAndDestroy()
            }
        }
        return await lifecycle.drain()
    }

    @MainActor
    private func archive(_ sink: SystemAudioIngressSink) {
        lastAcceptedIngressSequence = sink.publisher.latestAcceptedIngressSequence
            ?? lastAcceptedIngressSequence
        nextIngressSequence = sink.publisher.nextAttemptedIngressSequence
        completedGaps.append(contentsOf: sink.publisher.drainGaps())
    }
}

private struct SystemAudioCaptureStartInvalidated: Error, Sendable {}

private enum SystemAudioTapError: LocalizedError {
    case operation(String, OSStatus)
    case unsupportedFormat(AudioStreamBasicDescription)

    var errorDescription: String? {
        switch self {
        case let .operation(name, status):
            return "\(name) failed (Core Audio \(status))"
        case let .unsupportedFormat(format):
            return "Unsupported system-audio tap format: \(format.mFormatID)/\(format.mBitsPerChannel)-bit"
        }
    }
}

/// Owns every Core Audio object created for one system-audio generation.
/// Object IDs are app-owned and never discovered or swept globally.
private final class SystemAudioTapSession: @unchecked Sendable {
    typealias ReceiveAudio = @Sendable (
        SystemAudioTapSession,
        UnsafePointer<AudioBufferList>,
        UnsafePointer<AudioTimeStamp>
    ) -> Void
    typealias BecameUnavailable = @Sendable (SystemAudioTapSession) -> Void

    let format: AudioStreamBasicDescription
    private let tapID: AudioObjectID
    private let aggregateDeviceID: AudioObjectID
    private let ioProcID: AudioDeviceIOProcID
    private let becameUnavailable: BecameUnavailable
    private let stateLock = NSLock()
    private var started = false
    private var destroyed = false
    private var observedCallbackCount: UInt64 = 0
    private var observedPeak: Float = 0
    private var observedRMS: Float = 0

    private init(
        tapID: AudioObjectID,
        aggregateDeviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID,
        format: AudioStreamBasicDescription,
        becameUnavailable: @escaping BecameUnavailable
    ) {
        self.tapID = tapID
        self.aggregateDeviceID = aggregateDeviceID
        self.ioProcID = ioProcID
        self.format = format
        self.becameUnavailable = becameUnavailable
    }

    static func create(
        sampleQueue: DispatchQueue,
        receiveAudio: @escaping ReceiveAudio,
        becameUnavailable: @escaping BecameUnavailable
    ) throws -> SystemAudioTapSession {
        // Do not exclude Eye's process here. On macOS 26.1 a global tap that
        // excludes the same process currently holding microphone input keeps
        // calling IO but replaces every other process with zeroes. Signed
        // physical probes reproduced this only while microphone input was
        // active. Eye does not play media while a Call owns audio, so an empty
        // exclusion list preserves the authoritative system track without a
        // normal Call feedback path.
        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: []
        )
        tapDescription.name = "ZBS Eye System Audio"
        tapDescription.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            "Create system-audio tap"
        )

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        do {
            let tapUID = try stringProperty(
                objectID: tapID,
                selector: kAudioTapPropertyUID
            )
            let aggregateUID = "gg.zbs.eye.system-audio.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "ZBS Eye System Audio",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &aggregateDeviceID
                ),
                "Create system-audio aggregate device"
            )
            try attachTap(uid: tapUID, to: aggregateDeviceID)

            let format = try streamFormat(for: tapID)
            guard SystemAudioTapPCM.supports(format) else {
                throw SystemAudioTapError.unsupportedFormat(format)
            }

            let sessionBox = SystemAudioTapSessionBox()
            try check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &ioProcID,
                    aggregateDeviceID,
                    sampleQueue
                ) { _, inputData, inputTime, _, _ in
                    guard let session = sessionBox.value() else { return }
                    receiveAudio(session, inputData, inputTime)
                },
                "Create system-audio IO callback"
            )
            guard let ioProcID else {
                throw SystemAudioTapError.operation(
                    "Create system-audio IO callback",
                    kAudioHardwareUnspecifiedError
                )
            }

            let session = SystemAudioTapSession(
                tapID: tapID,
                aggregateDeviceID: aggregateDeviceID,
                ioProcID: ioProcID,
                format: format,
                becameUnavailable: becameUnavailable
            )
            sessionBox.set(session)
            session.installDeviceAliveListener()
            return session
        } catch {
            if let ioProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            if aggregateDeviceID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            }
            if tapID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
            throw error
        }
    }

    func start() throws {
        try Self.check(
            AudioDeviceStart(aggregateDeviceID, ioProcID),
            "Start system-audio tap"
        )
        stateLock.withLock { started = true }
    }

    func stopAndDestroy() async -> SystemAudioCaptureTeardownOutcome {
        let shouldDestroy = stateLock.withLock { () -> Bool in
            guard !destroyed else { return false }
            destroyed = true
            return true
        }
        guard shouldDestroy else { return .notNeeded }

        removeDeviceAliveListener()
        let observation = stateLock.withLock {
            (observedCallbackCount, observedPeak, observedRMS)
        }
        Log.audio.info(
            "system_audio_tap_summary callbacks=\(observation.0, privacy: .public) decoded_peak=\(observation.1, privacy: .public) decoded_rms=\(observation.2, privacy: .public)"
        )
        var failures: [String] = []
        if stateLock.withLock({ started }) {
            let status = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if status != noErr && status != kAudioHardwareBadObjectError {
                failures.append("stop=\(status)")
            }
        }
        let destroyIO = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        if destroyIO != noErr && destroyIO != kAudioHardwareBadObjectError {
            failures.append("io=\(destroyIO)")
        }
        let destroyAggregate = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        if destroyAggregate != noErr && destroyAggregate != kAudioHardwareBadObjectError {
            failures.append("aggregate=\(destroyAggregate)")
        }
        let destroyTap = AudioHardwareDestroyProcessTap(tapID)
        if destroyTap != noErr && destroyTap != kAudioHardwareBadObjectError {
            failures.append("tap=\(destroyTap)")
        }

        guard failures.isEmpty else {
            Log.audio.error("system_audio_tap_stop_failed")
            return .failed(failures.joined(separator: ","))
        }
        return .stopped
    }

    func observeDecodedBuffer(peak: Float, rms: Float) {
        stateLock.withLock {
            observedCallbackCount &+= 1
            observedPeak = max(observedPeak, peak)
            observedRMS = max(observedRMS, rms)
        }
    }

    private func installDeviceAliveListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListener(
            aggregateDeviceID,
            &address,
            systemAudioDeviceAliveListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func removeDeviceAliveListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListener(
            aggregateDeviceID,
            &address,
            systemAudioDeviceAliveListener,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    fileprivate func deviceAlivePropertyChanged() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            aggregateDeviceID,
            &address,
            0,
            nil,
            &size,
            &alive
        )
        if status != noErr || alive == 0 {
            becameUnavailable(self)
        }
    }

    private static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(
            withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(
                    objectID,
                    &address,
                    0,
                    nil,
                    &size,
                    pointer
                )
            },
            "Read system-audio tap UID"
        )
        return value as String
    }

    private static func streamFormat(
        for tapID: AudioObjectID
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                &format
            ),
            "Read system-audio tap format"
        )
        return format
    }

    /// Reassert and confirm the tap list after aggregate creation. Physical
    /// probes on macOS 26.1 showed that the creation dictionary or this update
    /// alone can produce callbacks containing only zeroes; both are required.
    private static func attachTap(
        uid: String,
        to aggregateDeviceID: AudioObjectID
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapList: CFArray = [uid as CFString] as CFArray
        try check(
            withUnsafePointer(to: &tapList) { pointer in
                AudioObjectSetPropertyData(
                    aggregateDeviceID,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<CFArray>.size),
                    pointer
                )
            },
            "Attach system-audio tap"
        )

        var confirmedList: CFArray = [] as CFArray
        var size = UInt32(MemoryLayout<CFArray>.size)
        try check(
            withUnsafeMutablePointer(to: &confirmedList) { pointer in
                AudioObjectGetPropertyData(
                    aggregateDeviceID,
                    &address,
                    0,
                    nil,
                    &size,
                    pointer
                )
            },
            "Confirm system-audio tap"
        )
        guard (confirmedList as? [String])?.contains(uid) == true else {
            throw SystemAudioTapError.operation(
                "Confirm system-audio tap",
                kAudioHardwareUnspecifiedError
            )
        }
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw SystemAudioTapError.operation(operation, status)
        }
    }
}

private final class SystemAudioTapSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: SystemAudioTapSession?

    func set(_ session: SystemAudioTapSession) {
        lock.withLock { self.session = session }
    }

    func value() -> SystemAudioTapSession? {
        lock.withLock { session }
    }
}

private let systemAudioDeviceAliveListener: AudioObjectPropertyListenerProc = {
    _, _, _, clientData in
    guard let clientData else { return noErr }
    let session = Unmanaged<SystemAudioTapSession>
        .fromOpaque(clientData)
        .takeUnretainedValue()
    session.deviceAlivePropertyChanged()
    return noErr
}

private final class SystemAudioIngressSink: @unchecked Sendable {
    let publisher: AudioIngressPublisher
    private let lock = NSLock()
    private var lastNormalizedNanoseconds: Int64?

    init(epoch: Int, initialSequence: Int64, capacity: Int) {
        publisher = AudioIngressPublisher(
            source: .system,
            epoch: epoch,
            capacity: capacity,
            initialSequence: initialSequence
        )
    }

    func normalizedHostTimeNs(_ candidate: Int64) -> Int64 {
        lock.withLock {
            let value = max(
                candidate,
                (lastNormalizedNanoseconds ?? (candidate - 1)) + 1
            )
            lastNormalizedNanoseconds = value
            return value
        }
    }
}
