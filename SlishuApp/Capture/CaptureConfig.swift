import Foundation

/// Бюджеты/пороги захвата (DI, тестируемо). Из плана v2 + цифр harness.
struct CaptureConfig: Sendable {
    var axBudgetMs = 120
    var axMessagingTimeout = 0.05          // 50мс/вызов — один медленный узел не съест бюджет
    var axMaxNodes = 20_000
    var axEmptyRetryMs = 400               // один ретрай при пустом дереве (lazy Electron build)
    var usefulThreshold = 40               // contentChars → не titleOnly
    var fullUsefulThreshold = 800
    var dedupHammingThreshold = 3
    var ocrMinContentChars = 24            // ниже + пустой AX → OCR
    var ocrLanguages = ["ru-RU", "en-US"]
    var activeTickSeconds = 6.0            // active-text fallback тик (MVP; burst-stream — позже)
    var captureMinIntervalMs = 1500        // не чаще этого на одно окно
}

/// Результат AX-извлечения (Sendable; AXUIElement не пересекает границу).
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
