import Foundation

enum SearchKind: String, Sendable { case screen, audio }

struct SearchResult: Sendable, Identifiable {
    let id: Int64
    let kind: SearchKind
    let ts: Date
    let bundleId: String?
    let appName: String?
    let windowTitle: String?
    let browserURL: String?
    let snippet: String
    let relativePath: String?

    /// `id` (rowid) сам по себе не уникален между screen и audio — в ForEach это коллизия.
    /// Композитный ключ kind:id уникален.
    var uniqueKey: String { "\(kind.rawValue):\(id)" }
}

struct DensityBucket: Sendable, Identifiable {
    let ts: Date
    let count: Int
    var id: Double { ts.timeIntervalSince1970 }
}

struct FrameDetail: Sendable, Identifiable {
    let id: Int64
    let ts: Date
    let relativePath: String?
    let bundleId: String?
    let appName: String?
    let windowTitle: String?
    let browserURL: String?
    let text: String
    let axQuality: String?
    /// Источники текста этого кадра (distinct по text_blocks.source): "ax" и/или "ocr".
    /// ax_quality ≠ источник: кадр может быть fullUseful, а блоки — смесь ax+ocr.
    var sources: [String] = []

    var hasAX: Bool { sources.contains("ax") }
    var hasOCR: Bool { sources.contains("ocr") }
}

struct TimeBounds: Sendable {
    let oldest: Date?
    let newest: Date?
}

/// Аудио-сегмент для таймлайна: транскрипт + файл для прослушивания. Раньше клик по аудио-хиту
/// показывал ближайший ЭКРАННЫЙ кадр и транскрипт пропадал — найденный звонок был тупиком.
struct AudioDetail: Sendable, Identifiable {
    let id: Int64
    let ts: Date
    let durationSec: Double
    let channel: String          // "mic" | "system"
    let relativePath: String
    let transcript: String?
    let language: String?
}

@inline(__always) func dateFromMs(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
@inline(__always) func msFromDate(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
