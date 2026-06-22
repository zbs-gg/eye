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
    /// Per-PID health (план: sick-backoff): подряд тайм-ауты без контента → skip AX на 60с,
    /// зависшее приложение не съедает бюджет каждого цикла.
    private var failStreak: [pid_t: Int] = [:]
    private var sickUntil: [pid_t: Date] = [:]
    private let queue = DispatchQueue(label: "com.zbseye.axreader", qos: .userInitiated)

    init(config: CaptureConfig) { self.config = config }

    func reset() { flaggedPIDs.removeAll(); failStreak.removeAll(); sickUntil.removeAll() }
    func forget(pid: pid_t) {                              // при смерти процесса (pid reuse)
        flaggedPIDs.remove(pid); failStreak[pid] = nil; sickUntil[pid] = nil
    }

    func extract(pid: pid_t) async -> AXExtraction {
        // sick-PID: недавно повисал — не дёргаем AX, сразу отдаём пустышку (Coordinator уйдёт в OCR)
        if let until = sickUntil[pid], until > Date() {
            var ext = AXExtraction(); ext.quality = .sickPID; return ext
        }
        let mayFlag = !flaggedPIDs.contains(pid)
        if mayFlag { flaggedPIDs.insert(pid) }
        let cfg = config
        let result = await withCheckedContinuation { (cont: CheckedContinuation<AXExtraction, Never>) in
            queue.async {
                cont.resume(returning: AXCore.perform(pid: pid, maySetFlags: mayFlag, config: cfg))
            }
        }
        // Флаги не «прилипли»? Откатываем — попробуем выставить в следующий раз (Electron поднимается лениво).
        if mayFlag && result.manualResult != nil
            && result.manualResult != "success" && result.enhancedResult != "success" {
            flaggedPIDs.remove(pid)
        }
        // health-учёт: timeout без контента — страйк; 3 подряд → sick на 60с
        if result.hitBudgetLimit && result.contentChars == 0 {
            let n = (failStreak[pid] ?? 0) + 1
            failStreak[pid] = n
            if n >= 3 { sickUntil[pid] = Date().addingTimeInterval(60); failStreak[pid] = 0 }
        } else if result.contentChars > 0 {
            failStreak[pid] = 0
        }
        return result
    }

    /// Дешёвый заголовок окна для ocrOnly-приложений (Zed/Figma): один AX-вызов, без обхода дерева —
    /// иначе их записи оставались без windowTitle вовсе.
    func titleOnly(pid: pid_t) async -> String? {
        let cfg = config
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            queue.async {
                cont.resume(returning: AXCore.focusedWindowTitle(pid: pid, config: cfg))
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

    static func perform(pid: pid_t, maySetFlags: Bool, config: CaptureConfig) -> AXExtraction {
        var ext = AXExtraction()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(config.axMessagingTimeout))

        // CONSERVATIVE (план/Pro): сначала пробуем БЕЗ флагов — здоровые нативные приложения отдают
        // дерево сразу, а AXEnhancedUserInterface им только вредит (ломает анимации/раскладку у части
        // приложений). Флаги — ТОЛЬКО если дерево пустое (Electron ленится), с retry-лестницей.
        var result = traverse(app: app, config: config)
        if result.contentChars == 0 && maySetFlags && !result.hitDeadline {
            ext.manualResult = errString(setAttr(app, "AXManualAccessibility", true))
            ext.enhancedResult = errString(setAttr(app, "AXEnhancedUserInterface", true))
            for delayMs in [250, 750] {                   // лестница: дерево строится лениво/асинхронно
                usleep(useconds_t(delayMs * 1000))
                result = traverse(app: app, config: config)
                if result.contentChars > 0 { break }
            }
        } else if result.contentChars == 0 && !result.hitDeadline {
            // флаги уже выставлялись ранее — один обычный ретрай
            usleep(useconds_t(config.axEmptyRetryMs * 1000))
            result = traverse(app: app, config: config)
        }
        ext.treeWasEmpty = result.contentChars == 0   // всегда, не только в ветке ретрая

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
            var nodeText = ""
            var len = 0
            for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                         kAXPlaceholderValueAttribute, kAXSelectedTextAttribute] {
                if let s = copyString(node, attr), !s.isEmpty {
                    nodeText += s + " "
                    len += s.count
                }
            }
            if len > 0 {
                let (c, ch) = contribution(role: role, len: len)
                r.contentChars += c; r.chromeChars += ch
                // в текст — только КОНТЕНТ: пункты меню/кнопки/тулбары засоряли FTS мусором
                // («Файл Правка Вид…» в каждом кадре) и съедали 20k-лимит
                if c > 0, r.text.count < 20_000 { r.text += nodeText }
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

    /// Только заголовок focused/main окна — один-два AX-вызова, без обхода.
    static func focusedWindowTitle(pid: pid_t, config: CaptureConfig) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(config.axMessagingTimeout))
        guard let win = copyElement(app, kAXFocusedWindowAttribute)
                ?? copyElement(app, kAXMainWindowAttribute) else { return nil }
        return copyString(win, kAXTitleAttribute)
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
