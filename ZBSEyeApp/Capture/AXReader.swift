import Foundation
import ApplicationServices

/// Reading the accessibility text of the active window. Per Pro: the heavy AX traversal (synchronous C-IPC)
/// runs on a DEDICATED serial queue, NOT on the cooperative actor executor. The actor only holds a per-pid cache
/// of "flags already set". The AXUIElement is created and dies on the queue — only the Sendable AXExtraction
/// leaves it. The logic is ported from the debugged harness `electron-ax-smoke` (production variant: one traversal +
/// one retry on an empty tree instead of a series of measurements).
actor AXReader {
    private let config: CaptureConfig
    private var flaggedPIDs: Set<pid_t> = []
    /// Per-PID health (plan: sick-backoff): consecutive timeouts with no content → skip AX for 60s,
    /// so a hung app doesn't eat the budget of every cycle.
    private var failStreak: [pid_t: Int] = [:]
    private var sickUntil: [pid_t: Date] = [:]
    private let queue = DispatchQueue(label: "com.zbseye.axreader", qos: .userInitiated)
    /// Our own PID. INVARIANT: AXReader NEVER inspects its own process — otherwise the traversal reads
    /// our own SwiftUI tree, and `kAXValue` on our Slider SYNCHRONOUSLY calls its @MainActor `Binding.get`
    /// (TimelineView) right on this serial queue → `dispatch_assert_queue(main)` → crash (Pro's diagnosis).
    private static let ownPID = ProcessInfo.processInfo.processIdentifier

    init(config: CaptureConfig) { self.config = config }

    func reset() { flaggedPIDs.removeAll(); failStreak.removeAll(); sickUntil.removeAll() }
    func forget(pid: pid_t) {                              // on process death (pid reuse)
        flaggedPIDs.remove(pid); failStreak[pid] = nil; sickUntil[pid] = nil
    }

    func extract(pid: pid_t) async -> AXExtraction {
        guard pid != Self.ownPID else {                       // invariant guard (see ownPID): the second line of defense,
            assertionFailure("AXReader must not inspect its own process")  // so a new call site doesn't resurrect the bug
            return AXExtraction()
        }
        // sick-PID: recently hung — don't poke AX, return an empty result right away (the Coordinator will fall back to OCR)
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
        // Flags didn't "stick"? Roll back — we'll try to set them next time (Electron starts up lazily).
        if mayFlag && result.manualResult != nil
            && result.manualResult != "success" && result.enhancedResult != "success" {
            flaggedPIDs.remove(pid)
        }
        // health accounting: timeout with no content — a strike; 3 in a row → sick for 60s
        if result.hitBudgetLimit && result.contentChars == 0 {
            let n = (failStreak[pid] ?? 0) + 1
            failStreak[pid] = n
            if n >= 3 { sickUntil[pid] = Date().addingTimeInterval(60); failStreak[pid] = 0 }
        } else if result.contentChars > 0 {
            failStreak[pid] = 0
        }
        return result
    }

    /// A cheap window title for ocrOnly apps (Zed/Figma): a single AX call, without traversing the tree —
    /// otherwise their records were left without a windowTitle at all.
    func titleOnly(pid: pid_t) async -> String? {
        guard pid != Self.ownPID else {
            assertionFailure("AXReader must not inspect its own process")
            return nil
        }
        let cfg = config
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            queue.async {
                cont.resume(returning: AXCore.focusedWindowTitle(pid: pid, config: cfg))
            }
        }
    }
}

// MARK: - synchronous AX core (runs on AXReader's serial queue)

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

        // CONSERVATIVE (plan/Pro): first try WITHOUT flags — healthy native apps return their tree
        // right away, and AXEnhancedUserInterface only hurts them (breaks animations/layout in some
        // apps). Flags — ONLY if the tree is empty (Electron is lazy), with a retry ladder.
        var result = traverse(app: app, config: config)
        if result.contentChars == 0 && maySetFlags && !result.hitDeadline {
            ext.manualResult = errString(setAttr(app, "AXManualAccessibility", true))
            ext.enhancedResult = errString(setAttr(app, "AXEnhancedUserInterface", true))
            for delayMs in [250, 750] {                   // ladder: the tree is built lazily/asynchronously
                usleep(useconds_t(delayMs * 1000))
                result = traverse(app: app, config: config)
                if result.contentChars > 0 { break }
            }
        } else if result.contentChars == 0 && !result.hitDeadline {
            // flags were already set earlier — one regular retry
            usleep(useconds_t(config.axEmptyRetryMs * 1000))
            result = traverse(app: app, config: config)
        }
        ext.treeWasEmpty = result.contentChars == 0   // always, not only in the retry branch

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

    // ── budgeted iterative traversal (stack, deadline on every node) ──
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
            // Pro: do NOT read kAXValue without inspecting the role. On non-text elements (AXSlider etc.) the numeric value
            // is then thrown away by `copyString` anyway, but the getter itself is a redundant IPC and a side effect (on our
            // own Slider it's a synchronous @MainActor Binding.get). text roles: the full set; chrome:
            // only title/description; everything else: nothing.
            let attrs: [String]
            if contentRoles.contains(role) || role == "AXStaticText" || role == "AXHeading" {
                attrs = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                         kAXPlaceholderValueAttribute, kAXSelectedTextAttribute]
            } else if chromeRoles.contains(role) {
                attrs = [kAXTitleAttribute, kAXDescriptionAttribute]
            } else {
                attrs = []
            }
            for attr in attrs {
                if let s = copyString(node, attr), !s.isEmpty {
                    nodeText += s + " "
                    len += s.count
                }
            }
            if len > 0 {
                let (c, ch) = contribution(role: role, len: len)
                r.contentChars += c; r.chromeChars += ch
                // into the text — only CONTENT: menu items/buttons/toolbars were polluting FTS with junk
                // ("File Edit View…" in every frame) and eating up the 20k limit
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

    /// Only the title of the focused/main window — one or two AX calls, without traversal.
    static func focusedWindowTitle(pid: pid_t, config: CaptureConfig) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(config.axMessagingTimeout))
        guard let win = copyElement(app, kAXFocusedWindowAttribute)
                ?? copyElement(app, kAXMainWindowAttribute) else { return nil }
        return copyString(win, kAXTitleAttribute)
    }

    // ── AX C wrappers ──
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
