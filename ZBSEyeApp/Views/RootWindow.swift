import SwiftUI

struct RootWindow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        NavigationSplitView {
            SidebarView(selection: $env.selectedSection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch env.selectedSection {
                case .timeline:    TimelineView()
                case .activities:  ActivitiesView()
                case .ask:         AskView()
                case .automations:       AutomationsView()
                case .connections: ConnectionsView()
                case .progress:    MemoryProgressView()
                case .settings:    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
        .overlay(alignment: .center) {
            if let milestone = env.progress?.pendingCelebration {
                MilestoneCelebrationOverlay(milestone: milestone) {
                    env.progress?.clearCelebration()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .animation(.spring(duration: 0.4), value: milestone)
                .zIndex(100)
            }
        }
        .sheet(isPresented: $env.showOnboarding) {
            OnboardingView()
                .environment(env)
                .interactiveDismissDisabled()   // закрытие — только кнопками (внутри есть «Позже»)
        }
    }
}
