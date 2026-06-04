import Foundation
import Observation

/// Корневое состояние приложения. Единственный @Observable, инжектится через .environment.
/// Владеет всеми store'ами (по плану v2 — вместо разрозненных @State и 14-биндингового антипаттерна).
@MainActor
@Observable
final class AppEnvironment {
    let permissions = PermissionsStore()
    let recording = RecordingStore()
    let server = ServerStore()

    var selectedSection: SidebarSection = .timeline

    // Data-слой (создаётся в bootstrap; nil до инициализации / при ошибке).
    private(set) var database: SlishuDatabase?
    private(set) var ingest: IngestService?
    private(set) var retention: RetentionManager?
    private(set) var dataError: String?

    /// Порядок запуска фоновых сервисов. Пока — пробы прав + Data-слой; capture/server/pipes добавятся
    /// по мере появления модулей (Фаза 2, шаги 3+).
    func bootstrap() async {
        await permissions.refreshAll()
        do {
            let storage = try StorageManager()
            let db = try SlishuDatabase(path: SlishuDatabase.defaultURL().path)
            self.database = db
            self.ingest = IngestService(db: db, storage: storage)
            self.retention = RetentionManager(db: db, storage: storage)
        } catch {
            self.dataError = String(describing: error)
        }
        // TODO(Фаза 2): server.start(); recording.startIfPermittedAndEnabled(); pipes.resume()
    }
}

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case timeline = "Таймлайн"
    case pipes = "Плагины"
    case connections = "Подключения"
    case settings = "Настройки"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .timeline:    return "clock.arrow.circlepath"
        case .pipes:       return "powerplug"
        case .connections: return "app.connected.to.app.below.fill"
        case .settings:    return "gearshape"
        }
    }
}
