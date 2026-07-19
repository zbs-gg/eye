import SwiftUI

struct WorkspaceHeader: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                primaryModes
                timelineRepresentation
                Spacer(minLength: 12)
                recordingControls
                featureMenu
                settingsButton
            }
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    primaryModes
                    timelineRepresentation
                    Spacer(minLength: 8)
                    featureMenu
                    settingsButton
                }
                HStack(spacing: 12) {
                    recordingControls
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory workspace")
    }

    private var primaryModes: some View {
        Picker("Memory", selection: modeBinding) {
            Label("Timeline", systemImage: "clock.arrow.circlepath")
                .tag(WorkspaceMode.timeline)
            Label("Calls", systemImage: "phone.badge.waveform")
                .tag(WorkspaceMode.calls)
            Label("Ask", systemImage: "questionmark.bubble")
                .tag(WorkspaceMode.ask)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 340)
        .accessibilityLabel("Memory mode")
    }

    @ViewBuilder
    private var timelineRepresentation: some View {
        if env.workspace.mode == .timeline {
            Menu {
                Button {
                    env.workspace.showTimeline(representation: .moments)
                } label: {
                    Label("Moments", systemImage: "rectangle.stack")
                }
                Button {
                    env.workspace.showActivities()
                } label: {
                    Label("Activities", systemImage: "calendar.day.timeline.left")
                }
            } label: {
                Label(
                    env.workspace.timelineRepresentation == .moments ? "Moments" : "Activities",
                    systemImage: env.workspace.timelineRepresentation == .moments
                        ? "rectangle.stack"
                        : "calendar.day.timeline.left"
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var recordingControls: some View {
        HStack(spacing: 10) {
            RecordingStatusView(compact: true)
                .fixedSize(horizontal: true, vertical: false)
            Button {
                env.recording.toggle()
            } label: {
                Label(recordingButtonTitle, systemImage: recordingButtonIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(env.recording.isCapturing ? .red : .accentColor)
        }
    }

    private var featureMenu: some View {
        Menu {
            featureButton(.insights, title: "Daily Insights", systemImage: "map")
            featureButton(.automations, title: "Automations", systemImage: "powerplug")
            featureButton(.progress, title: "Progress", systemImage: "chart.bar.fill")
            Divider()
            featureButton(.achievements, title: "Achievements", systemImage: "rosette")
            featureButton(.appearance, title: "Appearance", systemImage: "paintpalette")
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var settingsButton: some View {
        Button {
            env.workspace.present(.settings)
        } label: {
            Label("Settings", systemImage: "gearshape")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Settings")
    }

    private var modeBinding: Binding<WorkspaceMode> {
        Binding(
            get: { env.workspace.mode },
            set: { mode in
                switch mode {
                case .timeline: env.workspace.showTimeline()
                case .calls: env.workspace.openCalls()
                case .ask: env.workspace.openAsk()
                }
            }
        )
    }

    private func featureButton(
        _ feature: WorkspaceFeature,
        title: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        Button {
            env.workspace.present(feature)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private var recordingButtonTitle: LocalizedStringKey {
        if env.recording.lowDiskPaused, env.recording.wantsRecording {
            return "Stop"
        }
        return env.recording.isCapturing ? "Stop" : "Record"
    }

    private var recordingButtonIcon: String {
        env.recording.isCapturing ? "stop.circle.fill" : "record.circle"
    }
}
