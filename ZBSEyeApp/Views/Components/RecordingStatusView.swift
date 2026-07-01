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
            if env.recording.isCapturing {
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
                    sourceRow(active: systemOn, warn: systemWanted && !systemOn, icon: "speaker.wave.2",
                              text: systemOn ? "System audio" : "System audio didn't start")
                }
                audioModeRow
                if let degraded = env.recording.degradedReason {
                    Label(degraded, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(2)
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
        }
    }

    /// The "Screen" row: warn by the cycle HEARTBEAT (not by the last frame — a static screen is deduped for
    /// hours and that's healthy) and by needsRestart. The warning is visible in compact too (color/icon).
    private func screenRow(now: Date) -> some View {
        let needsRestart = env.permissions.screenNeedsRestart
        // nil = the first cycle hasn't passed yet (the first seconds after start) — don't scare for nothing
        let stale = staleSeconds(now: now).map { $0 > 90 } ?? false
        let warn = needsRestart || stale
        let text: String
        if needsRestart {
            text = "Screen: needs restart"
        } else if stale {
            text = "Screen: capture is silent"
        } else {
            text = "Screen" + frameAgeSuffix(now: now)
        }
        return sourceRow(active: !warn, warn: warn, icon: "display", text: text)
    }

    private var micOn: Bool { env.audio?.micRunning ?? false }
    private var systemOn: Bool { env.audio?.systemRunning ?? false }
    private var micWanted: Bool { env.recording.micEnabled() }
    private var systemWanted: Bool { env.recording.systemEnabled() }

    /// How many seconds the heartbeat has been silent (nil = there hasn't been a single cycle yet).
    private func staleSeconds(now: Date) -> Int? {
        env.recording.lastCycleOKAt.map { Int(now.timeIntervalSince($0)) }
    }

    private func frameAgeSuffix(now: Date) -> String {
        guard !compact, let t = env.recording.lastFrameAt else { return "" }
        let s = Int(now.timeIntervalSince(t))
        return s < 120 ? " · frame \(s)s ago" : ""   // an old frame ≠ a failure (dedup) — don't scare
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
