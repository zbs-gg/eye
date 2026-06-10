import Foundation
import Observation
import GRDB

/// Разбивка занятого места (Sendable — возвращается из Task.detached в @MainActor). Атрибуция
/// импорт/живое по monitorId='sp' (живой захват пишет monitorId=String(displayID): '0'/'1'…).
struct StorageBreakdown: Sendable, Equatable {
    var framesTotal = 0
    var framesImport = 0
    var framesLive = 0
    var audioTotal = 0
    var oldestTs: Int64?
    var newestTs: Int64?
    var liveFrameBytes: Int64 = 0       // импорт имеет bytes=NULL → это размер только живых кадров в БД
    var topApps: [AppUsage] = []

    struct AppUsage: Sendable, Equatable, Identifiable {
        let name: String
        let frames: Int
        var id: String { name }
    }
}

/// Настройки хранилища: retention (дни/объём, 0 = без лимита) + сколько реально занято.
/// Раньше юзер вообще не знал, что его история живёт 7 дней (хардкод без UI) — для продукта
/// «вечная память» это молчаливое стирание трёх недель жизни.
@MainActor
@Observable
final class StorageSettingsStore {
    /// 0 = хранить вечно. Дефолт 0 («вечная память» — НЕ удаляем по умолчанию).
    var retentionDays: Int {
        didSet { if retentionDays != oldValue { UserDefaults.standard.set(retentionDays, forKey: Self.daysKey) } }
    }
    /// Лимит в ГБ; 0 = без лимита. Дефолт 0.
    var maxGB: Int {
        didSet { if maxGB != oldValue { UserDefaults.standard.set(maxGB, forKey: Self.gbKey) } }
    }

    private(set) var mediaBytes: Int64 = 0
    private(set) var databaseBytes: Int64 = 0
    private(set) var freeBytes: Int64 = 0
    private(set) var breakdown: StorageBreakdown?
    var totalBytes: Int64 { mediaBytes + databaseBytes }

    // relocate (T1): состояние переноса хранилища
    var relocationInProgress = false
    var relocationProgress: Double = 0
    var relocationStatus = ""
    var relocationError: String?
    var dataRootDisplay: String { StorageLocation.displayPath() }
    var isRelocated: Bool { StorageLocation.isRelocated() }

    @ObservationIgnored private static let daysKey = "slishu.retention.days"
    @ObservationIgnored private static let gbKey = "slishu.retention.maxGB"

    static let dayOptions = [0, 7, 14, 30, 90]   // 0 = «Вечно» первым: дефолт и суть продукта
    static let gbOptions = [0, 10, 20, 50, 100]   // 0 = «Без лимита» первым

    var effectiveDays: Int? { retentionDays <= 0 ? nil : retentionDays }
    var effectiveMaxBytes: Int64? { maxGB <= 0 ? nil : Int64(maxGB) * 1024 * 1024 * 1024 }

    init() {
        let d = UserDefaults.standard
        retentionDays = (d.object(forKey: Self.daysKey) == nil) ? RetentionPolicy.defaultDays
                                                                : d.integer(forKey: Self.daysKey)
        maxGB = (d.object(forKey: Self.gbKey) == nil) ? 0 : d.integer(forKey: Self.gbKey)
    }

    /// Пересчёт занятого места (медиа — обход папки, БД — размер sqlite+wal, свободно на томе) +
    /// разбивка из БД (кадры импорт/живые, аудио, диапазон дат, топ-приложений). Вызывается при
    /// открытии Settings; всё на utility-фоне одной read-транзакцией.
    func refresh(storage: StorageManager?, db: SlishuDatabase?) async {
        guard let storage else { return }
        let computed = await Task.detached(priority: .utility) { () async -> (Int64, Int64, Int64, StorageBreakdown?) in
            let media = storage.totalBytes()
            let free = storage.freeBytes()
            var dbBytes: Int64 = 0
            if let url = try? SlishuDatabase.defaultURL() {
                for suffix in ["", "-wal", "-shm"] {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
                    dbBytes += (attrs?[.size] as? Int64) ?? 0
                }
            }
            let bd: StorageBreakdown? = await Self.computeBreakdown(db: db)
            return (media, dbBytes, free, bd)
        }.value
        mediaBytes = computed.0
        databaseBytes = computed.1
        freeBytes = computed.2
        breakdown = computed.3
    }

    /// Одна агрегатная read-транзакция: счётчики/атрибуция/диапазон + топ-приложений. nil при отсутствии БД.
    /// nonisolated: вызывается из Task.detached в refresh, не должна прыгать на MainActor.
    nonisolated private static func computeBreakdown(db: SlishuDatabase?) async -> StorageBreakdown? {
        guard let db else { return nil }
        return try? await db.pool.read { dbc -> StorageBreakdown in
            var bd = StorageBreakdown()
            if let row = try Row.fetchOne(dbc, sql: """
                SELECT
                  (SELECT COUNT(*) FROM screen_captures) AS framesTotal,
                  (SELECT COUNT(*) FROM screen_captures WHERE monitorId = 'sp') AS framesImport,
                  (SELECT COUNT(*) FROM screen_captures WHERE monitorId <> 'sp') AS framesLive,
                  (SELECT COUNT(*) FROM audio_captures) AS audioTotal,
                  (SELECT MIN(ts) FROM screen_captures) AS oldestTs,
                  (SELECT MAX(ts) FROM screen_captures) AS newestTs,
                  (SELECT COALESCE(SUM(bytes), 0) FROM screen_captures WHERE bytes IS NOT NULL) AS liveFrameBytes
                """) {
                bd.framesTotal = row["framesTotal"] ?? 0
                bd.framesImport = row["framesImport"] ?? 0
                bd.framesLive = row["framesLive"] ?? 0
                bd.audioTotal = row["audioTotal"] ?? 0
                bd.oldestTs = row["oldestTs"]
                bd.newestTs = row["newestTs"]
                bd.liveFrameBytes = row["liveFrameBytes"] ?? 0
            }
            bd.topApps = try Row.fetchAll(dbc, sql: """
                SELECT COALESCE(a.name, '(?)') AS name, COUNT(*) AS frames
                FROM screen_captures c LEFT JOIN apps a ON a.id = c.appId
                GROUP BY c.appId ORDER BY frames DESC LIMIT 6
                """).map { StorageBreakdown.AppUsage(name: $0["name"], frames: $0["frames"]) }
            return bd
        }
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
