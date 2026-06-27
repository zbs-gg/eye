import SwiftUI

// ⚙️ Generated from badge_spec_fixed.json (evolving tiers). Make edits in the spec/generator.

// MARK: — color accent (tier)

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

// MARK: — unlock condition

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

// MARK: — achievement

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

// MARK: — catalog (evolving families + special achievements)

enum AchievementCatalog {
    static let all: [Achievement] = [
        // frames — Memory · Volume
        Achievement(id: "frames.1000", title: "First Spark", detail: "A thousand frames. Memory has just lit up — a lone spark in a cold setting.", badge: "badge_frames_1", tint: .bronze, category: "Memory · Volume", condition: .framesAtLeast(1000), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "frames.50000", title: "First Crystal", detail: "Fifty thousand frames. The spark froze into the first faceted crystal — memory has taken shape.", badge: "badge_frames_2", tint: .silver, category: "Memory · Volume", condition: .framesAtLeast(50000), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "frames.250000", title: "Crystal Cluster", detail: "A quarter million frames. One crystal grew a cluster — memory crystallizes faster than you can look around.", badge: "badge_frames_3", tint: .gold, category: "Memory · Volume", condition: .framesAtLeast(250000), secret: false, reward: .theme(.gold), tierStars: 3),
        Achievement(id: "frames.1000000", title: "Reliquary", detail: "A million frames. The crystals are locked in an armored vault-reliquary — a memory store under lock and key.", badge: "badge_frames_4", tint: .diamond, category: "Memory · Volume", condition: .framesAtLeast(1000000), secret: false, reward: .theme(.magical), tierStars: 4),
        Achievement(id: "frames.4000000", title: "Galaxy of Memories", detail: "Four million frames. The vault unfolded into a spiral galaxy — every frame became a star.", badge: "badge_frames_5", tint: .violet, category: "Memory · Volume", condition: .framesAtLeast(4000000), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "frames.15000000", title: "Eternal Archive", detail: "Fifteen million frames. The galaxy collapsed into a single glowing core of eternity. Beyond — only space.", badge: "badge_frames_6", tint: .magenta, category: "Memory · Volume", condition: .framesAtLeast(15000000), secret: false, reward: .none, tierStars: 5),
        // age — Memory · Age
        Achievement(id: "age.7", title: "Sprout", detail: "A week of memory. A fragile sprout broke through the soil — your memory's roots are still fresh.", badge: "badge_age_1", tint: .bronze, category: "Memory · Age", condition: .memoryAgeDaysAtLeast(7), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "age.30", title: "Young Sapling", detail: "A month of memory. A thin trunk, first branches — the sapling has grown stronger.", badge: "badge_age_2", tint: .silver, category: "Memory · Age", condition: .memoryAgeDaysAtLeast(30), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "age.90", title: "First Rings", detail: "Three months. The first growth rings showed on the trunk's cross-section — memory is counting its age.", badge: "badge_age_3", tint: .gold, category: "Memory · Age", condition: .memoryAgeDaysAtLeast(90), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "age.180", title: "Spreading Tree", detail: "Half a year. A wide crown, deep roots — memory has truly taken root.", badge: "badge_age_4", tint: .diamond, category: "Memory · Age", condition: .memoryAgeDaysAtLeast(180), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "age.365", title: "Petrified Tree", detail: "A year of memory. The tree turned into a glowing petrified artifact — a year written in stone.", badge: "badge_age_5", tint: .violet, category: "Memory · Age", condition: .memoryAgeDaysAtLeast(365), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "age.730", title: "World Tree", detail: "Two years of unbroken memory. An eternal glowing tree whose rings reach into infinity. Keeper of everything you've seen.", badge: "badge_age_6", tint: .magenta, category: "Memory · Age", condition: .memoryAgeDaysAtLeast(730), secret: false, reward: .none, tierStars: 5),
        // streak — Consistency
        Achievement(id: "streak.3", title: "Spark", detail: "3 days in a row. A small spark caught — not a flame yet, but no longer darkness.", badge: "badge_streak_1", tint: .bronze, category: "Consistency", condition: .streakAtLeast(3), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "streak.7", title: "Steady Flame", detail: "A week without a miss. The spark grew into a steady tongue of fire.", badge: "badge_streak_2", tint: .silver, category: "Consistency", condition: .streakAtLeast(7), secret: false, reward: .appIcon("icon_alt_glow"), tierStars: 2),
        Achievement(id: "streak.21", title: "Blue Heat", detail: "Three weeks. The flame grew hotter and turned blue — burning calmly and fiercely at once.", badge: "badge_streak_3", tint: .blue, category: "Consistency", condition: .streakAtLeast(21), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "streak.60", title: "Inferno", detail: "Two months in a row. Not a flame — a furnace. Fire engulfs the whole medallion.", badge: "badge_streak_4", tint: .gold, category: "Consistency", condition: .streakAtLeast(60), secret: false, reward: .theme(.frost), tierStars: 4),
        Achievement(id: "streak.150", title: "Phoenix", detail: "Half a year without a single break. The fire gained wings and a gaze.", badge: "badge_streak_5", tint: .violet, category: "Consistency", condition: .streakAtLeast(150), secret: false, reward: .appIcon("icon_alt_gold"), tierStars: 5),
        Achievement(id: "streak.365", title: "Eternal Flame", detail: "A year. Three hundred sixty-five days in a row. This isn't a streak anymore — it's your physics.", badge: "badge_streak_6", tint: .diamond, category: "Consistency", condition: .streakAtLeast(365), secret: false, reward: .none, tierStars: 5),
        // days — Days of Memory
        Achievement(id: "days.10", title: "First Ring", detail: "10 days of memory collected. The first annual ring — thin, but it's there.", badge: "badge_days_1", tint: .bronze, category: "Days of Memory", condition: .activeDaysAtLeast(10), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "days.30", title: "Month Cross-Section", detail: "30 days. Several rings formed a dense pattern — like growth rings on a trunk's cross-section.", badge: "badge_days_2", tint: .silver, category: "Days of Memory", condition: .activeDaysAtLeast(30), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "days.90", title: "Rosette of Days", detail: "90 days of memory. The rings formed a radial rosette-dial — memory counts the days by its marks.", badge: "badge_days_3", tint: .teal, category: "Days of Memory", condition: .activeDaysAtLeast(90), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "days.180", title: "Half-Year Disc", detail: "180 days. The rings pressed into a dense golden disc-dial — a whole season on the cross-section.", badge: "badge_days_4", tint: .gold, category: "Days of Memory", condition: .activeDaysAtLeast(180), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "days.365", title: "Year of Rings", detail: "365 days with memory. The full annual circle has closed — a whole season of life recorded.", badge: "badge_days_5", tint: .violet, category: "Days of Memory", condition: .activeDaysAtLeast(365), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "days.730", title: "Two Seasons of Life", detail: "730 days. Two years of memory. The rings became orbits around a glowing core.", badge: "badge_days_6", tint: .diamond, category: "Days of Memory", condition: .activeDaysAtLeast(730), secret: false, reward: .none, tierStars: 5),
        // carto — Cartographer
        Achievement(id: "carto.1", title: "First Glance", detail: "The Cartographer worked a full day for the first time. The Eye cracked open its lid.", badge: "badge_carto_1", tint: .bronze, category: "Cartographer", condition: .cartographerRunsAtLeast(1), secret: false, reward: .theme(.neon), tierStars: 1),
        Achievement(id: "carto.5", title: "The Eye Opens", detail: "5 days with the Cartographer. The lid lifted — the pupil catches the day's first patterns.", badge: "badge_carto_2", tint: .silver, category: "Cartographer", condition: .cartographerRunsAtLeast(5), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "carto.15", title: "Map Within", detail: "15 days of insights. The pupil became a map of connections — the Eye reads the whole day.", badge: "badge_carto_3", tint: .teal, category: "Cartographer", condition: .cartographerRunsAtLeast(15), secret: false, reward: .theme(.midnight), tierStars: 3),
        Achievement(id: "carto.30", title: "All-Seeing", detail: "30 days of the Cartographer. The Eye grew meridian-rays and sees right through.", badge: "badge_carto_4", tint: .gold, category: "Cartographer", condition: .cartographerRunsAtLeast(30), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "carto.60", title: "Astrolabe of the Day", detail: "60 days. The Eye became a living astrolabe — spinning the orbits of your days and reading the patterns.", badge: "badge_carto_5", tint: .violet, category: "Cartographer", condition: .cartographerRunsAtLeast(60), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "carto.120", title: "Oracle", detail: "120 days with the Cartographer. The Eye became a crystal oracle — your life as a complete map.", badge: "badge_carto_6", tint: .diamond, category: "Cartographer", condition: .cartographerRunsAtLeast(120), secret: false, reward: .none, tierStars: 5),
        // activities — Scenes
        Achievement(id: "activities.5", title: "First Scenes", detail: "5 scenes opened. The day's first frames are caught.", badge: "badge_activities_1", tint: .bronze, category: "Scenes", condition: .activitiesOpenedAtLeast(5), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "activities.25", title: "Connected Frames", detail: "25 scenes. The frames linked up by routes — connections appeared between moments.", badge: "badge_activities_2", tint: .silver, category: "Scenes", condition: .activitiesOpenedAtLeast(25), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "activities.75", title: "Collage of the Day", detail: "75 scenes. The frames formed a dense collage — your days have taken shape.", badge: "badge_activities_3", tint: .teal, category: "Scenes", condition: .activitiesOpenedAtLeast(75), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "activities.200", title: "Gallery of the Day", detail: "200 scenes. A whole gallery of the lived — a dense wall of frames, yours.", badge: "badge_activities_4", tint: .gold, category: "Scenes", condition: .activitiesOpenedAtLeast(200), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "activities.500", title: "Diorama of Memory", detail: "500 scenes opened. The frames became a crystal diorama-casket — a whole volumetric world of your moments.", badge: "badge_activities_5", tint: .diamond, category: "Scenes", condition: .activitiesOpenedAtLeast(500), secret: false, reward: .none, tierStars: 5),
        // atlas — Atlas
        Achievement(id: "atlas.3", title: "First Shore", detail: "You've touched three different apps. One modest island emerged from the fog — the start of the map.", badge: "badge_atlas_1", tint: .bronze, category: "Atlas", condition: .distinctAppsAllTimeAtLeast(3), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "atlas.10", title: "Archipelago", detail: "Ten apps — a handful of neighbors surfaced around the first island. There's already something to link by routes.", badge: "badge_atlas_2", tint: .silver, category: "Atlas", condition: .distinctAppsAllTimeAtLeast(10), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "atlas.25", title: "Continent", detail: "The islands fused into a continent: mountains, rivers, a coastline. Twenty-five apps — that's a whole land already.", badge: "badge_atlas_3", tint: .gold, category: "Atlas", condition: .distinctAppsAllTimeAtLeast(25), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "atlas.50", title: "Hemisphere", detail: "The map curved into a sphere — a whole hemisphere of the planet is visible. Fifty apps, and the flat world is over.", badge: "badge_atlas_4", tint: .amber, category: "Atlas", condition: .distinctAppsAllTimeAtLeast(50), secret: false, reward: .appIcon("icon_alt_aurora"), tierStars: 4),
        Achievement(id: "atlas.100", title: "A Whole World", detail: "A full rotating globe. A hundred different apps mastered — you hold the entire map in your hands.", badge: "badge_atlas_5", tint: .diamond, category: "Atlas", condition: .distinctAppsAllTimeAtLeast(100), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "atlas.200", title: "World in Orbit", detail: "Two hundred apps. The globe is ringed by orbital rings and satellites — the map has outgrown the planet.", badge: "badge_atlas_6", tint: .gold, category: "Atlas", condition: .distinctAppsAllTimeAtLeast(200), secret: false, reward: .none, tierStars: 5),
        // constellation — Constellation
        Achievement(id: "constellation.3", title: "Three Fires", detail: "Three different apps in a day. Three lone stars lit up in the dark.", badge: "badge_constellation_1", tint: .bronze, category: "Constellation", condition: .distinctAppsInDayAtLeast(3), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "constellation.6", title: "First Lines", detail: "Six apps — the first glowing lines stretched between the stars. A figure begins to read.", badge: "badge_constellation_2", tint: .silver, category: "Constellation", condition: .distinctAppsInDayAtLeast(6), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "constellation.12", title: "Constellation", detail: "Twelve apps in a day — a full constellation with a clear figure and bright nodes.", badge: "badge_constellation_3", tint: .gold, category: "Constellation", condition: .distinctAppsInDayAtLeast(12), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "constellation.20", title: "Star Cluster", detail: "Twenty apps — the sky is packed with a dense, glowing cluster of stars. It was a full day.", badge: "badge_constellation_4", tint: .diamond, category: "Constellation", condition: .distinctAppsInDayAtLeast(20), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "constellation.30", title: "Galaxy of the Day", detail: "Thirty different apps in a day. This isn't a constellation anymore — it's a swirling galaxy. Phew.", badge: "badge_constellation_5", tint: .violet, category: "Constellation", condition: .distinctAppsInDayAtLeast(30), secret: false, reward: .none, tierStars: 5),
        // domains — Network
        Achievement(id: "domains.10", title: "First Route", detail: "Ten domains — the first waypoint with a single trail appeared on the map.", badge: "badge_domains_1", tint: .bronze, category: "Network", condition: .browserDomainsAtLeast(10), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "domains.30", title: "Crossroads", detail: "Thirty domains — the trails met at a crossroads with several nodes. The network comes alive.", badge: "badge_domains_2", tint: .silver, category: "Network", condition: .browserDomainsAtLeast(30), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "domains.75", title: "Web of Trails", detail: "Seventy-five domains wove into a dense web of trails and nodes. You go everywhere.", badge: "badge_domains_3", tint: .gold, category: "Network", condition: .browserDomainsAtLeast(75), secret: false, reward: .menuBarIcon("crown.fill"), tierStars: 3),
        Achievement(id: "domains.150", title: "Network Sphere", detail: "A hundred fifty domains — the network curved into a glowing sphere of nodes. The flat map is over.", badge: "badge_domains_4", tint: .diamond, category: "Network", condition: .browserDomainsAtLeast(150), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "domains.300", title: "Global Network", detail: "Three hundred domains wrapped a whole node-globe in glowing lines of connection. The whole world at hand.", badge: "badge_domains_5", tint: .teal, category: "Network", condition: .browserDomainsAtLeast(300), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "domains.600", title: "Omnipresent", detail: "Six hundred domains. The node-globe is surrounded by orbital data streams — your web has outgrown the planet.", badge: "badge_domains_6", tint: .violet, category: "Network", condition: .browserDomainsAtLeast(600), secret: false, reward: .none, tierStars: 5),
        // deep — Immersion
        Achievement(id: "deep.15", title: "First Breath", detail: "15 minutes straight in one app — you dove from the surface.", badge: "badge_deep_1", tint: .bronze, category: "Immersion", condition: .singleAppMinutesAtLeast(15), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "deep.45", title: "Below the Light", detail: "45 minutes without a break — you descended beneath the first rays.", badge: "badge_deep_2", tint: .silver, category: "Immersion", condition: .singleAppMinutesAtLeast(45), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "deep.90", title: "Beneath the Currents", detail: "90 minutes in one window — you passed through the layer of currents.", badge: "badge_deep_3", tint: .teal, category: "Immersion", condition: .singleAppMinutesAtLeast(90), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "deep.180", title: "Twilight Zone", detail: "180 minutes without looking up — where the light ends.", badge: "badge_deep_4", tint: .blue, category: "Immersion", condition: .singleAppMinutesAtLeast(180), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "deep.300", title: "The Abyss Answers", detail: "300 minutes of deep focus — five hours on a single point.", badge: "badge_deep_5", tint: .violet, category: "Immersion", condition: .singleAppMinutesAtLeast(300), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "deep.480", title: "Pearl of the Abyss", detail: "480 minutes — eight hours straight, you reached the floor of the glowing abyss.", badge: "badge_deep_6", tint: .diamond, category: "Immersion", condition: .singleAppMinutesAtLeast(480), secret: false, reward: .menuBarIcon("sparkles"), tierStars: 5),
        // burst — Intensity
        Achievement(id: "burst.2500", title: "Idling", detail: "2 500 frames in a day — the engine started up.", badge: "badge_burst_1", tint: .bronze, category: "Intensity", condition: .framesInDayAtLeast(2500), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "burst.7500", title: "Clutch Caught", detail: "7 500 frames in a day — the gears engaged.", badge: "badge_burst_2", tint: .silver, category: "Intensity", condition: .framesInDayAtLeast(7500), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "burst.15000", title: "Clockwork", detail: "15 000 frames in a day — the whole mechanism is running.", badge: "badge_burst_3", tint: .amber, category: "Intensity", condition: .framesInDayAtLeast(15000), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "burst.25000", title: "Full Throttle", detail: "25 000 frames in a day — the engine at full.", badge: "badge_burst_4", tint: .gold, category: "Intensity", condition: .framesInDayAtLeast(25000), secret: false, reward: .appIcon("icon_alt_neon"), tierStars: 4),
        Achievement(id: "burst.40000", title: "Turbine Overheat", detail: "40 000 frames in a day — the reactor in the red zone, did you even sleep?", badge: "badge_burst_5", tint: .diamond, category: "Intensity", condition: .framesInDayAtLeast(40000), secret: false, reward: .none, tierStars: 5),
        // switch — Defocus
        Achievement(id: "switch.50", title: "Warmed Up", detail: "50 switches in a day — the wheel started spinning.", badge: "badge_switch_1", tint: .green, category: "Defocus", condition: .switchesInDayAtLeast(50), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "switch.150", title: "Squirrel in a Wheel", detail: "150 switches in a day — the squirrel's off and running.", badge: "badge_switch_2", tint: .teal, category: "Defocus", condition: .switchesInDayAtLeast(150), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "switch.300", title: "Carousel of Context", detail: "300 switches in a day — the carousel's spinning.", badge: "badge_switch_3", tint: .amber, category: "Defocus", condition: .switchesInDayAtLeast(300), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "switch.500", title: "Whirlpool of Windows", detail: "500 switches in a day — being pulled into the funnel.", badge: "badge_switch_4", tint: .violet, category: "Defocus", condition: .switchesInDayAtLeast(500), secret: false, reward: .menuBarIcon("bolt.fill"), tierStars: 4),
        Achievement(id: "switch.800", title: "Tornado of Defocus", detail: "800 switches in a day — a full whirlwind of windows, take a breath.", badge: "badge_switch_5", tint: .red, category: "Defocus", condition: .switchesInDayAtLeast(800), secret: false, reward: .none, tierStars: 5),
        // searches — Curiosity · Detective
        Achievement(id: "searches.5", title: "First Squint", detail: "Five searches. For the first time you aimed the magnifying glass at your own memory and realized — it's searchable.", badge: "badge_searches_1", tint: .bronze, category: "Curiosity · Detective", condition: .searchesAtLeast(5), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "searches.25", title: "Bloodhound's Nose", detail: "Twenty-five queries. A skill has emerged — you know which word will pull up the right frame.", badge: "badge_searches_2", tint: .silver, category: "Curiosity · Detective", condition: .searchesAtLeast(25), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "searches.100", title: "The Card Index Swells", detail: "A hundred searches. You've built up a real card index — the magnifying glass isn't alone anymore, a fan of cards beside it.", badge: "badge_searches_3", tint: .gold, category: "Curiosity · Detective", condition: .searchesAtLeast(100), secret: false, reward: .none, tierStars: 3),
        Achievement(id: "searches.500", title: "Detective's Desk", detail: "Five hundred queries. The magnifying glass gained an investigator's kit: optics, threads of theories, a pinned case card.", badge: "badge_searches_4", tint: .teal, category: "Curiosity · Detective", condition: .searchesAtLeast(500), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "searches.2000", title: "Chief Detective", detail: "Two thousand searches. You don't search — you run the case. A grand magnifier-bureau at the center of a cross-crest.", badge: "badge_searches_5", tint: .diamond, category: "Curiosity · Detective", condition: .searchesAtLeast(2000), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "searches.10000", title: "All-Seeing Bureau", detail: "Ten thousand. The bureau never sleeps. The magnifying glass gave way to a living eye-core with an orbit of lenses — memory is found in a single squint.", badge: "badge_searches_6", tint: .violet, category: "Curiosity · Detective", condition: .searchesAtLeast(10000), secret: false, reward: .none, tierStars: 5),
        // questions — Curiosity · Oracle
        Achievement(id: "questions.3", title: "A Timid Question", detail: "Three questions to memory. The crystal has just sprouted — a spark barely smolders inside.", badge: "badge_questions_1", tint: .bronze, category: "Curiosity · Oracle", condition: .questionsAtLeast(3), secret: false, reward: .none, tierStars: 1),
        Achievement(id: "questions.15", title: "A Faceted Question", detail: "Fifteen questions. The crystal took on facets, the spark inside burns steady — memory has begun to answer.", badge: "badge_questions_2", tint: .silver, category: "Curiosity · Oracle", condition: .questionsAtLeast(15), secret: false, reward: .none, tierStars: 2),
        Achievement(id: "questions.50", title: "The Speaking Crystal", detail: "Fifty questions. The crystal has spoken — a glowing oracle formed inside, answering any query.", badge: "badge_questions_3", tint: .gold, category: "Curiosity · Oracle", condition: .questionsAtLeast(50), secret: false, reward: .menuBarIcon("eye.fill"), tierStars: 3),
        Achievement(id: "questions.150", title: "Floating Oracle", detail: "A hundred fifty questions. The crystal broke free of its setting and floats — shards of past answers orbit around it.", badge: "badge_questions_4", tint: .teal, category: "Curiosity · Oracle", condition: .questionsAtLeast(150), secret: false, reward: .none, tierStars: 4),
        Achievement(id: "questions.500", title: "Mind-Obelisk", detail: "Five hundred questions. The crystal grew into a floating obelisk of mind with an eye at its core — it sees the answer before the question.", badge: "badge_questions_5", tint: .diamond, category: "Curiosity · Oracle", condition: .questionsAtLeast(500), secret: false, reward: .none, tierStars: 5),
        Achievement(id: "questions.2000", title: "Omniscient Oracle", detail: "Two thousand questions. The obelisk collapsed into a self-luminous sphere-mind — you barely need to ask, it already knows.", badge: "badge_questions_6", tint: .violet, category: "Curiosity · Oracle", condition: .questionsAtLeast(2000), secret: false, reward: .none, tierStars: 5),
        // special achievements (flag signals)
        Achievement(id: "time.night", title: "Night Owl", detail: "Activity after midnight — the eye doesn't sleep, and neither do you", badge: "badge_night", tint: .violet, category: "Time of Day", condition: .nightActivity, secret: false, reward: .menuBarIcon("moon.stars.fill"), tierStars: 0),
        Achievement(id: "time.early", title: "Early Bird", detail: "Activity before 7 a.m. — dawn caught you at work", badge: "badge_early", tint: .amber, category: "Time of Day", condition: .earlyActivity, secret: false, reward: .none, tierStars: 0),
        Achievement(id: "time.weekend", title: "Weekend Ghost", detail: "Worked on a day off — ever tried resting?", badge: "badge_weekend", tint: .teal, category: "Time of Day", condition: .weekendActivity, secret: true, reward: .none, tierStars: 0),
        Achievement(id: "focus.zen", title: "Zen Focus", detail: "A day without fuss: lots of work, almost no switching", badge: "badge_focus", tint: .red, category: "Focus", condition: .focusDay, secret: false, reward: .none, tierStars: 0),
        Achievement(id: "ctrl.clean", title: "Cleaner", detail: "Wiped a period of history — your right", badge: "badge_clean", tint: .lime, category: "Control", condition: .deletedPeriod, secret: false, reward: .none, tierStars: 0),
        Achievement(id: "ctrl.disk", title: "To Your Own Disk", detail: "Moved your memory to an external SSD", badge: "badge_relocate", tint: .blue, category: "Control", condition: .relocated, secret: false, reward: .none, tierStars: 0),
        Achievement(id: "ctrl.cloud", title: "Cloud Guardian", detail: "Enabled compressed iCloud backup", badge: "badge_guard", tint: .teal, category: "Control", condition: .icloudBackup, secret: false, reward: .appIcon("icon_alt_frost"), tierStars: 0),
    ]

    /// Categories in order of appearance (for grouping in the gallery).
    static let categories: [String] = ["Memory · Volume", "Memory · Age", "Consistency", "Days of Memory", "Cartographer", "Scenes", "Atlas", "Constellation", "Network", "Immersion", "Intensity", "Defocus", "Curiosity · Detective", "Curiosity · Oracle", "Time of Day", "Focus", "Control"]
}
