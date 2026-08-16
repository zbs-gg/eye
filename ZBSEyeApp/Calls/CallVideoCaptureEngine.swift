import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import ScreenCaptureKit
import VideoToolbox

struct CallVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let wallMs: Int64
}

struct CallVideoPendingGap: Sendable, Equatable {
    let callID: Int64
    let startMs: Int64
    let reason: String
}

struct CallVideoGapInterval: Sendable, Equatable {
    let callID: Int64
    let startMs: Int64
    let endMs: Int64
    let reason: String
}

/// Keeps one honest unavailable-video interval open across failed restarts.
/// Intentional audio-only time closes it; a later successful start closes it
/// at the physical restart boundary. Repeated failures never move the start forward.
struct CallVideoPendingGapPolicy: Sendable {
    private(set) var pending: CallVideoPendingGap?

    mutating func open(callID: Int64, startMs: Int64, reason: String) {
        if let pending, pending.callID == callID {
            guard startMs < pending.startMs else { return }
            self.pending = CallVideoPendingGap(
                callID: callID,
                startMs: startMs,
                reason: pending.reason
            )
            return
        }
        pending = CallVideoPendingGap(callID: callID, startMs: startMs, reason: reason)
    }

    mutating func close(callID: Int64? = nil, at endMs: Int64) -> CallVideoGapInterval? {
        guard let pending,
              callID == nil || pending.callID == callID else { return nil }
        self.pending = nil
        return CallVideoGapInterval(
            callID: pending.callID,
            startMs: pending.startMs,
            endMs: max(pending.startMs + 1, endMs),
            reason: pending.reason
        )
    }

    func contains(callID: Int64) -> Bool {
        pending?.callID == callID
    }
}

/// One in-flight append plus one pending latest frame. Replacing a pending
/// frame is intentional video degradation; it can never backpressure audio.
final class CallVideoLatestFrameBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let consume: @Sendable (CallVideoFrame) async -> Void
    private let recordDroppedRange: @Sendable (Int64, Int64) async -> Void
    private var accepting = true
    private var busy = false
    private var pending: CallVideoFrame?
    private var pendingDropRange: (start: Int64, end: Int64)?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        consume: @escaping @Sendable (CallVideoFrame) async -> Void,
        recordDroppedRange: @escaping @Sendable (Int64, Int64) async -> Void
    ) {
        self.consume = consume
        self.recordDroppedRange = recordDroppedRange
    }

    func submit(_ frame: CallVideoFrame) {
        lock.lock()
        guard accepting else {
            lock.unlock()
            return
        }
        if busy {
            if let replaced = pending {
                pendingDropRange = (
                    start: min(pendingDropRange?.start ?? replaced.wallMs, replaced.wallMs),
                    end: max(pendingDropRange?.end ?? frame.wallMs, frame.wallMs)
                )
            }
            pending = frame
            lock.unlock()
            return
        }
        busy = true
        lock.unlock()
        Task { await drain(startingWith: frame) }
    }

    /// Closes callback admission and waits for every frame accepted before the
    /// boundary, including the latest pending frame and its drop evidence.
    func closeAndDrain() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            accepting = false
            if busy {
                drainWaiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func drain(startingWith first: CallVideoFrame) async {
        var current: CallVideoFrame? = first
        while let frame = current {
            await consume(frame)
            let transition = lock.withLock {
                let next = pending
                pending = nil
                let dropped = pendingDropRange
                pendingDropRange = nil
                let waiters: [CheckedContinuation<Void, Never>]
                if next == nil {
                    busy = false
                    waiters = drainWaiters
                    drainWaiters.removeAll(keepingCapacity: false)
                } else {
                    waiters = []
                }
                return (next, dropped, waiters)
            }
            if let dropped = transition.1 {
                await recordDroppedRange(
                    dropped.start,
                    max(dropped.start + 1, dropped.end)
                )
            }
            transition.2.forEach { $0.resume() }
            current = transition.0
        }
    }
}

private final class CallVideoStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable {
    let bridge: CallVideoLatestFrameBridge
    private let onStopped: @Sendable (String) -> Void

    init(
        bridge: CallVideoLatestFrameBridge,
        onStopped: @escaping @Sendable (String) -> Void
    ) {
        self.bridge = bridge
        self.onStopped = onStopped
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let buffer = sampleBuffer.imageBuffer else { return }
        bridge.submit(CallVideoFrame(
            pixelBuffer: buffer,
            wallMs: Int64(Date().timeIntervalSince1970 * 1_000)
        ))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped("screen_stream_stopped")
    }
}

/// A screenshot hotkey cannot wait for CallCoordinator's command queue or for
/// segment finalization. This controller starts only the physical SCK stop on
/// a detached user-initiated task; the MainActor engine later joins that exact
/// task and remains the sole owner of files, spans, gaps, and restart policy.
private final class CallVideoImmediateStopController: @unchecked Sendable {
    private struct SendableStream: @unchecked Sendable {
        let value: SCStream
    }

    private struct InFlight {
        let streamID: ObjectIdentifier
        let task: Task<Bool, Never>
    }

    private let lock = NSLock()
    private let resourceCoordinator: SCKResourceCoordinator
    private var boundStream: SCStream?
    private var inFlight: InFlight?

    init(resourceCoordinator: SCKResourceCoordinator) {
        self.resourceCoordinator = resourceCoordinator
    }

    func bind(_ stream: SCStream) {
        lock.lock()
        boundStream = stream
        lock.unlock()
    }

    @discardableResult
    func requestStop() -> Bool {
        lock.lock()
        guard let stream = boundStream else {
            lock.unlock()
            return false
        }
        let streamID = ObjectIdentifier(stream)
        if inFlight?.streamID == streamID {
            lock.unlock()
            return false
        }
        guard inFlight == nil else {
            lock.unlock()
            return false
        }
        let sendableStream = SendableStream(value: stream)
        let coordinator = resourceCoordinator
        let task = Task.detached(priority: .userInitiated) {
            do {
                try await coordinator.withExclusiveAccess(owner: .callVideo, operation: .stop) {
                    try await sendableStream.value.stopCapture()
                }
                return true
            } catch {
                return false
            }
        }
        inFlight = InFlight(streamID: streamID, task: task)
        lock.unlock()
        return true
    }

    func task(for stream: SCStream) -> Task<Bool, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight?.streamID == ObjectIdentifier(stream) else { return nil }
        return inFlight?.task
    }

    func clear(_ stream: SCStream) {
        lock.lock()
        if boundStream.map(ObjectIdentifier.init) == ObjectIdentifier(stream) {
            boundStream = nil
        }
        if inFlight?.streamID == ObjectIdentifier(stream) {
            inFlight = nil
        }
        lock.unlock()
    }
}

private actor CallVideoSegmentWriter {
    private struct OpenSegment {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let relativePath: String
        let temporaryURL: URL
        let finalURL: URL
        let startMs: Int64
        var endMs: Int64
        var frameCount: Int
    }

    private let callID: Int64
    private let spanID: Int64
    private let mediaGeneration: Int
    private let epoch: Int
    private let width: Int
    private let height: Int
    private let fps: Int
    private let mediaRoot: URL
    private let repository: CallRepository
    private let onFailure: @Sendable (String) -> Void
    private var sequence = 0
    private var open: OpenSegment?
    private var encoderDropStartMs: Int64?
    private var encoderDropEndMs: Int64?
    private(set) var codec: CallVideoCodec?
    private(set) var failedReason: String?

    init(
        callID: Int64,
        spanID: Int64,
        mediaGeneration: Int,
        epoch: Int,
        width: Int,
        height: Int,
        fps: Int,
        mediaRoot: URL,
        repository: CallRepository,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.callID = callID
        self.spanID = spanID
        self.mediaGeneration = mediaGeneration
        self.epoch = epoch
        self.width = width
        self.height = height
        self.fps = fps
        self.mediaRoot = mediaRoot
        self.repository = repository
        self.onFailure = onFailure
    }

    func append(_ frame: CallVideoFrame) async {
        guard failedReason == nil else { return }
        do {
            if let open, frame.wallMs - open.startMs >= 30_000 {
                try await finalizeOpenSegment()
            }
            if open == nil { try beginSegment(at: frame.wallMs) }
            guard var segment = open else { return }
            guard segment.input.isReadyForMoreMediaData else {
                encoderDropStartMs = encoderDropStartMs ?? frame.wallMs
                encoderDropEndMs = frame.wallMs
                return
            }
            if let start = encoderDropStartMs, let end = encoderDropEndMs {
                try? await repository.recordVideoGap(
                    callID: callID,
                    startMs: start,
                    endMs: max(start + 1, end),
                    reason: "video_encoder_backpressure",
                    nowMs: frame.wallMs
                )
                encoderDropStartMs = nil
                encoderDropEndMs = nil
            }
            let presentation = CMTime(
                value: max(0, frame.wallMs - segment.startMs) * Int64(fps),
                timescale: Int32(1_000 * fps)
            )
            if segment.adaptor.append(frame.pixelBuffer, withPresentationTime: presentation) {
                segment.endMs = frame.wallMs
                segment.frameCount += 1
                open = segment
            } else if segment.writer.status == .failed {
                throw segment.writer.error ?? CocoaError(.fileWriteUnknown)
            } else {
                encoderDropStartMs = encoderDropStartMs ?? frame.wallMs
                encoderDropEndMs = frame.wallMs
            }
        } catch {
            fail("video_encoder_failed")
        }
    }

    private func fail(_ reason: String) {
        guard failedReason == nil else { return }
        failedReason = reason
        if let segment = open {
            segment.input.markAsFinished()
            segment.writer.cancelWriting()
            try? FileManager.default.removeItem(at: segment.temporaryURL)
        }
        open = nil
        onFailure(reason)
    }

    func finish() async -> (CallVideoCodec?, String?) {
        guard failedReason == nil else { return (codec, failedReason) }
        do {
            try await finalizeOpenSegment()
        } catch {
            fail("video_finalize_failed")
        }
        if let start = encoderDropStartMs, let end = encoderDropEndMs {
            try? await repository.recordVideoGap(
                callID: callID,
                startMs: start,
                endMs: max(start + 1, end),
                reason: "video_encoder_backpressure",
                nowMs: max(start + 1, end)
            )
        }
        return (codec, failedReason)
    }

    private func beginSegment(at startMs: Int64) throws {
        let selected = try makeWriter(startMs: startMs, codec: .hevc)
            ?? makeWriter(startMs: startMs, codec: .h264)
        guard let selected else { throw CocoaError(.featureUnsupported) }
        codec = selected.codec
        open = selected.segment
    }

    private func makeWriter(
        startMs: Int64,
        codec selectedCodec: CallVideoCodec
    ) throws -> (segment: OpenSegment, codec: CallVideoCodec)? {
        let directory = String(format: "calls/%lld/video/epoch-%04d", callID, epoch)
        let filename = String(format: "segment-%06d.mp4", sequence)
        let relativePath = "\(directory)/\(filename)"
        let finalURL = mediaRoot.appendingPathComponent(relativePath)
        let temporaryURL = finalURL.appendingPathExtension("partial")
        try FileManager.default.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: finalURL.path),
              !FileManager.default.fileExists(atPath: temporaryURL.path) else { return nil }
        var ownsOpenPartial = false
        defer {
            if !ownsOpenPartial {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)
        let codecType: AVVideoCodecType = selectedCodec == .hevc ? .hevc : .h264
        let settings: [String: Any] = [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        ownsOpenPartial = true
        return (
            OpenSegment(
                writer: writer,
                input: input,
                adaptor: adaptor,
                relativePath: relativePath,
                temporaryURL: temporaryURL,
                finalURL: finalURL,
                startMs: startMs,
                endMs: startMs,
                frameCount: 0
            ),
            selectedCodec
        )
    }

    private func finalizeOpenSegment() async throws {
        guard let segment = open else { return }
        open = nil
        segment.input.markAsFinished()
        await segment.writer.finishWriting()
        guard segment.writer.status == .completed,
              segment.frameCount > 0 else {
            try? FileManager.default.removeItem(at: segment.temporaryURL)
            throw segment.writer.error ?? CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.moveItem(at: segment.temporaryURL, to: segment.finalURL)
        do {
            let data = try Data(contentsOf: segment.finalURL, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard let codec else { throw CocoaError(.fileWriteUnknown) }
            _ = try await repository.appendVideoSegment(CallVideoSegmentDraft(
                callId: callID,
                videoSpanId: spanID,
                mediaGeneration: mediaGeneration,
                epoch: epoch,
                sequence: sequence,
                startMs: segment.startMs,
                endMs: segment.endMs,
                relativePath: segment.relativePath,
                bytes: Int64(data.count),
                sha256: digest,
                width: width,
                height: height,
                fps: fps,
                codec: codec,
                audioMuxed: false
            ))
        } catch {
            // Final bytes without a generation-bound DB row are unreachable
            // evidence and unbounded disk growth, not a recoverable segment.
            try? FileManager.default.removeItem(at: segment.finalURL)
            throw error
        }
        sequence += 1
    }
}

@MainActor
final class CallVideoCaptureEngine {
    private enum StartAdmissionError: Error {
        case nativeScreenshotSuppressed
    }

    private struct Active {
        let callID: Int64
        let spanID: Int64
        let startedAtMs: Int64
        let stream: SCStream
        let output: CallVideoStreamOutput
        let writer: CallVideoSegmentWriter
    }

    private let repository: CallRepository
    private let mediaRoot: URL
    private let resourceCoordinator: SCKResourceCoordinator
    nonisolated private let immediateStopController: CallVideoImmediateStopController
    private let excludedBundleIDs: @MainActor () -> Set<String>
    private let isNativeScreenshotSuppressed: @MainActor () -> Bool
    private let waitForNativeScreenshotRelease: @MainActor () async -> Void
    private var active: Active?
    private var epoch = 0
    private var lockedCallID: Int64?
    private var lockedDisplayID: CGDirectDisplayID?
    private var startingCallID: Int64?
    private var startingWriterFailure: String?
    private var pendingGap = CallVideoPendingGapPolicy()
    var onUnexpectedStateChanged: (@MainActor (CallVideoState) -> Void)?

    init(
        repository: CallRepository,
        mediaRoot: URL,
        resourceCoordinator: SCKResourceCoordinator,
        excludedBundleIDs: @escaping @MainActor () -> Set<String>,
        isNativeScreenshotSuppressed: @escaping @MainActor () -> Bool = { false },
        waitForNativeScreenshotRelease: @escaping @MainActor () async -> Void = {}
    ) {
        self.repository = repository
        self.mediaRoot = mediaRoot
        self.resourceCoordinator = resourceCoordinator
        immediateStopController = CallVideoImmediateStopController(
            resourceCoordinator: resourceCoordinator
        )
        self.excludedBundleIDs = excludedBundleIDs
        self.isNativeScreenshotSuppressed = isNativeScreenshotSuppressed
        self.waitForNativeScreenshotRelease = waitForNativeScreenshotRelease
    }

    /// The screen belongs to the Call start, not to the first moment when the
    /// user happens to enable video later.
    func lockDisplay(callID: Int64) {
        guard lockedCallID != callID else { return }
        lockedCallID = callID
        lockedDisplayID = Self.frontmostDisplayID()
    }

    func start(callID: Int64) async -> CallVideoState {
        if active?.callID == callID { return .recording }
        if active != nil { _ = await stop(reason: "superseded") }
        let startedAtMs = Self.nowMs()
        var startedSpanID: Int64?
        var preparedStream: SCStream?
        startingCallID = callID
        startingWriterFailure = nil
        defer {
            if startingCallID == callID {
                startingCallID = nil
                startingWriterFailure = nil
            }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let display: SCDisplay?
            if lockedCallID == callID, let lockedDisplayID {
                display = content.displays.first(where: { $0.displayID == lockedDisplayID })
            } else {
                let preferred = Self.frontmostDisplayID()
                display = content.displays.first(where: { $0.displayID == preferred })
                    ?? content.displays.first
                lockedCallID = callID
                lockedDisplayID = display?.displayID
            }
            guard let display else {
                pendingGap.open(
                    callID: callID,
                    startMs: startedAtMs,
                    reason: "selected_display_unavailable"
                )
                return .unavailable
            }
            let (width, height) = Self.cappedSize(display.width, display.height)
            epoch += 1
            let span = try await repository.beginVideoSpan(
                callID: callID,
                epoch: epoch,
                displayID: String(display.displayID),
                startedAtMs: startedAtMs,
                width: width,
                height: height,
                fps: 15
            )
            guard let spanID = span.id else { return .unavailable }
            startedSpanID = spanID
            let writer = CallVideoSegmentWriter(
                callID: callID,
                spanID: spanID,
                mediaGeneration: span.mediaGeneration,
                epoch: epoch,
                width: width,
                height: height,
                fps: 15,
                mediaRoot: mediaRoot,
                repository: repository,
                onFailure: { [weak self] reason in
                    Task { @MainActor in
                        await self?.writerFailed(callID: callID, reason: reason)
                    }
                }
            )
            let bridge = CallVideoLatestFrameBridge(
                consume: { frame in
                    await writer.append(frame)
                },
                recordDroppedRange: { [repository] start, end in
                    try? await repository.recordVideoGap(
                        callID: callID,
                        startMs: start,
                        endMs: end,
                        reason: "video_frame_drop",
                        nowMs: end
                    )
                }
            )
            let output = CallVideoStreamOutput(
                bridge: bridge,
                onStopped: { [weak self] reason in
                    Task { @MainActor in await self?.unexpectedStop(reason: reason) }
                }
            )
            var exclusions = excludedBundleIDs()
            exclusions.insert("gg.zbs.eye")
            let excludedApps = content.applications.filter {
                exclusions.contains($0.bundleIdentifier)
                    || CaptureSessionPolicy.isProtectedCaptureSurface(
                        bundleId: $0.bundleIdentifier,
                        appName: $0.applicationName
                    )
                    || ScreenshotPriorityProcessPolicy.isNativeScreenshotApplication(
                        bundleIdentifier: $0.bundleIdentifier
                    )
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            configuration.showsCursor = true
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            configuration.queueDepth = 1
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            preparedStream = stream
            try stream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "gg.zbs.eye.call-video", qos: .utility)
            )
            while true {
                if isNativeScreenshotSuppressed() {
                    pendingGap.open(
                        callID: callID,
                        startMs: Self.nowMs(),
                        reason: "native_screenshot"
                    )
                    await waitForNativeScreenshotRelease()
                }
                do {
                    try await resourceCoordinator.withExclusiveAccess(
                        owner: .callVideo,
                        operation: .start
                    ) {
                        // The resource lease may have waited behind the physical
                        // Timeline-stream teardown. Re-check after acquiring it
                        // so Call video never starts inside the screenshot gate.
                        guard !isNativeScreenshotSuppressed() else {
                            throw StartAdmissionError.nativeScreenshotSuppressed
                        }
                        try await stream.startCapture()
                    }
                } catch StartAdmissionError.nativeScreenshotSuppressed {
                    pendingGap.open(
                        callID: callID,
                        startMs: Self.nowMs(),
                        reason: "native_screenshot"
                    )
                    continue
                }
                immediateStopController.bind(stream)
                guard isNativeScreenshotSuppressed() else { break }
                // Suppression opened while ScreenCaptureKit was awaiting its
                // start callback. Close the just-started stream immediately;
                // audio remains completely outside this loop.
                pendingGap.open(
                    callID: callID,
                    startMs: Self.nowMs(),
                    reason: "native_screenshot"
                )
                _ = immediateStopController.requestStop()
                await stopPhysicalCapture(stream)
            }
            if let failure = startingWriterFailure, startingCallID == callID {
                await stopPhysicalCapture(stream)
                try? stream.removeStreamOutput(output, type: .screen)
                await output.bridge.closeAndDrain()
                let (codec, _) = await writer.finish()
                let endedAtMs = Self.nowMs()
                try? await repository.finishVideoSpan(
                    spanID: spanID,
                    endedAtMs: max(startedAtMs + 1, endedAtMs),
                    codec: codec,
                    availability: .unavailable,
                    reason: failure
                )
                await persistImmediateGapIfUncovered(
                    callID: callID,
                    startMs: startedAtMs,
                    endMs: endedAtMs,
                    reason: failure
                )
                pendingGap.open(callID: callID, startMs: endedAtMs, reason: failure)
                startingCallID = nil
                startingWriterFailure = nil
                return .unavailable
            }
            active = Active(
                callID: callID,
                spanID: spanID,
                startedAtMs: startedAtMs,
                stream: stream,
                output: output,
                writer: writer
            )
            startingCallID = nil
            startingWriterFailure = nil
            if let gap = pendingGap.close(callID: callID, at: Self.nowMs()) {
                await persist(gap)
            }
            return .recording
        } catch {
            if let preparedStream {
                immediateStopController.clear(preparedStream)
            }
            startingCallID = nil
            startingWriterFailure = nil
            if let startedSpanID {
                try? await repository.finishVideoSpan(
                    spanID: startedSpanID,
                    endedAtMs: max(startedAtMs + 1, Self.nowMs()),
                    codec: nil,
                    availability: .unavailable,
                    reason: "video_start_failed"
                )
            }
            let failedAtMs = Self.nowMs()
            await persistImmediateGapIfUncovered(
                callID: callID,
                startMs: startedAtMs,
                endMs: failedAtMs,
                reason: "video_start_failed"
            )
            pendingGap.open(
                callID: callID,
                startMs: failedAtMs,
                reason: "video_start_failed"
            )
            return .unavailable
        }
    }

    func stop(reason: String?) async -> CallVideoState {
        guard let active else {
            if reason == "call_ended" || reason == "mode_audio_only" {
                if let gap = pendingGap.close(at: Self.nowMs()) {
                    await persist(gap)
                }
            }
            if reason == "call_ended" {
                lockedCallID = nil
                lockedDisplayID = nil
            }
            return .disabled
        }
        self.active = nil
        await stopPhysicalCapture(active.stream)
        try? active.stream.removeStreamOutput(active.output, type: .screen)
        await active.output.bridge.closeAndDrain()
        let (codec, writerFailure) = await active.writer.finish()
        let endedAtMs = Self.nowMs()
        let gracefulReasons: Set<String> = ["call_ended", "mode_audio_only", "native_screenshot"]
        let failure = writerFailure ?? reason.flatMap { gracefulReasons.contains($0) ? nil : $0 }
        let availability: CallVideoAvailability = failure == nil ? .available : .gap
        try? await repository.finishVideoSpan(
            spanID: active.spanID,
            endedAtMs: endedAtMs,
            codec: codec,
            availability: availability,
            reason: failure
        )
        if reason == "native_screenshot" {
            pendingGap.open(
                callID: active.callID,
                startMs: endedAtMs,
                reason: "native_screenshot"
            )
        } else if let failure {
            pendingGap.open(callID: active.callID, startMs: endedAtMs, reason: failure)
        }
        if reason == "call_ended" || reason == "mode_audio_only",
           let gap = pendingGap.close(callID: active.callID, at: endedAtMs) {
            await persist(gap)
        }
        if reason == "call_ended" {
            lockedCallID = nil
            lockedDisplayID = nil
        }
        if failure != nil { return .gap }
        switch reason {
        case "mode_audio_only":
            return .disabled
        case "native_screenshot":
            return .gap
        default:
            return .available
        }
    }

    private func stopPhysicalCapture(_ stream: SCStream) async {
        var stopped = false
        if let immediateStop = immediateStopController.task(for: stream) {
            stopped = await immediateStop.value
        }
        if !stopped {
            _ = try? await resourceCoordinator.withExclusiveAccess(owner: .callVideo, operation: .stop) {
                try await stream.stopCapture()
            }
        }
        immediateStopController.clear(stream)
    }

    /// Called by the native screenshot observer. Audio is untouched; video
    /// becomes one explicit gap and can be restarted by the caller afterwards.
    func yieldForNativeScreenshot() async -> Int64? {
        guard let callID = active?.callID else { return nil }
        _ = await stop(reason: "native_screenshot")
        return callID
    }

    /// Safe from the listen-only event callback. It starts no file or database
    /// work and never waits; `stop(reason:)` joins the same physical teardown.
    nonisolated func requestImmediateNativeScreenshotYield() {
        _ = immediateStopController.requestStop()
    }

    private func unexpectedStop(reason: String) async {
        guard active != nil else { return }
        let state = await stop(reason: reason)
        onUnexpectedStateChanged?(state)
    }

    private func writerFailed(callID: Int64, reason: String) async {
        if startingCallID == callID, active == nil {
            startingWriterFailure = reason
            return
        }
        guard active?.callID == callID else { return }
        let state = await stop(reason: reason)
        onUnexpectedStateChanged?(state)
    }

    private func persist(_ gap: CallVideoGapInterval) async {
        try? await repository.recordVideoGap(
            callID: gap.callID,
            startMs: gap.startMs,
            endMs: gap.endMs,
            reason: gap.reason,
            nowMs: gap.endMs
        )
    }

    private func persistImmediateGapIfUncovered(
        callID: Int64,
        startMs: Int64,
        endMs: Int64,
        reason: String
    ) async {
        // A pending interval already covers every unavailable frame through
        // this failed restart. Publishing another row would make evidence
        // overlap; the active Call state still exposes the newer failure.
        guard !pendingGap.contains(callID: callID) else { return }
        let boundedEnd = max(startMs + 1, endMs)
        try? await repository.recordVideoGap(
            callID: callID,
            startMs: startMs,
            endMs: boundedEnd,
            reason: reason,
            nowMs: boundedEnd
        )
    }

    private static func cappedSize(_ sourceWidth: Int, _ sourceHeight: Int) -> (Int, Int) {
        let longEdge = Double(max(sourceWidth, sourceHeight))
        let shortEdge = Double(max(1, min(sourceWidth, sourceHeight)))
        let scale = min(1.0, 1920.0 / longEdge, 1080.0 / shortEdge)
        let width = max(2, Int(Double(sourceWidth) * scale) & ~1)
        let height = max(2, Int(Double(sourceHeight) * scale) & ~1)
        return (width, height)
    }

    private static func frontmostDisplayID() -> CGDirectDisplayID {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else { return CGMainDisplayID() }
        for item in list where item[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier {
            guard let bounds = item[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"] else { continue }
            let center = CGPoint(x: x + w / 2, y: y + h / 2)
            var displays = [CGDirectDisplayID](repeating: 0, count: 16)
            var count: UInt32 = 0
            if CGGetDisplaysWithPoint(center, UInt32(displays.count), &displays, &count) == .success,
               count > 0 { return displays[0] }
        }
        return CGMainDisplayID()
    }

    private static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}
