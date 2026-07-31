import Foundation

enum CaptureClass: Sendable, Equatable {
    case unknown
    case axViable
    case ocrOnly
}

struct AccessibilityCaptureDecision: Sendable, Equatable {
    let needsOCR: Bool
    let learnedClass: CaptureClass?
    let emptyStreak: Int
}

enum BrowserCapturePolicy {
    static let chromiumBrowserBundleIDs: Set<String> = [
        "company.thebrowser.dia",
        "company.thebrowser.arc",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "org.chromium.Chromium",
    ]

    static func isChromiumBrowser(_ bundleID: String) -> Bool {
        chromiumBrowserBundleIDs.contains(bundleID)
    }

    static func effectiveClass(bundleID: String, learned: CaptureClass) -> CaptureClass {
        if isChromiumBrowser(bundleID), learned == .ocrOnly { return .unknown }
        return learned
    }

    static func afterAccessibility(
        bundleID: String,
        extraction: AXExtraction,
        previousEmptyStreak: Int,
        config: CaptureConfig
    ) -> AccessibilityCaptureDecision {
        if extraction.contentChars >= config.usefulThreshold {
            return .init(needsOCR: false, learnedClass: .axViable, emptyStreak: 0)
        }

        let timedOut = extraction.hitBudgetLimit || extraction.quality == .timedOut
        if isChromiumBrowser(bundleID) {
            return .init(
                needsOCR: browserFallbackNeedsOCR(url: extraction.browserURL),
                learnedClass: nil,
                emptyStreak: 0
            )
        }

        let lowSemanticText = extraction.contentChars < config.ocrMinContentChars
        let fallbackQuality = extraction.quality == .none
            || extraction.quality == .titleOnly
            || extraction.quality == .sickPID
            || extraction.quality == .timedOut
            || extraction.treeWasEmpty
        let needsOCR = lowSemanticText && fallbackQuality
        guard !timedOut, extraction.treeWasEmpty else {
            return .init(needsOCR: needsOCR, learnedClass: nil, emptyStreak: timedOut ? 0 : previousEmptyStreak)
        }
        let nextStreak = previousEmptyStreak + 1
        return .init(
            needsOCR: needsOCR,
            learnedClass: nextStreak >= config.ocrOnlyEmptyStreak ? .ocrOnly : nil,
            emptyStreak: nextStreak
        )
    }

    static func browserFallbackNeedsOCR(url: String?) -> Bool {
        guard let url, let parsed = URL(string: url) else { return false }
        if let scheme = parsed.scheme?.lowercased(), scheme != "http", scheme != "https" { return true }
        return [
            "pdf", "png", "jpg", "jpeg", "gif", "webp", "avif", "heic",
            "mp4", "mov", "m4v", "webm",
        ].contains(parsed.pathExtension.lowercased())
    }

    static func allowsBrowserOCR(lastAt: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastAt else { return true }
        return now.timeIntervalSince(lastAt) >= interval
    }
}
