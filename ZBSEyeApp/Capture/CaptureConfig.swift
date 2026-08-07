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
    var maxCaptureDim: CGFloat = 2560      // cap capture to this longest side: a full 5K frame is a ~59MB IOSurface —
                                           // capping to 2560 cuts the per-frame surface & HEIC ~2–4× (OCR downscales anyway)
    var heicQuality: Double = 0.6          // HEIC lossy quality for STORED frames (0…1). OCR runs on the live frame
                                           // BEFORE encode, so this only affects timeline viewing. Measured on real
                                           // frames: the old untuned default was ≈q0.8; 0.6 is ~19% smaller with no
                                           // visible loss (0.5 ≈ −35%, 0.4 ≈ −44% if you want more aggressive).
    var activeTickSeconds = 3.0            // active-text fallback tick (single-flight + dedup protect it)
    var streamFrameIntervalSec = 2.0       // one persistent SCK stream; low-frequency enough to coexist with screenshots
    var streamQueueDepth = 3               // Apple's recommended small IOSurface queue; processing remains latest-wins
    var streamLivenessTimeoutSec = 8.0     // only complete/idle frame silence this long is a screen-leg failure
    var idleThresholdSec = 180.0           // no input for longer → rare idle mode (not a full stop)
    var idleCaptureIntervalSec = 60.0      // in idle: one frame per minute — "incoming without input" isn't lost
    var ocrOnlyEmptyStreak = 2             // consecutive empty AX → mark the bundleId as ocrOnly
    var browserOCRIntervalSec = 30.0       // canvas/PDF/video fallback: never OCR more often than this
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
