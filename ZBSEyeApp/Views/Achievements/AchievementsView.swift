import SwiftUI
import AppKit

// MARK: — бейдж (картинка-из-ассета, иначе fallback-squircle с SF-символом)

struct AchievementBadgeView: View {
    let achievement: Achievement
    let unlocked: Bool
    var size: CGFloat = 96

    private var hasAsset: Bool { NSImage(named: achievement.badge) != nil }

    var body: some View {
        VStack(spacing: max(3, size * 0.05)) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                    .fill(LinearGradient(colors: cardColors, startPoint: .top, endPoint: .bottom))
                if hasAsset {
                    Image(achievement.badge).resizable().scaledToFit()
                        .padding(size * 0.02)
                        .saturation(unlocked ? 1 : 0)
                        .opacity(unlocked ? 1 : 0.5)
                } else {
                    fallback
                }
                if !unlocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: size * 0.22, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .shadow(color: .black.opacity(0.6), radius: 3)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .strokeBorder(.white.opacity(unlocked ? 0.10 : 0.04), lineWidth: 1))
            .shadow(color: unlocked ? achievement.tint.color.opacity(0.35) : .clear, radius: size * 0.09)

            if achievement.tierStars > 0 {
                HStack(spacing: size * 0.02) {
                    ForEach(0..<min(5, achievement.tierStars), id: \.self) { _ in
                        Image(systemName: "star.fill").font(.system(size: size * 0.085))
                            .foregroundStyle(unlocked ? achievement.tint.color : Color.gray.opacity(0.4))
                    }
                }
            }
        }
    }

    private var cardColors: [Color] {
        unlocked
            ? [Color(white: 0.14), achievement.tint.color.opacity(0.18), Color(white: 0.06)]
            : [Color(white: 0.12), Color(white: 0.05)]
    }

    /// Запасной бейдж в стиле иконки: тёмный squircle + кант + SF-символ в цвете (пока ассет не нарезан).
    private var fallback: some View {
        let r = size * 0.235
        return ZStack {
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.12), Color(white: 0.03)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.15)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: size * 0.02)
            Image(systemName: Self.fallbackSymbol(achievement.badge))
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(unlocked ? achievement.tint.color : Color(white: 0.4))
                .shadow(color: unlocked ? achievement.tint.color.opacity(0.7) : .clear, radius: size * 0.08)
        }
        .frame(width: size * 0.92, height: size * 0.92)
        .saturation(unlocked ? 1 : 0.2)
        .opacity(unlocked ? 1 : 0.55)
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

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 18)]

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
                AchievementBadgeView(achievement: a, unlocked: unlocked, size: 96)
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
