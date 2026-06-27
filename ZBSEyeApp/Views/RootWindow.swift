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
                case .timeline:     TimelineView()
                case .activities:   ActivitiesView()
                case .ask:          AskView()
                case .cartographer: CartographerView()
                case .automations:  AutomationsView()
                case .connections:  ConnectionsView()
                case .progress:     MemoryProgressView()
                case .achievements: AchievementsView()
                case .appearance:   AppearanceView()
                case .settings:     SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(ThemeAuraView(theme: env.rewards.theme).ignoresSafeArea())   // theme aura background
        .tint(env.rewards.theme.accent)                                          // accent for the whole UI
        .animation(.easeInOut(duration: 0.5), value: env.rewards.theme)
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
        .overlay(alignment: .center) {
            if let unlock = env.achievements?.pendingUnlock {
                AchievementUnlockOverlay(achievement: unlock) {
                    env.achievements?.clearPendingUnlock()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .animation(.spring(duration: 0.45), value: unlock.id)
                .zIndex(110)
            }
        }
        .sheet(isPresented: $env.showOnboarding) {
            OnboardingView()
                .environment(env)
                .interactiveDismissDisabled()   // dismiss only via buttons (there's a "Later" inside)
        }
    }
}
