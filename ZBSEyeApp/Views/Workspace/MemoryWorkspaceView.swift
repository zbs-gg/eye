import SwiftUI

struct MemoryWorkspaceView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader()
            if let banner = env.automaticCallBanner {
                AutomaticCallBannerView(state: banner)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let feature = env.workspace.presentedFeature {
            NavigationStack {
                secondaryFeature(feature)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                env.workspace.dismissFeature()
                            } label: {
                                Label("Back to memory", systemImage: "chevron.backward")
                            }
                        }
                    }
            }
        } else {
            switch env.workspace.mode {
            case .timeline:
                switch env.workspace.timelineRepresentation {
                case .moments:
                    TimelineView()
                case .activities:
                    ActivitiesView { moment in
                        env.workspace.returnToTimeline(moment: moment)
                    }
                }
            case .calls:
                if let store = env.callsLibrary {
                    CallsLibraryView(store: store)
                } else if let err = env.dataError {
                    ContentUnavailableView(
                        "Calls unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(err)
                    )
                } else {
                    ProgressView("Initializing calls…")
                }
            case .ask:
                AskView()
            }
        }
    }

    @ViewBuilder
    private func secondaryFeature(_ feature: WorkspaceFeature) -> some View {
        switch feature {
        case .insights:
            CartographerView()
        case .automations:
            AutomationsView()
        case .progress:
            MemoryProgressView()
        case .achievements:
            AchievementsView()
        case .appearance:
            AppearanceView()
        case .settings:
            SettingsView()
        }
    }
}

private struct AutomaticCallBannerView: View {
    @Environment(AppEnvironment.self) private var env
    let state: AutomaticCallBannerState

    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            switch state.phase {
            case .started, .endingGrace:
                Button("Not a call", role: .destructive) {
                    env.rejectDetectedCall()
                }
                .help("Stop and permanently remove only this automatically detected call")
            case .endedUndo:
                Button("Undo") { env.undoDetectedCallEnd() }
                    .buttonStyle(.borderedProminent)
                    .help("Resume the same call without losing its end boundary")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var title: LocalizedStringKey {
        switch state.phase {
        case .started: "Call recording started"
        case .endingGrace: "Call may have ended"
        case .endedUndo: "Call ended automatically"
        }
    }

    private var detail: LocalizedStringKey? {
        switch state.phase {
        case .started: "Eye found call controls and microphone use."
        case .endingGrace: "Waiting 30 seconds for the call to resume."
        case .endedUndo: "Undo is available for 15 seconds. Recording is not split."
        }
    }

    private var icon: String {
        switch state.phase {
        case .started: "phone.badge.waveform"
        case .endingGrace: "timer"
        case .endedUndo: "checkmark.circle"
        }
    }

    private var tint: Color {
        switch state.phase {
        case .started: .green
        case .endingGrace, .endedUndo: .orange
        }
    }
}
