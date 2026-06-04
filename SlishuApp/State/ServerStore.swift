import Foundation
import Observation

/// Заглушка состояния локального сервера. В Фазе 2 (шаг 5) обёрнёт SlishuHTTPServer (actor),
/// покажет реальный активный порт (фикс путаницы с 8080).
@MainActor
@Observable
final class ServerStore {
    private(set) var activePort: Int?
    private(set) var running = false

    var baseURL: String { activePort.map { "http://127.0.0.1:\($0)" } ?? "—" }
}
