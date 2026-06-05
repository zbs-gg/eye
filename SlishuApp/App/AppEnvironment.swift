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
    private(set) var timelineStore: TimelineStore?
    private(set) var httpServer: SlishuHTTPServer?
    private(set) var dataError: String?

    /// Порядок запуска фоновых сервисов. Пока — пробы прав + Data-слой; capture/server/pipes добавятся
    /// по мере появления модулей (Фаза 2, шаги 3+).
    func bootstrap() async {
        SlishuHTTPServer.log("bootstrap: begin")
        await permissions.refreshAll()
        do {
            let storage = try StorageManager()
            let db = try SlishuDatabase(path: SlishuDatabase.defaultURL().path)
            SlishuHTTPServer.log("bootstrap: db ok")
            self.database = db
            // Отдельные embedder для ingest и search — иначе тяжёлый embed на захвате блокирует
            // эмбеддинг поискового запроса (head-of-line, по ревью).
            let ingestService = IngestService(db: db, storage: storage, embedder: EmbeddingService())
            self.ingest = ingestService
            let retention = RetentionManager(db: db, storage: storage)
            self.retention = retention

            // Capture loop (сердце). Стартует по toggle в RecordingStore.
            let coordinator = CaptureCoordinator(ingest: ingestService)
            coordinator.onFrame = { [weak rec = recording] in rec?.noteFrame() }
            recording.coordinator = coordinator

            // Поиск (гибрид FTS+vector) + таймлайн.
            let searchSvc = SearchService(db: db, embedder: EmbeddingService())
            let timelineSvc = TimelineService(db: db)
            self.timelineStore = TimelineStore(search: searchSvc, timeline: timelineSvc,
                                               mediaDirectory: storage.mediaDirectory)

            // Локальный REST /v1 (auth на всё кроме /health).
            let token = KeychainStore.apiToken()
            let rec = recording
            let deps = SlishuHTTPServer.Deps(
                search: searchSvc, timeline: timelineSvc, db: db, mediaDir: storage.mediaDirectory,
                token: token, version: "0.1.0",
                isCapturing: { await MainActor.run { rec.isCapturing } },
                toggleCapture: { enable in
                    await MainActor.run {
                        if let enable, enable == rec.isCapturing { return rec.isCapturing }
                        rec.toggle()
                        return rec.isCapturing
                    }
                },
                mediaBytes: { storage.totalBytes() })
            let server = SlishuHTTPServer(deps: deps)
            self.httpServer = server
            Task { [weak self] in
                let port = await server.start()
                SlishuHTTPServer.log("bootstrap: start -> \(String(describing: port))")
                if let port { await MainActor.run { self?.server.setActive(port: port, token: token) } }
            }

            // Прунинг по дефолтам (7д/20GB) фоном при старте. Позже (шаг 11) — таймер + size-trigger.
            Task.detached(priority: .utility) {
                _ = try? await retention.prune(retentionDays: RetentionPolicy.defaultDays,
                                               maxBytes: RetentionPolicy.defaultMaxBytes)
            }
        } catch {
            self.dataError = String(describing: error)
            SlishuHTTPServer.log("bootstrap: dataError \(error)")
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
