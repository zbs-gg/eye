import Foundation
import CoreAudio
import AppKit   // NSRunningApplication

/// Detects whether a call/meeting is happening right now — on-device, with NO new permission.
///
/// SIGNAL: a **known meeting app is actively using the microphone**. We enumerate the audio process
/// objects (`kAudioHardwarePropertyProcessObjectList`), keep the ones running mic input
/// (`kAudioProcessPropertyIsRunningInput`), resolve each to a bundle id, and report a meeting if any
/// of them is a known conferencing app (Zoom, Teams, FaceTime, Discord, Slack, Webex, Skype).
///
/// Why not just "the microphone is in use"? On a real machine the mic is held by all sorts of things:
///  - ZBS Eye itself while it's recording (self-latch — the meeting would never "end");
///  - `replayd` (a by-product of our own screen/system-audio capture);
///  - a browser (e.g. Dia/Arc) that holds the mic 24/7 for an assistant tab.
/// None of those are meetings. Tying the signal to a meeting-app identity excludes all of them by
/// construction (they resolve to a non-meeting bundle, or to none) and only fires on a real call,
/// where the app holds the mic exactly while the call is live.
///
/// KNOWN LIMITATION (v1): a call that lives ONLY in a browser tab (Google Meet, Zoom web) is not
/// auto-detected — the mic holder is a browser helper, indistinguishable from a 24/7 assistant grab.
/// Use the menu-bar "Force audio on" for those. Native apps and browser calls that also open the
/// native app are covered.
///
/// Emits a DEBOUNCED Bool over an AsyncStream: start is immediate; stop waits a 10s grace (absorbs
/// Zoom reconnects / network blips); only settled state changes are emitted. Sendable actor.
actor MeetingDetector {
    /// Apps that hold the mic only during an actual call (not resident background mic use).
    static let meetingBundles: Set<String> = [
        "us.zoom.xos",                  // Zoom
        "com.microsoft.teams",          // Teams (classic)
        "com.microsoft.teams2",         // Teams (new)
        "com.apple.FaceTime",           // FaceTime
        "com.hnc.Discord",              // Discord
        "com.tinyspeck.slackmacgpu",    // Slack
        "com.cisco.webexmeetingsapp",   // Webex Meetings
        "com.webex.meetingmanager",     // Webex (older)
        "com.skype.skype",              // Skype
    ]

    private let stopGrace: TimeInterval = 10

    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<Bool>.Continuation?
    private var settled = false            // last emitted state
    private var pendingStopSince: Date?    // when raw first went false while settled == true

    /// Start polling (2s) and return a stream of settled meeting-active booleans. Initial state is
    /// treated as "not active"; the first value is emitted only when a meeting is actually detected.
    func start() -> AsyncStream<Bool> {
        let (stream, cont) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = cont
        settled = false
        pendingStopSince = nil
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(now: Date())
                try? await Task.sleep(for: .seconds(2))
            }
        }
        return stream
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        continuation?.finish(); continuation = nil
        settled = false
        pendingStopSince = nil
    }

    /// One debounce step. `now` is injected so tests can drive the grace window deterministically.
    func tick(now: Date) async {
        let raw = await Self.detectRaw()
        if raw {
            pendingStopSince = nil
            if !settled { settled = true; continuation?.yield(true) }
        } else if settled {
            if let since = pendingStopSince {
                if now.timeIntervalSince(since) >= stopGrace {
                    settled = false; pendingStopSince = nil; continuation?.yield(false)
                }
            } else {
                pendingStopSince = now      // start the grace window
            }
        }
    }

    /// Testing seam: raw (undebounced) detection — is a known meeting app holding the mic right now?
    static func detectRaw() async -> Bool {
        await MainActor.run { meetingAppHoldingMic() }
    }

    // MARK: implementation

    @MainActor
    private static func meetingAppHoldingMic() -> Bool {
        let mine = ProcessInfo.processInfo.processIdentifier
        for obj in processObjects() where isRunningInput(obj) {
            let pid = pidOf(obj)
            if pid == mine || pid <= 0 { continue }
            guard let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { continue }
            if meetingBundles.contains(bid) { return true }
        }
        return false
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func isRunningInput(_ obj: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr && v != 0
    }

    private static func pidOf(_ obj: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid) == noErr ? pid : -1
    }
}
