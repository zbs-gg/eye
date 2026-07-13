import SwiftUI

struct MemoryWorkspaceView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader()
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
