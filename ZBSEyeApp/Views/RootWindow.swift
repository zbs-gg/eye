import SwiftUI

struct RootWindow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        MemoryWorkspaceView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Self-repair sheet lives below the workspace — a different presenter than onboarding.
            // Two `.sheet(isPresented:)` on the same view collide and only one ever presents.
            .sheet(isPresented: $env.showSelfRepair) {
                SelfRepairView(onClose: { env.showSelfRepair = false }).environment(env)
            }
            .frame(minWidth: 720, minHeight: 560)
        /* Global overlays stay above the workspace so feature presentation
           cannot hide a milestone or achievement unlock. */
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { env.showSelfRepair = true } label: {
                    Label("Something wrong?", systemImage: "wrench.and.screwdriver")
                }
                .help("Something not working? Describe it and have your own agent fix it — or file a GitHub issue.")
            }
        }
        .background(ThemeAuraView(theme: env.rewards.theme).ignoresSafeArea())   // theme aura background
        .background { AISetupSheetHost().environment(env) }
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
