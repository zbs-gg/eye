import XCTest

final class BrowserCapturePolicyTests: XCTestCase {
    func testBudgetTimeoutNeverLearnsOCROnly() {
        var extraction = AXExtraction()
        extraction.treeWasEmpty = true
        extraction.hitBudgetLimit = true
        extraction.quality = .timedOut
        let decision = BrowserCapturePolicy.afterAccessibility(
            bundleID: "com.example.slow-app",
            extraction: extraction,
            previousEmptyStreak: 1,
            config: CaptureConfig()
        )
        XCTAssertNil(decision.learnedClass)
        XCTAssertEqual(decision.emptyStreak, 0)
    }

    func testChromiumNeverLearnsOCROnlyFromEmptyAccessibility() {
        var extraction = AXExtraction()
        extraction.treeWasEmpty = true
        extraction.quality = .none
        let decision = BrowserCapturePolicy.afterAccessibility(
            bundleID: "company.thebrowser.dia",
            extraction: extraction,
            previousEmptyStreak: 10,
            config: CaptureConfig()
        )
        XCTAssertNil(decision.learnedClass)
        XCTAssertEqual(decision.emptyStreak, 0)
        XCTAssertFalse(decision.needsOCR)
        XCTAssertEqual(
            BrowserCapturePolicy.effectiveClass(bundleID: "company.thebrowser.dia", learned: .ocrOnly),
            .unknown
        )
    }

    func testBrowserFallbackOCRIsLimitedAndThrottled() {
        XCTAssertFalse(BrowserCapturePolicy.browserFallbackNeedsOCR(url: "https://example.com/article"))
        XCTAssertTrue(BrowserCapturePolicy.browserFallbackNeedsOCR(url: "https://example.com/report.pdf"))
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(BrowserCapturePolicy.allowsBrowserOCR(lastAt: nil, now: now, interval: 30))
        XCTAssertFalse(BrowserCapturePolicy.allowsBrowserOCR(
            lastAt: now.addingTimeInterval(-29), now: now, interval: 30
        ))
        XCTAssertTrue(BrowserCapturePolicy.allowsBrowserOCR(
            lastAt: now.addingTimeInterval(-30), now: now, interval: 30
        ))
    }
}
