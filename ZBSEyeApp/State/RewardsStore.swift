import SwiftUI
import AppKit
import Observation

/// Оформление-награды: выбранная тема / альт-иконка приложения / значок меню-бара. Что РАЗБЛОКИРОВАНО —
/// выводится из открытых достижений (reward в каталоге). Выбор персистится. @MainActor @Observable.
@MainActor
@Observable
final class RewardsStore {
    var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }
    /// Имя ассета альт-иконки приложения; "" = дефолтная (из AppIcon).
    var appIconAsset: String {
        didSet {
            UserDefaults.standard.set(appIconAsset, forKey: Self.iconKey)
            applyAppIcon()
        }
    }
    /// SF-символ значка меню-бара «в покое».
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

    /// Применить выбранную иконку приложения к dock (на старте и при смене). nil → дефолтная.
    func applyAppIcon() {
        if appIconAsset.isEmpty {
            NSApp.applicationIconImage = nil
        } else if let img = NSImage(named: appIconAsset) {
            NSApp.applicationIconImage = img
        }
    }

    // MARK: — что разблокировано (из достижений)

    func isThemeUnlocked(_ t: AppTheme) -> Bool { t == .standard || rewardUnlocked(.theme(t)) }
    func isAppIconUnlocked(_ asset: String) -> Bool { asset.isEmpty || rewardUnlocked(.appIcon(asset)) }
    func isMenuBarUnlocked(_ sym: String) -> Bool { sym == "waveform" || rewardUnlocked(.menuBarIcon(sym)) }

    /// Достижение, чьё открытие даёт этот reward (для подсказки «откроется за X»).
    func unlockingAchievement(for r: AchievementReward) -> Achievement? {
        AchievementCatalog.all.first { $0.reward == r }
    }

    private func rewardUnlocked(_ r: AchievementReward) -> Bool {
        guard let ach = achievements else { return false }
        return AchievementCatalog.all.contains { $0.reward == r && ach.isUnlocked($0) }
    }
}
