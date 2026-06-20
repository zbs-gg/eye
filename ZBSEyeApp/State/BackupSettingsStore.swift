import Foundation
import Observation

/// Настройки iCloud-бэкапа. Дефолт ON если iCloud доступен (директива Ника «по умолчанию в iCloud» —
/// безопасно, потому что в iCloud уезжает только сжатый снапшот, живая база локальна). См. [[BackupManager]].
@MainActor
@Observable
final class BackupSettingsStore {
    var enabled: Bool {
        didSet { if enabled != oldValue { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) } }
    }
    var keepN: Int {
        didSet { if keepN != oldValue { UserDefaults.standard.set(keepN, forKey: Self.keepKey) } }
    }

    private(set) var iCloudAvailable = false
    private(set) var lastBackupAt: Date?
    private(set) var lastResult: String?
    private(set) var backupCount = 0
    private(set) var busy = false
    private(set) var error: String?

    static let keepOptions = [3, 7, 14, 30]
    @ObservationIgnored private static let enabledKey = "zbseye.backup.enabled"
    @ObservationIgnored private static let keepKey = "zbseye.backup.keepN"
    @ObservationIgnored private static let lastKey = "zbseye.backup.lastAt"

    @ObservationIgnored var manager: BackupManager?

    init() {
        let d = UserDefaults.standard
        let available = BackupManager.iCloudAvailable()
        enabled = (d.object(forKey: Self.enabledKey) == nil) ? available : d.bool(forKey: Self.enabledKey)
        keepN = (d.object(forKey: Self.keepKey) == nil) ? 7 : d.integer(forKey: Self.keepKey)
        iCloudAvailable = available
        if let t = d.object(forKey: Self.lastKey) as? Double { lastBackupAt = Date(timeIntervalSince1970: t) }
    }

    func refresh() {
        iCloudAvailable = BackupManager.iCloudAvailable()
        backupCount = BackupManager.listBackups().count
    }

    /// Зафиксировать результат фонового (по расписанию) бэкапа в UI-состоянии.
    func noteScheduledBackup(_ r: BackupResult) {
        let now = Date()
        lastBackupAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastKey)
        lastResult = "\(StorageSettingsStore.format(r.compressedBytes)) (\(r.frames) кадров)"
        backupCount = BackupManager.listBackups().count
    }

    @discardableResult
    func backupNow() async -> Bool {
        guard let manager else { return false }
        guard BackupManager.iCloudAvailable() else {
            error = BackupError.iCloudUnavailable.errorDescription
            return false
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let r = try await manager.makeBackup(keepN: keepN)
            let now = Date()
            lastBackupAt = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastKey)
            lastResult = "\(StorageSettingsStore.format(r.compressedBytes)) (из \(StorageSettingsStore.format(r.sourceBytes)), \(r.frames) кадров)"
            backupCount = BackupManager.listBackups().count
            return true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return false
        }
    }
}
