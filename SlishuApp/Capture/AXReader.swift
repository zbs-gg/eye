import Foundation
import ApplicationServices

/// Чтение accessibility-текста активного окна. По Pro: тяжёлый AX-обход (синхронный C-IPC) выполняется
/// на ВЫДЕЛЕННОЙ serial-очереди, НЕ на cooperative actor executor. Actor хранит только per-pid кэш
/// «флаги уже выставлены». AXUIElement создаётся и умирает на очереди — наружу только Sendable AXExtraction.
/// Логика портирована из отлаженного harness `electron-ax-smoke` (production-вариант: один обход + один
/// ретрай при пустом дереве вместо серии замеров).
actor AXReader {
    private let config: CaptureConfig
    private var flaggedPIDs: Set<pid_t> = []
    private let queue = DispatchQueue(label: "com.slishu.axreader", qos: .userInitiated)

    init(config: CaptureConfig) { self.config = config }

    func reset() { flaggedPIDs.removeAll() }

    func extract(pid: pid_t) async -> AXExtraction {
        let needFlags = !flaggedPIDs.contains(pid)
        if needFlags { flaggedPIDs.insert(pid) }
        let cfg = config
        return await withCheckedContinuation { (cont: CheckedContinuation<AXExtraction, Never>) in
            queue.async {
                cont.resume(returning: AXCore.perform(pid: pid, setFlags: needFlags, config: cfg))
            }
        }
    }
}

// MARK: - синхронное AX-ядро (выполняется на serial-очереди AXReader)

private enum AXCore {
    static let contentRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXText", "AXWebArea", "AXComboBox", "AXSearchField",
    ]
    static let chromeRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXMenu", "AXMenuBar", "AXPopUpButton",
        "AXCheckBox", "AXRadioButton", "AXTab", "AXTabGroup", "AXToolbar", "AXImage",
    ]

    static func perform(pid: pid_t, setFlags: Bool, config: CaptureConfig) -> AXExtraction {
        var ext = AXExtraction()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(config.axMessagingTimeout))

        if setFlags {
            ext.manualResult = errString(setAttr(app, "AXManualAccessibility", true))
            ext.enhancedResult = errString(setAttr(app, "AXEnhancedUserInterface", true))
        }

        var result = traverse(app: app, config: config)
        // lazy Electron build: пустое дерево → один ретрай после паузы
        if result.contentChars == 0 && result.nodeCount <= 1 {
            usleep(useconds_t(config.axEmptyRetryMs * 1000))
            result = traverse(app: app, config: config)
            ext.treeWasEmpty = result.contentChars == 0
        }

        ext.contentText = String(result.text.prefix(20_000))
        ext.contentChars = result.contentChars
        ext.chromeChars = result.chromeChars
        ext.nodeCount = result.nodeCount
        ext.hitBudgetLimit = result.hitDeadline
        ext.browserURL = result.url

        // focused window title
        if let win = copyElement(app, kAXFocusedWindowAttribute) ?? copyElement(app, kAXMainWindowAttribute) {
            ext.windowTitle = copyString(win, kAXTitleAttribute)
        }
        ext.quality = classify(ext, config: config)
        return ext
    }

    // ── budgeted iterative traversal (стек, deadline на каждом узле) ──
    struct TR { var nodeCount = 0; var text = ""; var contentChars = 0; var chromeChars = 0
        var url: String?; var hitDeadline = false }

    static func traverse(app: AXUIElement, config: CaptureConfig) -> TR {
        var r = TR()
        let deadline = Date().addingTimeInterval(Double(config.axBudgetMs) / 1000.0)
        var stack: [AXUIElement] = [app]
        while let node = stack.popLast() {
            if Date() >= deadline { r.hitDeadline = true; break }
            if r.nodeCount >= config.axMaxNodes { break }
            r.nodeCount += 1

            let role = copyString(node, kAXRoleAttribute) ?? "?"
            var len = 0
            for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                         kAXPlaceholderValueAttribute, kAXSelectedTextAttribute] {
                if let s = copyString(node, attr), !s.isEmpty {
                    if r.text.count < 20_000 { r.text += s + " " }
                    len += s.count
                }
            }
            if len > 0 {
                let (c, ch) = contribution(role: role, len: len)
                r.contentChars += c; r.chromeChars += ch
            }
            if role == "AXWebArea", r.url == nil { r.url = copyURL(node) }

            for kid in copyChildren(node) { stack.append(kid) }
        }
        return r
    }

    static func contribution(role: String, len: Int) -> (Int, Int) {
        if contentRoles.contains(role) { return (len, 0) }
        if chromeRoles.contains(role) { return (0, len) }
        if role == "AXStaticText" || role == "AXHeading" { return len > 25 ? (len, 0) : (0, len) }
        return (0, 0)
    }

    static func classify(_ e: AXExtraction, config: CaptureConfig) -> AXQuality {
        if e.contentChars >= config.fullUsefulThreshold { return .fullUseful }
        if e.contentChars >= config.usefulThreshold { return .partialUseful }
        if let t = e.windowTitle, !t.isEmpty { return .titleOnly }
        if e.hitBudgetLimit && e.contentChars == 0 { return .timedOut }
        return .none
    }

    // ── AX C-обёртки ──
    static func copyString(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let val = v else { return nil }
        return CFGetTypeID(val) == CFStringGetTypeID() ? (val as! String) : nil
    }
    static func copyChildren(_ e: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == CFArrayGetTypeID() else { return [] }
        return (val as! [AXUIElement])
    }
    static func copyElement(_ e: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success,
              let val = v, CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
        return (val as! AXUIElement)
    }
    static func copyURL(_ e: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXURLAttribute as CFString, &v) == .success, let val = v else { return nil }
        if CFGetTypeID(val) == CFURLGetTypeID() { return (val as! NSURL).absoluteString }
        if CFGetTypeID(val) == CFStringGetTypeID() { return (val as! String) }
        return nil
    }
    static func setAttr(_ app: AXUIElement, _ name: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(app, name as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse))
    }
    static func errString(_ e: AXError) -> String {
        switch e {
        case .success: return "success"
        case .attributeUnsupported: return "attributeUnsupported"
        case .cannotComplete: return "cannotComplete"
        case .notImplemented: return "notImplemented"
        case .apiDisabled: return "apiDisabled"
        default: return "err(\(e.rawValue))"
        }
    }
}
