import Foundation
import Observation

/// Recording state. Delegates start/stop to CaptureCoordinator (set from AppEnvironment.bootstrap).
/// The "recording on" desire is persisted — after a reboot/crash bootstrap resumes recording itself
/// (forever memory must not depend on a manual click). isCapturing doesn't lie: without critical permissions
/// recording doesn't start, and instead of a false green dot — blockedReason.
@MainActor
@Observable
final class RecordingStore {
    private(set) var isCapturing = false
    private(set) var screenFrameCount = 0
    private(set) var audioChunkCount = 0

    // Health for the indicators (menubar/sidebar): the product must show WHAT is actually being recorded.
    private(set) var lastFrameAt: Date?
    /// Capture-cycle heartbeat: a successful pass (including dedup and deliberate idle-skip). Separate from
    /// lastFrameAt — a static screen gets deduped for hours, that is NOT "capture died" (anti-false-alarm).
    private(set) var lastCycleOKAt: Date?
    private(set) var lastAudioAt: Date?
    private(set) var lowDiskPaused = false
    /// Recording didn't start due to permissions — the reason for the UI (instead of a false "Recording").
    private(set) var blockedReason: String?
    /// Recording is on but degraded (permissions revoked mid-run, etc.) — shown WHEN isCapturing.
    private(set) var degradedReason: String?
    /// Temporary privacy pause ("don't record for 15 minutes"): the recording desire is KEPT, the autostart watcher
    /// doesn't resume until it expires. nil = no pause active.
    private(set) var pausedUntil: Date?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private static let pausedKey = "zbseye.recording.pausedUntil"

    init() {
        // The pause survives restart/crash: otherwise a relaunch would silently resume recording in the middle
        // of "don't record for 15 minutes" — breaking the privacy promise.
        if let saved = UserDefaults.standard.object(forKey: Self.pausedKey) as? Date {
            if saved > Date() {
                pausedUntil = saved
                let remain = saved.timeIntervalSinceNow
                resumeTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(remain))
                    guard !Task.isCancelled, let self else { return }
                    self.clearPause()
                    self.startIfWanted()
                }
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pausedKey)
            }
        }
    }

    private func clearPause() {
        pausedUntil = nil
        UserDefaults.standard.removeObject(forKey: Self.pausedKey)
    }

    @ObservationIgnored var coordinator: CaptureCoordinator?
    @ObservationIgnored var audio: AudioCoordinator?
    /// Gates (set from AppEnvironment): critical recording permissions; mic/system audio.
    @ObservationIgnored var canCapture: @MainActor () -> Bool = { false }
    /// Why recording is unavailable (needsRestart vs denied — different texts; set by AppEnvironment).
    @ObservationIgnored var blockedHint: @MainActor () -> String = {
        "No permissions (Screen Recording + Accessibility). Recording will turn on automatically once granted; click again to cancel"
    }
    @ObservationIgnored var micEnabled: @MainActor () -> Bool = { false }
    @ObservationIgnored var systemEnabled: @MainActor () -> Bool = { false }
    /// Called when recording truly stops/pauses (NOT on syncAudio re-sync) — clears the session-scoped
    /// manual audio override. Set from AppEnvironment.
    @ObservationIgnored var onSessionStop: @MainActor () -> Void = {}

    @ObservationIgnored private static let enabledKey = "zbseye.recording.enabled"

    /// User's desire (persisted): was "Recording" on at the last exit.
    var wantsRecording: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func toggle() {
        guard let coordinator else {
            // bootstrap is still running — the button must not be a silent no-op: we remember/clear the intent,
            // the autostart watcher will finish the start after initialization.
            if wantsRecording {
                UserDefaults.standard.set(false, forKey: Self.enabledKey)
                blockedReason = nil
            } else {
                UserDefaults.standard.set(true, forKey: Self.enabledKey)
                blockedReason = "ZBS Eye is still starting up — recording will turn on automatically"
            }
            return
        }
        if isCapturing {
            coordinator.stop()
            audio?.stop()
            onSessionStop()
            isCapturing = false
            degradedReason = nil
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
        } else {
            // a manual turn-on clears the temporary pause (the user changed their mind about waiting)
            resumeTask?.cancel(); resumeTask = nil
            clearPause()
            guard canCapture() else {
                // Honest INTENT toggle: the first click arms it (recording will start itself after permissions
                // are granted — we say so), a second click DISARMS it (otherwise it can't be canceled).
                if wantsRecording {
                    UserDefaults.standard.set(false, forKey: Self.enabledKey)
                    blockedReason = nil
                } else {
                    UserDefaults.standard.set(true, forKey: Self.enabledKey)
                    blockedReason = blockedHint()
                }
                return
            }
            blockedReason = nil
            coordinator.start()
            audio?.start(mic: micEnabled(), system: systemEnabled())
            isCapturing = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
    }

    /// Explicit refusal (onboarding "Later" while the intent is armed): stop and disarm.
    func disarm() {
        if isCapturing { toggle() }
        else {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            blockedReason = nil
        }
    }

    /// Stop for maintenance (storage migration): silence the capture, but do NOT touch the intent
    /// (enabledKey) or the pause — after restart autostart will resume. Guarantees that during the data
    /// copy to the new root nobody writes to the old one.
    func pauseForMaintenance() {
        guard isCapturing, let coordinator else { return }
        coordinator.stop()
        audio?.stop()
        onSessionStop()
        isCapturing = false
        degradedReason = nil
    }

    /// Autostart from bootstrap (and after permissions are granted): if the user wanted recording and has permissions — turn it on.
    /// A temporary pause blocks autostart until it expires (the resume task will clear pausedUntil).
    func startIfWanted() {
        guard pausedUntil == nil else { return }
        guard wantsRecording, !isCapturing, canCapture() else { return }
        toggle()
    }

    /// Privacy pause from the menubar: stop recording for N minutes, then resume itself.
    /// We don't touch the recording desire (enabledKey) — this is a pause, not a turn-off.
    func pauseFor(minutes: Int) {
        guard isCapturing, let coordinator else { return }
        coordinator.stop()
        audio?.stop()
        onSessionStop()
        isCapturing = false
        degradedReason = nil
        let until = Date().addingTimeInterval(Double(minutes) * 60)
        pausedUntil = until
        UserDefaults.standard.set(until, forKey: Self.pausedKey)
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled, let self else { return }
            self.clearPause()
            self.startIfWanted()
        }
    }

    /// Clear the pause early (the "Resume now" button).
    func resumeNow() {
        resumeTask?.cancel(); resumeTask = nil
        clearPause()
        startIfWanted()
    }

    /// Apply an audio-settings change on the fly (called from Settings if recording is active).
    func syncAudio() {
        guard isCapturing, let audio else { return }
        audio.stop()
        let m = micEnabled(), s = systemEnabled()
        if m || s { audio.start(mic: m, system: s) }
    }

    func noteFrame() { screenFrameCount += 1; lastFrameAt = Date(); lastCycleOKAt = Date() }
    func noteCycleOK() { lastCycleOKAt = Date() }
    func noteAudioChunk() { audioChunkCount += 1; lastAudioAt = Date() }
    func setLowDisk(_ paused: Bool) { lowDiskPaused = paused }
    func setDegraded(_ reason: String?) { if degradedReason != reason { degradedReason = reason } }
}
