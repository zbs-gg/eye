import os

/// Structured logs (os.Logger, subsystem gg.zbs.eye) — visible in Console.app on any machine,
/// including a friend's during remote diagnostics of "recording died overnight". Categories by subsystem.
/// privacy: .public only for non-private values (counters, error codes) — NOT for screen text.
enum Log {
    static let app = Logger(subsystem: "gg.zbs.eye", category: "app")
    static let capture = Logger(subsystem: "gg.zbs.eye", category: "capture")
    static let ingest = Logger(subsystem: "gg.zbs.eye", category: "ingest")
    static let audio = Logger(subsystem: "gg.zbs.eye", category: "audio")
    static let server = Logger(subsystem: "gg.zbs.eye", category: "server")
    static let retention = Logger(subsystem: "gg.zbs.eye", category: "retention")
}
