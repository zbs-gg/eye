import Foundation
import Observation

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
    var totalBytes: Int64 { mediaBytes + databaseBytes }

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

    /// Пересчёт занятого места (медиа — обход папки, БД — размер sqlite+wal). Вызывается при открытии
    /// Settings; обход на utility-фоне.
    func refresh(storage: StorageManager?) async {
        guard let storage else { return }
        let computed = await Task.detached(priority: .utility) { () -> (Int64, Int64) in
            let media = storage.totalBytes()
            var db: Int64 = 0
            if let url = try? SlishuDatabase.defaultURL() {
                for suffix in ["", "-wal", "-shm"] {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
                    db += (attrs?[.size] as? Int64) ?? 0
                }
            }
            return (media, db)
        }.value
        mediaBytes = computed.0
        databaseBytes = computed.1
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
