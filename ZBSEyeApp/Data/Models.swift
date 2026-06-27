import Foundation
import GRDB

/// GRDB models. Columns — camelCase (matching the property names, without CodingKeys mapping).
/// REST-DTO (snake_case/ISO) — a separate layer (Phase 2, step 5).

struct AppRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "apps"
    var id: Int64?
    var bundleId: String
    var name: String
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct ScreenCaptureRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "screen_captures"
    var id: Int64?
    var ts: Int64                 // epoch ms
    var appId: Int64?
    var windowTitle: String?
    var browserUrl: String?
    var monitorId: String
    var relativePath: String?
    var width: Int?
    var height: Int?
    var bytes: Int?
    var axQuality: String?
    // telemetry (v2 plan — to prove AX-first)
    var usefulTextChars: Int?
    var nodeCount: Int?
    var treeWasEmpty: Bool?
    var hitBudgetLimit: Bool?
    var ocrFallbackReason: String?
    var manualAccessibilityResult: String?
    var enhancedUiResult: String?
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct TextBlockRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "text_blocks"
    var id: Int64?
    var captureId: Int64
    var source: String            // "ax" | "ocr"
    var text: String
    var confidence: Double
    // bbox: NORMALIZED [0..1], origin BOTTOM-LEFT (Vision/CoreGraphics; only source='ocr' writes it).
    // To draw on the SwiftUI/AppKit layer (origin top-left), invert Y: screenY = 1 - bboxY - bboxH.
    var bboxX: Double?
    var bboxY: Double?
    var bboxW: Double?
    var bboxH: Double?
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct AudioCaptureRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "audio_captures"
    var id: Int64?
    var ts: Int64
    var relativePath: String
    var durationSec: Double
    var channel: String
    var bytes: Int?
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct TranscriptionRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "transcriptions"
    var id: Int64?
    var audioId: Int64
    var text: String
    var language: String
    var speaker: String?
    var startOffset: Double?
    var endOffset: Double?
    var engine: String
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
