import SwiftUI
import AppKit
import Observation

/// Cosmetic rewards: selected theme / alt app icon / menu-bar icon. What's UNLOCKED is
/// derived from earned achievements (the reward in the catalog). The choice persists. @MainActor @Observable.
@MainActor
@Observable
final class RewardsStore {
    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }
    /// Alt app icon asset name; "" = default (from AppIcon).
    var appIconAsset: String {
        didSet {
            UserDefaults.standard.set(appIconAsset, forKey: Self.iconKey)
            applyAppIcon()
        }
    }
    /// SF Symbol for the menu-bar icon "at rest".
    var menuBarIcon: String {
        didSet { UserDefaults.standard.set(menuBarIcon, forKey: Self.menuKey) }
    }

    @ObservationIgnored weak var achievements: AchievementStore?

    private static let themeKey = "zbseye.reward.theme"
    private static let iconKey  = "zbseye.reward.appIcon"
    private static let menuKey  = "zbseye.reward.menuBarIcon"

    init() {
        theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: Self.themeKey) ?? "") ?? .standard
        appIconAsset = UserDefaults.standard.string(forKey: Self.iconKey) ?? ""
        menuBarIcon = UserDefaults.standard.string(forKey: Self.menuKey) ?? "waveform"
    }

    /// Apply the selected app icon to the dock (on launch and on change). nil → default.
    func applyAppIcon() {
        if appIconAsset.isEmpty {
            NSApp.applicationIconImage = nil
        } else if let img = NSImage(named: appIconAsset) {
            NSApp.applicationIconImage = img
        }
    }

    // MARK: — what's unlocked (from achievements)

    func isThemeUnlocked(_ t: AppTheme) -> Bool { t == .standard || rewardUnlocked(.theme(t)) }
    func isAppIconUnlocked(_ asset: String) -> Bool { asset.isEmpty || rewardUnlocked(.appIcon(asset)) }
    func isMenuBarUnlocked(_ sym: String) -> Bool { sym == "waveform" || rewardUnlocked(.menuBarIcon(sym)) }

    /// The achievement whose unlock grants this reward (for the "unlocks at X" hint).
    func unlockingAchievement(for r: AchievementReward) -> Achievement? {
        AchievementCatalog.all.first { $0.reward == r }
    }

    private func rewardUnlocked(_ r: AchievementReward) -> Bool {
        guard let ach = achievements else { return false }
        return AchievementCatalog.all.contains { $0.reward == r && ach.isUnlocked($0) }
    }
}
