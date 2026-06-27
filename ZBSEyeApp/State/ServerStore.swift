import Foundation
import Observation

/// Stub for the local server state. In Phase 2 (step 5) it will wrap ZBSEyeHTTPServer (actor)
/// and show the real active port (fixes the confusion with 8080).
@MainActor
@Observable
final class ServerStore {
    private(set) var activePort: Int?
    private(set) var running = false
    private(set) var token: String?

    var baseURL: String { activePort.map { "http://127.0.0.1:\($0)" } ?? "—" }

    func setActive(port: Int, token: String) {
        activePort = port
        self.token = token
        running = true
    }
}
