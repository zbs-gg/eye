import XCTest

@MainActor
final class SystemAudioCaptureLifecycleTests: XCTestCase {
    func testDrainWaitsForPhysicalCaptureTeardown() async throws {
        let lifecycle = SystemAudioCaptureLifecycle<TestSystemAudioSession>()
        let maybeToken = await lifecycle.beginStart()
        let token = try XCTUnwrap(maybeToken)
        let session = TestSystemAudioSession()
        XCTAssertTrue(lifecycle.publishStarted(session, token: token))

        let gate = SystemAudioLifecycleGate()
        let teardown = lifecycle.beginStop { stoppedSession in
            XCTAssertTrue(stoppedSession === session)
            await gate.wait()
            return .stopped
        }
        XCTAssertNotNil(teardown)
        await gate.waitUntilEntered()

        let completion = SystemAudioLifecycleFlag()
        let drain = Task { @MainActor in
            let outcome = await lifecycle.drain()
            await completion.set()
            return outcome
        }
        for _ in 0..<20 { await Task.yield() }
        let completedBeforeOpen = await completion.snapshot()
        XCTAssertFalse(completedBeforeOpen)

        await gate.open()
        let outcome = await drain.value
        XCTAssertEqual(outcome, .stopped)
        let completedAfterOpen = await completion.snapshot()
        XCTAssertTrue(completedAfterOpen)
    }

    func testStopDuringStartRejectsTheLateSession() async throws {
        let lifecycle = SystemAudioCaptureLifecycle<TestSystemAudioSession>()
        let maybeToken = await lifecycle.beginStart()
        let token = try XCTUnwrap(maybeToken)
        let lateSession = TestSystemAudioSession()

        XCTAssertNil(lifecycle.beginStop { stoppedSession in
            XCTAssertTrue(stoppedSession === lateSession)
            return .stopped
        })
        XCTAssertFalse(
            lifecycle.publishStarted(lateSession, token: token),
            "a capture that finishes after stop must never become the running session"
        )
        let teardownOutcome = await lifecycle.drain()
        XCTAssertEqual(teardownOutcome, .stopped)
    }

    func testDrainWaitsForRejectedPendingStartToPublishAndStop() async throws {
        let lifecycle = SystemAudioCaptureLifecycle<TestSystemAudioSession>()
        let maybeToken = await lifecycle.beginStart()
        let token = try XCTUnwrap(maybeToken)
        let lateSession = TestSystemAudioSession()
        let stopGate = SystemAudioLifecycleGate()

        XCTAssertNil(lifecycle.beginStop { stoppedSession in
            XCTAssertTrue(stoppedSession === lateSession)
            await stopGate.wait()
            return .stopped
        })

        let completion = SystemAudioLifecycleFlag()
        let drain = Task { @MainActor in
            let outcome = await lifecycle.drain()
            await completion.set()
            return outcome
        }
        for _ in 0..<20 { await Task.yield() }
        let completedBeforePublish = await completion.snapshot()
        XCTAssertFalse(completedBeforePublish)

        XCTAssertFalse(lifecycle.publishStarted(lateSession, token: token))
        await stopGate.waitUntilEntered()
        for _ in 0..<20 { await Task.yield() }
        let completedBeforeStop = await completion.snapshot()
        XCTAssertFalse(completedBeforeStop)

        await stopGate.open()
        let outcome = await drain.value
        let completedAfterStop = await completion.snapshot()
        XCTAssertEqual(outcome, .stopped)
        XCTAssertTrue(completedAfterStop)
    }

    func testDrainOfRejectedPendingStartCompletesWhenStartFails() async throws {
        let lifecycle = SystemAudioCaptureLifecycle<TestSystemAudioSession>()
        let maybeToken = await lifecycle.beginStart()
        let token = try XCTUnwrap(maybeToken)

        XCTAssertNil(lifecycle.beginStop { _ in
            XCTFail("a failed start never published a physical session")
            return .failed("unexpected teardown")
        })
        let drain = Task { @MainActor in await lifecycle.drain() }
        for _ in 0..<20 { await Task.yield() }

        lifecycle.failStart(token: token)
        let outcome = await drain.value
        XCTAssertEqual(outcome, .notNeeded)
    }

    func testStopInvalidatesStartTokenBeforePhysicalCaptureBegins() async throws {
        let lifecycle = SystemAudioCaptureLifecycle<TestSystemAudioSession>()
        let maybeToken = await lifecycle.beginStart()
        let token = try XCTUnwrap(maybeToken)
        XCTAssertTrue(lifecycle.isStartCurrent(token))

        XCTAssertNil(lifecycle.beginStop { _ in
            XCTFail("an invalidated preflight never acquired a physical session")
            return .failed("unexpected teardown")
        })
        XCTAssertFalse(lifecycle.isStartCurrent(token))

        lifecycle.failStart(token: token)
        let outcome = await lifecycle.drain()
        XCTAssertEqual(outcome, .notNeeded)
    }

    func testFailedLateStartTeardownRetainsOwnershipUntilRetrySucceeds() async throws {
        let lifecycle = SystemAudioCaptureLifecycle<TestSystemAudioSession>()
        let maybeToken = await lifecycle.beginStart()
        let token = try XCTUnwrap(maybeToken)
        let session = TestSystemAudioSession()
        let stopScript = SystemAudioRetryStopScript(session: session)

        XCTAssertNil(
            lifecycle.beginStop { stoppedSession in
                await stopScript.stop(stoppedSession)
            },
            "the suspended start has not published its physical session yet"
        )
        XCTAssertFalse(
            lifecycle.publishStarted(session, token: token),
            "Stop must reject a physical session that arrives after cancellation"
        )

        let firstOutcome = await lifecycle.drain()
        guard firstOutcome == .failed("first stop failed") else {
            XCTFail("the lifecycle lost ownership of the failed late teardown: \(firstOutcome)")
            return
        }

        let replacementCompleted = SystemAudioLifecycleFlag()
        let replacement = Task { @MainActor in
            let replacementToken = await lifecycle.beginStart()
            await replacementCompleted.set()
            return replacementToken
        }
        await stopScript.waitUntilRetryEntered()
        for _ in 0..<20 { await Task.yield() }
        let completedBeforeRetry = await replacementCompleted.snapshot()
        XCTAssertFalse(
            completedBeforeRetry,
            "a replacement must remain blocked while the retained stop retry owns the session"
        )

        await stopScript.allowRetryToFinish()
        let replacementToken = await replacement.value
        XCTAssertNotNil(replacementToken)
        XCTAssertEqual(stopScript.attempts, 2)
    }

    func testNextStartWaitsForPreviousPhysicalTeardown() async throws {
        let lifecycle = SystemAudioCaptureLifecycle<TestSystemAudioSession>()
        let maybeFirstToken = await lifecycle.beginStart()
        let firstToken = try XCTUnwrap(maybeFirstToken)
        XCTAssertTrue(
            lifecycle.publishStarted(TestSystemAudioSession(), token: firstToken)
        )

        let gate = SystemAudioLifecycleGate()
        XCTAssertNotNil(lifecycle.beginStop { _ in
            await gate.wait()
            return .stopped
        })
        await gate.waitUntilEntered()

        let completion = SystemAudioLifecycleFlag()
        let nextStart = Task { @MainActor in
            let token = await lifecycle.beginStart()
            await completion.set()
            return token
        }
        for _ in 0..<20 { await Task.yield() }
        let startedBeforeOpen = await completion.snapshot()
        XCTAssertFalse(startedBeforeOpen)

        await gate.open()
        let nextToken = await nextStart.value
        XCTAssertNotNil(nextToken)
        let startedAfterOpen = await completion.snapshot()
        XCTAssertTrue(startedAfterOpen)
    }

    func testStopWhileNextStartWaitsForTeardownInvalidatesThatStart() async throws {
        let lifecycle = SystemAudioCaptureLifecycle<TestSystemAudioSession>()
        let maybeFirstToken = await lifecycle.beginStart()
        let firstToken = try XCTUnwrap(maybeFirstToken)
        XCTAssertTrue(
            lifecycle.publishStarted(TestSystemAudioSession(), token: firstToken)
        )

        let gate = SystemAudioLifecycleGate()
        XCTAssertNotNil(lifecycle.beginStop { _ in
            await gate.wait()
            return .stopped
        })
        await gate.waitUntilEntered()

        let startEntered = SystemAudioLifecycleFlag()
        let waitingStart = Task { @MainActor in
            await startEntered.set()
            return await lifecycle.beginStart()
        }
        while !(await startEntered.snapshot()) { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }

        XCTAssertNotNil(
            lifecycle.beginStop { _ in
                XCTFail("the existing teardown must retain physical-session ownership")
                return .failed("unexpected replacement teardown")
            }
        )
        await gate.open()

        let staleStart = await waitingStart.value
        XCTAssertNil(
            staleStart,
            "a Stop received while beginStart is suspended must win"
        )
    }

    func testPhysicalTeardownFailureIsReturnedByDrain() async throws {
        let lifecycle = SystemAudioCaptureLifecycle<TestSystemAudioSession>()
        let maybeToken = await lifecycle.beginStart()
        let token = try XCTUnwrap(maybeToken)
        XCTAssertTrue(
            lifecycle.publishStarted(TestSystemAudioSession(), token: token)
        )

        XCTAssertNotNil(lifecycle.beginStop { _ in .failed("SCK stop failed") })

        let outcome = await lifecycle.drain()
        XCTAssertEqual(outcome, .failed("SCK stop failed"))
    }

    func testNextStartAutomaticallyRetriesCompletedFailedTeardown() async throws {
        let lifecycle = SystemAudioCaptureLifecycle<TestSystemAudioSession>()
        let maybeToken = await lifecycle.beginStart()
        let token = try XCTUnwrap(maybeToken)
        let session = TestSystemAudioSession()
        XCTAssertTrue(lifecycle.publishStarted(session, token: token))
        let stopScript = SystemAudioStopScript(
            session: session,
            outcomes: [.failed("first stop failed"), .stopped]
        )

        let first = try XCTUnwrap(lifecycle.beginStop { stoppedSession in
            stopScript.stop(stoppedSession)
        })
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .failed("first stop failed"))

        let nextStart = await lifecycle.beginStart()
        XCTAssertNotNil(nextStart)
        XCTAssertEqual(stopScript.attempts, 2)
    }

    func testNextStartDoesNotTreatCompletedTimeoutAsRetryableFailure() async throws {
        let lifecycle = SystemAudioCaptureLifecycle<TestSystemAudioSession>()
        let maybeToken = await lifecycle.beginStart()
        let token = try XCTUnwrap(maybeToken)
        let session = TestSystemAudioSession()
        XCTAssertTrue(lifecycle.publishStarted(session, token: token))
        let stopScript = SystemAudioStopScript(
            session: session,
            outcomes: [.timedOut, .stopped]
        )

        let first = try XCTUnwrap(lifecycle.beginStop { stoppedSession in
            stopScript.stop(stoppedSession)
        })
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .timedOut)

        let nextStart = await lifecycle.beginStart()
        XCTAssertNil(nextStart)
        XCTAssertEqual(stopScript.attempts, 1)
    }

    func testExternallyStoppedSessionNeedsNoSecondTeardownAndAllowsRestart() async throws {
        let lifecycle = SystemAudioCaptureLifecycle<TestSystemAudioSession>()
        let maybeToken = await lifecycle.beginStart()
        let token = try XCTUnwrap(maybeToken)
        let session = TestSystemAudioSession()
        XCTAssertTrue(lifecycle.publishStarted(session, token: token))

        XCTAssertTrue(
            lifecycle.acknowledgeExternalStop(sessionID: ObjectIdentifier(session))
        )
        let drain = await lifecycle.drain()
        XCTAssertEqual(drain, .notNeeded)
        let nextStart = await lifecycle.beginStart()
        XCTAssertNotNil(nextStart)
    }

    func testTeardownDeadlineReturnsWithoutCancellingResourceOwner() async {
        let gate = SystemAudioLifecycleGate()
        let teardown = Task {
            await gate.wait()
            return SystemAudioCaptureTeardownOutcome.stopped
        }
        await gate.waitUntilEntered()

        let outcome = await SystemAudioTeardownDeadline.wait(
            for: teardown,
            timeout: .milliseconds(20)
        )

        XCTAssertEqual(outcome, .timedOut)
        await gate.open()
        let eventualOutcome = await teardown.value
        XCTAssertEqual(eventualOutcome, .stopped)
    }

    func testTeardownDeadlineReturnsCompletedFailure() async {
        let teardown = Task {
            SystemAudioCaptureTeardownOutcome.failed("SCK stop failed")
        }

        let outcome = await SystemAudioTeardownDeadline.wait(
            for: teardown,
            timeout: .seconds(1)
        )

        XCTAssertEqual(outcome, .failed("SCK stop failed"))
    }

    func testFrameAdmissionExposesOnlyTheCurrentSessionSink() {
        let admission = SystemAudioFrameAdmission<TestSystemAudioSession, Int>()
        let first = TestSystemAudioSession()
        let second = TestSystemAudioSession()

        admission.open(session: first, sink: 42)

        XCTAssertEqual(admission.sink(for: first), 42)
        XCTAssertNil(admission.sink(for: second))
        XCTAssertEqual(admission.close(), 42)
        XCTAssertNil(admission.sink(for: first))
        XCTAssertNil(admission.close())
    }

    func testCoordinatorDoesNotReportAnIntentionalStopAsAStartFailure() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "ZBSEyeApp/Audio/AudioCoordinator.swift"),
            encoding: .utf8
        )
        let engineStart = try XCTUnwrap(
            source.range(of: "stream = try await engine.start()")
        )
        let failureLog = try XCTUnwrap(
            source.range(
                of: "Log.audio.error(\"system_audio_start_failed\")",
                range: engineStart.upperBound..<source.endIndex
            )
        )
        let reattestation = source[engineStart.upperBound..<failureLog.lowerBound]

        XCTAssertTrue(reattestation.contains("self.systemEpoch == epoch"))
        XCTAssertTrue(reattestation.contains("self.systemStarting"))
        XCTAssertTrue(reattestation.contains("self.desiredSources.system"))
        XCTAssertTrue(reattestation.contains("!self.suppressSystemStopObservation"))
        XCTAssertTrue(reattestation.contains("return await engine.stopAndDrain()"))
    }
}

private final class TestSystemAudioSession {}

@MainActor
private final class SystemAudioStopScript {
    private let session: TestSystemAudioSession
    private var outcomes: [SystemAudioCaptureTeardownOutcome]
    private(set) var attempts = 0

    init(
        session: TestSystemAudioSession,
        outcomes: [SystemAudioCaptureTeardownOutcome]
    ) {
        self.session = session
        self.outcomes = outcomes
    }

    func stop(
        _ stoppedSession: TestSystemAudioSession
    ) -> SystemAudioCaptureTeardownOutcome {
        XCTAssertTrue(stoppedSession === session)
        attempts += 1
        return outcomes.removeFirst()
    }
}

@MainActor
private final class SystemAudioRetryStopScript {
    private let session: TestSystemAudioSession
    private let retryGate = SystemAudioLifecycleGate()
    private(set) var attempts = 0

    init(session: TestSystemAudioSession) {
        self.session = session
    }

    func stop(
        _ stoppedSession: TestSystemAudioSession
    ) async -> SystemAudioCaptureTeardownOutcome {
        XCTAssertTrue(stoppedSession === session)
        attempts += 1
        guard attempts > 1 else { return .failed("first stop failed") }
        await retryGate.wait()
        return .stopped
    }

    func waitUntilRetryEntered() async {
        await retryGate.waitUntilEntered()
    }

    func allowRetryToFinish() async {
        await retryGate.open()
    }
}

private actor SystemAudioLifecycleGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SystemAudioLifecycleFlag {
    private var value = false
    func set() { value = true }
    func snapshot() -> Bool { value }
}
