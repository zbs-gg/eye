import Foundation
import Observation

struct RecordingMaintenanceDrain: Sendable, Equatable {
    let lease: RecordingMaintenanceLease
    let capture: CaptureDrainAcknowledgement
    let audio: AudioDrainAcknowledgement
}

private struct RecordingHardwareDrain: Sendable, Equatable {
    let capture: CaptureDrainAcknowledgement
    let audio: AudioDrainAcknowledgement
}

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

    private(set) var lastAudioAt: Date?
    private(set) var lowDiskPaused = false
    /// Recording didn't start due to permissions — the reason for the UI (instead of a false "Recording").
    private(set) var blockedReason: String?
    /// Temporary privacy pause ("don't record for 15 minutes"): the recording desire is KEPT, the autostart watcher
    /// doesn't resume until it expires. nil = no pause active.
    private(set) var pausedUntil: Date?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceAdmission = RecordingMaintenanceAdmission()
    @ObservationIgnored private var activeDrain: Task<RecordingHardwareDrain, Never>?
    @ObservationIgnored private var lowDiskLease: RecordingMaintenanceLease?
    @ObservationIgnored private var drainGeneration: UInt64 = 0
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let pausedKey = "zbseye.recording.pausedUntil"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // The pause survives restart/crash: otherwise a relaunch would silently resume recording in the middle
        // of "don't record for 15 minutes" — breaking the privacy promise.
        if let saved = defaults.object(forKey: Self.pausedKey) as? Date {
            if saved > Date() {
                pausedUntil = saved
                let remain = saved.timeIntervalSinceNow
                resumeTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(remain))
                    guard !Task.isCancelled, let self else { return }
                    self.clearPrivacyPauseAndNotify()
                    self.healthController?.setSuspension(
                        nil,
                        nowMs: Self.epochMs()
                    )
                    self.startIfWanted()
                }
            } else {
                defaults.removeObject(forKey: Self.pausedKey)
            }
        }
    }

    private func clearPause() {
        pausedUntil = nil
        defaults.removeObject(forKey: Self.pausedKey)
    }

    private func clearPrivacyPauseAndNotify() {
        let wasPaused = pausedUntil != nil
        clearPause()
        if wasPaused { onPrivacyPauseEnded() }
    }

    @ObservationIgnored var coordinator: CaptureCoordinator?
    @ObservationIgnored var audio: AudioCoordinator?
    @ObservationIgnored var healthController: CaptureHealthController? {
        didSet {
            publishCaptureIntent()
            if pausedUntil != nil {
                healthController?.setSuspension(
                    .privacy,
                    nowMs: Self.epochMs()
                )
            }
        }
    }
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
    /// A temporary privacy gate has reopened, either by timeout, Resume now, or an explicit
    /// recording restart. AppEnvironment uses this exact boundary to re-arm a still-live mic owner.
    @ObservationIgnored var onPrivacyPauseEnded: @MainActor () -> Void = {}
    /// Closes automatic Call admission synchronously with the first maintenance lease. This edge
    /// must be latched before any drain can suspend, otherwise a close-and-reopen wholly inside an
    /// asynchronous Call start could be missed.
    @ObservationIgnored var onMaintenanceAdmissionClosed: @MainActor () -> Void = {}

    @ObservationIgnored private static let enabledKey = "zbseye.recording.enabled"

    /// User's desire (persisted): was "Recording" on at the last exit.
    var wantsRecording: Bool { defaults.bool(forKey: Self.enabledKey) }
    var maintenancePermitsStart: Bool { maintenanceAdmission.permitsStart }

    func toggle() {
        // A low-disk pause still lets the user change intent. First click disarms
        // auto-resume; a later click can arm it without starting capture early.
        if lowDiskPaused {
            if wantsRecording {
                setRecordingIntent(false)
                blockedReason = nil
            } else {
                setRecordingIntent(true)
                blockedReason = String(localized: "Low disk space — recording will resume after storage recovers")
            }
            return
        }
        // Each maintenance owner retains its own lease. User actions and
        // permission observers cannot reopen capture while any lease remains.
        // Intent changes still win: Stop during relocation/repair/quit must
        // disarm the later automatic resume instead of becoming a no-op.
        guard maintenanceAdmission.permitsStart else {
            let nextIntent = !wantsRecording
            setRecordingIntent(nextIntent)
            if !nextIntent { blockedReason = nil }
            return
        }
        guard let coordinator else {
            // bootstrap is still running — the button must not be a silent no-op: we remember/clear the intent,
            // the autostart watcher will finish the start after initialization.
            if wantsRecording {
                setRecordingIntent(false)
                blockedReason = nil
            } else {
                setRecordingIntent(true)
                blockedReason = "ZBS Eye is still starting up — recording will turn on automatically"
            }
            return
        }
        if isCapturing {
            coordinator.stop()
            audio?.stop()
            onSessionStop()
            isCapturing = false
            setRecordingIntent(false)
        } else {
            // a manual turn-on clears the temporary pause (the user changed their mind about waiting)
            resumeTask?.cancel(); resumeTask = nil
            clearPrivacyPauseAndNotify()
            guard canCapture() else {
                // Honest INTENT toggle: the first click arms it (recording will start itself after permissions
                // are granted — we say so), a second click DISARMS it (otherwise it can't be canceled).
                if wantsRecording {
                    setRecordingIntent(false)
                    blockedReason = nil
                } else {
                    setRecordingIntent(true)
                    blockedReason = blockedHint()
                }
                return
            }
            blockedReason = nil
            coordinator.start()
            audio?.start(mic: micEnabled(), system: systemEnabled())
            isCapturing = true
            setRecordingIntent(true)
        }
    }

    /// Explicit refusal (onboarding "Later" while the intent is armed): stop and disarm.
    func disarm() {
        guard maintenanceAdmission.permitsStart else { return }
        if isCapturing { toggle() }
        else {
            setRecordingIntent(false)
            blockedReason = nil
        }
    }

    /// Stop for maintenance (storage migration): silence the capture, but do NOT touch the intent
    /// (enabledKey) or the pause — after restart autostart will resume. Guarantees that during the data
    /// copy to the new root nobody writes to the old one.
    @discardableResult
    func pauseForMaintenance(
        owner: RecordingMaintenanceOwner
    ) -> RecordingMaintenanceLease {
        let lease = acquireMaintenanceLease(owner)
        guard isCapturing, let coordinator else { return lease }
        coordinator.stop()
        audio?.stop()
        onSessionStop()
        isCapturing = false
        return lease
    }

    /// Strong relocation pause. Both admission paths stop and acknowledge all
    /// boundary writes; the persisted recording intent remains untouched.
    func pauseForMaintenanceAndDrain(
        owner: RecordingMaintenanceOwner,
        waitForTranscription: Bool = true,
        systemCaptureTimeout: Duration? = nil
    ) async -> RecordingMaintenanceDrain {
        let lease = acquireMaintenanceLease(owner)
        return await pauseForMaintenanceAndDrain(
            lease: lease,
            waitForTranscription: waitForTranscription,
            systemCaptureTimeout: systemCaptureTimeout
        )
    }

    func acquireMaintenanceLease(
        _ owner: RecordingMaintenanceOwner
    ) -> RecordingMaintenanceLease {
        let wasOpen = maintenanceAdmission.permitsStart
        let lease = maintenanceAdmission.acquire(owner)
        if wasOpen { onMaintenanceAdmissionClosed() }
        return lease
    }

    func pauseForMaintenanceAndDrain(
        lease: RecordingMaintenanceLease,
        waitForTranscription: Bool = true,
        systemCaptureTimeout: Duration? = nil
    ) async -> RecordingMaintenanceDrain {
        precondition(
            maintenanceAdmission.contains(lease),
            "maintenance drain requires a live lease from this recording store"
        )
        if isCapturing {
            onSessionStop()
            isCapturing = false
        }
        return await stopAndDrain(
            lease: lease,
            waitForTranscription: waitForTranscription,
            systemCaptureTimeout: systemCaptureTimeout
        )
    }

    /// Disk pressure is a pause, not a user stop. Close every capture leg and
    /// await its boundary writes while preserving the persisted recording intent.
    func pauseForLowDiskAndDrain(
        systemCaptureTimeout: Duration? = nil
    ) async -> RecordingMaintenanceDrain {
        lowDiskPaused = true
        let lease: RecordingMaintenanceLease
        if let lowDiskLease {
            lease = lowDiskLease
        } else {
            lease = maintenanceAdmission.acquire(.lowDisk)
            lowDiskLease = lease
        }
        if isCapturing {
            isCapturing = false
        }
        return await stopAndDrain(
            lease: lease,
            waitForTranscription: false,
            systemCaptureTimeout: systemCaptureTimeout
        )
    }

    /// Relocation, termination, and low-disk transitions may arrive while a
    /// previous stop is awaiting hardware. Join that exact drain so no caller
    /// publishes a boundary acknowledgement before the in-flight write ends.
    private func stopAndDrain(
        lease: RecordingMaintenanceLease,
        waitForTranscription: Bool,
        systemCaptureTimeout: Duration?
    ) async -> RecordingMaintenanceDrain {
        if let activeDrain {
            let joined = await activeDrain.value
            guard waitForTranscription, !joined.audio.transcriptionDrained else {
                return RecordingMaintenanceDrain(
                    lease: lease,
                    capture: joined.capture,
                    audio: joined.audio
                )
            }
            // The joined hardware task is complete. Clear its published handle
            // before the stronger maintenance caller starts a transcription drain.
            self.activeDrain = nil
            return await stopAndDrain(
                lease: lease,
                waitForTranscription: true,
                systemCaptureTimeout: systemCaptureTimeout
            )
        }

        let coordinator = self.coordinator
        let audio = self.audio
        let captureTask = Task { @MainActor in
            guard let coordinator else {
                return CaptureDrainAcknowledgement(
                    hadActiveCapture: false,
                    hadInFlightCycle: false,
                    activeCycles: 0
                )
            }
            return await coordinator.stopAndDrain()
        }
        let audioTask = Task { @MainActor in
            guard let audio else {
                return AudioDrainAcknowledgement(
                    hadActiveAudio: false,
                    activeLegs: 0,
                    transcriptionDrained: true,
                    systemCaptureOutcome: .notNeeded
                )
            }
            return await audio.stopAndDrain(
                waitForTranscription: waitForTranscription,
                systemCaptureTimeout: systemCaptureTimeout
            )
        }
        drainGeneration &+= 1
        let generation = drainGeneration
        let drain = Task { @MainActor in
            RecordingHardwareDrain(
                capture: await captureTask.value,
                audio: await audioTask.value
            )
        }
        activeDrain = drain
        let result = await drain.value
        if drainGeneration == generation { activeDrain = nil }
        return RecordingMaintenanceDrain(
            lease: lease,
            capture: result.capture,
            audio: result.audio
        )
    }

    /// Autostart from bootstrap (and after permissions are granted): if the user wanted recording and has permissions — turn it on.
    /// A temporary pause blocks autostart until it expires (the resume task will clear pausedUntil).
    func startIfWanted() {
        guard maintenanceAdmission.permitsStart else { return }
        guard !lowDiskPaused else { return }
        guard pausedUntil == nil else { return }
        guard wantsRecording, !isCapturing, canCapture() else { return }
        toggle()
    }

    /// Privacy pause from the menubar: stop recording for N minutes, then resume itself.
    /// We don't touch the recording desire (enabledKey) — this is a pause, not a turn-off.
    func pauseFor(minutes: Int) {
        if isCapturing {
            coordinator?.stop()
            audio?.stop()
            onSessionStop()
            isCapturing = false
        }
        let until = Date().addingTimeInterval(Double(minutes) * 60)
        pausedUntil = until
        defaults.set(until, forKey: Self.pausedKey)
        healthController?.setSuspension(.privacy, nowMs: Self.epochMs())
        // remember the window so a retroactive importer (browser history) never backfills it
        PrivacyPauseLog.record(startMs: Int64(Date().timeIntervalSince1970 * 1000),
                               endMs: Int64(until.timeIntervalSince1970 * 1000))
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled, let self else { return }
            self.clearPrivacyPauseAndNotify()
            self.healthController?.setSuspension(nil, nowMs: Self.epochMs())
            self.startIfWanted()
        }
    }

    /// Clear the pause early (the "Resume now" button).
    func resumeNow() {
        resumeTask?.cancel(); resumeTask = nil
        PrivacyPauseLog.closeLast(atMs: Int64(Date().timeIntervalSince1970 * 1000))
        clearPrivacyPauseAndNotify()
        healthController?.setSuspension(nil, nowMs: Self.epochMs())
        startIfWanted()
    }

    /// Apply an audio-settings change on the fly (called from Settings if recording is active).
    func syncAudio() {
        guard maintenanceAdmission.permitsStart else { return }
        guard !lowDiskPaused else { return }
        guard isCapturing, let audio else { return }
        let m = micEnabled(), s = systemEnabled()
        publishCaptureIntent()
        audio.reconfigure(mic: m, system: s)
    }

    func noteFrame() { screenFrameCount += 1 }
    func noteAudioChunk() { audioChunkCount += 1; lastAudioAt = Date() }
    func setLowDisk(_ paused: Bool) {
        lowDiskPaused = paused
    }

    func resumeAfterLowDisk() {
        guard lowDiskPaused else { return }
        lowDiskPaused = false
        if let lowDiskLease {
            _ = maintenanceAdmission.release(lowDiskLease)
            self.lowDiskLease = nil
        }
        if blockedReason == String(localized: "Low disk space — recording will resume after storage recovers") {
            blockedReason = nil
        }
        startIfWanted()
    }

    func resumeAfterMaintenance(_ lease: RecordingMaintenanceLease) {
        guard maintenanceAdmission.release(lease) else { return }
        startIfWanted()
    }

    /// Completes a leg-scoped repair while the repair admission lease still
    /// owns restart. A Stop pressed during an asynchronous drain changes the
    /// persisted intent immediately; that newer intent wins before the lease
    /// is released, so repair can never resurrect capture behind the user.
    func completeCaptureRepair(
        _ lease: RecordingMaintenanceLease,
        screenWasDrained: Bool,
        drainSucceeded: Bool
    ) {
        guard maintenanceAdmission.contains(lease) else { return }

        if !wantsRecording {
            coordinator?.stop()
            audio?.stop()
            if isCapturing { onSessionStop() }
            isCapturing = false
            blockedReason = nil
        } else if screenWasDrained, drainSucceeded, isCapturing {
            coordinator?.start()
        } else if screenWasDrained, !drainSucceeded {
            coordinator?.stop()
            audio?.stop()
            if isCapturing { onSessionStop() }
            isCapturing = false
            blockedReason = String(localized: "Capture repair could not safely finish — retry repair")
        }

        guard maintenanceAdmission.release(lease) else { return }
        if drainSucceeded { startIfWanted() }
    }

    private func setRecordingIntent(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        publishCaptureIntent()
    }

    private func publishCaptureIntent() {
        let enabled = wantsRecording
        healthController?.setIntent(
            CaptureIntent(
                screenEnabled: enabled,
                systemAudioEnabled: enabled && systemEnabled()
            ),
            nowMs: Int64(Date().timeIntervalSince1970 * 1_000)
        )
    }

    nonisolated private static func epochMs(_ date: Date = Date()) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }
}
