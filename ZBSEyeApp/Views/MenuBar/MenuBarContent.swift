import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ZBS Eye").font(.headline)

            RecordingStatusView()

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

            Button(env.recording.isCapturing ? "Pause" : "Start recording") {
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

            Divider()

            Button("Quit ZBS Eye") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 260)
    }

    private var audioOverrideTitle: String {
        switch env.audioSettings.manualAudioOverride {
        case nil: "Force audio on"
        case .some(true): "Audio forced on — tap to force off"
        case .some(false): "Audio forced off — tap for auto"
        }
    }
}
