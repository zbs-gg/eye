import SwiftUI

/// Honest per-source recording status (screen / microphone / system audio) — shared by the menu bar and sidebar.
/// A recorder product has no right to show a single green dot "all good" when half the sources are dead:
/// a false green dot = holes in the "eternal memory" discovered a week later.
/// Wrapped in SwiftUI.TimelineView (1s) — the frame age and staleness are live, not a frozen Date() in the body.
struct RecordingStatusView: View {
    @Environment(AppEnvironment.self) private var env
    var compact = false

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            statusBody(now: context.date)
        }
    }

    @ViewBuilder
    private func statusBody(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CallControlView(compact: compact)
            if env.calls.isActive {
                callSourceRows
                if env.recording.isCapturing {
                    screenRow(now: now)
                } else {
                    sourceRow(
                        active: false,
                        warn: false,
                        icon: "display",
                        text: String(localized: "Screen: off")
                    )
                }
            } else if env.recording.isCapturing {
                screenRow(now: now)
                if env.recording.lowDiskPaused {
                    sourceRow(active: false, warn: true, icon: "externaldrive.badge.exclamationmark",
                              text: "Low disk space — capture paused")
                }
                if micWanted || micOn {
                    sourceRow(active: micOn, warn: micWanted && !micOn, icon: "mic",
                              text: micOn ? "Microphone" : "Microphone didn't start")
                }
                if systemWanted || systemOn {
                    systemAudioRow
                }
                audioModeRow
                if CaptureRepairPresentation(snapshot: env.captureHealth).state == .repairRequired {
                    Button("Repair Capture") {
                        Task { await env.repairCapture() }
                    }
                    .font(.caption)
                }
            } else if env.recording.lowDiskPaused {
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text("Low disk space — capture paused")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else if let until = env.recording.pausedUntil {
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                HStack(spacing: 6) {
                    Circle().fill(Color.secondary).frame(width: 8, height: 8)
                    Text("Paused").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let reason = env.recording.blockedReason, !env.recording.isCapturing {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
                    .lineLimit(3)
            }
            if let error = env.calls.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private var callSourceRows: some View {
        let snapshot = env.calls.snapshot
        let meState = liveCallState(snapshot.me, engineRunning: env.audio?.micRunning == true)
        let systemState = liveCallState(snapshot.system, engineRunning: env.audio?.systemRunning == true)
        sourceRow(
            active: meState == .recording,
            warn: meState == .unavailable || meState == .gap,
            icon: "mic",
            text: callSourceText(.me, state: meState)
        )
        sourceRow(
            active: systemState == .recording,
            warn: systemState == .unavailable || systemState == .gap,
            icon: "speaker.wave.2",
            text: callSourceText(.system, state: systemState)
        )
        if snapshot.bookmarkCount > 0 {
            sourceRow(
                active: true,
                warn: false,
                icon: "bookmark",
                text: "\(snapshot.bookmarkCount) bookmarks saved"
            )
        }
    }

    private func callSourceText(_ source: CallAudioSource, state: CallSourceState) -> String {
        switch (source, state) {
        case (.me, .recording): String(localized: "Microphone")
        case (.me, .disabled): String(localized: "Microphone: off")
        case (.me, .unavailable): String(localized: "Microphone: unavailable")
        case (.me, .gap): String(localized: "Microphone: gap recorded")
        case (.system, .recording): String(localized: "System audio")
        case (.system, .disabled): String(localized: "System audio: off")
        case (.system, .unavailable): String(localized: "System audio: unavailable")
        case (.system, .gap): String(localized: "System audio: gap recorded")
        }
    }

    private func liveCallState(
        _ persisted: CallSourceState,
        engineRunning: Bool
    ) -> CallSourceState {
        if persisted == .disabled || persisted == .gap { return persisted }
        return engineRunning ? .recording : .unavailable
    }

    private func screenRow(now: Date) -> some View {
        _ = now
        let state = env.captureHealth.legs[.screen]?.state ?? .paused
        return sourceRow(
            active: state == .healthy,
            warn: state == .recovering || state == .repairRequired || state == .permissionBlocked,
            icon: "display",
            text: captureLabel(.screen, state: state)
        )
    }

    private var micOn: Bool { env.audio?.micRunning ?? false }
    private var systemOn: Bool { env.audio?.systemRunning ?? false }
    private var micWanted: Bool { env.recording.micEnabled() }
    private var systemWanted: Bool { env.recording.systemEnabled() }
    private var systemState: CaptureLegState {
        env.captureHealth.legs[.systemAudio]?.state ?? .paused
    }

    private var systemAudioRow: some View {
        sourceRow(
            active: systemState == .healthy,
            warn: systemState == .recovering
                || systemState == .repairRequired
                || systemState == .permissionBlocked,
            icon: "speaker.wave.2",
            text: captureLabel(.systemAudio, state: systemState)
        )
    }

    private func captureLabel(_ leg: CaptureLeg, state: CaptureLegState) -> String {
        if leg == .screen, state == .repairRequired {
            return String(localized: "Capture needs repair")
        }
        let source = switch leg {
        case .screen: String(localized: "Screen")
        case .systemAudio: String(localized: "System audio")
        }
        guard state != .healthy else { return source }
        let status = switch state {
        case .healthy: ""
        case .recovering: String(localized: "recovering")
        case .repairRequired: String(localized: "repair needed")
        case .permissionBlocked: String(localized: "permission needed")
        case .suspended: String(localized: "suspended")
        case .paused: String(localized: "off")
        }
        return "\(source): \(status)"
    }

    /// Audio-mode line: what the tri-state / manual override is doing right now. In `.always` the
    /// mic/system rows already tell the story, so this row stays quiet there.
    @ViewBuilder
    private var audioModeRow: some View {
        let mode = env.audioSettings.audioMode
        let override = env.audioSettings.manualAudioOverride
        if let override {
            sourceRow(active: override, warn: false,
                      icon: override ? "waveform" : "speaker.slash",
                      text: override ? "Audio: forced on" : "Audio: forced off")
        } else if mode == .off {
            sourceRow(active: false, warn: false, icon: "speaker.slash", text: "Audio: off")
        } else if mode == .meetingsOnly {
            if env.audioSettings.meetingActive {
                sourceRow(active: true, warn: false, icon: "waveform", text: "Recording this meeting")
            } else {
                sourceRow(active: false, warn: false, icon: "ear", text: "Listening for meetings")
            }
        }
    }

    private func sourceRow(active: Bool, warn: Bool, icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(warn ? Color.orange : (active ? Color.green : Color.secondary))
                .frame(width: 14)
            Text(text).font(.caption)
                .foregroundStyle(warn ? Color.orange : Color.secondary)
        }
    }
}
