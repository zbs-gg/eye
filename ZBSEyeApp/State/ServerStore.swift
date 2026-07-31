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
    private(set) var browserToken: String?
    private(set) var browserLastSeenAt: Date?

    var baseURL: String { activePort.map { "http://127.0.0.1:\($0)" } ?? "—" }

    func setActive(port: Int, token: String, browserToken: String) {
        activePort = port
        self.token = token
        self.browserToken = browserToken
        running = true
    }

    func noteBrowserSnapshot(at date: Date) {
        browserLastSeenAt = date
    }

    func clearBrowserConnection() {
        browserLastSeenAt = nil
    }

    func browserConnectionStatus(now: Date = Date()) -> BrowserConnectionStatus {
        guard let browserLastSeenAt else { return .disconnected }
        let age = now.timeIntervalSince(browserLastSeenAt)
        if age <= 10 { return .connected }
        if age <= 60 { return .stale }
        return .disconnected
    }
}
