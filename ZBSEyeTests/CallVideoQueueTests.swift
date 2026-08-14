import CoreVideo
import XCTest

final class CallVideoQueueTests: XCTestCase {
    func testPostprocessAdmissionLeaseIsInvalidatedByCallAudioPriority() {
        let gate = CallVideoPostprocessAdmissionGate()
        let first = gate.acquire()
        XCTAssertNotNil(first)
        XCTAssertTrue(first.map(gate.permits) ?? false)

        gate.suspend()
        XCTAssertNil(gate.acquire())
        XCTAssertFalse(first.map(gate.permits) ?? true)

        gate.resume()
        let second = gate.acquire()
        XCTAssertNotNil(second)
        XCTAssertTrue(second.map(gate.permits) ?? false)
        XCTAssertNotEqual(first, second)
    }

    func testPendingGapPreservesEarliestFailureAndClosesAtRealBoundary() {
        var policy = CallVideoPendingGapPolicy()

        policy.open(callID: 7, startMs: 100, reason: "selected_display_unavailable")
        policy.open(callID: 7, startMs: 180, reason: "video_start_failed")
        XCTAssertEqual(
            policy.pending,
            CallVideoPendingGap(
                callID: 7,
                startMs: 100,
                reason: "selected_display_unavailable"
            )
        )

        XCTAssertEqual(
            policy.close(callID: 7, at: 900),
            CallVideoGapInterval(
                callID: 7,
                startMs: 100,
                endMs: 900,
                reason: "selected_display_unavailable"
            )
        )
        XCTAssertNil(policy.pending)

        policy.open(callID: 7, startMs: 1_000, reason: "screen_stream_stopped")
        XCTAssertNil(policy.close(callID: 8, at: 1_500))
        XCTAssertEqual(
            policy.close(at: 1_500),
            CallVideoGapInterval(
                callID: 7,
                startMs: 1_000,
                endMs: 1_500,
                reason: "screen_stream_stopped"
            )
        )
    }

    func testScreenshotSuppressionReusesOnePendingGapAcrossResumeEdges() {
        var policy = CallVideoPendingGapPolicy()

        // The first interval represents video already stopped for a screenshot.
        policy.open(callID: 9, startMs: 100, reason: "native_screenshot")
        // A second edge lands while the same video leg is trying to resume.
        policy.open(callID: 9, startMs: 180, reason: "native_screenshot")
        policy.open(callID: 9, startMs: 220, reason: "native_screenshot")
        XCTAssertTrue(policy.contains(callID: 9))
        XCTAssertFalse(policy.contains(callID: 10))

        XCTAssertEqual(
            policy.close(callID: 9, at: 400),
            CallVideoGapInterval(
                callID: 9,
                startMs: 100,
                endMs: 400,
                reason: "native_screenshot"
            )
        )
        // There is no nested/local interval left to publish over the first one.
        XCTAssertNil(policy.close(callID: 9, at: 400))

        // First-time video enable inside a screenshot window uses the same policy.
        policy.open(callID: 10, startMs: 500, reason: "native_screenshot")
        XCTAssertEqual(
            policy.close(callID: 10, at: 650),
            CallVideoGapInterval(
                callID: 10,
                startMs: 500,
                endMs: 650,
                reason: "native_screenshot"
            )
        )
    }

    func testCloseDrainsAcceptedLatestFrameAndKeepsDropBurstsSeparate() async throws {
        let probe = CallVideoBridgeProbe(blockedFrames: [1, 5])
        let bridge = CallVideoLatestFrameBridge(
            consume: { frame in await probe.consume(frame) },
            recordDroppedRange: { start, end in
                await probe.recordGap(start: start, end: end)
            }
        )

        bridge.submit(try frame(at: 1))
        await probe.waitUntilStarted(1)
        bridge.submit(try frame(at: 2))
        bridge.submit(try frame(at: 3))
        bridge.submit(try frame(at: 4))
        await probe.release(1)
        await probe.waitUntilStarted(4)

        bridge.submit(try frame(at: 5))
        await probe.waitUntilStarted(5)
        bridge.submit(try frame(at: 6))
        bridge.submit(try frame(at: 7))
        let close = Task { await bridge.closeAndDrain() }
        await probe.release(5)
        await close.value

        let consumed = await probe.consumedFrames()
        let gaps = await probe.gaps()
        XCTAssertEqual(consumed, [1, 4, 5, 7])
        XCTAssertEqual(
            gaps,
            [CallVideoBridgeProbe.Gap(start: 2, end: 4), .init(start: 6, end: 7)]
        )

        // Admission is closed: a late SCK callback is not accepted after the
        // writer-finalization boundary.
        bridge.submit(try frame(at: 8))
        await Task.yield()
        let afterClose = await probe.consumedFrames()
        XCTAssertEqual(afterClose, [1, 4, 5, 7])
    }

    private func frame(at wallMs: Int64) throws -> CallVideoFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return CallVideoFrame(pixelBuffer: try XCTUnwrap(buffer), wallMs: wallMs)
    }
}

private actor CallVideoBridgeProbe {
    struct Gap: Equatable {
        let start: Int64
        let end: Int64
    }

    private let blockedFrames: Set<Int64>
    private var consumed: [Int64] = []
    private var recordedGaps: [Gap] = []
    private var started: Set<Int64> = []
    private var startedWaiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [Int64: CheckedContinuation<Void, Never>] = [:]

    init(blockedFrames: Set<Int64>) {
        self.blockedFrames = blockedFrames
    }

    func consume(_ frame: CallVideoFrame) async {
        consumed.append(frame.wallMs)
        started.insert(frame.wallMs)
        let waiters = startedWaiters.removeValue(forKey: frame.wallMs) ?? []
        waiters.forEach { $0.resume() }
        guard blockedFrames.contains(frame.wallMs) else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters[frame.wallMs] = continuation
        }
    }

    func waitUntilStarted(_ wallMs: Int64) async {
        guard !started.contains(wallMs) else { return }
        await withCheckedContinuation { continuation in
            startedWaiters[wallMs, default: []].append(continuation)
        }
    }

    func release(_ wallMs: Int64) {
        releaseWaiters.removeValue(forKey: wallMs)?.resume()
    }

    func recordGap(start: Int64, end: Int64) {
        recordedGaps.append(Gap(start: start, end: end))
    }

    func consumedFrames() -> [Int64] { consumed }
    func gaps() -> [Gap] { recordedGaps }
}
