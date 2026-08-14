import CoreVideo
import XCTest

final class CallVideoQueueTests: XCTestCase {
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
