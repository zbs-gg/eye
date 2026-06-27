import SwiftUI
import AppKit

// MARK: — badge (asset image, otherwise a fallback squircle with an SF Symbol)

struct AchievementBadgeView: View {
    let achievement: Achievement
    let unlocked: Bool
    var size: CGFloat = 104

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    private var hasAsset: Bool { NSImage(named: achievement.badge) != nil }
    /// Phase scatter by id — the badges shimmer out of sync rather than in unison.
    private var phaseDelay: Double { Double(abs(achievement.id.hashValue) % 1000) / 1000.0 * 3.0 }

    var body: some View {
        VStack(spacing: max(4, size * 0.06)) {
            ZStack {
                // The badge itself — large, with no backing plate (the medallion already has its own shape, transparent background).
                badgeArt
                    .frame(width: size, height: size)
                    .saturation(unlocked ? 1 : 0)
                    .opacity(unlocked ? 1 : 0.4)
                    // soft glow in the tier color
                    .shadow(color: unlocked ? achievement.tint.color.opacity(0.55) : .clear, radius: size * 0.13)
                    .overlay { if unlocked { shimmer } }       // shimmer on top, masked to the badge

                if !unlocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: size * 0.22, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.7), radius: 3)
                }
            }
            .frame(width: size, height: size)

            if achievement.tierStars > 0 {
                HStack(spacing: size * 0.025) {
                    ForEach(0..<5, id: \.self) { i in
                        Image(systemName: i < achievement.tierStars ? "star.fill" : "star")
                            .font(.system(size: size * 0.082))
                            .foregroundStyle(i < achievement.tierStars
                                ? (unlocked ? achievement.tint.color : Color.gray.opacity(0.5))
                                : Color.gray.opacity(0.22))
                    }
                }
            }
        }
        .onAppear {
            guard unlocked, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: false).delay(phaseDelay)) {
                sweep = true
            }
        }
    }

    @ViewBuilder private var badgeArt: some View {
        if hasAsset {
            Image(achievement.badge).resizable().scaledToFit()
        } else {
            fallback
        }
    }

    /// Holographic shimmer: a diagonal light band sweeping across the badge, masked to its shape.
    @ViewBuilder private var shimmer: some View {
        let band = LinearGradient(
            colors: [.clear, .white.opacity(0.0), .white.opacity(0.45), .white.opacity(0.0), .clear],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        GeometryReader { geo in
            Rectangle().fill(band)
                .frame(width: geo.size.width * 0.55)
                .rotationEffect(.degrees(22))
                .offset(x: sweep ? geo.size.width * 1.25 : -geo.size.width * 1.25)
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
        // the band is visible only on the badge's pixels (not on the transparent background/square)
        .mask(badgeArt.frame(width: size, height: size))
    }

    /// Fallback badge (until the asset is cut): squircle + SF Symbol in the tier color.
    private var fallback: some View {
        let r = size * 0.235
        return ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.04)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(LinearGradient(colors: [achievement.tint.color.opacity(0.7), Color(white: 0.2)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: size * 0.025)
            Image(systemName: Self.fallbackSymbol(achievement.badge))
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(achievement.tint.color)
                .shadow(color: achievement.tint.color.opacity(0.7), radius: size * 0.08)
        }
        .frame(width: size * 0.94, height: size * 0.94)
    }

    static func fallbackSymbol(_ badge: String) -> String {
        // by family prefix (badge_<family>_<i>) / special achievement
        if badge.hasPrefix("badge_frames") { return "sparkles" }
        if badge.hasPrefix("badge_age") { return "tree.fill" }
        if badge.hasPrefix("badge_streak") { return "flame.fill" }
        if badge.hasPrefix("badge_days") { return "circle.circle.fill" }
        if badge.hasPrefix("badge_carto") { return "eye.fill" }
        if badge.hasPrefix("badge_activities") { return "photo.stack.fill" }
        if badge.hasPrefix("badge_atlas") { return "globe" }
        if badge.hasPrefix("badge_constellation") { return "sparkles" }
        if badge.hasPrefix("badge_domains") { return "point.3.connected.trianglepath.dotted" }
        if badge.hasPrefix("badge_deep") { return "water.waves" }
        if badge.hasPrefix("badge_burst") { return "gauge.high" }
        if badge.hasPrefix("badge_switch") { return "tornado" }
        if badge.hasPrefix("badge_searches") { return "magnifyingglass" }
        if badge.hasPrefix("badge_questions") { return "bubble.left.and.bubble.right.fill" }
        if badge.hasPrefix("badge_night") { return "moon.stars.fill" }
        if badge.hasPrefix("badge_early") { return "sunrise.fill" }
        if badge.hasPrefix("badge_weekend") { return "theatermasks.fill" }
        if badge.hasPrefix("badge_focus") { return "target" }
        if badge.hasPrefix("badge_clean") { return "wind" }
        if badge.hasPrefix("badge_relocate") { return "externaldrive.fill" }
        if badge.hasPrefix("badge_guard") { return "icloud.fill" }
        return "rosette.fill"
    }
}

// MARK: — achievements gallery

struct AchievementsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let store = env.achievements {
                AchievementsGallery(store: store)
            } else if let err = env.dataError {
                ContentUnavailableView {
                    Label("Memory unavailable", systemImage: "exclamationmark.triangle.fill")
                } description: { Text(err) }
            } else {
                ContentUnavailableView("Initializing…", systemImage: "rosette")
            }
        }
        .navigationTitle("Achievements")
    }
}

private struct AchievementsGallery: View {
    let store: AchievementStore
    @State private var selected: Achievement?

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 168), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                progressHeader
                ForEach(AchievementCatalog.categories, id: \.self) { cat in
                    let items = store.catalog.filter { $0.category == cat }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(cat).font(.headline)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                                ForEach(items) { a in cell(a) }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await store.refresh() }
        .sheet(item: $selected) { a in detailSheet(a) }
    }

    private var progressHeader: some View {
        let frac = store.totalCount > 0 ? Double(store.unlockedCount) / Double(store.totalCount) : 0
        return VStack(alignment: .leading, spacing: 10) {
            Text("Achievements").font(.largeTitle.bold())
            HStack {
                Text("\(store.unlockedCount) of \(store.totalCount) unlocked")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(frac * 100))%").font(.callout.bold()).monospacedDigit()
            }
            ProgressView(value: frac)
                .tint(.accentColor)
        }
    }

    private func cell(_ a: Achievement) -> some View {
        let unlocked = store.isUnlocked(a)
        let hidden = a.secret && !unlocked
        return Button {
            selected = a
        } label: {
            VStack(spacing: 8) {
                AchievementBadgeView(achievement: a, unlocked: unlocked, size: 116)
                Text(hidden ? "???" : a.title)
                    .font(.caption).multilineTextAlignment(.center)
                    .foregroundStyle(unlocked ? .primary : .secondary)
                    .lineLimit(2).frame(height: 30)
                if unlocked, let d = store.unlockedDate(a.id) {
                    Text(d.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2).foregroundStyle(a.tint.color.opacity(0.9))
                } else if !hidden {
                    Text(" ").font(.caption2)   // height alignment
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func detailSheet(_ a: Achievement) -> some View {
        let unlocked = store.isUnlocked(a)
        let hidden = a.secret && !unlocked
        return VStack(spacing: 18) {
            AchievementBadgeView(achievement: a, unlocked: unlocked, size: 160)
                .padding(.top, 10)
            Text(hidden ? "Secret achievement" : a.title).font(.title2.bold())
            Text(hidden ? "Unlock it — and you'll find out what it's for." : a.detail)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if unlocked, let d = store.unlockedDate(a.id) {
                Label("Unlocked \(d.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(a.tint.color)
            } else {
                Label("Still locked", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Close") { selected = nil }.keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 360)
    }
}
