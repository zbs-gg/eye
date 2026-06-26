import SwiftUI

/// Тонкая аврора-анимация на достижении вехи.
/// Уважает Reduce Motion: при включённом — простой fade без градиентного перелива.
/// Показывается поверх всего окна через .overlay в RootWindow; dismisses сам через 3с.
struct MilestoneCelebrationOverlay: View {
    let milestone: Int
    let onDismiss: () -> Void

    @State private var phase: Double = 0
    @State private var opacity: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var prettyNumber: String {
        NumberFormatter.localizedString(from: NSNumber(value: milestone), number: .decimal)
    }

    var body: some View {
        ZStack {
            if reduceMotion {
                // Accessibility: simple translucent backdrop
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.85)
            } else {
                // Aurora gradient wave
                SwiftUI.TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    auroraGradient(t: t)
                }
            }

            VStack(spacing: 12) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .white.opacity(0.6), radius: 12)
                Text("\(prettyNumber) моментов")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                Text("всё — здесь, только для тебя")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(32)
        }
        .frame(maxWidth: 340, maxHeight: 200)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 40, x: 0, y: 12)
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeIn(duration: 0.4)) { opacity = 1 }
            // Auto-dismiss after 3s
            Task {
                try? await Task.sleep(for: .seconds(3.2))
                withAnimation(.easeOut(duration: 0.5)) { opacity = 0 }
                try? await Task.sleep(for: .seconds(0.5))
                onDismiss()
            }
        }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.3)) { opacity = 0 }
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                onDismiss()
            }
        }
    }

    @ViewBuilder
    private func auroraGradient(t: TimeInterval) -> some View {
        let phase1 = t * 0.4
        let phase2 = t * 0.31 + 1.7
        let phase3 = t * 0.22 + 3.4

        ZStack {
            // Base deep background
            LinearGradient(
                colors: [Color(hue: 0.72, saturation: 0.7, brightness: 0.18),
                         Color(hue: 0.62, saturation: 0.6, brightness: 0.14)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            // Aurora layer 1 — slow violet sweep
            EllipticalGradient(
                colors: [Color(hue: 0.75, saturation: 0.9, brightness: 0.7).opacity(0.55), .clear],
                center: UnitPoint(x: 0.3 + 0.25 * sin(phase1), y: 0.4 + 0.15 * cos(phase1)),
                endRadiusFraction: 0.65
            )

            // Aurora layer 2 — teal accent
            EllipticalGradient(
                colors: [Color(hue: 0.52, saturation: 0.8, brightness: 0.65).opacity(0.45), .clear],
                center: UnitPoint(x: 0.65 + 0.2 * cos(phase2), y: 0.55 + 0.2 * sin(phase2)),
                endRadiusFraction: 0.55
            )

            // Aurora layer 3 — pink shimmer
            EllipticalGradient(
                colors: [Color(hue: 0.87, saturation: 0.7, brightness: 0.75).opacity(0.35), .clear],
                center: UnitPoint(x: 0.5 + 0.3 * sin(phase3), y: 0.3 + 0.25 * cos(phase3 * 0.8)),
                endRadiusFraction: 0.45
            )

            // Holographic sheen — thin diagonal stripe
            LinearGradient(
                colors: [.white.opacity(0.0), .white.opacity(0.12), .white.opacity(0.0)],
                startPoint: UnitPoint(x: -0.3 + 0.3 * sin(t * 0.18), y: 0),
                endPoint: UnitPoint(x: 0.7 + 0.3 * sin(t * 0.18), y: 1)
            )
        }
    }
}
