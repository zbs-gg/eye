import Foundation
import CoreGraphics

/// Capture budgets/thresholds (DI, testable). From the v2 plan + harness numbers.
struct CaptureConfig: Sendable {
    var axBudgetMs = 120
    var axMessagingTimeout = 0.05          // 50ms/call — one slow node won't eat the budget
    var axMaxNodes = 20_000
    var axEmptyRetryMs = 400               // one retry on an empty tree (lazy Electron build)
    var usefulThreshold = 40               // contentChars → not titleOnly
    var fullUsefulThreshold = 800
    var dedupHammingThreshold = 3
    var ocrMinContentChars = 24            // below this + empty AX → OCR
    var ocrLanguages = ["ru-RU", "en-US"]
    var ocrDownscaleMaxDim: CGFloat = 1800 // downscale before OCR (Pro: don't OCR a full Retina frame)
    var activeTickSeconds = 3.0            // active-text fallback tick (single-flight + dedup protect it)
    var idleThresholdSec = 180.0           // no input for longer → rare idle mode (not a full stop)
    var idleCaptureIntervalSec = 60.0      // in idle: one frame per minute — "incoming without input" isn't lost
    var burstTrioDelays: [Double] = [0.7, 2.0]  // extra frames after an app switch (Electron finishes rendering)
    var ocrOnlyEmptyStreak = 2             // consecutive empty AX → mark the bundleId as ocrOnly
}

/// Result of AX extraction (Sendable; AXUIElement does not cross the boundary).
struct AXExtraction: Sendable {
    var contentText: String = ""
    var contentChars: Int = 0
    var chromeChars: Int = 0
    var windowTitle: String?
    var browserURL: String?
    var nodeCount: Int = 0
    var hitBudgetLimit: Bool = false
    var treeWasEmpty: Bool = false
    var quality: AXQuality = .none
    var manualResult: String?
    var enhancedResult: String?
}
