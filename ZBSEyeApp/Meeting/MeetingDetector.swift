import Foundation
import CoreAudio
import AppKit   // NSRunningApplication
import Darwin   // proc_pidinfo — resolve a helper/renderer pid up to its owning app

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
    /// Bundle-id PREFIXES of apps that hold the mic only during an actual call. Prefixes (not exact ids)
    /// so audio helper/XPC processes — e.g. "us.zoom.helper", "com.tinyspeck.slack.helper2" — still match
    /// once we resolve them to their owning app.
    static let meetingPrefixes: [String] = [
        "us.zoom",                 // Zoom (+ helpers)
        "com.microsoft.teams",     // Teams classic + new (teams2)
        "com.apple.FaceTime",      // FaceTime
        "com.hnc.Discord",         // Discord
        "com.tinyspeck.slack",     // Slack (+ helpers)
        "com.cisco.webex",         // Webex
        "com.webex",               // Webex (older)
        "com.skype",               // Skype
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
            guard let bid = owningBundleId(for: pid) else { continue }
            if meetingPrefixes.contains(where: { bid.hasPrefix($0) }) { return true }
        }
        return false
    }

    /// Bundle id of the app that OWNS `pid`, walking up the parent chain — a mic-holding process is often
    /// an audio helper/renderer whose own bundle id is nil; its owning app is what we match against.
    @MainActor
    private static func owningBundleId(for pid: pid_t) -> String? {
        var p = pid
        for _ in 0..<5 {
            if let b = NSRunningApplication(processIdentifier: p)?.bundleIdentifier { return b }
            let parent = parentPid(of: p)
            if parent <= 1 || parent == p { break }
            p = parent
        }
        return nil
    }

    private static func parentPid(of pid: pid_t) -> pid_t {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let r = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
        return r == size ? pid_t(info.pbsi_ppid) : -1
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
