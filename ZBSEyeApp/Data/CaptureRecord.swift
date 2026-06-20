import Foundation
import CoreGraphics

/// Контракт между capture-слоем (Фаза 2, шаг 6) и Data-слоем. Capture формирует эти Sendable-значения
/// и отдаёт в `IngestService`. Не трогает SQL/FTS напрямую.

public enum TextSource: String, Sendable, Codable {
    case ax     // accessibility — primary
    case ocr    // Vision fallback
}

/// Качество AX-извлечения (телеметрия, чтобы доказывать AX-first; из harness 1a).
public enum AXQuality: String, Sendable, Codable {
    case none, titleOnly, partialUseful, fullUseful, timedOut, sickPID, ocr
}

public struct CapturedTextBlock: Sendable {
    public let source: TextSource
    public let text: String
    public let confidence: Double
    public let bbox: CGRect?
    public init(source: TextSource, text: String, confidence: Double = 1.0, bbox: CGRect? = nil) {
        self.source = source; self.text = text; self.confidence = confidence; self.bbox = bbox
    }
}

public enum ImagePayload: Sendable {
    case heicData(Data)                       // capture сжал, Data-слой пишет файл
    case fileWritten(relativePath: String)    // capture уже записал файл
    case none                                 // dedup context-only record (без кадра)
}

/// Телеметрия извлечения (план v2 — доказывать AX-first, не «tree непустой = успех»). Из harness 1a.
public struct CaptureTelemetry: Sendable {
    public var usefulTextChars: Int = 0
    public var nodeCount: Int = 0
    public var treeWasEmpty: Bool = false
    public var hitBudgetLimit: Bool = false
    public var ocrFallbackReason: String? = nil
    public var manualAccessibilityResult: String? = nil   // success/attributeUnsupported/...
    public var enhancedUiResult: String? = nil
    public init() {}
    public init(usefulTextChars: Int, nodeCount: Int, treeWasEmpty: Bool, hitBudgetLimit: Bool,
                ocrFallbackReason: String?, manualAccessibilityResult: String?, enhancedUiResult: String?) {
        self.usefulTextChars = usefulTextChars; self.nodeCount = nodeCount
        self.treeWasEmpty = treeWasEmpty; self.hitBudgetLimit = hitBudgetLimit
        self.ocrFallbackReason = ocrFallbackReason
        self.manualAccessibilityResult = manualAccessibilityResult; self.enhancedUiResult = enhancedUiResult
    }
}

public struct ScreenCaptureRecord: Sendable {
    public let timestamp: Date
    public let bundleId: String
    public let appName: String
    public let windowTitle: String?
    public let browserURL: String?
    public let monitorId: String
    public let image: ImagePayload
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let textBlocks: [CapturedTextBlock]
    public let axQuality: AXQuality
    public let telemetry: CaptureTelemetry

    public init(timestamp: Date, bundleId: String, appName: String, windowTitle: String?,
                browserURL: String?, monitorId: String, image: ImagePayload,
                pixelWidth: Int, pixelHeight: Int, textBlocks: [CapturedTextBlock],
                axQuality: AXQuality, telemetry: CaptureTelemetry = CaptureTelemetry()) {
        self.timestamp = timestamp; self.bundleId = bundleId; self.appName = appName
        self.windowTitle = windowTitle; self.browserURL = browserURL; self.monitorId = monitorId
        self.image = image; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.textBlocks = textBlocks; self.axQuality = axQuality; self.telemetry = telemetry
    }
}

public struct AudioCaptureRecord: Sendable {
    public let timestamp: Date
    public let relativePath: String
    public let durationSec: Double
    public let channel: String   // "mic" | "system"
    public let bytes: Int?       // размер файла (для retention size-accounting)
    public init(timestamp: Date, relativePath: String, durationSec: Double,
                channel: String = "mic", bytes: Int? = nil) {
        self.timestamp = timestamp; self.relativePath = relativePath
        self.durationSec = durationSec; self.channel = channel; self.bytes = bytes
    }
}
