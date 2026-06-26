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

// MARK: — условие открытия (data-driven, Sendable; вычисляется по AchievementStats)

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
    case nightActivity            // активность 0:00–5:00
    case earlyActivity            // активность 5:00–7:00
    case weekendActivity
    case focusDay                 // день с ≥1000 кадров и мало переключений
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
    let detail: String          // как открыть / что значит
    let badge: String           // имя ассета-бейджа (сгенерированная иконка)
    let tint: AchievementTint
    let category: AchievementCategory
    let condition: AchievementCondition
    let secret: Bool            // скрытое (показываем «???» пока закрыто) — для ироничных
}

// MARK: — каталог

enum AchievementCatalog {
    /// Текущий срез (~25). Расширяемо до 100 — добавляй строки. Тиры одной семьи делят бейдж,
    /// различаются tint'ом. `badge` — имя ассета (генерится через Nano Banana Pro).
    static let all: [Achievement] = [
        // ── Память (объём) ──
        a("memory.1k",   "Первая память",   "1 000 моментов в твоей памяти",        "badge_star",     .bronze,  .memory, .framesAtLeast(1_000)),
        a("memory.10k",  "Архивариус",      "10 000 моментов",                       "badge_star",     .silver,  .memory, .framesAtLeast(10_000)),
        a("memory.100k", "Хранитель",       "100 000 моментов",                      "badge_star",     .gold,    .memory, .framesAtLeast(100_000)),
        a("memory.1m",   "Вечная память",   "1 000 000 моментов — ты не забываешь ничего", "badge_trophy", .diamond, .memory, .framesAtLeast(1_000_000)),

        // ── Постоянство (стрик) ──
        a("streak.7",    "Неделя в потоке", "7 дней подряд с записью",               "badge_flame",    .bronze,  .streak, .streakAtLeast(7)),
        a("streak.30",   "Месяц без пропусков", "30 дней подряд",                    "badge_flame",    .gold,    .streak, .streakAtLeast(30)),
        a("streak.100",  "Сотня дней",      "100 дней подряд — машина",              "badge_flame",    .blue,    .streak, .streakAtLeast(100)),

        // ── Возраст памяти ──
        a("age.1",       "День прожит",     "Твоей памяти больше суток",             "badge_calendar", .teal,    .memory, .memoryAgeDaysAtLeast(1)),
        a("age.30",      "Ветеран памяти",  "Памяти больше месяца",                  "badge_calendar", .gold,    .memory, .memoryAgeDaysAtLeast(30)),

        // ── Интенсивность ──
        a("intense.day", "Марафонец",       "10 000 кадров за один день",            "badge_stopwatch", .amber,  .focus,  .framesInDayAtLeast(10_000)),

        // ── Время суток ──
        a("time.night",  "Ночная сова",     "Активность после полуночи",             "badge_owl",      .violet,  .time,   .nightActivity),
        a("time.early",  "Ранняя пташка",   "Активность до 7 утра",                  "badge_sunrise",  .amber,   .time,   .earlyActivity),
        a("time.weekend","Призрак выходного","Работал в выходной — отдыхать не пробовал?", "badge_ghost", .teal, .fun, .weekendActivity, secret: true),

        // ── Широта ──
        a("breadth.10",  "Многостаночник",  "10 разных приложений за день",          "badge_apps",     .green,   .breadth, .distinctAppsInDayAtLeast(10)),
        a("breadth.50",  "Исследователь",   "50 разных приложений за всё время",     "badge_apps",     .blue,    .breadth, .distinctAppsAllTimeAtLeast(50)),
        a("breadth.tabs","Коллекционер вкладок","30 разных сайтов за день",          "badge_tabs",     .blue,    .breadth, .browserDomainsAtLeast(30)),

        // ── Фокус / характер ──
        a("focus.day",   "Глубокий фокус",  "День с кучей работы и почти без переключений", "badge_target", .red, .focus, .focusDay),
        a("focus.switch","Карусель контекста","200 переключений за день — белка в колесе", "badge_spiral", .magenta, .fun, .switchesInDayAtLeast(200), secret: true),
        a("focus.deep",  "Глубокая работа", "3 часа в одном приложении без отрыва",  "badge_anchor",   .blue,    .focus,  .singleAppMinutesAtLeast(180)),

        // ── Поиск и вопросы ──
        a("ask.first",   "Первый вопрос",   "Спросил свою память впервые",           "badge_bubble",   .teal,    .ask,    .questionsAtLeast(1)),
        a("ask.50",      "Дознаватель",     "50 вопросов к памяти",                  "badge_bubble",   .violet,  .ask,    .questionsAtLeast(50)),
        a("ask.search",  "Ищейка",          "100 поисков по истории",                "badge_magnifier", .blue,   .ask,    .searchesAtLeast(100)),

        // ── Картограф ──
        a("carto.first", "Картограф пробудился", "Первый дневной инсайт",            "badge_brain",    .violet,  .cartographer, .cartographerRunsAtLeast(1)),
        a("carto.7",     "Под наблюдением",  "7 дней с инсайтами Картографа",        "badge_brain",    .magenta, .cartographer, .cartographerRunsAtLeast(7)),

        // ── Активности ──
        a("act.first",   "Хронист дня",     "Открыл «День в активностях»",           "badge_timeline", .blue,    .cartographer, .activitiesOpenedAtLeast(1)),

        // ── Контроль / приватность ──
        a("ctrl.clean",  "Чистильщик",      "Стёр период истории — твоё право",      "badge_broom",    .lime,    .control, .deletedPeriod),
        a("ctrl.disk",   "На свой диск",    "Перенёс память на внешний SSD",         "badge_drive",    .blue,    .control, .relocated),
        a("ctrl.cloud",  "Облачный страж",  "Включил сжатый iCloud-бэкап",           "badge_cloud",    .teal,    .control, .icloudBackup),
    ]

    private static func a(_ id: String, _ title: String, _ detail: String, _ badge: String,
                          _ tint: AchievementTint, _ category: AchievementCategory,
                          _ condition: AchievementCondition, secret: Bool = false) -> Achievement {
        Achievement(id: id, title: title, detail: detail, badge: badge, tint: tint,
                    category: category, condition: condition, secret: secret)
    }
}
