import Foundation
import XCTest

final class AudioIngressPublisherTests: XCTestCase {
    func testBoundedGapBufferCoalescesBoundsAndPrunesCoveredIntervals() {
        var buffer = BoundedAudioIngressGaps(capacity: 2)
        for sequence in [1, 2, 10, 20] {
            buffer.record(
                AudioIngressGap(
                    source: .me,
                    epoch: 0,
                    firstIngressSequence: Int64(sequence),
                    lastIngressSequence: Int64(sequence),
                    reason: .consumerOverflow
                )
            )
        }

        XCTAssertTrue(buffer.hadAnyGap)
        XCTAssertEqual(buffer.intervals.count, 2)
        XCTAssertTrue(buffer.covers(source: .me, sequence: 20))
        buffer.prune(source: .me, through: 20)
        XCTAssertTrue(buffer.intervals.isEmpty)
        XCTAssertTrue(buffer.hadAnyGap)
    }

    func testBufferingNewestAcceptsNewFrameAndReportsDroppedOldFrameAsGap() async throws {
        let publisher = AudioIngressPublisher(source: .me, epoch: 3, capacity: 1)
        let first = publisher.yield(
            samples: [0.1],
            rms: 0.1,
            captureSampleRate: 48_000,
            sourceSampleTime: 0,
            normalizedHostTimeNs: 1_000,
            capturedAt: Date(timeIntervalSince1970: 1),
            provenance: .microphone
        )
        let second = publisher.yield(
            samples: [0.2],
            rms: 0.2,
            captureSampleRate: 48_000,
            sourceSampleTime: 1,
            normalizedHostTimeNs: 2_000,
            capturedAt: Date(timeIntervalSince1970: 2),
            provenance: .microphone
        )

        guard case let .accepted(firstSequence, firstGap) = first else {
            XCTFail("the first frame should be accepted")
            return
        }
        XCTAssertEqual(firstSequence, 0)
        XCTAssertNil(firstGap)

        guard case let .accepted(secondSequence, droppedGap) = second else {
            XCTFail("bufferingNewest must accept the new frame even when it evicts an old frame")
            return
        }
        XCTAssertEqual(secondSequence, 1)
        XCTAssertEqual(droppedGap?.source, .me)
        XCTAssertEqual(droppedGap?.epoch, 3)
        XCTAssertEqual(droppedGap?.firstIngressSequence, 0)
        XCTAssertEqual(droppedGap?.lastIngressSequence, 0)
        XCTAssertEqual(droppedGap?.reason, .consumerOverflow)
        XCTAssertEqual(droppedGap?.startHostTimeNs, 1_000)
        XCTAssertEqual(droppedGap?.startMs, 1_000)
        XCTAssertNotNil(droppedGap?.endHostTimeNs)
        XCTAssertNotNil(droppedGap?.endMs)
        XCTAssertEqual(publisher.latestAcceptedIngressSequence, 1)

        var iterator = publisher.stream.makeAsyncIterator()
        let maybeRetained = await iterator.next()
        let retained = try XCTUnwrap(maybeRetained)
        XCTAssertEqual(retained.samples, [0.2])
        XCTAssertEqual(retained.timing.source, .me)
        XCTAssertEqual(retained.timing.epoch, 3)
        XCTAssertEqual(retained.timing.ingressSequence, 1)
        XCTAssertEqual(retained.timing.sourceSampleTime, 1)
        XCTAssertEqual(retained.timing.normalizedHostTimeNs, 2_000)
    }

    func testHostClockMapperRemovesCallbackDeliveryDelay() {
        let callbackWall = Date(timeIntervalSince1970: 1_000)
        let mapped = AudioHostClockWallMapper.date(
            for: 8_000_000_000,
            callbackHostTimeNs: 10_000_000_000,
            callbackWallDate: callbackWall
        )

        XCTAssertEqual(mapped.timeIntervalSince1970, 998, accuracy: 0.000_001)
    }

    func testYieldAfterTerminationIsRejectedAndDoesNotAdvanceAcceptedTarget() {
        let publisher = AudioIngressPublisher(source: .system, epoch: 7, capacity: 1)
        publisher.finish()

        let result = publisher.yield(
            samples: [0.5],
            rms: 0.5,
            captureSampleRate: 48_000,
            sourceSampleTime: 10,
            normalizedHostTimeNs: 20_000,
            capturedAt: Date(timeIntervalSince1970: 3),
            provenance: .screenCaptureKit
        )

        guard case let .rejected(sequence, reason) = result else {
            XCTFail("a terminated continuation must reject the frame")
            return
        }
        XCTAssertEqual(sequence, 0)
        XCTAssertEqual(reason, .terminated)
        XCTAssertNil(publisher.latestAcceptedIngressSequence)
    }

    func testIngressSequenceContinuesAcrossPublisherEpochsAndLossTelemetryStaysBounded() {
        let publisher = AudioIngressPublisher(
            source: .me,
            epoch: 4,
            capacity: 1,
            initialSequence: 90
        )
        for index in 0..<100 {
            _ = publisher.yield(
                samples: [Float(index)],
                rms: 0,
                captureSampleRate: 48_000,
                sourceSampleTime: Int64(index),
                normalizedHostTimeNs: Int64(index),
                capturedAt: Date(timeIntervalSince1970: Double(index)),
                provenance: .microphone
            )
        }

        XCTAssertEqual(publisher.latestAcceptedIngressSequence, 189)
        XCTAssertEqual(publisher.nextAttemptedIngressSequence, 190)
        let gaps = publisher.drainGaps()
        XCTAssertLessThanOrEqual(gaps.count, 16)
        XCTAssertEqual(gaps.first?.firstIngressSequence, 90)
        XCTAssertEqual(gaps.last?.lastIngressSequence, 188)
    }

    func testTelemetryCollapseIncludesNewestDroppedFrameTimeBounds() async throws {
        let publisher = AudioIngressPublisher(source: .me, epoch: 0, capacity: 1)
        var iterator = publisher.stream.makeAsyncIterator()
        for pair in 0..<17 {
            let first = pair * 2
            _ = publisher.yield(
                samples: [0.1],
                rms: 0.1,
                captureSampleRate: 48_000,
                sourceSampleTime: Int64(first),
                normalizedHostTimeNs: Int64(first * 1_000),
                capturedAt: Date(timeIntervalSince1970: Double(first)),
                provenance: .microphone
            )
            _ = publisher.yield(
                samples: [0.2],
                rms: 0.2,
                captureSampleRate: 48_000,
                sourceSampleTime: Int64(first + 1),
                normalizedHostTimeNs: Int64((first + 1) * 1_000),
                capturedAt: Date(timeIntervalSince1970: Double(first + 1)),
                provenance: .microphone
            )
            let retained = await iterator.next()
            _ = try XCTUnwrap(retained)
        }

        let gaps = publisher.drainGaps()
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].reason, .telemetryOverflow)
        XCTAssertEqual(gaps[0].firstIngressSequence, 0)
        XCTAssertEqual(gaps[0].lastIngressSequence, 32)
        XCTAssertEqual(gaps[0].startHostTimeNs, 0)
        XCTAssertGreaterThanOrEqual(gaps[0].endHostTimeNs ?? -1, 32_000)
        XCTAssertEqual(gaps[0].startMs, 0)
        XCTAssertGreaterThanOrEqual(gaps[0].endMs ?? -1, 32_000)
    }

    func testStatefulPCMResamplerOutputDoesNotDependOnInputFrameSplits() {
        let input = (0..<4_811).map { index in
            Float(sin(Double(index) * 0.071) * 0.75)
        }

        var whole = CallPCM16Resampler(inputSampleRate: 48_000, outputSampleRate: 16_000)
        var wholeOutput = whole.append(input)
        wholeOutput.append(whole.finish())

        var split = CallPCM16Resampler(inputSampleRate: 48_000, outputSampleRate: 16_000)
        var splitOutput = Data()
        var cursor = 0
        for requestedCount in [1, 17, 509, 2, 997, 31, 2_003, 1_251] where cursor < input.count {
            let end = min(cursor + requestedCount, input.count)
            splitOutput.append(split.append(Array(input[cursor..<end])))
            cursor = end
        }
        if cursor < input.count {
            splitOutput.append(split.append(Array(input[cursor...])))
        }
        splitOutput.append(split.finish())

        XCTAssertFalse(wholeOutput.isEmpty)
        XCTAssertEqual(splitOutput, wholeOutput)
        XCTAssertEqual(wholeOutput.count % MemoryLayout<Int16>.size, 0)
    }
}
