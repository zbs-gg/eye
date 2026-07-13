import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ZBS Eye").font(.headline)

            // Glanceable one-liner: how much memory + the current streak.
            if let s = env.progress?.snapshot, s.totalFrames > 0 {
                let moments = NumberFormatter.localizedString(from: NSNumber(value: s.totalFrames), number: .decimal)
                // Drop the streak clause on a gap day — "0-day streak" reads as a bug, not a status.
                if s.streakDays > 0 {
                    Text("\(moments) moments · \(s.streakDays)-day streak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(moments) moments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            RecordingStatusView()

            if env.recording.lowDiskPaused {
                // Low disk isn't a dead end: give a way straight to storage settings.
                Button {
                    env.selectedSection = .settings
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    StatusPill(text: "Low disk — manage storage", color: .orange,
                               system: "externaldrive.badge.exclamationmark")
                }
                .buttonStyle(.plain)
            }

            if !env.permissions.allCriticalGranted {
                // Clickable pill: from the menubar straight to permission setup, not a dead end.
                Button {
                    env.selectedSection = .settings
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    StatusPill(text: "Permissions needed — set up", color: .orange, system: "lock.shield")
                }
                .buttonStyle(.plain)
            }

            Divider()

            Button(recordingButtonTitle) {
                env.recording.toggle()
            }
            if env.recording.isCapturing {
                // privacy micro-pause: «something sensitive is coming — don't record for 15 minutes»
                Button("Don't record for 15 minutes") { env.recording.pauseFor(minutes: 15) }
                // manual audio override — force ON/OFF at any moment (wins over the mode for this session)
                if env.audioSettings.audioMode != .off {
                    Button(audioOverrideTitle) {
                        env.audioSettings.cycleManualOverride()
                        env.recording.syncAudio()
                    }
                }
            }
            if let until = env.recording.pausedUntil {
                Text("Resumes at \(until.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Resume now") { env.recording.resumeNow() }
            }
            Button("Open ZBS Eye") { openWindow(id: "main") }
            Button("Something not working?") {
                env.showSelfRepair = true
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Quit ZBS Eye") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
        // Throttled so opening the menu never triggers a full screen_captures scan every time — the
        // glance line reuses the cached snapshot (Pro perf #3). The menu opens instantly.
        .task { await env.progress?.refreshThrottled() }
    }

    private var audioOverrideTitle: String {
        switch env.audioSettings.manualAudioOverride {
        case nil: "Force audio on"
        case .some(true): "Audio forced on — tap to force off"
        case .some(false): "Audio forced off — tap for auto"
        }
    }

    private var recordingButtonTitle: String {
        if env.recording.lowDiskPaused, env.recording.wantsRecording {
            return String(localized: "Stop recording")
        }
        return env.recording.isCapturing
            ? String(localized: "Pause")
            : String(localized: "Start recording")
    }
}
