import os

/// Структурные логи (os.Logger, subsystem com.slishu.app) — видны в Console.app на любой машине,
/// в т.ч. у друга при удалённой диагностике «запись умерла ночью». Категории по подсистемам.
/// privacy: .public только для не-приватных значений (счётчики, коды ошибок) — НЕ для текста экрана.
enum Log {
    static let app = Logger(subsystem: "com.slishu.app", category: "app")
    static let capture = Logger(subsystem: "com.slishu.app", category: "capture")
    static let ingest = Logger(subsystem: "com.slishu.app", category: "ingest")
    static let audio = Logger(subsystem: "com.slishu.app", category: "audio")
    static let server = Logger(subsystem: "com.slishu.app", category: "server")
    static let retention = Logger(subsystem: "com.slishu.app", category: "retention")
}
