import SwiftUI

/// Pop-up reward when an achievement unlocks: badge + title + glow in the tier color.
/// Reduce Motion is respected. Auto-dismisses after 3.5s + on tap.
struct AchievementUnlockOverlay: View {
    let achievement: Achievement
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appear = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Achievement unlocked")
                .font(.caption.weight(.bold)).textCase(.uppercase).tracking(1.6)
                .foregroundStyle(achievement.tint.color)          // tier accent — high contrast
            AchievementBadgeView(achievement: achievement, unlocked: true, size: 132)
                .scaleEffect(appear ? 1 : 0.55)
                .rotationEffect(.degrees(appear || reduceMotion ? 0 : -8))
            Text(LocalizedStringKey(achievement.title)).font(.title2.bold()).multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Text(LocalizedStringKey(achievement.detail)).font(.callout)
                .foregroundStyle(.white.opacity(0.82)).multilineTextAlignment(.center)   // not gray
            if let reward = achievement.reward.label {
                Label("\(reward) — in “Appearance”", systemImage: "gift.fill")
                    .font(.caption.bold()).foregroundStyle(achievement.tint.color)
                    .padding(.top, 2)
            }
        }
        .padding(28)
        .frame(maxWidth: 340)
        // dark opaque panel — always readable over any (bright) photo on the timeline
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.11), Color(white: 0.04)],
                                         startPoint: .top, endPoint: .bottom).opacity(0.96))
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(achievement.tint.color.opacity(0.10))    // light tier wash
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(achievement.tint.color.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        .shadow(color: achievement.tint.color.opacity(0.4), radius: 34)
        .scaleEffect(appear ? 1 : 0.9)
        .opacity(appear ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .none : .spring(response: 0.55, dampingFraction: 0.68)) {
                appear = true
            }
            Task {
                try? await Task.sleep(for: .seconds(3.5))
                onDismiss()
            }
        }
        .onTapGesture { onDismiss() }
    }
}
