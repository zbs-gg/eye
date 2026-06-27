import SwiftUI

// MARK: — appearance theme (applies app-wide)

enum AppTheme: String, Sendable, CaseIterable, Identifiable {
    case standard, magical, midnight, gold, neon, frost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .magical:  return "Magic"
        case .midnight: return "Midnight"
        case .gold:     return "Gold"
        case .neon:     return "Neon"
        case .frost:    return "Frost"
        }
    }

    /// Accent color (app-wide tint).
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

    /// "Aura" colors — a soft animated background under the content. Empty → no background (standard).
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

    /// How much aura to blend in (magic — noticeable, the rest — subtler).
    var auraOpacity: Double { self == .magical || self == .neon ? 0.32 : 0.20 }
}

// MARK: — achievement reward

enum AchievementReward: Sendable, Equatable {
    case none
    case theme(AppTheme)
    case appIcon(String)       // asset name of the alternate app icon (dock)
    case menuBarIcon(String)   // SF Symbol for the menu bar (when idle)

    /// Short description for the UI ("+ Magic theme").
    var label: String? {
        switch self {
        case .none:               return nil
        case .theme(let t):       return "\"\(t.title)\" theme"
        case .appIcon:            return "App icon"
        case .menuBarIcon:        return "Menu bar icon"
        }
    }
}

// MARK: — catalog of alternate icons and menu bar icons (for the "Appearance" section)

enum RewardCatalog {
    /// Alternate app icons (asset name → caption). "" = the default (from AppIcon).
    static let appIcons: [(asset: String, title: String)] = [
        ("", "Standard"),
        ("icon_alt_glow", "Glowing"),
        ("icon_alt_gold", "Golden Eye"),
        ("icon_alt_neon", "Neon Eye"),
        ("icon_alt_aurora", "Aurora"),
        ("icon_alt_frost", "Frosty"),
    ]

    /// Menu bar icons (SF Symbol → caption) for the "idle" state.
    static let menuBarIcons: [(symbol: String, title: String)] = [
        ("waveform", "Wave"),
        ("eye.fill", "Eye"),
        ("sparkles", "Sparkles"),
        ("moon.stars.fill", "Night"),
        ("bolt.fill", "Lightning"),
        ("crown.fill", "Crown"),
    ]
}
