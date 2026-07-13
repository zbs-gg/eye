import AppKit
import XCTest

@MainActor
final class ZBSEyeAppDelegateTests: XCTestCase {
    func testApplicationLaunchStartsRuntimeWithoutAWindowAndOnlyOnce() async {
        defer {
            ZBSEyeAppDelegate.onLaunch = nil
            ZBSEyeAppDelegate.onTerminate = nil
        }
        let probe = ApplicationLaunchProbe()
        ZBSEyeAppDelegate.onLaunch = {
            await probe.runAndWait()
        }
        let delegate = ZBSEyeAppDelegate()
        let notification = Notification(
            name: NSApplication.didFinishLaunchingNotification
        )

        delegate.applicationDidFinishLaunching(notification)
        await probe.waitUntilStarted()

        delegate.applicationDidFinishLaunching(notification)
        let startsWhileInFlight = await probe.startCount()
        XCTAssertEqual(startsWhileInFlight, 1)

        await probe.release()
        await probe.waitUntilFinished()

        delegate.applicationDidFinishLaunching(notification)
        let startsAfterCompletion = await probe.startCount()
        XCTAssertEqual(startsAfterCompletion, 1)
    }
}

private actor ApplicationLaunchProbe {
    private var starts = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var finished = false

    func runAndWait() async {
        starts += 1
        let pendingStarts = startedWaiters
        startedWaiters.removeAll()
        pendingStarts.forEach { $0.resume() }

        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        finished = true
        let pendingFinishes = finishedWaiters
        finishedWaiters.removeAll()
        pendingFinishes.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        if starts > 0 { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        released = true
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func waitUntilFinished() async {
        if finished { return }
        await withCheckedContinuation { finishedWaiters.append($0) }
    }

    func startCount() -> Int { starts }
}
