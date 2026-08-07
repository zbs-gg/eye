import SwiftUI

struct MemoryWorkspaceView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader()
            if let banner = env.automaticCallBanner {
                AutomaticCallBannerView(
                    state: banner,
                    rejectionInProgress: env.automaticCallRejectionInProgress,
                    onEndAndSave: { env.endDetectedCallAndSave() },
                    onReject: { env.rejectDetectedCall() },
                    onNeverAutoRecord: { target in
                        env.neverAutoRecordDetectedApp(target)
                    }
                )
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
