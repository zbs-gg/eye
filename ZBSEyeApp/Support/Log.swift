import os

/// Структурные логи (os.Logger, subsystem gg.zbs.eye) — видны в Console.app на любой машине,
/// в т.ч. у друга при удалённой диагностике «запись умерла ночью». Категории по подсистемам.
/// privacy: .public только для не-приватных значений (счётчики, коды ошибок) — НЕ для текста экрана.
enum Log {
    static let app = Logger(subsystem: "gg.zbs.eye", category: "app")
    static let capture = Logger(subsystem: "gg.zbs.eye", category: "capture")
    static let ingest = Logger(subsystem: "gg.zbs.eye", category: "ingest")
    static let audio = Logger(subsystem: "gg.zbs.eye", category: "audio")
    static let server = Logger(subsystem: "gg.zbs.eye", category: "server")
    static let retention = Logger(subsystem: "gg.zbs.eye", category: "retention")
}
