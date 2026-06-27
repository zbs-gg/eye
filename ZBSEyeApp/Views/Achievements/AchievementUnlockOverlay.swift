import SwiftUI

/// Всплывающая награда при открытии достижения: бейдж + название + свечение в цвете тира.
/// Reduce Motion уважается. Авто-дисмисс через 3.5с + тап.
struct AchievementUnlockOverlay: View {
    let achievement: Achievement
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appear = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Достижение открыто")
                .font(.caption).textCase(.uppercase).tracking(1.5)
                .foregroundStyle(.secondary)
            AchievementBadgeView(achievement: achievement, unlocked: true, size: 132)
                .scaleEffect(appear ? 1 : 0.55)
                .rotationEffect(.degrees(appear || reduceMotion ? 0 : -8))
            Text(achievement.title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(achievement.detail).font(.callout)
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let reward = achievement.reward.label {
                Label("\(reward) — в «Оформлении»", systemImage: "gift.fill")
                    .font(.caption.bold()).foregroundStyle(achievement.tint.color)
                    .padding(.top, 2)
            }
        }
        .padding(28)
        .frame(maxWidth: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(achievement.tint.color.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: achievement.tint.color.opacity(0.45), radius: 34)
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
