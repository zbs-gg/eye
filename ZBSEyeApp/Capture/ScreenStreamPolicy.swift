import Foundation

/// Context that must still own the frontmost pixels when an asynchronous AX +
/// ScreenCaptureKit cycle is ready to commit. Window and display identity keep
/// a rapid same-process window switch from pairing old text with new pixels.
struct CaptureSourceIdentity: Sendable, Equatable {
    let processIdentifier: Int32
    let bundleIdentifier: String
    let windowNumber: UInt32?
    let displayID: UInt32?
}

enum CaptureSourceAttestationPolicy {
    static func accepts(
        expected: CaptureSourceIdentity,
        current: CaptureSourceIdentity?
    ) -> Bool {
        current == expected
    }

    /// Exact identity alone cannot detect an A -> B -> A focus round-trip
    /// while AX or ScreenCaptureKit is suspended. The monotonic focus revision
    /// makes that ABA transition terminal for the admitted cycle.
    static func accepts(
        expected: CaptureSourceIdentity,
        current: CaptureSourceIdentity?,
        expectedFocusRevision: UInt64,
        currentFocusRevision: UInt64
    ) -> Bool {
        expectedFocusRevision == currentFocusRevision
            && accepts(expected: expected, current: current)
    }
}

/// A MainActor topology/privacy invalidation may overtake an event already
/// queued by ScreenCaptureKit. Each stream generation carries the revision it
/// was admitted under; the MainActor sink accepts only the current revision.
final class ScreenStreamEventFence: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0

    func snapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    @discardableResult
    func invalidate() -> UInt64 {
        lock.lock()
        revision &+= 1
        let current = revision
        lock.unlock()
        return current
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate == revision
    }
}

/// Pure publication state used under ScreenCaptureStreamOutput's lock. The
/// pending-rebind state deliberately attributes a delegate failure to the old
/// published generation until the new generation crosses publication.
struct ScreenStreamPublicationPolicy: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case inactive
        case pendingInitial(generation: Int64, eventRevision: UInt64)
        case pendingRebind(previous: Int64, current: Int64, eventRevision: UInt64)
        case published(generation: Int64, eventRevision: UInt64)
    }

    private(set) var phase: Phase = .inactive

    mutating func bind(generation: Int64, eventRevision: UInt64) {
        phase = .pendingInitial(
            generation: generation,
            eventRevision: eventRevision
        )
    }

    mutating func rebindIfPublished(
        from oldGeneration: Int64,
        to newGeneration: Int64,
        eventRevision: UInt64
    ) -> Bool {
        guard case .published(oldGeneration, eventRevision) = phase else {
            return false
        }
        phase = .pendingRebind(
            previous: oldGeneration,
            current: newGeneration,
            eventRevision: eventRevision
        )
        return true
    }

    mutating func publishIfPending(generation: Int64) -> UInt64? {
        let eventRevision: UInt64
        switch phase {
        case .pendingInitial(generation, let revision),
             .pendingRebind(_, generation, let revision):
            eventRevision = revision
        case .inactive, .pendingInitial, .pendingRebind, .published:
            return nil
        }
        phase = .published(
            generation: generation,
            eventRevision: eventRevision
        )
        return eventRevision
    }

    func isPublished(generation: Int64, eventRevision: UInt64? = nil) -> Bool {
        guard case .published(generation, let publishedRevision) = phase else {
            return false
        }
        return eventRevision.map { $0 == publishedRevision } ?? true
    }

    func publishedEventRevision(generation: Int64) -> UInt64? {
        guard case .published(generation, let eventRevision) = phase else {
            return nil
        }
        return eventRevision
    }

    func failureEvent(
        boundGeneration: Int64?
    ) -> (generation: Int64, eventRevision: UInt64)? {
        switch phase {
        case .published(let generation, let eventRevision):
            return generation == boundGeneration ? (generation, eventRevision) : nil
        case .pendingRebind(let previous, let current, let eventRevision):
            return current == boundGeneration ? (previous, eventRevision) : nil
        case .inactive, .pendingInitial:
            return nil
        }
    }

    mutating func end() {
        phase = .inactive
    }
}

enum ScreenStreamMissingPixelDecision: Sendable, Equatable {
    case none
    case failWaiter
}

/// A finite run of accepted compositor progress without a usable current
/// surface must open recovery instead of keeping one intent alive forever.
struct ScreenStreamMissingPixelPolicy: Sendable, Equatable {
    let progressLimit: Int
    private(set) var progressCount = 0

    init(progressLimit: Int = 3) {
        self.progressLimit = max(1, progressLimit)
    }

    mutating func observe(
        acceptedProgress: Bool,
        hasUsablePixel: Bool,
        hasWaiter: Bool
    ) -> ScreenStreamMissingPixelDecision {
        guard acceptedProgress else { return .none }
        guard hasWaiter else {
            progressCount = 0
            return .none
        }
        guard !hasUsablePixel else {
            progressCount = 0
            return .none
        }
        progressCount += 1
        guard progressCount >= progressLimit else { return .none }
        progressCount = 0
        return .failWaiter
    }

    mutating func reset() {
        progressCount = 0
    }
}

enum ScreenStreamStopAdmission<Resource> {
    case noResource
    case join(Resource)
    case own(Resource)
}

/// Pure ownership state for a physical stream stop. A concurrent caller joins
/// the current resource; an unconfirmed stop remains the only admissible retry
/// target and blocks every replacement.
struct ScreenStreamStopOwnership<Resource: Equatable> {
    private(set) var stopping: Resource?
    private(set) var failed: Resource?

    var permitsReplacement: Bool {
        stopping == nil && failed == nil
    }

    mutating func begin(target: Resource?) -> ScreenStreamStopAdmission<Resource> {
        if let stopping { return .join(stopping) }
        guard let selected = failed ?? target else { return .noResource }
        failed = nil
        stopping = selected
        return .own(selected)
    }

    mutating func complete(_ resource: Resource, confirmed: Bool) -> Bool {
        guard stopping == resource else { return false }
        stopping = nil
        failed = confirmed ? nil : resource
        return true
    }

    mutating func acknowledgeExternalStop(_ resource: Resource) -> Bool {
        guard failed == resource else { return false }
        failed = nil
        return true
    }
}

enum ScreenStreamStartStopDisposition: Sendable, Equatable {
    case confirmedNotStarted
    case requiresPhysicalStop
}

/// Linearizes a queued start against Stop without assuming which SCK resource
/// lease runs first. Stop may suppress a start that has not entered
/// `startCapture()` yet; once start wins, teardown must conservatively confirm
/// the physical session stopped even when `startCapture()` later throws.
final class ScreenStreamStartHandshake: @unchecked Sendable {
    private enum State {
        case pending
        case suppressed
        case physicalStartBegan
    }

    private let lock = NSLock()
    private var state: State = .pending

    /// Called immediately before invoking `SCStream.startCapture()`.
    func beginPhysicalStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = state else { return false }
        state = .physicalStartBegan
        return true
    }

    /// Called by the stop owner before any suspension. This either prevents a
    /// queued start from ever invoking SCK, or requires exact physical stop.
    func stopDisposition() -> ScreenStreamStartStopDisposition {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .pending:
            state = .suppressed
            return .confirmedNotStarted
        case .suppressed:
            return .confirmedNotStarted
        case .physicalStartBegan:
            return .requiresPhysicalStop
        }
    }

    func cancelBeforePhysicalStart() {
        _ = stopDisposition()
    }

    var physicalStartBegan: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .physicalStartBegan = state else { return false }
        return true
    }
}

/// Only these ScreenCaptureKit statuses prove that the stream is alive. An
/// idle frame is positive evidence: the compositor answered and the display
/// simply had no changed pixels.
enum ScreenStreamFrameStatus: Sendable, Equatable {
    case complete
    case idle
    case nonProgress

    var provesLiveness: Bool {
        self == .complete || self == .idle
    }
}

struct ScreenStreamFrameStamp: Sendable, Equatable {
    let generation: Int64
    let status: ScreenStreamFrameStatus
    let displayTime: UInt64
}

struct ScreenStreamIntent: Sendable, Equatable {
    let id: UInt64
    let generation: Int64
    let afterDisplayTime: UInt64?
}

enum ScreenStreamFrameObservation: Sendable, Equatable {
    case rejected
    case heartbeat
    case fulfilled(ScreenStreamIntent)
}

/// Pure freshness contract shared by the callback bridge and unit tests.
/// Generation rejects a late frame from an old stream; status rejects blank,
/// suspended, started and stopped notifications; displayTime makes an intent
/// wait for a compositor event strictly newer than the moment it was armed.
struct ScreenStreamFreshnessPolicy: Sendable, Equatable {
    private(set) var generation: Int64 = 0
    private(set) var lastDisplayTime: UInt64?
    private(set) var pendingIntent: ScreenStreamIntent?
    private var nextIntentID: UInt64 = 0

    mutating func beginGeneration(_ generation: Int64) {
        self.generation = generation
        lastDisplayTime = nil
        pendingIntent = nil
    }

    mutating func endGeneration() {
        pendingIntent = nil
    }

    @discardableResult
    mutating func requestFrame() -> ScreenStreamIntent {
        nextIntentID &+= 1
        let intent = ScreenStreamIntent(
            id: nextIntentID,
            generation: generation,
            afterDisplayTime: lastDisplayTime
        )
        // Latest wins. Replacing an unfulfilled intent never creates another
        // physical stream or another processing slot.
        pendingIntent = intent
        return intent
    }

    mutating func cancelIntent(_ intent: ScreenStreamIntent) {
        if pendingIntent == intent { pendingIntent = nil }
    }

    mutating func observe(
        _ stamp: ScreenStreamFrameStamp,
        canFulfillIntent: Bool = true
    ) -> ScreenStreamFrameObservation {
        guard stamp.generation == generation,
              stamp.status.provesLiveness,
              lastDisplayTime.map({ stamp.displayTime > $0 }) ?? true else {
            return .rejected
        }
        lastDisplayTime = stamp.displayTime
        guard let intent = pendingIntent,
              canFulfillIntent,
              intent.generation == generation,
              intent.afterDisplayTime.map({ stamp.displayTime > $0 }) ?? true else {
            return .heartbeat
        }
        pendingIntent = nil
        return .fulfilled(intent)
    }
}

/// Trigger coalescing for the expensive AX/OCR/HEIC path. At most one intent
/// is processing and one is waiting; every additional trigger replaces the
/// waiting intent instead of building an unbounded queue.
struct LatestCaptureWorkPolicy: Sendable, Equatable {
    enum Submission: Sendable, Equatable {
        case start(UInt64)
        case queued(UInt64)
    }

    private(set) var processing: UInt64?
    private(set) var waiting: UInt64?
    private var nextID: UInt64 = 0

    var retainedCount: Int {
        (processing == nil ? 0 : 1) + (waiting == nil ? 0 : 1)
    }

    mutating func submit() -> Submission {
        nextID &+= 1
        if processing == nil {
            processing = nextID
            return .start(nextID)
        }
        waiting = nextID
        return .queued(nextID)
    }

    mutating func complete(_ id: UInt64) -> UInt64? {
        guard processing == id else { return nil }
        processing = waiting
        waiting = nil
        return processing
    }

    mutating func discardWaiting() {
        waiting = nil
    }

    mutating func cancelAll() {
        processing = nil
        waiting = nil
    }
}

/// Why Eye asked the already-running screen stream for a fresh frame. Hard
/// reasons are never delayed by input coalescing; soft reasons contain no key,
/// text, cursor, or clipboard payload and are rate-limited together.
enum CaptureTriggerReason: Sendable, Equatable {
    case startup
    case applicationSwitch
    case activeFallback
    case idleFallback
    case click
    case typingPause
    case scrollStop
    case recovery
    case displayChange
    case contentTopologyChange
    case sessionResume
}

/// The only information allowed to leave the listen-only input callback. This
/// deliberately cannot carry what was typed, a hardware key code, coordinates,
/// scroll deltas, or clipboard contents.
enum MeaningfulCaptureInput: Sendable, Equatable {
    case click
    case typingActivity
    case scrollActivity
}

enum MeaningfulCaptureTriggerDecision: Sendable, Equatable {
    case capture(CaptureTriggerReason)
    case schedule(deadlineMs: UInt64)
    case none
}

/// Pure latest-event scheduler for click/type/scroll capture. It retains at
/// most one pending semantic reason. A newer event replaces it, typing and
/// scrolling debounce from their latest event, and every soft capture shares
/// one minimum interval.
struct MeaningfulCaptureTriggerPolicy: Sendable, Equatable {
    struct Pending: Sendable, Equatable {
        let reason: CaptureTriggerReason
        let deadlineMs: UInt64
    }

    let clickDelayMs: UInt64
    let typingPauseDelayMs: UInt64
    let scrollStopDelayMs: UInt64
    let softFloorMs: UInt64

    private(set) var lastCaptureAtMs: UInt64?
    private(set) var pending: Pending?

    init(
        clickDelayMs: UInt64 = 0,
        typingPauseDelayMs: UInt64 = 700,
        scrollStopDelayMs: UInt64 = 350,
        softFloorMs: UInt64 = 1_500
    ) {
        self.clickDelayMs = clickDelayMs
        self.typingPauseDelayMs = typingPauseDelayMs
        self.scrollStopDelayMs = scrollStopDelayMs
        self.softFloorMs = softFloorMs
    }

    mutating func observe(
        _ input: MeaningfulCaptureInput,
        at nowMs: UInt64
    ) -> MeaningfulCaptureTriggerDecision {
        let reason: CaptureTriggerReason
        let inputDelayMs: UInt64
        switch input {
        case .click:
            reason = .click
            inputDelayMs = clickDelayMs
        case .typingActivity:
            reason = .typingPause
            inputDelayMs = typingPauseDelayMs
        case .scrollActivity:
            reason = .scrollStop
            inputDelayMs = scrollStopDelayMs
        }

        let debouncedDeadline = Self.saturatingAdd(nowMs, inputDelayMs)
        let floorDeadline = lastCaptureAtMs.map {
            Self.saturatingAdd($0, softFloorMs)
        } ?? 0
        pending = Pending(
            reason: reason,
            deadlineMs: max(debouncedDeadline, floorDeadline)
        )
        return consumeIfDue(at: nowMs)
    }

    mutating func timerFired(at nowMs: UInt64) -> MeaningfulCaptureTriggerDecision {
        consumeIfDue(at: nowMs)
    }

    mutating func cancelPending() {
        pending = nil
    }

    mutating func reset() {
        pending = nil
        lastCaptureAtMs = nil
    }

    private mutating func consumeIfDue(
        at nowMs: UInt64
    ) -> MeaningfulCaptureTriggerDecision {
        guard let pending else { return .none }
        guard nowMs >= pending.deadlineMs else {
            return .schedule(deadlineMs: pending.deadlineMs)
        }
        self.pending = nil
        lastCaptureAtMs = nowMs
        return .capture(pending.reason)
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }
}

/// Monotonic liveness policy. Pixel hashes are deliberately absent: unchanged
/// pixels are healthy when ScreenCaptureKit keeps producing complete/idle
/// compositor events.
struct ScreenStreamLivenessPolicy: Sendable, Equatable {
    private(set) var generation: Int64?
    private(set) var lastProgressAtMs: Int64?
    private(set) var failureReported = false
    let timeoutMs: Int64

    init(timeoutMs: Int64 = 8_000) {
        self.timeoutMs = timeoutMs
    }

    mutating func started(generation: Int64, nowMs: Int64) {
        self.generation = generation
        lastProgressAtMs = nowMs
        failureReported = false
    }

    @discardableResult
    mutating func observed(_ stamp: ScreenStreamFrameStamp, nowMs: Int64) -> Bool {
        guard stamp.generation == generation, stamp.status.provesLiveness else { return false }
        lastProgressAtMs = nowMs
        return true
    }

    mutating func shouldReportStall(nowMs: Int64) -> Bool {
        guard !failureReported,
              generation != nil,
              let lastProgressAtMs,
              nowMs - lastProgressAtMs >= timeoutMs else { return false }
        failureReported = true
        return true
    }

    mutating func stopped() {
        generation = nil
        lastProgressAtMs = nil
        failureReported = false
    }
}
