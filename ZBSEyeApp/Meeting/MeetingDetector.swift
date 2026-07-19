import Foundation
import CoreAudio
import AppKit   // NSRunningApplication, Accessibility
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
/// Emits typed evidence every two seconds. The pure `CallDetectionPolicy` and automatic lifecycle own
/// confidence, suppression, and the 30-second end grace; this adapter never persists a call by itself.
actor MeetingDetector {
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<CallEvidenceSnapshot>.Continuation?

    /// Start polling (2s) and return the latest bounded evidence snapshot.
    func start() -> AsyncStream<CallEvidenceSnapshot> {
        let (stream, cont) = AsyncStream<CallEvidenceSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation = cont
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
    }

    /// One collection step. `now` is injected so policy tests can remain deterministic.
    func tick(now: Date) async {
        continuation?.yield(await Self.collectEvidence(now: now))
    }

    /// Testing seam: raw (undebounced) detection — is a known meeting app holding the mic right now?
    static func detectRaw() async -> Bool {
        let owner = await MainActor.run { meetingAppHoldingMic() }
        guard let owner else { return false }
        return await NativeCallSurfaceInspector.hasCallControls(pid: owner.pid)
    }

    static func collectEvidence(now: Date) async -> CallEvidenceSnapshot {
        let observedAt = now.timeIntervalSince1970
        guard let owner = await MainActor.run(body: { meetingAppHoldingMic() }) else {
            return CallEvidenceSnapshot(
                now: observedAt,
                microphoneOwnerBundleID: nil,
                surface: nil,
                microphoneAudioActive: false,
                systemAudioActive: false,
                calendarHint: false,
                isStale: false,
                fingerprint: "idle"
            )
        }
        let marker: CallStateMarker? = await NativeCallSurfaceInspector.hasCallControls(pid: owner.pid)
            ? .nativeCallControls
            : nil
        let session = "pid:\(owner.pid)"
        return CallEvidenceSnapshot(
            now: observedAt,
            microphoneOwnerBundleID: owner.bundleID,
            surface: CallSurfaceEvidence(
                kind: .native,
                ownerBundleID: owner.bundleID,
                trustedOrigin: nil,
                marker: marker,
                observedAt: observedAt
            ),
            microphoneAudioActive: true,
            systemAudioActive: false,
            calendarHint: false,
            isStale: false,
            fingerprint: CallDetectorFingerprint.make(
                bundleID: owner.bundleID,
                sessionMarker: session,
                originHost: nil
            )
        )
    }

    // MARK: implementation

    private struct MicrophoneOwner: Sendable {
        let pid: pid_t
        let bundleID: String
    }

    @MainActor
    private static func meetingAppHoldingMic() -> MicrophoneOwner? {
        let mine = ProcessInfo.processInfo.processIdentifier
        for obj in processObjects() where isRunningInput(obj) {
            let pid = pidOf(obj)
            if pid == mine || pid <= 0 { continue }
            guard let bid = owningBundleId(for: pid) else { continue }
            if CallSurfaceCatalog.nativeBundlePrefixes.contains(where: { bid.hasPrefix($0) }) {
                return MicrophoneOwner(pid: pid, bundleID: bid)
            }
        }
        return nil
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

/// A bounded, non-prompting Accessibility probe for an independent native call marker. It runs on a
/// dedicated queue because AX calls may block, and it never copies the discovered labels into logs or DB.
private enum NativeCallSurfaceInspector {
    private static let queue = DispatchQueue(label: "gg.zbs.eye.call-surface-ax", qos: .utility)
    private static let hardMarkers = [
        "end call", "hang up", "leave call", "leave meeting",
        "завершить звонок", "положить трубку", "покинуть звонок", "выйти из конференции",
    ]
    private static let softMarkers = [
        "mute", "unmute", "participants", "camera", "share screen",
        "микрофон", "выключить звук", "участники", "камера", "демонстрация экрана",
    ]

    static func hasCallControls(pid: pid_t) async -> Bool {
        guard AXIsProcessTrusted() else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: inspect(pid: pid))
            }
        }
    }

    private static func inspect(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var pending = [app]
        var index = 0
        var softHits = Set<String>()
        while index < pending.count, index < 500 {
            let element = pending[index]
            index += 1
            let text = searchableText(element)
            if hardMarkers.contains(where: text.contains) { return true }
            for marker in softMarkers where text.contains(marker) { softHits.insert(marker) }
            if softHits.count >= 2 { return true }
            if pending.count < 500 {
                pending.append(contentsOf: children(element).prefix(500 - pending.count))
            }
        }
        return false
    }

    private static func searchableText(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
            .compactMap { stringAttribute($0 as CFString, from: element) }
            .joined(separator: " ")
            .lowercased()
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement]
        else { return [] }
        return children
    }
}
