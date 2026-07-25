import AppKit
import Foundation

struct NativeCallSurfaceInspection: Equatable, Sendable {
    let hasCallSignature: Bool
    let authoritativeNoMatch: Bool
    /// Opaque, process-local ownership lease. It contains no title, label, participant, or URL.
    let surfaceHandleToken: String?
}

enum NativeCallSurfaceState: Equatable, Sendable {
    case active
    /// The retained call window/control still exists, but is minimized, hidden, or temporarily
    /// non-actionable. This is known continuity, not an Accessibility read failure.
    case obscured
    case ended
    case invalidated
    case unknown

    /// Direct trust result for a retained root. Invalidated/unknown require the bounded rebind or
    /// failure paths in MeetingDetector instead.
    var directSurfaceMatch: Bool? {
        switch self {
        case .active, .obscured: true
        case .ended: false
        case .invalidated, .unknown: nil
        }
    }
}

/// A bounded, non-prompting Accessibility probe for native call windows.
///
/// Raw AX text exists only on the dedicated serial queue. A positive result retains one exact
/// top-level window behind an opaque UUID so consecutive calls in the same app PID do not share
/// identity. Missing trust, timeout, traversal errors, and invalid roots are never reported as an
/// authoritative end.
enum NativeCallSurfaceInspector {
    struct NodeSnapshot: Equatable, Sendable {
        var role: String?
        var title: String?
        var description: String?
        var help: String?
        var value: String?
        var isEnabled = false
        var isVisible = true
        var supportsPressAction = false
    }

    struct WindowSnapshot: Equatable, Sendable {
        let nodes: [NodeSnapshot]
        var traversalSucceeded = true
        var isHidden = false
        var isMinimized = false
    }

    private enum ScanResult: Equatable {
        case active
        case obscured
        case ended
        case unknown
    }

    private struct WindowsRead {
        let windows: [AXUIElement]
        let succeeded: Bool
    }

    private struct ChildrenRead {
        let children: [AXUIElement]
        let succeeded: Bool
        let wasTruncated: Bool
    }

    // AXUIElement is not Sendable. This registry is nevertheless passed into the one dedicated
    // inspector queue; every mutation and lookup asserts that exact serial queue below.
    private final class SurfaceRegistry: @unchecked Sendable {
        struct Entry {
            let pid: pid_t
            let bundleID: String
            let window: AXUIElement
            var pinned: Bool
        }

        private var entries: [String: Entry] = [:]
        private var insertionOrder: [String] = []
        private let maximumEntries = 16

        func insert(pid: pid_t, bundleID: String, window: AXUIElement) -> String? {
            dispatchPrecondition(condition: .onQueue(NativeCallSurfaceInspector.queue))
            while entries.count >= maximumEntries {
                guard let provisional = insertionOrder.first(where: {
                    entries[$0]?.pinned == false
                }) else { return nil }
                entries.removeValue(forKey: provisional)
                insertionOrder.removeAll { $0 == provisional }
            }
            let token = UUID().uuidString.lowercased()
            entries[token] = Entry(
                pid: pid,
                bundleID: bundleID,
                window: window,
                pinned: false
            )
            insertionOrder.append(token)
            return token
        }

        func entry(for token: String) -> Entry? {
            dispatchPrecondition(condition: .onQueue(NativeCallSurfaceInspector.queue))
            return entries[token]
        }

        func pin(_ token: String) -> Bool {
            dispatchPrecondition(condition: .onQueue(NativeCallSurfaceInspector.queue))
            guard var entry = entries[token] else { return false }
            entry.pinned = true
            entries[token] = entry
            return true
        }

        func remove(_ token: String) {
            dispatchPrecondition(condition: .onQueue(NativeCallSurfaceInspector.queue))
            entries.removeValue(forKey: token)
            insertionOrder.removeAll { $0 == token }
        }

        func windows(for tokens: Set<String>) -> [AXUIElement] {
            dispatchPrecondition(condition: .onQueue(NativeCallSurfaceInspector.queue))
            return tokens.compactMap { entries[$0]?.window }
        }

#if DEBUG
        func resetForTesting() {
            dispatchPrecondition(condition: .onQueue(NativeCallSurfaceInspector.queue))
            entries.removeAll()
            insertionOrder.removeAll()
        }
#endif
    }

    private static let queue = DispatchQueue(
        label: "gg.zbs.eye.native-call-surface-ax",
        qos: .utility
    )
    private static let registry = SurfaceRegistry()
    private static let maximumWindows = 16
    private static let maximumNodes = 500
    private static let deadlineSeconds: TimeInterval = 1
    private static let messagingTimeoutSeconds: Float = 0.05
    private static let hardControlLabels: Set<String> = [
        "end call", "hang up", "leave call", "leave meeting",
        "завершить звонок", "положить трубку", "покинуть звонок", "выйти из конференции",
    ]

    /// `AXIsProcessTrusted()` is intentionally the non-prompting trust probe. Keep even this
    /// lightweight AX call confined to the same serial utility queue as every other AX access.
    private static func isAccessibilityTrustedOnAXQueue() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return AXIsProcessTrusted()
    }

    static func inspect(
        pid: pid_t,
        bundleID: String,
        excludingSurfaceTokens: Set<String> = []
    ) async -> NativeCallSurfaceInspection {
        return await withCheckedContinuation { continuation in
            queue.async {
                guard isAccessibilityTrustedOnAXQueue() else {
                    continuation.resume(
                        returning: NativeCallSurfaceInspection(
                            hasCallSignature: false,
                            authoritativeNoMatch: false,
                            surfaceHandleToken: nil
                        )
                    )
                    return
                }
                continuation.resume(
                    returning: inspectAX(
                        pid: pid,
                        bundleID: bundleID,
                        excludingSurfaceTokens: excludingSurfaceTokens
                    )
                )
            }
        }
    }

    static func revalidateSurface(_ token: String) async -> NativeCallSurfaceState {
        return await withCheckedContinuation { continuation in
            queue.async {
                guard isAccessibilityTrustedOnAXQueue() else {
                    continuation.resume(returning: .unknown)
                    return
                }
                guard let entry = registry.entry(for: token) else {
                    continuation.resume(returning: .unknown)
                    return
                }
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let deadline = deadlineNanoseconds(startedAt: startedAt)
                let windowsRead = windows(pid: entry.pid, deadline: deadline)
                guard windowsRead.succeeded, !reachedDeadline(deadline) else {
                    continuation.resume(returning: .unknown)
                    return
                }
                guard let retainedWindow = windowsRead.windows.first(where: {
                    CFEqual($0, entry.window)
                }) else {
                    // A destroyed root can also be an AX rebuild. It is not an authoritative end.
                    continuation.resume(returning: .invalidated)
                    return
                }
                let obscured = obscuredState(retainedWindow, deadline: deadline)
                guard obscured.succeeded else {
                    continuation.resume(returning: .unknown)
                    return
                }
                if obscured.value {
                    continuation.resume(returning: .obscured)
                    return
                }
                var remainingNodes = maximumNodes
                let scan = scanWindow(
                    retainedWindow,
                    bundleID: entry.bundleID,
                    deadline: deadline,
                    remainingNodes: &remainingNodes
                )
                switch scan {
                case .active:
                    continuation.resume(returning: .active)
                case .obscured:
                    continuation.resume(returning: .obscured)
                case .ended:
                    continuation.resume(returning: .ended)
                case .unknown:
                    continuation.resume(returning: .unknown)
                }
            }
        }
    }

    static func pinSurface(_ token: String?) async -> Bool {
        guard let token else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: registry.pin(token))
            }
        }
    }

    static func discardSurface(_ token: String?) async {
        guard let token else { return }
        await withCheckedContinuation { continuation in
            queue.async {
                registry.remove(token)
                continuation.resume()
            }
        }
    }

#if DEBUG
    static func resetSurfaceRegistryForTesting() async {
        await withCheckedContinuation { continuation in
            queue.async {
                registry.resetForTesting()
                continuation.resume()
            }
        }
    }

    static func insertSurfaceForTesting(id: Int) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: registry.insert(
                        pid: pid_t(300_000 + id),
                        bundleID: "test.bundle.\(id)",
                        window: AXUIElementCreateApplication(pid_t(300_000 + id))
                    )
                )
            }
        }
    }
#endif

    /// Pure test seam proving that only an actionable hard end-call control qualifies.
    static func inspect(
        snapshots: [WindowSnapshot],
        bundleID: String = "test.generic",
        accessibilityTrusted: Bool = true,
        maximumWindows: Int = maximumWindows,
        maximumNodes: Int = maximumNodes
    ) -> NativeCallSurfaceInspection {
        guard accessibilityTrusted else {
            return NativeCallSurfaceInspection(
                hasCallSignature: false,
                authoritativeNoMatch: false,
                surfaceHandleToken: nil
            )
        }
        let bounded = snapshots.prefix(max(0, maximumWindows))
        var remaining = max(0, maximumNodes)
        var complete = snapshots.count <= maximumWindows
        for window in bounded {
            guard !window.isHidden, !window.isMinimized else {
                complete = false
                continue
            }
            for node in window.nodes {
                guard remaining > 0 else {
                    complete = false
                    break
                }
                remaining -= 1
                if isHardCallControl(node, bundleID: bundleID) {
                    return NativeCallSurfaceInspection(
                        hasCallSignature: true,
                        authoritativeNoMatch: false,
                        surfaceHandleToken: nil
                    )
                }
                if hasHardCallLabel(node, bundleID: bundleID) {
                    // A known end-call control that is temporarily hidden, disabled, or not
                    // actionable is continuity uncertainty, not proof that the call ended.
                    complete = false
                }
            }
            complete = complete && window.traversalSucceeded
        }
        return NativeCallSurfaceInspection(
            hasCallSignature: false,
            authoritativeNoMatch: complete,
            surfaceHandleToken: nil
        )
    }

    private static func inspectAX(
        pid: pid_t,
        bundleID: String,
        excludingSurfaceTokens: Set<String>
    ) -> NativeCallSurfaceInspection {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = deadlineNanoseconds(startedAt: startedAt)
        let windowsRead = windows(pid: pid, deadline: deadline)
        guard windowsRead.succeeded else {
            return NativeCallSurfaceInspection(
                hasCallSignature: false,
                authoritativeNoMatch: false,
                surfaceHandleToken: nil
            )
        }

        let excluded = registry.windows(for: excludingSurfaceTokens)
        let candidates = windowsRead.windows.filter { window in
            !excluded.contains(where: { CFEqual($0, window) })
        }
        var remainingNodes = maximumNodes
        var complete = windowsRead.windows.count <= maximumWindows
        for window in candidates.prefix(maximumWindows) {
            guard !reachedDeadline(deadline) else {
                complete = false
                break
            }
            let obscured = obscuredState(window, deadline: deadline)
            guard obscured.succeeded else {
                complete = false
                continue
            }
            guard !obscured.value else {
                complete = false
                continue
            }
            let scan = scanWindow(
                window,
                bundleID: bundleID,
                deadline: deadline,
                remainingNodes: &remainingNodes
            )
            if scan == .active,
               !reachedDeadline(deadline),
               let token = registry.insert(pid: pid, bundleID: bundleID, window: window) {
                return NativeCallSurfaceInspection(
                    hasCallSignature: true,
                    authoritativeNoMatch: false,
                    surfaceHandleToken: token
                )
            }
            if scan != .ended {
                complete = false
            }
        }
        return NativeCallSurfaceInspection(
            hasCallSignature: false,
            authoritativeNoMatch:
                complete && !reachedDeadline(deadline) && remainingNodes >= 0,
            surfaceHandleToken: nil
        )
    }

    private static func scanWindow(
        _ root: AXUIElement,
        bundleID: String,
        deadline: UInt64,
        remainingNodes: inout Int
    ) -> ScanResult {
        var pending = [root]
        var nextIndex = 0
        var sawObscuredHardControl = false

        while nextIndex < pending.count {
            guard remainingNodes > 0, !reachedDeadline(deadline) else {
                return sawObscuredHardControl ? .obscured : .unknown
            }
            let element = pending[nextIndex]
            nextIndex += 1
            remainingNodes -= 1

            let control = controlSnapshot(element, deadline: deadline)
            guard control.succeeded else {
                return sawObscuredHardControl ? .obscured : .unknown
            }
            if isHardCallControl(control.snapshot, bundleID: bundleID) {
                return .active
            }
            if hasHardCallLabel(control.snapshot, bundleID: bundleID) {
                sawObscuredHardControl = true
            }

            let queuedNodes = pending.count - nextIndex
            let availableToEnqueue = max(0, remainingNodes - queuedNodes)
            let children = children(
                element,
                deadline: deadline,
                maximumCount: availableToEnqueue
            )
            guard children.succeeded else {
                return sawObscuredHardControl ? .obscured : .unknown
            }
            if children.wasTruncated {
                return sawObscuredHardControl ? .obscured : .unknown
            }
            pending.append(contentsOf: children.children)
        }
        return sawObscuredHardControl ? .obscured : .ended
    }

    private static func windows(pid: pid_t, deadline: UInt64) -> WindowsRead {
        let app = AXUIElementCreateApplication(pid)
        guard prepare(app, deadline: deadline) else {
            return WindowsRead(windows: [], succeeded: false)
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            app,
            kAXWindowsAttribute as CFString,
            &value
        )
        if error == .noValue || error == .attributeUnsupported {
            return WindowsRead(windows: [], succeeded: true)
        }
        guard error == .success,
              !reachedDeadline(deadline),
              let windows = value as? [AXUIElement]
        else {
            return WindowsRead(windows: [], succeeded: false)
        }
        return WindowsRead(windows: windows, succeeded: true)
    }

    private static func children(
        _ element: AXUIElement,
        deadline: UInt64,
        maximumCount: Int
    ) -> ChildrenRead {
        guard prepare(element, deadline: deadline) else {
            return ChildrenRead(children: [], succeeded: false, wasTruncated: false)
        }
        var values: CFArray?
        let requested = max(1, maximumCount + 1)
        let error = AXUIElementCopyAttributeValues(
            element,
            kAXChildrenAttribute as CFString,
            0,
            requested,
            &values
        )
        if error == .noValue || error == .attributeUnsupported {
            return ChildrenRead(children: [], succeeded: true, wasTruncated: false)
        }
        guard error == .success,
              !reachedDeadline(deadline),
              let children = values as? [AXUIElement]
        else {
            return ChildrenRead(children: [], succeeded: false, wasTruncated: false)
        }
        return ChildrenRead(
            children: Array(children.prefix(maximumCount)),
            succeeded: true,
            wasTruncated: children.count > maximumCount
        )
    }

    private static func controlSnapshot(
        _ element: AXUIElement,
        deadline: UInt64
    ) -> (snapshot: NodeSnapshot, succeeded: Bool) {
        func stringAttribute(_ attribute: CFString) -> (String?, Bool) {
            guard prepare(element, deadline: deadline) else {
                return (nil, false)
            }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute, &value)
            if error == .noValue || error == .attributeUnsupported {
                return (nil, true)
            }
            guard error == .success, !reachedDeadline(deadline) else {
                return (nil, false)
            }
            return (value as? String, true)
        }

        let role = stringAttribute(kAXRoleAttribute as CFString)
        guard role.1 else { return (NodeSnapshot(), false) }
        let normalizedRole = normalizedLabel(role.0)
        guard normalizedRole == "axbutton" || normalizedRole == "axmenubutton" else {
            // Do not read chat/document text from non-controls. The tree topology is enough to
            // continue traversal, and ordinary text can never become call evidence.
            return (NodeSnapshot(role: role.0), true)
        }

        func boolAttribute(
            _ attribute: CFString,
            missingValue: Bool
        ) -> (Bool, Bool) {
            guard prepare(element, deadline: deadline) else {
                return (missingValue, false)
            }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute, &value)
            if error == .noValue || error == .attributeUnsupported {
                return (missingValue, true)
            }
            guard error == .success,
                  !reachedDeadline(deadline),
                  let flag = value as? Bool
            else {
                return (missingValue, false)
            }
            return (flag, true)
        }

        let enabled = boolAttribute(kAXEnabledAttribute as CFString, missingValue: false)
        guard enabled.1 else { return (NodeSnapshot(), false) }
        let hidden = boolAttribute(kAXHiddenAttribute as CFString, missingValue: false)
        guard hidden.1 else { return (NodeSnapshot(), false) }

        let title = stringAttribute(kAXTitleAttribute as CFString)
        guard title.1 else { return (NodeSnapshot(), false) }
        let description = stringAttribute(kAXDescriptionAttribute as CFString)
        guard description.1 else { return (NodeSnapshot(), false) }
        let help = stringAttribute(kAXHelpAttribute as CFString)
        guard help.1 else { return (NodeSnapshot(), false) }

        guard prepare(element, deadline: deadline) else {
            return (NodeSnapshot(), false)
        }
        var rawActions: CFArray?
        let actionError = AXUIElementCopyActionNames(element, &rawActions)
        let actions: [String]
        if actionError == .actionUnsupported || actionError == .notImplemented {
            actions = []
        } else if actionError == .success,
                  !reachedDeadline(deadline),
                  let values = rawActions as? [String] {
            actions = values
        } else {
            return (NodeSnapshot(), false)
        }

        return (
            NodeSnapshot(
                role: role.0,
                title: title.0,
                description: description.0,
                help: help.0,
                isEnabled: enabled.0,
                isVisible: !hidden.0,
                supportsPressAction: actions.contains(kAXPressAction as String)
            ),
            true
        )
    }

    private static func isHardCallControl(_ node: NodeSnapshot, bundleID: String) -> Bool {
        guard hasHardCallLabel(node, bundleID: bundleID),
              node.isEnabled,
              node.isVisible,
              node.supportsPressAction
        else {
            return false
        }
        return true
    }

    private static func hasHardCallLabel(_ node: NodeSnapshot, bundleID: String) -> Bool {
        let role = normalizedLabel(node.role)
        guard role == "axbutton" || role == "axmenubutton" else {
            return false
        }
        // AXValue and AXIdentifier are deliberately excluded: chat text and implementation
        // identifiers can contain call words without representing an actionable call control.
        var acceptedLabels = hardControlLabels
        if bundleID.hasPrefix("com.hnc.Discord")
            || bundleID.hasPrefix("com.tinyspeck.slack") {
            // Verified installed Discord/Slack builds expose this exact call-exit label.
            // Keep it application-scoped: "Disconnect" is too broad for a global AX signal.
            acceptedLabels.insert("disconnect")
        }
        return [node.title, node.description, node.help]
            .compactMap(normalizedLabel)
            .contains(where: acceptedLabels.contains)
    }

    private static func normalizedLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private static func obscuredState(
        _ element: AXUIElement,
        deadline: UInt64
    ) -> (value: Bool, succeeded: Bool) {
        for attribute in [
            kAXHiddenAttribute as CFString,
            kAXMinimizedAttribute as CFString,
        ] {
            guard prepare(element, deadline: deadline) else { return (false, false) }
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute, &value)
            if error == .noValue || error == .attributeUnsupported {
                continue
            }
            guard error == .success,
                  !reachedDeadline(deadline),
                  let flag = value as? Bool
            else { return (false, false) }
            if flag { return (true, true) }
        }
        return (false, true)
    }

    private static func prepare(_ element: AXUIElement, deadline: UInt64) -> Bool {
        guard !reachedDeadline(deadline) else { return false }
        AXUIElementSetMessagingTimeout(element, messagingTimeoutSeconds)
        return !reachedDeadline(deadline)
    }

    private static func deadlineNanoseconds(startedAt: UInt64) -> UInt64 {
        startedAt + UInt64(deadlineSeconds * 1_000_000_000)
    }

    private static func reachedDeadline(_ deadline: UInt64) -> Bool {
        DispatchTime.now().uptimeNanoseconds >= deadline
    }
}
