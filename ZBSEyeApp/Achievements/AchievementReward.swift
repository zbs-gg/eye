import SwiftUI

// MARK: — тема оформления (на всё приложение)

enum AppTheme: String, Sendable, CaseIterable, Identifiable {
    case standard, magical, midnight, gold, neon, frost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Стандарт"
        case .magical:  return "Магия"
        case .midnight: return "Полночь"
        case .gold:     return "Золото"
        case .neon:     return "Неон"
        case .frost:    return "Мороз"
        }
    }

    /// Акцентный цвет (tint всего приложения).
    var accent: Color {
        switch self {
        case .standard: return Color(red: 0.30, green: 0.55, blue: 1.00)
        case .magical:  return Color(red: 0.65, green: 0.45, blue: 1.00)
        case .midnight: return Color(red: 0.40, green: 0.50, blue: 0.95)
        case .gold:     return Color(red: 1.00, green: 0.78, blue: 0.28)
        case .neon:     return Color(red: 1.00, green: 0.30, blue: 0.80)
        case .frost:    return Color(red: 0.55, green: 0.85, blue: 1.00)
        }
    }

    /// Цвета «ауры» — мягкий анимированный фон под контентом. Пусто → без фона (стандарт).
    var auraColors: [Color] {
        switch self {
        case .standard: return []
        case .magical:  return [Color(red: 0.45, green: 0.20, blue: 0.85), Color(red: 0.20, green: 0.55, blue: 0.95), Color(red: 0.80, green: 0.30, blue: 0.75)]
        case .midnight: return [Color(red: 0.06, green: 0.08, blue: 0.22), Color(red: 0.12, green: 0.10, blue: 0.30)]
        case .gold:     return [Color(red: 0.45, green: 0.32, blue: 0.05), Color(red: 0.30, green: 0.22, blue: 0.04)]
        case .neon:     return [Color(red: 0.55, green: 0.05, blue: 0.45), Color(red: 0.10, green: 0.10, blue: 0.40)]
        case .frost:    return [Color(red: 0.10, green: 0.30, blue: 0.45), Color(red: 0.06, green: 0.18, blue: 0.35)]
        }
    }

    var hasAura: Bool { !auraColors.isEmpty }

    /// Сколько ауры подмешивать (магия — заметно, остальные — тоньше).
    var auraOpacity: Double { self == .magical || self == .neon ? 0.32 : 0.20 }
}

// MARK: — награда за достижение

enum AchievementReward: Sendable, Equatable {
    case none
    case theme(AppTheme)
    case appIcon(String)       // имя ассета альт-иконки приложения (dock)
    case menuBarIcon(String)   // SF-символ для меню-бара (в покое)

    /// Короткое описание для UI («+ тема Магия»).
    var label: String? {
        switch self {
        case .none:               return nil
        case .theme(let t):       return "Тема «\(t.title)»"
        case .appIcon:            return "Иконка приложения"
        case .menuBarIcon:        return "Значок в меню-баре"
        }
    }
}

// MARK: — каталог альт-иконок и меню-бар-значков (для раздела «Оформление»)

enum RewardCatalog {
    /// Альт-иконки приложения (имя ассета → подпись). «» = дефолтная (из AppIcon).
    static let appIcons: [(asset: String, title: String)] = [
        ("", "Стандарт"),
        ("icon_alt_gold", "Золотой глаз"),
        ("icon_alt_neon", "Неоновый глаз"),
        ("icon_alt_aurora", "Аврора"),
        ("icon_alt_frost", "Морозный"),
    ]

    /// Значки меню-бара (SF-символ → подпись) для состояния «в покое».
    static let menuBarIcons: [(symbol: String, title: String)] = [
        ("waveform", "Волна"),
        ("eye.fill", "Глаз"),
        ("sparkles", "Искры"),
        ("moon.stars.fill", "Ночь"),
        ("bolt.fill", "Молния"),
        ("crown.fill", "Корона"),
    ]
}
