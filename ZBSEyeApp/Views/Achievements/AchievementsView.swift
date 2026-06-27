import SwiftUI
import AppKit

// MARK: — бейдж (картинка-из-ассета, иначе fallback-squircle с SF-символом)

struct AchievementBadgeView: View {
    let achievement: Achievement
    let unlocked: Bool
    var size: CGFloat = 104

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    private var hasAsset: Bool { NSImage(named: achievement.badge) != nil }
    /// Разнобой фазы по id — бейджи переливаются не в унисон.
    private var phaseDelay: Double { Double(abs(achievement.id.hashValue) % 1000) / 1000.0 * 3.0 }

    var body: some View {
        VStack(spacing: max(4, size * 0.06)) {
            ZStack {
                // Сам бейдж — крупно, без подложки (медальон уже своей формы, фон прозрачный).
                badgeArt
                    .frame(width: size, height: size)
                    .saturation(unlocked ? 1 : 0)
                    .opacity(unlocked ? 1 : 0.4)
                    // мягкое свечение в цвете тира
                    .shadow(color: unlocked ? achievement.tint.color.opacity(0.55) : .clear, radius: size * 0.13)
                    .overlay { if unlocked { shimmer } }       // перелив поверх, маскирован по бейджу

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

    /// Голографический перелив: диагональная световая полоса, бегущая по бейджу, маскированная его формой.
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
        // полоса видна только на пикселях бейджа (не на прозрачном фоне/квадрате)
        .mask(badgeArt.frame(width: size, height: size))
    }

    /// Запасной бейдж (пока ассет не нарезан): squircle + SF-символ в цвете тира.
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
        switch badge {
        case "badge_star": return "star.fill"
        case "badge_trophy": return "trophy.fill"
        case "badge_flame": return "flame.fill"
        case "badge_calendar": return "calendar"
        case "badge_stopwatch": return "stopwatch.fill"
        case "badge_owl": return "moon.stars.fill"
        case "badge_sunrise": return "sunrise.fill"
        case "badge_ghost": return "theatermasks.fill"
        case "badge_apps": return "square.grid.3x3.fill"
        case "badge_tabs": return "rectangle.stack.fill"
        case "badge_spiral": return "tornado"
        case "badge_target": return "target"
        case "badge_anchor": return "anchor"
        case "badge_bubble": return "bubble.left.fill"
        case "badge_magnifier": return "magnifyingglass"
        case "badge_brain": return "brain.head.profile"
        case "badge_timeline": return "calendar.day.timeline.left"
        case "badge_broom": return "wind"
        case "badge_drive": return "externaldrive.fill"
        case "badge_cloud": return "icloud.fill"
        default: return "rosette.fill"
        }
    }
}

// MARK: — галерея достижений

struct AchievementsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let store = env.achievements {
                AchievementsGallery(store: store)
            } else if let err = env.dataError {
                ContentUnavailableView {
                    Label("Память недоступна", systemImage: "exclamationmark.triangle.fill")
                } description: { Text(err) }
            } else {
                ContentUnavailableView("Инициализация…", systemImage: "rosette")
            }
        }
        .navigationTitle("Достижения")
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
                ForEach(AchievementCategory.allCases) { cat in
                    let items = store.catalog.filter { $0.category == cat }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(cat.rawValue).font(.headline)
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
            Text("Достижения").font(.largeTitle.bold())
            HStack {
                Text("\(store.unlockedCount) из \(store.totalCount) открыто")
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
                    Text(" ").font(.caption2)   // выравнивание высоты
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
            Text(hidden ? "Секретное достижение" : a.title).font(.title2.bold())
            Text(hidden ? "Открой его — и узнаешь, за что." : a.detail)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if unlocked, let d = store.unlockedDate(a.id) {
                Label("Открыто \(d.formatted(date: .abbreviated, time: .omitted))", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(a.tint.color)
            } else {
                Label("Ещё закрыто", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Закрыть") { selected = nil }.keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 360)
    }
}
