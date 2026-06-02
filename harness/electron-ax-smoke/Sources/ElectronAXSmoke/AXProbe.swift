import Foundation
import ApplicationServices
import AppKit

enum ProbeMode: String { case conservative, aggressive }

private let usefulTextThreshold = 40        // символов, чтобы считать «не titleOnly»
private let fullUsefulThreshold = 800       // символов всего → fullUseful
private let webAreaUsefulThreshold = 400
private let focusedUsefulThreshold = 200
private let nodeCap = 6000
private let charCap = 40_000

// ── низкоуровневые AX-обёртки ──────────────────────────────────────────────

private func axErrorString(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "unknown(\(e.rawValue))"
    }
}

private func copyString(_ e: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let val = v else { return nil }
    if CFGetTypeID(val) == CFStringGetTypeID() { return (val as! String) }
    return nil
}

private func copyChildren(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success,
          let val = v, CFGetTypeID(val) == CFArrayGetTypeID() else { return [] }
    return (val as! [AXUIElement])
}

private func copyElement(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success,
          let val = v, CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
    return (val as! AXUIElement)
}

private func copyURL(_ e: AXUIElement) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXURLAttribute as CFString, &v) == .success, let val = v else { return nil }
    if CFGetTypeID(val) == CFURLGetTypeID() { return (val as! NSURL).absoluteString }
    if CFGetTypeID(val) == CFStringGetTypeID() { return (val as! String) }
    return nil
}

private func setFlag(_ app: AXUIElement, _ name: String, _ value: Bool) -> AXError {
    let b: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
    return AXUIElementSetAttributeValue(app, name as CFString, b)
}

// ── обход дерева под бюджетом ──────────────────────────────────────────────

struct TraverseResult {
    var nodeCount = 0
    var textChars = 0
    var webAreaFound = false
    var url: String?
    var hitDeadline = false
}

private func nodeText(_ e: AXUIElement) -> Int {
    var n = 0
    for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                 kAXPlaceholderValueAttribute, kAXSelectedTextAttribute] {
        if let s = copyString(e, attr) { n += s.count }
    }
    return n
}

// Итеративный обход (стек, не рекурсия), wall-clock deadline проверяется на каждом узле.
private func traverse(app: AXUIElement, budgetMs: Int) -> TraverseResult {
    var r = TraverseResult()
    let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000.0)
    var stack: [AXUIElement] = [app]

    while let node = stack.popLast() {
        if Date() >= deadline { r.hitDeadline = true; break }
        if r.nodeCount >= nodeCap { break }
        r.nodeCount += 1

        if r.textChars < charCap { r.textChars += nodeText(node) }

        if let role = copyString(node, kAXRoleAttribute), role == "AXWebArea" {
            r.webAreaFound = true
            if r.url == nil, let u = copyURL(node) { r.url = u }
        }
        // children в конец стека
        let kids = copyChildren(node)
        if !kids.isEmpty { stack.append(contentsOf: kids) }
    }
    return r
}

// ── проба одного приложения ────────────────────────────────────────────────

enum AXProbe {

    static func probe(app running: NSRunningApplication, mode: ProbeMode) -> AppProbeResult {
        let pid = running.processIdentifier
        let bundleURL = running.bundleURL
        let (isElectron, electronVer) = SystemContext.electronInfo(bundleURL: bundleURL)

        var result = AppProbeResult(
            bundleId: running.bundleIdentifier ?? "unknown",
            appName: running.localizedName ?? "unknown",
            appVersion: SystemContext.appVersion(bundleURL: bundleURL),
            electronVersion: electronVer,
            isElectron: isElectron,
            pid: pid,
            frontmost: running.isActive,
            manualSetError: "n/a",
            enhancedSetError: "skipped",
            preFlagsChildren: 0,
            preFlagsTextChars: 0,
            firstNonEmptyMs: nil,
            firstUsefulTextMs: nil,
            nodeCount: 0,
            textCharCount: 0,
            focusedTextChars: 0,
            webAreaFound: false,
            urlFound: false,
            url: nil,
            windowTitle: nil,
            cpuBeforePct: nil,
            cpuAfterPct: nil,
            cpuDeltaTargetApp: nil,
            quality: "none",
            budgetMs: 300,
            traversalMs: 0,
            retriesUsed: 0,
            notes: []
        )

        let appElem = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElem, 0.2)   // 200мс на каждый AX-вызов (для замера лояльнее 100мс)

        // CPU baseline до флагов
        result.cpuBeforePct = sampleCPUPercent(pid, intervalSec: 0.4)

        // состояние ДО флагов
        let pre = traverse(app: appElem, budgetMs: 80)
        result.preFlagsChildren = copyChildren(appElem).count
        result.preFlagsTextChars = pre.textChars

        let tFlags = Date()

        // установка флагов
        let manualErr = setFlag(appElem, "AXManualAccessibility", true)
        result.manualSetError = axErrorString(manualErr)
        if manualErr == .apiDisabled {
            result.notes.append("apiDisabled — harness не имеет Accessibility-прав? проверь System Settings")
        }

        if mode == .aggressive {
            let enhErr = setFlag(appElem, "AXEnhancedUserInterface", true)
            result.enhancedSetError = axErrorString(enhErr)
        }

        // ретраи: 250 / 750 / 1500 / 3000 мс (кумулятивно от tFlags)
        let retryPoints = [250, 750, 1500, 3000]
        var prevPoint = 0
        var lastTraverse = pre
        for (i, point) in retryPoints.enumerated() {
            let sleepMs = point - prevPoint
            prevPoint = point
            Thread.sleep(forTimeInterval: Double(sleepMs) / 1000.0)
            result.retriesUsed = i + 1

            let t = traverse(app: appElem, budgetMs: 120)
            lastTraverse = t
            let elapsed = Int(Date().timeIntervalSince(tFlags) * 1000)

            if result.firstNonEmptyMs == nil && t.nodeCount > 1 {
                result.firstNonEmptyMs = elapsed
            }
            if result.firstUsefulTextMs == nil && t.textChars >= usefulTextThreshold {
                result.firstUsefulTextMs = elapsed
            }

            // conservative: добиваем Enhanced только если manual не дал useful-текста
            if mode == .conservative && result.enhancedSetError == "skipped" {
                let stillWeak = (t.textChars < usefulTextThreshold) || (manualErr != .success)
                if stillWeak && i >= 1 {   // после второй попытки
                    let enhErr = setFlag(appElem, "AXEnhancedUserInterface", true)
                    result.enhancedSetError = axErrorString(enhErr)
                    result.notes.append("conservative→enhanced включён после weak manual")
                }
            }

            if result.firstUsefulTextMs != nil && t.textChars >= fullUsefulThreshold { break }
        }

        // финальный полный обход
        let finalStart = Date()
        let fin = traverse(app: appElem, budgetMs: result.budgetMs)
        result.traversalMs = Int(Date().timeIntervalSince(finalStart) * 1000)
        result.nodeCount = max(fin.nodeCount, lastTraverse.nodeCount)
        result.textCharCount = max(fin.textChars, lastTraverse.textChars)
        result.webAreaFound = fin.webAreaFound || lastTraverse.webAreaFound
        result.url = fin.url ?? lastTraverse.url
        result.urlFound = result.url != nil

        // focused element text + window title
        if let focused = copyElement(appElem, kAXFocusedUIElementAttribute) {
            var fc = 0
            if let s = copyString(focused, kAXValueAttribute) { fc += s.count }
            if let s = copyString(focused, kAXSelectedTextAttribute) { fc += s.count }
            result.focusedTextChars = fc
        }
        if let win = copyElement(appElem, kAXFocusedWindowAttribute) ?? copyElement(appElem, kAXMainWindowAttribute) {
            result.windowTitle = copyString(win, kAXTitleAttribute)
        }

        // CPU после построения дерева
        result.cpuAfterPct = sampleCPUPercent(pid, intervalSec: 0.4)
        if let a = result.cpuAfterPct, let b = result.cpuBeforePct {
            result.cpuDeltaTargetApp = a - b
        }

        result.quality = classify(result, manualErr: manualErr)
        return result
    }

    private static func classify(_ r: AppProbeResult, manualErr: AXError) -> String {
        if manualErr == .apiDisabled { return "sickPID" }
        if r.focusedTextChars >= focusedUsefulThreshold { return "fullUseful" }
        if r.webAreaFound && r.textCharCount >= webAreaUsefulThreshold { return "fullUseful" }
        if r.textCharCount >= fullUsefulThreshold { return "fullUseful" }
        if r.textCharCount >= usefulTextThreshold { return "partialUseful" }
        if r.windowTitle != nil && !(r.windowTitle!.isEmpty) { return "titleOnly" }
        if r.traversalMs >= r.budgetMs && r.textCharCount == 0 { return "timedOut" }
        return "none"
    }
}
