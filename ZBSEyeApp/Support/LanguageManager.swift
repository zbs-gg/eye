import Foundation

/// In-app language override, independent of the system language. We store our own preference; on every
/// launch (very early in main, before any UI or localized-string access) we push it into `AppleLanguages`
/// so the main bundle resolves the right localization. Changing the language relaunches the app
/// (Foundation caches the chosen localization at startup, so a restart is the reliable way to apply it).
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, en, ru
    var id: String { rawValue }
}

enum LanguageManager {
    static let key = "zbseye.language"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Call FIRST in `main()`, before any UI / localized string is read. Pushes our preference into
    /// `AppleLanguages` (or clears the override for `.system`).
    static func applyAtLaunch() {
        let d = UserDefaults.standard
        switch current {
        case .system:
            d.removeObject(forKey: "AppleLanguages")
        case .en, .ru:
            d.set([current.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Persist a new language and relaunch so the bundle loads its localization on the next launch.
    @MainActor static func set(_ lang: AppLanguage) {
        UserDefaults.standard.set(lang.rawValue, forKey: key)
        applyAtLaunch()
        AppRelauncher.relaunch()
    }
}
