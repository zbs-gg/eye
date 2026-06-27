import SwiftUI

/// First run: consent ("ZBS Eye records everything — locally") + granting permissions with live status.
/// Without onboarding the user landed in an empty Timeline, hit "Record", got a false green dot and zero
/// frames — the first experience was a silent failure. Permissions are refreshed by PermissionsStore's background polling.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 480)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: welcome
        default: permissions
        }
    }

    // MARK: step 1 — what it is and consent

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 40)).foregroundStyle(.tint)
                Text("ZBS Eye — your Mac's perfect memory").font(.title2.bold())
            }
            Text("ZBS Eye continuously records your work on the computer so any moment can be found and replayed:")
                .font(.callout)
            VStack(alignment: .leading, spacing: 10) {
                bullet("display", "Your screen and its text — every app, window, tab")
                bullet("mic", "Microphone — your voice (if you enable it)")
                bullet("speaker.wave.2", "System audio — calls, meetings, video (if you enable it)")
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Everything stays on this Mac: no cloud, accounts, or subscriptions.",
                      systemImage: "lock.shield.fill").font(.callout).bold()
                Text("History is kept for 7 days or up to 20 GB (configurable). Recording other people in calls is "
                     + "your responsibility: macOS shows them no indicator.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.tint)
            Text(text).font(.callout)
        }
    }

    // MARK: step 2 — permissions with live status

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.title2.bold())
            Text("Statuses update on their own — grant a permission and come back.")
                .font(.callout).foregroundStyle(.secondary)

            permissionStep(
                title: "Screen Recording", required: true,
                status: env.permissions.snapshot.screenRecording,
                request: { PermissionChecker.requestScreenRecording() },
                settingsPane: "Privacy_ScreenCapture")
            if env.permissions.snapshot.screenRecording == .needsRestart {
                Label("Permission granted — ZBS Eye needs a restart (that's how macOS works).",
                      systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange)
                Button("Restart ZBS Eye") { AppRelauncher.relaunch() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            permissionStep(
                title: "Accessibility (text from the screen)", required: true,
                status: env.permissions.snapshot.accessibility,
                request: { PermissionChecker.requestAccessibility() },
                settingsPane: "Privacy_Accessibility")
            permissionStep(
                title: "Microphone (voice recording)", required: false,
                status: env.permissions.snapshot.microphone,
                request: { Task { await env.permissions.requestMicrophone() } },
                settingsPane: "Privacy_Microphone")
            permissionStep(
                title: "Speech Recognition (search across calls)", required: false,
                status: env.permissions.snapshot.speech,
                request: { Task { await env.permissions.requestSpeech() } },
                settingsPane: "Privacy_SpeechRecognition")

            Spacer()
            if env.permissions.allCriticalGranted {
                Label("Ready — you can start recording.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout.bold())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionStep(title: String, required: Bool, status: PermissionStatus,
                                request: @escaping () -> Void, settingsPane: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(status == .granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                if !required { Text("optional").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            switch status {
            case .granted:
                EmptyView()
            case .notDetermined:
                Button("Request", action: request).controlSize(.small).buttonStyle(.borderedProminent)
            case .denied, .needsRestart:
                Button("Open Settings") { PermissionChecker.openSettings(settingsPane) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            if step == 0 {
                Button("Continue") { step = 1 }.buttonStyle(.borderedProminent)
            } else {
                // You can close even without permissions (onboarding isn't a cage), but we only start recording when granted.
                Button(env.permissions.allCriticalGranted ? "Start recording" : "Later") {
                    env.completeOnboarding(startRecording: env.permissions.allCriticalGranted)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}
