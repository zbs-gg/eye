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

    /// Порядок запуска фоновых сервисов. Пока — только пробы прав; capture/server/pipes добавятся
    /// по мере появления модулей (Фаза 2, шаги 3+).
    func bootstrap() async {
        await permissions.refreshAll()
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
