import SwiftUI
import AppKit

// MARK: — аура-фон темы (мягкие дрейфующие цветовые пятна)

struct ThemeAuraView: View {
    let theme: AppTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Double = 0

    var body: some View {
        GeometryReader { geo in
            if theme.hasAura {
                ZStack {
                    ForEach(Array(theme.auraColors.enumerated()), id: \.offset) { pair in
                        blob(geo: geo, index: pair.offset, color: pair.element)
                    }
                }
                .blur(radius: 95)
                .opacity(theme.auraOpacity)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.linear(duration: 36).repeatForever(autoreverses: false)) {
                        phase = .pi * 2
                    }
                }
            } else {
                Color.clear
            }
        }
    }

    private func blob(geo: GeometryProxy, index: Int, color: Color) -> some View {
        let a = phase + Double(index) * 2.1
        let x = geo.size.width * (0.5 + 0.28 * cos(a))
        let y = geo.size.height * (0.5 + 0.30 * sin(a * 1.13))
        let d = geo.size.width * 0.95
        return Circle().fill(color).frame(width: d, height: d).position(x: x, y: y)
    }
}

// MARK: — раздел «Оформление»

struct AppearanceView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var rewards = env.rewards
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Оформление").font(.largeTitle.bold())
                Text("Награды за достижения. Открывай ачивки — и здесь появляются темы, иконки приложения "
                     + "и значки меню-бара.")
                    .font(.callout).foregroundStyle(.secondary)

                themesSection(rewards)
                appIconsSection(rewards)
                menuBarSection(rewards)
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Оформление")
    }

    // ── темы ──
    private func themesSection(_ rewards: RewardsStore) -> some View {
        section("Тема") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)],
                      alignment: .leading, spacing: 14) {
                ForEach(AppTheme.allCases) { t in
                    let unlocked = rewards.isThemeUnlocked(t)
                    themeCard(t, selected: rewards.theme == t, unlocked: unlocked,
                              lockHint: lockHint(.theme(t), rewards))
                        .onTapGesture { if unlocked { rewards.theme = t } }
                }
            }
        }
    }

    private func themeCard(_ t: AppTheme, selected: Bool, unlocked: Bool, lockHint: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: t.hasAura ? t.auraColors : [Color(white: 0.15), Color(white: 0.08)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 76)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                        selected ? t.accent : .white.opacity(0.12), lineWidth: selected ? 2.5 : 1))
                Circle().fill(t.accent).frame(width: 18, height: 18).padding(8)
                if !unlocked {
                    RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.55))
                    Image(systemName: "lock.fill").foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text(t.title).font(.callout.weight(selected ? .semibold : .regular))
            if let lockHint { Text(lockHint).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .contentShape(Rectangle())
    }

    // ── иконки приложения ──
    private func appIconsSection(_ rewards: RewardsStore) -> some View {
        section("Иконка приложения") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 14)],
                      alignment: .leading, spacing: 14) {
                ForEach(RewardCatalog.appIcons, id: \.asset) { item in
                    let unlocked = rewards.isAppIconUnlocked(item.asset)
                    iconCard(asset: item.asset, title: item.title,
                             selected: rewards.appIconAsset == item.asset, unlocked: unlocked,
                             lockHint: lockHint(.appIcon(item.asset), rewards))
                        .onTapGesture { if unlocked { rewards.appIconAsset = item.asset } }
                }
            }
        }
    }

    private func iconCard(asset: String, title: String, selected: Bool, unlocked: Bool, lockHint: String?) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if asset.isEmpty {
                    Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                        .resizable().scaledToFit()
                } else if NSImage(named: asset) != nil {
                    Image(asset).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.1))
                        .overlay(Image(systemName: "eye.fill").foregroundStyle(.secondary))
                }
                if !unlocked {
                    RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.55))
                    Image(systemName: "lock.fill").foregroundStyle(.white.opacity(0.8))
                }
                if selected {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(env.rewards.theme.accent, lineWidth: 3)
                }
            }
            .frame(width: 72, height: 72)
            .saturation(unlocked ? 1 : 0.2)
            Text(title).font(.caption).foregroundStyle(unlocked ? .primary : .secondary).lineLimit(1)
            if let lockHint { Text(lockHint).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(width: 110)
        .contentShape(Rectangle())
    }

    // ── меню-бар ──
    private func menuBarSection(_ rewards: RewardsStore) -> some View {
        section("Значок в меню-баре") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80, maximum: 110), spacing: 12)],
                      alignment: .leading, spacing: 12) {
                ForEach(RewardCatalog.menuBarIcons, id: \.symbol) { item in
                    let unlocked = rewards.isMenuBarUnlocked(item.symbol)
                    VStack(spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(rewards.menuBarIcon == item.symbol ? env.rewards.theme.accent.opacity(0.25) : Color(white: 0.12))
                                .frame(width: 56, height: 56)
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                                    rewards.menuBarIcon == item.symbol ? env.rewards.theme.accent : .clear, lineWidth: 2))
                            Image(systemName: item.symbol).font(.title2)
                                .foregroundStyle(unlocked ? .primary : .secondary)
                            if !unlocked {
                                RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.5)).frame(width: 56, height: 56)
                                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        Text(item.title).font(.caption2).foregroundStyle(unlocked ? .primary : .secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if unlocked { rewards.menuBarIcon = item.symbol } }
                }
            }
        }
    }

    // ── helpers ──
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
    }

    private func lockHint(_ reward: AchievementReward, _ rewards: RewardsStore) -> String? {
        // подсказка только для закрытых
        switch reward {
        case .theme(let t) where rewards.isThemeUnlocked(t): return nil
        case .appIcon(let a) where rewards.isAppIconUnlocked(a): return nil
        case .menuBarIcon(let m) where rewards.isMenuBarUnlocked(m): return nil
        default: break
        }
        guard let ach = rewards.unlockingAchievement(for: reward) else { return nil }
        return "Откроется: «\(ach.title)»"
    }
}
