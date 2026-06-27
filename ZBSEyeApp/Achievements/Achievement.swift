import SwiftUI

// MARK: — категории

enum AchievementCategory: String, Sendable, CaseIterable, Identifiable {
    case memory      = "Память"
    case streak      = "Постоянство"
    case time        = "Время суток"
    case breadth     = "Широта"
    case focus       = "Фокус"
    case ask         = "Поиск и вопросы"
    case cartographer = "Картограф"
    case control     = "Контроль"
    case fun         = "С характером"

    var id: String { rawValue }
}

// MARK: — цветовой акцент (тир)

enum AchievementTint: String, Sendable {
    case bronze, silver, gold, diamond, blue, violet, teal, amber, magenta, green, red, lime

    var color: Color {
        switch self {
        case .bronze:  return Color(red: 0.80, green: 0.50, blue: 0.25)
        case .silver:  return Color(red: 0.72, green: 0.76, blue: 0.84)
        case .gold:    return Color(red: 1.00, green: 0.78, blue: 0.28)
        case .diamond: return Color(red: 0.60, green: 0.90, blue: 1.00)
        case .blue:    return Color(red: 0.30, green: 0.55, blue: 1.00)
        case .violet:  return Color(red: 0.65, green: 0.45, blue: 1.00)
        case .teal:    return Color(red: 0.25, green: 0.80, blue: 0.78)
        case .amber:   return Color(red: 1.00, green: 0.66, blue: 0.30)
        case .magenta: return Color(red: 1.00, green: 0.40, blue: 0.80)
        case .green:   return Color(red: 0.35, green: 0.85, blue: 0.45)
        case .red:     return Color(red: 1.00, green: 0.40, blue: 0.40)
        case .lime:    return Color(red: 0.70, green: 0.95, blue: 0.35)
        }
    }
}

// MARK: — условие открытия

enum AchievementCondition: Sendable {
    case framesAtLeast(Int)
    case framesInDayAtLeast(Int)
    case streakAtLeast(Int)
    case activeDaysAtLeast(Int)
    case memoryAgeDaysAtLeast(Int)
    case distinctAppsAllTimeAtLeast(Int)
    case distinctAppsInDayAtLeast(Int)
    case browserDomainsAtLeast(Int)
    case switchesInDayAtLeast(Int)
    case singleAppMinutesAtLeast(Int)
    case nightActivity
    case earlyActivity
    case weekendActivity
    case focusDay
    case searchesAtLeast(Int)
    case questionsAtLeast(Int)
    case cartographerRunsAtLeast(Int)
    case activitiesOpenedAtLeast(Int)
    case deletedPeriod
    case relocated
    case icloudBackup

    func isMet(_ s: AchievementStats) -> Bool {
        switch self {
        case .framesAtLeast(let n):              return s.totalFrames >= n
        case .framesInDayAtLeast(let n):         return s.maxFramesInOneDay >= n
        case .streakAtLeast(let n):              return s.streakDays >= n
        case .activeDaysAtLeast(let n):          return s.activeDays >= n
        case .memoryAgeDaysAtLeast(let n):       return s.memoryAgeDays >= n
        case .distinctAppsAllTimeAtLeast(let n): return s.distinctAppsAllTime >= n
        case .distinctAppsInDayAtLeast(let n):   return s.maxDistinctAppsInDay >= n
        case .browserDomainsAtLeast(let n):      return s.distinctBrowserDomains >= n
        case .switchesInDayAtLeast(let n):       return s.maxSwitchesInDay >= n
        case .singleAppMinutesAtLeast(let n):    return s.maxSingleAppMinutes >= n
        case .nightActivity:                     return s.hadNightActivity
        case .earlyActivity:                     return s.hadEarlyActivity
        case .weekendActivity:                   return s.hadWeekendActivity
        case .focusDay:                          return s.hadFocusDay
        case .searchesAtLeast(let n):            return s.searches >= n
        case .questionsAtLeast(let n):           return s.questions >= n
        case .cartographerRunsAtLeast(let n):    return s.cartographerRuns >= n
        case .activitiesOpenedAtLeast(let n):    return s.activitiesOpened >= n
        case .deletedPeriod:                     return s.deletedPeriod
        case .relocated:                         return s.relocated
        case .icloudBackup:                      return s.icloudBackup
        }
    }
}

// MARK: — достижение

struct Achievement: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let badge: String
    let tint: AchievementTint
    let category: AchievementCategory
    let condition: AchievementCondition
    let secret: Bool
    let reward: AchievementReward
    let tierStars: Int          // 1–5 для тиров семьи (прогресс звёздами), 0 — без звёзд
}

// MARK: — каталог (тир-семьи + специалы ≈ 180)

enum AchievementCatalog {
    static let all: [Achievement] = specials + families

    // ── тир-семьи (количественные, генерируются) ──
    private static let families: [Achievement] =
        fam("frames", "badge_star", .memory,
            [1_000, 2_500, 5_000, 10_000, 20_000, 35_000, 50_000, 75_000, 100_000, 150_000, 200_000, 350_000, 500_000, 750_000, 1_000_000, 1_500_000, 2_500_000, 5_000_000],
            name: { "\(fmt($0)) моментов" }, detail: { "В памяти \(fmt($0)) кадров" },
            cond: { .framesAtLeast($0) }, rewards: [100_000: .theme(.gold), 1_000_000: .theme(.magical)])
      + fam("streak", "badge_flame", .streak,
            [3, 5, 7, 10, 14, 21, 30, 45, 60, 75, 90, 100, 150, 200, 300, 365],
            name: { "\($0) дней подряд" }, detail: { "Запись \($0) дней подряд без пропусков" },
            cond: { .streakAtLeast($0) }, rewards: [7: .appIcon("icon_alt_glow"), 30: .theme(.frost), 100: .appIcon("icon_alt_gold")])
      + fam("days", "badge_calendar", .memory,
            [1, 3, 5, 7, 14, 21, 30, 45, 60, 90, 120, 150, 200, 250, 300, 365],
            name: { "\($0) дней с памятью" }, detail: { "\($0) разных дней с записью" },
            cond: { .activeDaysAtLeast($0) })
      + fam("age", "badge_calendar", .memory,
            [1, 3, 7, 14, 30, 60, 90, 180, 270, 365, 540, 730],
            name: { "Памяти \($0) дн." }, detail: { "Самый ранний кадр старше \($0) дней" },
            cond: { .memoryAgeDaysAtLeast($0) })
      + fam("burst", "badge_stopwatch", .focus,
            [1_000, 2_500, 5_000, 7_500, 10_000, 15_000, 20_000, 30_000, 40_000],
            name: { "\(fmt($0)) кадров за день" }, detail: { "За один день — \(fmt($0)) кадров" },
            cond: { .framesInDayAtLeast($0) }, rewards: [10_000: .appIcon("icon_alt_neon")])
      + fam("apps", "badge_apps", .breadth,
            [5, 10, 15, 25, 40, 50, 65, 75, 100, 125, 150, 200],
            name: { "\($0) приложений" }, detail: { "\($0) разных приложений за всё время" },
            cond: { .distinctAppsAllTimeAtLeast($0) }, rewards: [50: .appIcon("icon_alt_aurora")])
      + fam("appsday", "badge_apps", .breadth,
            [3, 5, 8, 12, 16, 20, 25, 30],
            name: { "\($0) приложений за день" }, detail: { "За один день — \($0) разных приложений" },
            cond: { .distinctAppsInDayAtLeast($0) })
      + fam("domains", "badge_tabs", .breadth,
            [10, 25, 50, 75, 100, 150, 200, 300, 400],
            name: { "\($0) сайтов" }, detail: { "\($0) разных доменов в истории" },
            cond: { .browserDomainsAtLeast($0) }, rewards: [50: .menuBarIcon("crown.fill")])
      + fam("search", "badge_magnifier", .ask,
            [1, 5, 10, 25, 50, 100, 200, 350, 500, 750, 1_000],
            name: { "\(fmt($0)) поисков" }, detail: { "\(fmt($0)) поисков по истории" },
            cond: { .searchesAtLeast($0) })
      + fam("ask", "badge_bubble", .ask,
            [1, 5, 10, 25, 50, 100, 200, 350, 500],
            name: { "\(fmt($0)) вопросов" }, detail: { "\(fmt($0)) вопросов к своей памяти" },
            cond: { .questionsAtLeast($0) }, rewards: [50: .menuBarIcon("eye.fill")])
      + fam("carto", "badge_brain", .cartographer,
            [1, 3, 7, 14, 21, 30, 45, 60, 90, 100],
            name: { "\($0) дней с Картографом" }, detail: { "Картограф давал инсайты \($0) раз" },
            cond: { .cartographerRunsAtLeast($0) }, rewards: [1: .theme(.neon), 7: .theme(.midnight)])
      + fam("switch", "badge_spiral", .fun,
            [50, 100, 150, 200, 300, 500, 800],
            name: { "\($0) переключений за день" }, detail: { "\($0) смен контекста за день — белка в колесе" },
            cond: { .switchesInDayAtLeast($0) }, secret: true, rewards: [200: .menuBarIcon("bolt.fill")])
      + fam("deep", "badge_anchor", .focus,
            [15, 30, 45, 60, 90, 120, 180, 240, 300, 480],
            name: { "\($0) мин в одном приложении" }, detail: { "Непрерывно \($0) минут в одном приложении" },
            cond: { .singleAppMinutesAtLeast($0) })
      + fam("acts", "badge_timeline", .cartographer,
            [1, 5, 10, 25, 50, 100],
            name: { "Активности ×\($0)" }, detail: { "Открыл «День в активностях» \($0) раз" },
            cond: { .activitiesOpenedAtLeast($0) })

    // ── специалы (флаги/ироничные/контроль/награды) ──
    private static let specials: [Achievement] = [
        s("time.night",   "Ночная сова",     "Активность после полуночи",            "badge_owl",     .violet,  .time,   .nightActivity, reward: .menuBarIcon("moon.stars.fill")),
        s("time.early",   "Ранняя пташка",   "Активность до 7 утра",                 "badge_sunrise", .amber,   .time,   .earlyActivity),
        s("time.weekend", "Призрак выходного","Работал в выходной — отдыхать не пробовал?", "badge_ghost", .teal, .fun, .weekendActivity, secret: true),
        s("focus.zen",    "Дзен-фокус",      "День без суеты: много работы, почти без переключений", "badge_target", .red, .focus, .focusDay),
        s("ctrl.clean",   "Чистильщик",      "Стёр период истории — твоё право",     "badge_broom",   .lime,    .control, .deletedPeriod),
        s("ctrl.disk",    "На свой диск",    "Перенёс память на внешний SSD",        "badge_drive",   .blue,    .control, .relocated),
        s("ctrl.cloud",   "Облачный страж",  "Включил сжатый iCloud-бэкап",          "badge_cloud",   .teal,    .control, .icloudBackup, reward: .appIcon("icon_alt_frost")),
        // ироничные (используют те же сигналы, иные пороги/рамка — «характер»)
        s("fun.insomniac","Бессонница",      "Опять не спишь? Кадры идут за полночь.", "badge_owl",   .magenta, .fun,   .nightActivity, secret: true),
        s("fun.tabs",     "Вкладочный хомяк","Сайтов больше, чем здравого смысла",    "badge_tabs",    .amber,   .fun,   .browserDomainsAtLeast(100), secret: true),
        s("fun.juggler",  "Многорукий",      "16 приложений за день — ты осьминог?",  "badge_apps",    .green,   .fun,   .distinctAppsInDayAtLeast(16), secret: true),
        s("fun.machine",  "Машина памяти",   "Полмиллиона кадров. Тебя пора в музей.","badge_trophy",  .diamond, .fun,   .framesAtLeast(500_000), secret: true),
        s("fun.marathon", "Без тормозов",    "40 000 кадров за сутки — ты вообще спал?","badge_stopwatch", .red, .fun,   .framesInDayAtLeast(40_000), secret: true),
        s("fun.hermit",   "Однолюб",         "8 часов в одном приложении — преданность","badge_anchor", .blue,   .fun,   .singleAppMinutesAtLeast(480), secret: true),
        s("fun.year",     "Под наблюдением год","365 дней подряд. Глаз гордится.",     "badge_flame",   .gold,    .fun,   .streakAtLeast(365), secret: true),
        s("fun.plushkin", "Цифровой Плюшкин","300 000 кадров — всё в дом",           "badge_trophy",  .amber,   .fun,   .framesAtLeast(300_000), secret: true),
        s("fun.terabyte", "Терабайт памяти", "3 миллиона кадров. Серьёзно?",         "badge_trophy",  .diamond, .fun,   .framesAtLeast(3_000_000), secret: true),
        s("fun.streak11", "Чёртова дюжина",  "11 дней подряд — без суеверий",        "badge_flame",   .bronze,  .fun,   .streakAtLeast(11), secret: true),
        s("fun.streak50", "Полста",          "50 дней подряд",                       "badge_flame",   .silver,  .fun,   .streakAtLeast(50), secret: true),
        s("fun.search75", "Сыщик",           "75 поисков по истории",                "badge_magnifier", .teal,  .fun,   .searchesAtLeast(75), secret: true),
        s("fun.search300","Архивный детектив","300 поисков",                         "badge_magnifier", .blue,  .fun,   .searchesAtLeast(300), secret: true),
        s("fun.ask15",    "Любопытный",      "15 вопросов к памяти",                 "badge_bubble",  .green,   .fun,   .questionsAtLeast(15), secret: true),
        s("fun.ask150",   "Допрос с пристрастием","150 вопросов",                    "badge_bubble",  .violet,  .fun,   .questionsAtLeast(150), secret: true),
        s("fun.dom60",    "Серфингист",      "60 разных сайтов",                     "badge_tabs",    .teal,    .fun,   .browserDomainsAtLeast(60), secret: true),
        s("fun.dom250",   "Интернет-всеяд",  "250 сайтов в истории",                 "badge_tabs",    .amber,   .fun,   .browserDomainsAtLeast(250), secret: true),
        s("fun.apps30",   "Швейцарский нож", "30 приложений за всё время",           "badge_apps",    .green,   .fun,   .distinctAppsAllTimeAtLeast(30), secret: true),
        s("fun.apps90",   "Цифровой кочевник","90 приложений",                       "badge_apps",    .blue,    .fun,   .distinctAppsAllTimeAtLeast(90), secret: true),
        s("fun.deep200",  "Залип капитально","200 минут в одном приложении",         "badge_anchor",  .blue,    .fun,   .singleAppMinutesAtLeast(200), secret: true),
        s("fun.deep360",  "6 часов кряду",   "360 минут не отрываясь",               "badge_anchor",  .violet,  .fun,   .singleAppMinutesAtLeast(360), secret: true),
        s("fun.burst25k", "Конвейер",        "25 000 кадров за день",                "badge_stopwatch", .amber, .fun,   .framesInDayAtLeast(25_000), secret: true),
        s("fun.burst50k", "Не остановить",   "50 000 кадров за день",                "badge_stopwatch", .red,   .fun,   .framesInDayAtLeast(50_000), secret: true),
        s("fun.sw250",    "Расфокус-мастер", "250 переключений за день",             "badge_spiral",  .magenta, .fun,   .switchesInDayAtLeast(250), secret: true),
        s("fun.sw1000",   "Тысяча окон",     "1000 переключений за день",            "badge_spiral",  .red,     .fun,   .switchesInDayAtLeast(1000), secret: true),
        s("fun.carto25",  "Самокопатель",    "25 дней инсайтов Картографа",          "badge_brain",   .magenta, .fun,   .cartographerRunsAtLeast(25), secret: true),
        s("fun.days100",  "Сотня дней памяти","100 разных дней с записью",           "badge_calendar", .gold,   .fun,   .activeDaysAtLeast(100), secret: true),
        s("fun.age500",   "Древняя память",  "Памяти больше 500 дней",               "badge_calendar", .diamond, .fun,  .memoryAgeDaysAtLeast(500), secret: true),
    ]

    // MARK: — генератор семьи

    private static func fam(_ key: String, _ badge: String, _ category: AchievementCategory,
                            _ thresholds: [Int], name: (Int) -> String, detail: (Int) -> String,
                            cond: (Int) -> AchievementCondition, secret: Bool = false,
                            rewards: [Int: AchievementReward] = [:]) -> [Achievement] {
        let n = thresholds.count
        return thresholds.enumerated().map { i, t in
            let stars = n > 1 ? min(5, 1 + Int(round(Double(i) / Double(n - 1) * 4))) : 3
            return Achievement(id: "\(key).\(t)", title: name(t), detail: detail(t), badge: badge,
                        tint: tierTint(i, n), category: category, condition: cond(t),
                        secret: secret, reward: rewards[t] ?? .none, tierStars: stars)
        }
    }

    private static func s(_ id: String, _ title: String, _ detail: String, _ badge: String,
                          _ tint: AchievementTint, _ category: AchievementCategory,
                          _ condition: AchievementCondition, secret: Bool = false,
                          reward: AchievementReward = .none) -> Achievement {
        Achievement(id: id, title: title, detail: detail, badge: badge, tint: tint,
                    category: category, condition: condition, secret: secret, reward: reward,
                    tierStars: 0)
    }

    /// Эскалация цвета по индексу тира.
    private static func tierTint(_ i: Int, _ count: Int) -> AchievementTint {
        let ramp: [AchievementTint] = [.bronze, .silver, .teal, .green, .blue, .violet, .amber, .gold, .magenta, .diamond]
        guard count > 1 else { return .gold }
        let idx = Int(round(Double(i) / Double(count - 1) * Double(ramp.count - 1)))
        return ramp[min(ramp.count - 1, idx)]
    }

    /// «1 000» / «1 200 000» с разрядкой.
    private static func fmt(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
