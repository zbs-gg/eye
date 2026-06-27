import SwiftUI

// ⚙️ Сгенерировано из badge_spec_fixed.json (эволюционирующие тиры). Правки — в спеке/генераторе.

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
    case framesAtLeast(Int), framesInDayAtLeast(Int), streakAtLeast(Int), activeDaysAtLeast(Int)
    case memoryAgeDaysAtLeast(Int), distinctAppsAllTimeAtLeast(Int), distinctAppsInDayAtLeast(Int)
    case browserDomainsAtLeast(Int), switchesInDayAtLeast(Int), singleAppMinutesAtLeast(Int)
    case nightActivity, earlyActivity, weekendActivity, focusDay
    case searchesAtLeast(Int), questionsAtLeast(Int), cartographerRunsAtLeast(Int), activitiesOpenedAtLeast(Int)
    case deletedPeriod, relocated, icloudBackup

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
    let category: String
    let condition: AchievementCondition
    let secret: Bool
    let reward: AchievementReward
    let tierStars: Int
}

// MARK: — каталог (эволюционирующие семьи + спец-ачивки)

enum AchievementCatalog {
    static let all: [Achievement] = [
        // frames — Память · Объём
        Achievement(id: "frames.1000", title: "Первая искра", detail: "Тысяча кадров. Память только зажглась — одинокая искорка в холодной оправе.", badge: "badge_frames_1", tint: .bronze, category: "Память · Объём", condition: .framesAtLeast(1000), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "frames.50000", title: "Первый кристалл", detail: "Пятьдесят тысяч кадров. Искра застыла в первый гранёный кристалл — память обрела форму.", badge: "badge_frames_2", tint: .silver, category: "Память · Объём", condition: .framesAtLeast(50000), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "frames.250000", title: "Кристальный кластер", detail: "Четверть миллиона кадров. Один кристалл оброс гроздью — память кристаллизуется быстрее, чем ты успеваешь оглянуться.", badge: "badge_frames_3", tint: .gold, category: "Память · Объём", condition: .framesAtLeast(250000), secret: false, reward: .theme(.gold), tierStars: 3),
        Achievement(id: "frames.1000000", title: "Реликварий", detail: "Миллион кадров. Кристаллы заперты в бронированный vault-реликварий — хранилище памяти под замком.", badge: "badge_frames_4", tint: .diamond, category: "Память · Объём", condition: .framesAtLeast(1000000), secret: false, reward: .theme(.magical), tierStars: 4),
        Achievement(id: "frames.4000000", title: "Галактика воспоминаний", detail: "Четыре миллиона кадров. Хранилище раскрылось в спиральную галактику — каждый кадр стал звездой.", badge: "badge_frames_5", tint: .violet, category: "Память · Объём", condition: .framesAtLeast(4000000), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "frames.15000000", title: "Вечный архив", detail: "Пятнадцать миллионов кадров. Галактика свернулась в единое сияющее ядро вечности. Дальше — только космос.", badge: "badge_frames_6", tint: .magenta, category: "Память · Объём", condition: .framesAtLeast(15000000), secret: false, reward: .none, tierStars: 5),
        // age — Память · Древность
        Achievement(id: "age.7", title: "Проросток", detail: "Неделя памяти. Хрупкий росток пробил землю — корни у твоей памяти ещё свежие.", badge: "badge_age_1", tint: .bronze, category: "Память · Древность", condition: .memoryAgeDaysAtLeast(7), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "age.30", title: "Молодое деревце", detail: "Месяц памяти. Тонкий ствол, первые ветви — деревце окрепло.", badge: "badge_age_2", tint: .silver, category: "Память · Древность", condition: .memoryAgeDaysAtLeast(30), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "age.90", title: "Первые кольца", detail: "Три месяца. На срезе ствола проступили первые годовые кольца — память считает свой возраст.", badge: "badge_age_3", tint: .gold, category: "Память · Древность", condition: .memoryAgeDaysAtLeast(90), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "age.180", title: "Раскидистое древо", detail: "Полгода. Крона широкая, корни глубокие — память пустила корни всерьёз.", badge: "badge_age_4", tint: .diamond, category: "Память · Древность", condition: .memoryAgeDaysAtLeast(180), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "age.365", title: "Окаменевшее древо", detail: "Год памяти. Древо обратилось в светящийся окаменелый артефакт — год записан в камне.", badge: "badge_age_5", tint: .violet, category: "Память · Древность", condition: .memoryAgeDaysAtLeast(365), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "age.730", title: "Мировое древо", detail: "Два года непрерывной памяти. Вечное светящееся древо, чьи кольца уходят в бесконечность. Хранитель всего, что ты видел.", badge: "badge_age_6", tint: .magenta, category: "Память · Древность", condition: .memoryAgeDaysAtLeast(730), secret: false, reward: .none, tierStars: 5),
        // streak — Постоянство
        Achievement(id: "streak.3", title: "Искра", detail: "3 дня подряд. Маленькая искра поймана — ещё не пламя, но уже не темнота.", badge: "badge_streak_1", tint: .bronze, category: "Постоянство", condition: .streakAtLeast(3), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "streak.7", title: "Ровное пламя", detail: "Неделя без пропусков. Искра окрепла в устойчивый язык огня.", badge: "badge_streak_2", tint: .silver, category: "Постоянство", condition: .streakAtLeast(7), secret: false, reward: .appIcon("icon_alt_glow"), tierStars: 2),
        Achievement(id: "streak.21", title: "Синий жар", detail: "Три недели. Пламя стало горячее и посинело — горит спокойно и яростно одновременно.", badge: "badge_streak_3", tint: .blue, category: "Постоянство", condition: .streakAtLeast(21), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "streak.60", title: "Инферно", detail: "Два месяца подряд. Не пламя — печь. Огонь захлёстывает весь медальон.", badge: "badge_streak_4", tint: .gold, category: "Постоянство", condition: .streakAtLeast(60), secret: false, reward: .theme(.frost), tierStars: 4),
        Achievement(id: "streak.150", title: "Феникс", detail: "Полгода без единого разрыва. Огонь обрёл крылья и взгляд.", badge: "badge_streak_5", tint: .violet, category: "Постоянство", condition: .streakAtLeast(150), secret: false, reward: .appIcon("icon_alt_gold"), tierStars: 5),
        Achievement(id: "streak.365", title: "Вечный огонь", detail: "Год. Триста шестьдесят пять дней подряд. Это уже не серия — это твоя физика.", badge: "badge_streak_6", tint: .diamond, category: "Постоянство", condition: .streakAtLeast(365), secret: false, reward: .none, tierStars: 5),
        // days — Дни памяти
        Achievement(id: "days.10", title: "Первое кольцо", detail: "10 дней памяти набрано. Первый годовой круг — тонкий, но он есть.", badge: "badge_days_1", tint: .bronze, category: "Дни памяти", condition: .activeDaysAtLeast(10), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "days.30", title: "Срез месяца", detail: "30 дней. Несколько колец сложились в плотный узор — как годичные кольца на срезе ствола.", badge: "badge_days_2", tint: .silver, category: "Дни памяти", condition: .activeDaysAtLeast(30), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "days.90", title: "Розетка дней", detail: "90 дней памяти. Кольца сложились в радиальную розетку-циферблат — память считает дни по делениям.", badge: "badge_days_3", tint: .teal, category: "Дни памяти", condition: .activeDaysAtLeast(90), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "days.180", title: "Полугодовой диск", detail: "180 дней. Кольца спрессовались в плотный золотой диск-циферблат — целый сезон на срезе.", badge: "badge_days_4", tint: .gold, category: "Дни памяти", condition: .activeDaysAtLeast(180), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "days.365", title: "Год колец", detail: "365 дней с памятью. Полный годовой круг сомкнулся — целый сезон жизни записан.", badge: "badge_days_5", tint: .violet, category: "Дни памяти", condition: .activeDaysAtLeast(365), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "days.730", title: "Два сезона жизни", detail: "730 дней. Два года памяти. Кольца стали орбитами вокруг сияющего ядра.", badge: "badge_days_6", tint: .diamond, category: "Дни памяти", condition: .activeDaysAtLeast(730), secret: false, reward: .none, tierStars: 5),
        // carto — Картограф
        Achievement(id: "carto.1", title: "Первый взгляд", detail: "Картограф отработал день впервые. Око приоткрыло веко.", badge: "badge_carto_1", tint: .bronze, category: "Картограф", condition: .cartographerRunsAtLeast(1), secret: false, reward: .theme(.neon), tierStars: 1),
        Achievement(id: "carto.5", title: "Око открывается", detail: "5 дней с Картографом. Веко поднялось — зрачок ловит первые узоры дня.", badge: "badge_carto_2", tint: .silver, category: "Картограф", condition: .cartographerRunsAtLeast(5), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "carto.15", title: "Картой внутри", detail: "15 дней инсайтов. Зрачок стал картой связей — око читает день целиком.", badge: "badge_carto_3", tint: .teal, category: "Картограф", condition: .cartographerRunsAtLeast(15), secret: false, reward: .theme(.midnight), tierStars: 3),
        Achievement(id: "carto.30", title: "Всевидящее", detail: "30 дней Картографа. Око обросло лучами-меридианами и видит насквозь.", badge: "badge_carto_4", tint: .gold, category: "Картограф", condition: .cartographerRunsAtLeast(30), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "carto.60", title: "Астролябия дня", detail: "60 дней. Око стало живой астролябией — крутит орбиты твоих дней и читает закономерности.", badge: "badge_carto_5", tint: .violet, category: "Картограф", condition: .cartographerRunsAtLeast(60), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "carto.120", title: "Оракул", detail: "120 дней с Картографом. Око стало кристальным оракулом — твоя жизнь как карта целиком.", badge: "badge_carto_6", tint: .diamond, category: "Картограф", condition: .cartographerRunsAtLeast(120), secret: false, reward: .none, tierStars: 5),
        // activities — Сцены
        Achievement(id: "activities.5", title: "Первые сцены", detail: "5 открытых сцен. Первые кадры дня пойманы.", badge: "badge_activities_1", tint: .bronze, category: "Сцены", condition: .activitiesOpenedAtLeast(5), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "activities.25", title: "Связанные кадры", detail: "25 сцен. Кадры соединились маршрутами — между моментами появились связи.", badge: "badge_activities_2", tint: .silver, category: "Сцены", condition: .activitiesOpenedAtLeast(25), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "activities.75", title: "Коллаж дня", detail: "75 сцен. Кадры сложились в плотный коллаж — у твоих дней появилась форма.", badge: "badge_activities_3", tint: .teal, category: "Сцены", condition: .activitiesOpenedAtLeast(75), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "activities.200", title: "Галерея дня", detail: "200 сцен. Целая галерея прожитого — плотная стена кадров, твоя.", badge: "badge_activities_4", tint: .gold, category: "Сцены", condition: .activitiesOpenedAtLeast(200), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "activities.500", title: "Диорама памяти", detail: "500 открытых сцен. Кадры стали кристальной диорамой-шкатулкой — целый объёмный мир твоих моментов.", badge: "badge_activities_5", tint: .diamond, category: "Сцены", condition: .activitiesOpenedAtLeast(500), secret: false, reward: .none, tierStars: 5),
        // atlas — Атлас
        Achievement(id: "atlas.3", title: "Первый берег", detail: "Ты потрогал три разных приложения. Из тумана показался один скромный островок — начало карты.", badge: "badge_atlas_1", tint: .bronze, category: "Атлас", condition: .distinctAppsAllTimeAtLeast(3), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "atlas.10", title: "Архипелаг", detail: "Десять приложений — вокруг первого острова всплыла горстка соседей. Уже есть что соединять маршрутами.", badge: "badge_atlas_2", tint: .silver, category: "Атлас", condition: .distinctAppsAllTimeAtLeast(10), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "atlas.25", title: "Континент", detail: "Острова срослись в материк: горы, реки, береговая линия. Двадцать пять приложений — это уже целая земля.", badge: "badge_atlas_3", tint: .gold, category: "Атлас", condition: .distinctAppsAllTimeAtLeast(25), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "atlas.50", title: "Полушарие", detail: "Карта выгнулась в шар — видно целое полушарie планеты. Пятьдесят приложений, и плоский мир кончился.", badge: "badge_atlas_4", tint: .amber, category: "Атлас", condition: .distinctAppsAllTimeAtLeast(50), secret: false, reward: .appIcon("icon_alt_aurora"), tierStars: 4),
        Achievement(id: "atlas.100", title: "Целый мир", detail: "Полный вращающийся глобус. Сто разных приложений освоено — ты держишь в руках всю карту.", badge: "badge_atlas_5", tint: .diamond, category: "Атлас", condition: .distinctAppsAllTimeAtLeast(100), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "atlas.200", title: "Мир на орбите", detail: "Двести приложений. Глобус окружён орбитальными кольцами и спутниками — карта переросла планету.", badge: "badge_atlas_6", tint: .gold, category: "Атлас", condition: .distinctAppsAllTimeAtLeast(200), secret: false, reward: .none, tierStars: 5),
        // constellation — Созвездие
        Achievement(id: "constellation.3", title: "Три огня", detail: "За день — три разных приложения. Три одиноких звезды загорелись в темноте.", badge: "badge_constellation_1", tint: .bronze, category: "Созвездие", condition: .distinctAppsInDayAtLeast(3), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "constellation.6", title: "Первые линии", detail: "Шесть приложений — между звёздами протянулись первые светящиеся линии. Рисунок начинает читаться.", badge: "badge_constellation_2", tint: .silver, category: "Созвездие", condition: .distinctAppsInDayAtLeast(6), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "constellation.12", title: "Созвездие", detail: "Двенадцать приложений за день — полноценное созвездие с ясной фигурой и яркими узлами.", badge: "badge_constellation_3", tint: .gold, category: "Созвездие", condition: .distinctAppsInDayAtLeast(12), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "constellation.20", title: "Звёздное скопление", detail: "Двадцать приложений — небо забито плотным сияющим скоплением звёзд. День был насыщенным.", badge: "badge_constellation_4", tint: .diamond, category: "Созвездие", condition: .distinctAppsInDayAtLeast(20), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "constellation.30", title: "Галактика дня", detail: "Тридцать разных приложений за сутки. Это уже не созвездие — это закрученная галактика. Уф.", badge: "badge_constellation_5", tint: .violet, category: "Созвездие", condition: .distinctAppsInDayAtLeast(30), secret: false, reward: .none, tierStars: 5),
        // domains — Сеть
        Achievement(id: "domains.10", title: "Первый маршрут", detail: "Десять доменов — на карте появился первый путевой знак с одной тропой.", badge: "badge_domains_1", tint: .bronze, category: "Сеть", condition: .browserDomainsAtLeast(10), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "domains.30", title: "Перекрёсток", detail: "Тридцать доменов — тропы сошлись в перекрёсток с несколькими узлами. Сеть оживает.", badge: "badge_domains_2", tint: .silver, category: "Сеть", condition: .browserDomainsAtLeast(30), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "domains.75", title: "Паутина троп", detail: "Семьдесят пять доменов сплелись в густую сеть троп и узлов. Ты ходишь везде.", badge: "badge_domains_3", tint: .gold, category: "Сеть", condition: .browserDomainsAtLeast(75), secret: false, reward: .menuBarIcon("crown.fill"), tierStars: 3),
        Achievement(id: "domains.150", title: "Сетевая сфера", detail: "Сто пятьдесят доменов — сеть выгнулась в светящуюся сферу из узлов. Плоская карта кончилась.", badge: "badge_domains_4", tint: .diamond, category: "Сеть", condition: .browserDomainsAtLeast(150), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "domains.300", title: "Глобальная сеть", detail: "Триста доменов опутали целый узловой глобус сияющими линиями связи. Весь мир под рукой.", badge: "badge_domains_5", tint: .teal, category: "Сеть", condition: .browserDomainsAtLeast(300), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "domains.600", title: "Вездесущий", detail: "Шестьсот доменов. Узловой глобус окружён орбитальными потоками данных — твоя паутина переросла планету.", badge: "badge_domains_6", tint: .violet, category: "Сеть", condition: .browserDomainsAtLeast(600), secret: false, reward: .none, tierStars: 5),
        // deep — Погружение
        Achievement(id: "deep.15", title: "Первый вдох", detail: "Непрерывно 15 минут в одном приложении — нырнул с поверхности.", badge: "badge_deep_1", tint: .bronze, category: "Погружение", condition: .singleAppMinutesAtLeast(15), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "deep.45", title: "Уходя под свет", detail: "45 минут без отрыва — спустился под первые лучи.", badge: "badge_deep_2", tint: .silver, category: "Погружение", condition: .singleAppMinutesAtLeast(45), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "deep.90", title: "Глубже течений", detail: "90 минут в одном окне — прошёл слой течений.", badge: "badge_deep_3", tint: .teal, category: "Погружение", condition: .singleAppMinutesAtLeast(90), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "deep.180", title: "Сумеречная зона", detail: "180 минут не отрываясь — там, где кончается свет.", badge: "badge_deep_4", tint: .blue, category: "Погружение", condition: .singleAppMinutesAtLeast(180), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "deep.300", title: "Бездна отвечает", detail: "300 минут глубокого фокуса — пять часов в одной точке.", badge: "badge_deep_5", tint: .violet, category: "Погружение", condition: .singleAppMinutesAtLeast(300), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "deep.480", title: "Жемчужина бездны", detail: "480 минут — восемь часов кряду, ты достиг дна сияющей бездны.", badge: "badge_deep_6", tint: .diamond, category: "Погружение", condition: .singleAppMinutesAtLeast(480), secret: false, reward: .menuBarIcon("sparkles"), tierStars: 5),
        // burst — Интенсивность
        Achievement(id: "burst.2500", title: "Холостой ход", detail: "2 500 кадров за день — двигатель завёлся.", badge: "badge_burst_1", tint: .bronze, category: "Интенсивность", condition: .framesInDayAtLeast(2500), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "burst.7500", title: "Сцепление поймано", detail: "7 500 кадров за день — шестерни сошлись.", badge: "badge_burst_2", tint: .silver, category: "Интенсивность", condition: .framesInDayAtLeast(7500), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "burst.15000", title: "Часовой механизм", detail: "15 000 кадров за день — заработал весь механизм.", badge: "badge_burst_3", tint: .amber, category: "Интенсивность", condition: .framesInDayAtLeast(15000), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "burst.25000", title: "Полный газ", detail: "25 000 кадров за день — двигатель на максимум.", badge: "badge_burst_4", tint: .gold, category: "Интенсивность", condition: .framesInDayAtLeast(25000), secret: false, reward: .appIcon("icon_alt_neon"), tierStars: 4),
        Achievement(id: "burst.40000", title: "Перегрев турбины", detail: "40 000 кадров за день — реактор на красной зоне, ты вообще спал?", badge: "badge_burst_5", tint: .diamond, category: "Интенсивность", condition: .framesInDayAtLeast(40000), secret: false, reward: .none, tierStars: 5),
        // switch — Расфокус
        Achievement(id: "switch.50", title: "Размялся", detail: "50 переключений за день — колесо закрутилось.", badge: "badge_switch_1", tint: .green, category: "Расфокус", condition: .switchesInDayAtLeast(50), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "switch.150", title: "Белка в колесе", detail: "150 переключений за день — побежала белка.", badge: "badge_switch_2", tint: .teal, category: "Расфокус", condition: .switchesInDayAtLeast(150), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "switch.300", title: "Карусель контекста", detail: "300 переключений за день — закружилась карусель.", badge: "badge_switch_3", tint: .amber, category: "Расфокус", condition: .switchesInDayAtLeast(300), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "switch.500", title: "Водоворот окон", detail: "500 переключений за день — затягивает в воронку.", badge: "badge_switch_4", tint: .violet, category: "Расфокус", condition: .switchesInDayAtLeast(500), secret: false, reward: .menuBarIcon("bolt.fill"), tierStars: 4),
        Achievement(id: "switch.800", title: "Торнадо расфокуса", detail: "800 переключений за день — полный смерч из окон, выдохни.", badge: "badge_switch_5", tint: .red, category: "Расфокус", condition: .switchesInDayAtLeast(800), secret: false, reward: .none, tierStars: 5),
        // searches — Любопытство · Сыск
        Achievement(id: "searches.5", title: "Первый прищур", detail: "Пять поисков. Ты впервые навёл лупу на собственную память и понял — оно ищется.", badge: "badge_searches_1", tint: .bronze, category: "Любопытство · Сыск", condition: .searchesAtLeast(5), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "searches.25", title: "Нюх ищейки", detail: "Двадцать пять запросов. Появился навык — ты знаешь, какое слово вытащит нужный кадр.", badge: "badge_searches_2", tint: .silver, category: "Любопытство · Сыск", condition: .searchesAtLeast(25), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "searches.100", title: "Картотека пухнет", detail: "Сотня поисков. У тебя завелась настоящая картотека — лупа уже не одна, рядом веер карточек.", badge: "badge_searches_3", tint: .gold, category: "Любопытство · Сыск", condition: .searchesAtLeast(100), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "searches.500", title: "Стол следователя", detail: "Пятьсот запросов. Лупа обросла снаряжением дознавателя: оптика, нити версий, пришпиленная карточка дела.", badge: "badge_searches_4", tint: .teal, category: "Любопытство · Сыск", condition: .searchesAtLeast(500), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "searches.2000", title: "Главный сыщик", detail: "Две тысячи поисков. Ты не ищешь — ты ведёшь дело. Большая лупа-бюро в центре крест-герба.", badge: "badge_searches_5", tint: .diamond, category: "Любопытство · Сыск", condition: .searchesAtLeast(2000), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "searches.10000", title: "Всевидящее бюро", detail: "Десять тысяч. Бюро не спит. Лупа уступила место живому оку-ядру с орбитой линз — память находится за один прищур.", badge: "badge_searches_6", tint: .violet, category: "Любопытство · Сыск", condition: .searchesAtLeast(10000), secret: false, reward: .none, tierStars: 5),
        // questions — Любопытство · Оракул
        Achievement(id: "questions.3", title: "Робкий вопрос", detail: "Три вопроса к памяти. Кристалл только проклюнулся — внутри едва тлеет искра.", badge: "badge_questions_1", tint: .bronze, category: "Любопытство · Оракул", condition: .questionsAtLeast(3), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "questions.15", title: "Гранёный вопрос", detail: "Пятнадцать вопросов. Кристалл огранился, искра внутри загорелась ровно — память начала отвечать.", badge: "badge_questions_2", tint: .silver, category: "Любопытство · Оракул", condition: .questionsAtLeast(15), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "questions.50", title: "Говорящий кристалл", detail: "Полсотни вопросов. Кристалл заговорил — внутри сложился светящийся оракул, отвечающий на любой запрос.", badge: "badge_questions_3", tint: .gold, category: "Любопытство · Оракул", condition: .questionsAtLeast(50), secret: false, reward: .menuBarIcon("eye.fill"), tierStars: 3),
        Achievement(id: "questions.150", title: "Парящий оракул", detail: "Полтораста вопросов. Кристалл оторвался от оправы и парит — вокруг него вращаются осколки прошлых ответов.", badge: "badge_questions_4", tint: .teal, category: "Любопытство · Оракул", condition: .questionsAtLeast(150), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "questions.500", title: "Разум-обелиск", detail: "Пятьсот вопросов. Кристалл вырос в парящий обелиск разума с глазом-сердцевиной — он видит ответ раньше вопроса.", badge: "badge_questions_5", tint: .diamond, category: "Любопытство · Оракул", condition: .questionsAtLeast(500), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "questions.2000", title: "Всеведущий оракул", detail: "Две тысячи вопросов. Обелиск свернулся в самосветящуюся сферу-разум — спрашивать почти не нужно, она уже знает.", badge: "badge_questions_6", tint: .violet, category: "Любопытство · Оракул", condition: .questionsAtLeast(2000), secret: false, reward: .none, tierStars: 5),
        // спец-ачивки (флаговые сигналы)
        Achievement(id: "time.night", title: "Ночная сова", detail: "Активность после полуночи — глаз не спит, и ты тоже", badge: "badge_night", tint: .violet, category: "Время суток", condition: .nightActivity, secret: false, reward: .menuBarIcon("moon.stars.fill"), tierStars: 0),
        Achievement(id: "time.early", title: "Ранняя пташка", detail: "Активность до 7 утра — рассвет застал тебя за делом", badge: "badge_early", tint: .amber, category: "Время суток", condition: .earlyActivity, secret: false, reward: .none, tierStars: 0),
        Achievement(id: "time.weekend", title: "Призрак выходного", detail: "Работал в выходной — отдыхать не пробовал?", badge: "badge_weekend", tint: .teal, category: "Время суток", condition: .weekendActivity, secret: true, reward: .none, tierStars: 0),
        Achievement(id: "focus.zen", title: "Дзен-фокус", detail: "День без суеты: много работы, почти без переключений", badge: "badge_focus", tint: .red, category: "Фокус", condition: .focusDay, secret: false, reward: .none, tierStars: 0),
        Achievement(id: "ctrl.clean", title: "Чистильщик", detail: "Стёр период истории — твоё право", badge: "badge_clean", tint: .lime, category: "Контроль", condition: .deletedPeriod, secret: false, reward: .none, tierStars: 0),
        Achievement(id: "ctrl.disk", title: "На свой диск", detail: "Перенёс память на внешний SSD", badge: "badge_relocate", tint: .blue, category: "Контроль", condition: .relocated, secret: false, reward: .none, tierStars: 0),
        Achievement(id: "ctrl.cloud", title: "Облачный страж", detail: "Включил сжатый iCloud-бэкап", badge: "badge_guard", tint: .teal, category: "Контроль", condition: .icloudBackup, secret: false, reward: .appIcon("icon_alt_frost"), tierStars: 0),
    ]

    /// Категории в порядке появления (для группировки в галерее).
    static let categories: [String] = ["Память · Объём", "Память · Древность", "Постоянство", "Дни памяти", "Картограф", "Сцены", "Атлас", "Созвездие", "Сеть", "Погружение", "Интенсивность", "Расфокус", "Любопытство · Сыск", "Любопытство · Оракул", "Время суток", "Фокус", "Контроль"]
}
