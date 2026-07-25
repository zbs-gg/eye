import AppKit
import CryptoKit
import Foundation

enum BrowserCallService: String, Codable, Sendable {
    case googleMeet = "google_meet"
    case zoom
    case microsoftTeams = "microsoft_teams"
}

struct BrowserCallInspectionDiagnostics: Equatable, Sendable {
    let accessibilityTrusted: Bool
    let windowsVisited: Int
    let nodesVisited: Int
    let elapsedMilliseconds: Int
    let hitWindowLimit: Bool
    let hitNodeLimit: Bool
    let timedOut: Bool
}

struct BrowserCallSurfaceInspection: Equatable, Sendable {
    let trustedOrigin: TrustedCallOrigin?
    let service: BrowserCallService?
    let sessionDiscriminator: String?
    /// False for collision-prone generic SPA routes (currently Teams `/v2`). Exact retained-root
    /// continuity still works, but a different AX root must never inherit that identity.
    let allowsCrossRootReconciliation: Bool
    let diagnostics: BrowserCallInspectionDiagnostics
    /// True only when every exposed window/node was traversed without AX errors or budget loss.
    /// It says "no call in the authoritative exposed tree", not "every background tab is visible".
    let authoritativeNoMatch: Bool
    /// Opaque in-memory capability for revalidating the exact admitted call control. It contains
    /// no URL/title text and is never logged or persisted.
    let controlHandleToken: String?

    init(
        trustedOrigin: TrustedCallOrigin?,
        service: BrowserCallService?,
        sessionDiscriminator: String?,
        allowsCrossRootReconciliation: Bool = false,
        diagnostics: BrowserCallInspectionDiagnostics,
        authoritativeNoMatch: Bool = false,
        controlHandleToken: String? = nil
    ) {
        self.trustedOrigin = trustedOrigin
        self.service = service
        self.sessionDiscriminator = sessionDiscriminator
        self.allowsCrossRootReconciliation = allowsCrossRootReconciliation
        self.diagnostics = diagnostics
        self.authoritativeNoMatch = authoritativeNoMatch
        self.controlHandleToken = controlHandleToken
    }

    var isTrustedCall: Bool {
        trustedOrigin != nil && service != nil && sessionDiscriminator != nil
    }
}

enum BrowserCallControlState: Equatable, Sendable {
    case active
    /// The same retained top-level web root produced a replacement hard control. The opaque token
    /// stays stable, but callers may combine this with a complete CoreAudio carrier replacement.
    case rebound
    /// The retained AX object disappeared. Chromium may have rebuilt the same toolbar, so callers
    /// must attempt a bounded rebind before treating this as call end.
    case invalidated
    /// The retained AX object is still readable but no longer represents the admitted hard control.
    case ended
    /// The retained AXWebArea now exposes an explicit document identity for another page/session.
    /// Unlike a missing control, this is a collision-safe boundary for the old call.
    case replaced
    case unknown
}

/// A non-prompting, bounded Accessibility probe for browser call surfaces.
///
/// The caller supplies the root PID of a supported browser. Raw Accessibility strings never leave this
/// type: the result contains only a normalized origin, a service enum, and bounded numeric diagnostics.
enum BrowserCallSurfaceInspector {
    enum RetainedDocumentState: Equatable, Sendable {
        case same
        case replaced
        case unknown
    }

    struct Limits: Equatable, Sendable {
        let maximumWindows: Int
        let maximumNodes: Int
        let deadlineSeconds: TimeInterval
        let messagingTimeoutSeconds: Float

        static let production = Limits(
            maximumWindows: 16,
            maximumNodes: 500,
            deadlineSeconds: 1,
            messagingTimeoutSeconds: 0.05
        )
    }

    /// Pure, flattened Accessibility seam used by unit tests. It deliberately mirrors only attributes
    /// needed for origin and hard-control classification.
    struct NodeSnapshot: Equatable, Sendable {
        var role: String?
        var identifier: String?
        var title: String?
        var description: String?
        var help: String?
        var value: String?
        var document: String?
        var url: String?
        var inBrowserChrome: Bool
        var inBrowserWebContent: Bool
        var webContentRootID: Int?
        var webContentTreeDepth: Int?
        var isEnabled: Bool
        var isVisible: Bool
        var supportsPressAction: Bool

        init(
            role: String? = nil,
            identifier: String? = nil,
            title: String? = nil,
            description: String? = nil,
            help: String? = nil,
            value: String? = nil,
            document: String? = nil,
            url: String? = nil,
            inBrowserChrome: Bool = false,
            inBrowserWebContent: Bool = false,
            webContentRootID: Int? = nil,
            webContentTreeDepth: Int? = nil,
            isEnabled: Bool = true,
            isVisible: Bool = true,
            supportsPressAction: Bool = true
        ) {
            self.role = role
            self.identifier = identifier
            self.title = title
            self.description = description
            self.help = help
            self.value = value
            self.document = document
            self.url = url
            self.inBrowserChrome = inBrowserChrome
            self.inBrowserWebContent = inBrowserWebContent
            self.webContentRootID = webContentRootID
            self.webContentTreeDepth = webContentTreeDepth
            self.isEnabled = isEnabled
            self.isVisible = isVisible
            self.supportsPressAction = supportsPressAction
        }

        var authoritativePageURL: String? {
            for candidate in [url, document] {
                let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmed, !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }
    }

    struct WindowSnapshot: Equatable, Sendable {
        var nodes: [NodeSnapshot]
        /// Test seam for the live walk's `hadAXFailure` fail-closed bit.
        var traversalSucceeded = true
    }

    private struct Match {
        let origin: TrustedCallOrigin
        let service: BrowserCallService
        let sessionDiscriminator: String
        let allowsCrossRootReconciliation: Bool
        let controlNodeIndex: Int
        let webContentRootID: Int
    }

    private struct PendingAXNode {
        let element: AXUIElement
        let insideBrowserChrome: Bool
        let webContentRootID: Int?
        let webContentTreeDepth: Int?
    }

    private struct PendingAXChildrenPage {
        let parent: AXUIElement
        let startIndex: Int
        let insideBrowserChrome: Bool
        let webContentRootID: Int?
        let webContentTreeDepth: Int?
    }

    private enum PendingAXWork {
        case node(PendingAXNode)
        case children(PendingAXChildrenPage)
    }

    private struct AXWindowTraversal {
        var pending: [PendingAXWork]
        var nextIndex = 0
        var snapshots: [NodeSnapshot] = []
        var elements: [AXUIElement] = []
        var countedAsVisited = false
        var nextWebContentRootID = 0
        var webContentRoots: [Int: AXUIElement] = [:]
        var hadAXFailure = false
    }

    private struct AXElementsRead {
        let elements: [AXUIElement]
        let succeeded: Bool
    }

    private struct AXCountRead {
        let count: Int
        let succeeded: Bool
    }

    private struct AXSnapshotRead {
        let snapshot: NodeSnapshot
        let topologySucceeded: Bool
        let invalidElement: Bool
    }

    private struct AXActionNamesRead {
        let names: [String]
        let succeeded: Bool
        let invalidElement: Bool
    }

    private enum RetainedRootRevalidation {
        case active(AXUIElement)
        case invalidated
        case ended
        case replaced
        case unknown
    }

    private final class ControlHandleRegistry: @unchecked Sendable {
        struct Entry {
            var element: AXUIElement
            let webContentRoot: AXUIElement
            let service: BrowserCallService
            let sessionDiscriminator: String
            var pinned: Bool
        }

        // AXUIElement is not Sendable. Entries are created, read, compared, and destroyed only
        // on the inspector's single serial AX queue; the lock is defensive, not an isolation
        // substitute. Every access asserts that queue confinement below.
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]
        private var insertionOrder: [String] = []
        private let maximumEntries = 16

        func insert(
            element: AXUIElement,
            webContentRoot: AXUIElement,
            service: BrowserCallService,
            sessionDiscriminator: String
        ) -> String? {
            dispatchPrecondition(condition: .onQueue(BrowserCallSurfaceInspector.queue))
            lock.lock()
            // Tokens are ownership leases, not AX-element identities. Never recycle one: an
            // already-enqueued teardown for the previous owner must be unable to delete a later
            // adoption of the same AX object/root.
            while entries.count >= maximumEntries {
                guard let provisional = insertionOrder.first(where: {
                    entries[$0]?.pinned == false
                }) else {
                    lock.unlock()
                    return nil
                }
                insertionOrder.removeAll { $0 == provisional }
                entries.removeValue(forKey: provisional)
            }
            let token = UUID().uuidString.lowercased()
            entries[token] = Entry(
                element: element,
                webContentRoot: webContentRoot,
                service: service,
                sessionDiscriminator: sessionDiscriminator,
                pinned: false
            )
            insertionOrder.append(token)
            lock.unlock()
            return token
        }

        func entry(for token: String) -> Entry? {
            dispatchPrecondition(condition: .onQueue(BrowserCallSurfaceInspector.queue))
            lock.lock()
            defer { lock.unlock() }
            return entries[token]
        }

        func remove(_ token: String) {
            dispatchPrecondition(condition: .onQueue(BrowserCallSurfaceInspector.queue))
            lock.lock()
            entries.removeValue(forKey: token)
            insertionOrder.removeAll { $0 == token }
            lock.unlock()
        }

        func replaceControl(_ token: String, with element: AXUIElement) {
            dispatchPrecondition(condition: .onQueue(BrowserCallSurfaceInspector.queue))
            lock.lock()
            if var entry = entries[token] {
                entry.element = element
                entries[token] = entry
            }
            lock.unlock()
        }

        func pin(_ token: String) -> Bool {
            dispatchPrecondition(condition: .onQueue(BrowserCallSurfaceInspector.queue))
            lock.lock()
            defer { lock.unlock() }
            guard var entry = entries[token] else { return false }
            entry.pinned = true
            entries[token] = entry
            return true
        }

        func roots(for tokens: Set<String>) -> [AXUIElement] {
            dispatchPrecondition(condition: .onQueue(BrowserCallSurfaceInspector.queue))
            lock.lock()
            defer { lock.unlock() }
            return tokens.compactMap { entries[$0]?.webContentRoot }
        }

#if DEBUG
        func resetForTesting() {
            dispatchPrecondition(condition: .onQueue(BrowserCallSurfaceInspector.queue))
            lock.lock()
            entries.removeAll()
            insertionOrder.removeAll()
            lock.unlock()
        }

        func containsForTesting(_ token: String) -> Bool {
            dispatchPrecondition(condition: .onQueue(BrowserCallSurfaceInspector.queue))
            lock.lock()
            defer { lock.unlock() }
            return entries[token] != nil
        }

        func countForTesting() -> Int {
            dispatchPrecondition(condition: .onQueue(BrowserCallSurfaceInspector.queue))
            lock.lock()
            defer { lock.unlock() }
            return entries.count
        }
#endif
    }

    private static let queue = DispatchQueue(
        label: "gg.zbs.eye.browser-call-surface-ax",
        qos: .utility
    )
    private static let controlHandles = ControlHandleRegistry()

    /// `AXIsProcessTrusted()` is intentionally the non-prompting trust probe. Keep even this
    /// lightweight AX call confined to the same serial utility queue as every other AX access.
    private static func isAccessibilityTrustedOnAXQueue() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        return AXIsProcessTrusted()
    }

#if DEBUG
    static func resetControlRegistryForTesting() async {
        await withCheckedContinuation { continuation in
            queue.async {
                controlHandles.resetForTesting()
                continuation.resume()
            }
        }
    }

    static func insertControlForTesting(id: Int, pinned: Bool) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let element = AXUIElementCreateApplication(pid_t(100_000 + id))
                let root = AXUIElementCreateApplication(pid_t(200_000 + id))
                let token = controlHandles.insert(
                    element: element,
                    webContentRoot: root,
                    service: .googleMeet,
                    sessionDiscriminator: "test-\(id)"
                )
                if pinned, let token {
                    _ = controlHandles.pin(token)
                }
                continuation.resume(returning: token)
            }
        }
    }

    static func controlRegistryContainsForTesting(_ token: String) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: controlHandles.containsForTesting(token)
                )
            }
        }
    }

    static func controlRegistryCountForTesting() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: controlHandles.countForTesting())
            }
        }
    }
#endif

    static func inspect(
        pid: pid_t,
        excludingControlTokens: Set<String> = []
    ) async -> BrowserCallSurfaceInspection {
        return await withCheckedContinuation { continuation in
            queue.async {
                guard isAccessibilityTrustedOnAXQueue() else {
                    continuation.resume(
                        returning: emptyInspection(accessibilityTrusted: false)
                    )
                    return
                }
                let excludedRoots = controlHandles.roots(for: excludingControlTokens)
                continuation.resume(
                    returning: inspectAX(
                        pid: pid,
                        limits: .production,
                        excludingWebContentRoots: excludedRoots
                    )
                )
            }
        }
    }

    static func revalidateControl(
        _ token: String,
        allowRootRebind: Bool
    ) async -> BrowserCallControlState {
        return await withCheckedContinuation { continuation in
            queue.async {
                guard isAccessibilityTrustedOnAXQueue() else {
                    continuation.resume(returning: .unknown)
                    return
                }
                guard let entry = controlHandles.entry(for: token) else {
                    continuation.resume(returning: .unknown)
                    return
                }
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let limits = Limits.production
                let deadline = deadlineNanoseconds(
                    startedAt: startedAt,
                    seconds: limits.deadlineSeconds
                )
                let rootRead = snapshot(
                    entry.webContentRoot,
                    deadline: deadline,
                    messagingTimeoutSeconds: limits.messagingTimeoutSeconds
                )
                if rootRead.invalidElement {
                    continuation.resume(returning: .invalidated)
                    return
                }
                guard rootRead.topologySucceeded,
                      !reachedDeadline(deadline),
                      normalized(rootRead.snapshot.role) == "axwebarea"
                else {
                    continuation.resume(returning: .unknown)
                    return
                }
                switch retainedDocumentState(
                    rawDocument: rootRead.snapshot.authoritativePageURL,
                    expectedService: entry.service,
                    expectedSessionDiscriminator: entry.sessionDiscriminator
                ) {
                case .same:
                    break
                case .replaced:
                    continuation.resume(returning: .replaced)
                    return
                case .unknown:
                    continuation.resume(returning: .unknown)
                    return
                }
                let read = snapshot(
                    entry.element,
                    deadline: deadline,
                    messagingTimeoutSeconds: limits.messagingTimeoutSeconds
                )
                if read.topologySucceeded,
                   !reachedDeadline(deadline),
                   isPersistentHardControl(read.snapshot, for: entry.service) {
                    continuation.resume(returning: .active)
                    return
                }

                guard allowRootRebind else {
                    if read.invalidElement {
                        continuation.resume(returning: .invalidated)
                    } else if !read.topologySucceeded || reachedDeadline(deadline) {
                        continuation.resume(returning: .unknown)
                    } else {
                        continuation.resume(returning: .ended)
                    }
                    return
                }

                switch revalidateWithinRetainedRoot(
                    entry,
                    deadline: deadline,
                    limits: limits
                ) {
                case let .active(replacement):
                    controlHandles.replaceControl(token, with: replacement)
                    continuation.resume(returning: .rebound)
                case .invalidated:
                    continuation.resume(returning: .invalidated)
                case .ended:
                    continuation.resume(returning: .ended)
                case .replaced:
                    continuation.resume(returning: .replaced)
                case .unknown:
                    continuation.resume(returning: .unknown)
                }
            }
        }
    }

    static func pinControl(_ token: String?) async -> Bool {
        guard let token else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: controlHandles.pin(token))
            }
        }
    }

    static func discardControl(_ token: String?) async {
        guard let token else { return }
        await withCheckedContinuation { continuation in
            queue.async {
                controlHandles.remove(token)
                continuation.resume()
            }
        }
    }

    static func retainedDocumentState(
        rawDocument: String?,
        expectedService: BrowserCallService,
        expectedSessionDiscriminator: String
    ) -> RetainedDocumentState {
        guard let rawDocument,
              !rawDocument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let components = URLComponents(string: rawDocument),
              components.scheme != nil,
              components.host != nil
        else { return .unknown }
        guard let origin = TrustedCallOrigin.normalize(rawDocument),
              let observedService = service(for: origin)
        else { return .replaced }
        let observedDiscriminator = sessionDiscriminator(
            rawURL: rawDocument,
            origin: origin
        )
        return observedService == expectedService
            && observedDiscriminator == expectedSessionDiscriminator
            ? .same
            : .replaced
    }

    /// Deterministic test seam. `clock` is monotonic nanoseconds and is injectable so deadline behavior
    /// can be tested without sleeping or touching the real Accessibility server.
    static func inspect(
        snapshots: [WindowSnapshot],
        limits: Limits = .production,
        accessibilityTrusted: Bool = true,
        excludingRootIDsByWindow: [Int: Set<Int>] = [:],
        clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> BrowserCallSurfaceInspection {
        guard accessibilityTrusted else {
            return emptyInspection(accessibilityTrusted: false)
        }

        let startedAt = clock()
        let deadline = deadlineNanoseconds(startedAt: startedAt, seconds: limits.deadlineSeconds)
        var windowsVisited = 0
        var nodesVisited = 0
        var timedOut = false
        var hitNodeLimit = false
        let hitWindowLimit = snapshots.count > limits.maximumWindows

        let boundedWindows = Array(snapshots.prefix(max(0, limits.maximumWindows)))
        var nextNode = Array(repeating: 0, count: boundedWindows.count)
        var visitedNodes = Array(repeating: [NodeSnapshot](), count: boundedWindows.count)

        // Fair round-robin traversal: a single huge Chromium window cannot consume the global
        // 500-node allowance before the focused call window is inspected.
        traversal: while nodesVisited < max(0, limits.maximumNodes) {
            var madeProgress = false
            for windowIndex in boundedWindows.indices {
                if reachedDeadline(deadline, clock: clock) {
                    timedOut = true
                    break traversal
                }
                guard nextNode[windowIndex] < boundedWindows[windowIndex].nodes.count else {
                    continue
                }

                if nextNode[windowIndex] == 0 {
                    windowsVisited += 1
                }
                madeProgress = true
                let node = boundedWindows[windowIndex].nodes[nextNode[windowIndex]]
                nextNode[windowIndex] += 1
                nodesVisited += 1
                if let rootID = node.webContentRootID,
                   excludingRootIDsByWindow[windowIndex]?.contains(rootID) == true {
                    continue
                }
                visitedNodes[windowIndex].append(node)

                if let match = classifyWindow(visitedNodes[windowIndex]) {
                    let endedAt = clock()
                    guard endedAt < deadline else {
                        timedOut = true
                        break traversal
                    }
                    return BrowserCallSurfaceInspection(
                        trustedOrigin: match.origin,
                        service: match.service,
                        sessionDiscriminator: match.sessionDiscriminator,
                        allowsCrossRootReconciliation:
                            match.allowsCrossRootReconciliation,
                        diagnostics: diagnostics(
                            trusted: true,
                            windows: windowsVisited,
                            nodes: nodesVisited,
                            startedAt: startedAt,
                            endedAt: endedAt,
                            hitWindowLimit: hitWindowLimit,
                            hitNodeLimit: false,
                            timedOut: false
                        )
                    )
                }
                if nodesVisited >= limits.maximumNodes {
                    break traversal
                }
            }
            if !madeProgress { break }
        }
        hitNodeLimit = nodesVisited >= max(0, limits.maximumNodes)
            && boundedWindows.indices.contains {
                nextNode[$0] < boundedWindows[$0].nodes.count
            }

        // A full-window second pass is retained for deterministic accounting, but 0.5.0 never
        // admits an automatic call from the omnibox alone. AXURL/AXDocument on the exact retained
        // AXWebArea is required so a hidden/rebuilt toolbar can be rebound without allowing a
        // different tab to inherit the session.
        if !timedOut {
            for windowIndex in boundedWindows.indices
            where nextNode[windowIndex] >= boundedWindows[windowIndex].nodes.count
                && boundedWindows[windowIndex].traversalSucceeded {
                guard !reachedDeadline(deadline, clock: clock) else {
                    timedOut = true
                    break
                }
                if let match = classifyWindow(
                    visitedNodes[windowIndex],
                    allowAddressBarFallback: false
                ) {
                    let endedAt = clock()
                    guard endedAt < deadline else {
                        timedOut = true
                        break
                    }
                    return BrowserCallSurfaceInspection(
                        trustedOrigin: match.origin,
                        service: match.service,
                        sessionDiscriminator: match.sessionDiscriminator,
                        allowsCrossRootReconciliation:
                            match.allowsCrossRootReconciliation,
                        diagnostics: diagnostics(
                            trusted: true,
                            windows: windowsVisited,
                            nodes: nodesVisited,
                            startedAt: startedAt,
                            endedAt: endedAt,
                            hitWindowLimit: hitWindowLimit,
                            hitNodeLimit: hitNodeLimit,
                            timedOut: false
                        )
                    )
                }
            }
        }

        let endedAt = clock()
        if endedAt >= deadline {
            timedOut = true
        }

        let authoritativeNoMatch = !timedOut
            && !hitWindowLimit
            && !hitNodeLimit
            && boundedWindows.indices.allSatisfy {
                nextNode[$0] >= boundedWindows[$0].nodes.count
                    && boundedWindows[$0].traversalSucceeded
            }
        return BrowserCallSurfaceInspection(
            trustedOrigin: nil,
            service: nil,
            sessionDiscriminator: nil,
            diagnostics: diagnostics(
                trusted: true,
                windows: windowsVisited,
                nodes: nodesVisited,
                startedAt: startedAt,
                endedAt: endedAt,
                hitWindowLimit: hitWindowLimit,
                hitNodeLimit: hitNodeLimit,
                timedOut: timedOut
            ),
            authoritativeNoMatch: authoritativeNoMatch
        )
    }

    // MARK: Live Accessibility bridge

    private static func inspectAX(
        pid: pid_t,
        limits: Limits,
        excludingWebContentRoots: [AXUIElement]
    ) -> BrowserCallSurfaceInspection {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = deadlineNanoseconds(startedAt: startedAt, seconds: limits.deadlineSeconds)
        let app = AXUIElementCreateApplication(pid)

        let windowCountRead = attributeValueCount(
            attribute: kAXWindowsAttribute as CFString,
            from: app,
            deadline: deadline,
            messagingTimeoutSeconds: limits.messagingTimeoutSeconds
        )
        let availableWindowCount = windowCountRead.count
        let maximumTraversedWindows = min(
            max(0, limits.maximumWindows),
            max(0, limits.maximumNodes)
        )
        let windowRead = elements(
            attribute: kAXWindowsAttribute as CFString,
            from: app,
            deadline: deadline,
            messagingTimeoutSeconds: limits.messagingTimeoutSeconds,
            maximumCount: maximumTraversedWindows
        )
        guard windowRead.succeeded else {
            return BrowserCallSurfaceInspection(
                trustedOrigin: nil,
                service: nil,
                sessionDiscriminator: nil,
                diagnostics: liveDiagnostics(
                    windows: 0,
                    nodes: 0,
                    startedAt: startedAt,
                    hitWindowLimit: false,
                    hitNodeLimit: false,
                    timedOut: reachedDeadline(deadline)
                )
            )
        }
        var allWindows = windowRead.elements
        if maximumTraversedWindows > 0,
           let focusedWindow = element(
            attribute: kAXFocusedWindowAttribute as CFString,
            from: app,
            deadline: deadline,
            messagingTimeoutSeconds: limits.messagingTimeoutSeconds
           )
        {
            if let focusedIndex = allWindows.firstIndex(where: { CFEqual($0, focusedWindow) }) {
                allWindows.remove(at: focusedIndex)
            } else if allWindows.count >= maximumTraversedWindows {
                allWindows.removeLast()
            }
            allWindows.insert(focusedWindow, at: 0)
        }

        let hitWindowLimit = availableWindowCount > limits.maximumWindows
        var windowsVisited = 0
        var nodesVisited = 0
        var timedOut = reachedDeadline(deadline)
        var hitNodeLimit = false

        var traversals = allWindows.prefix(maximumTraversedWindows).map {
            AXWindowTraversal(
                pending: [
                    .node(
                        PendingAXNode(
                            element: $0,
                            insideBrowserChrome: false,
                            webContentRootID: nil,
                            webContentTreeDepth: nil
                        )
                    ),
                ]
            )
        }
        var totalEnqueuedNodes = traversals.count
        let childPageSize = 8

        traversal: while nodesVisited < max(0, limits.maximumNodes) {
            var madeProgress = false
            for windowIndex in traversals.indices {
                if reachedDeadline(deadline) {
                    timedOut = true
                    break traversal
                }
                guard traversals[windowIndex].nextIndex < traversals[windowIndex].pending.count else {
                    continue
                }

                madeProgress = true
                let pendingWork = traversals[windowIndex].pending[
                    traversals[windowIndex].nextIndex
                ]
                traversals[windowIndex].nextIndex += 1

                switch pendingWork {
                case let .node(pendingNode):
                    if !traversals[windowIndex].countedAsVisited {
                        traversals[windowIndex].countedAsVisited = true
                        windowsVisited += 1
                    }
                    nodesVisited += 1

                    let snapshotRead = snapshot(
                        pendingNode.element,
                        deadline: deadline,
                        messagingTimeoutSeconds: limits.messagingTimeoutSeconds
                    )
                    var node = snapshotRead.snapshot
                    if !snapshotRead.topologySucceeded {
                        traversals[windowIndex].hadAXFailure = true
                    }
                    if reachedDeadline(deadline) {
                        timedOut = true
                        break traversal
                    }
                    let role = normalized(node.role)
                    let isToolbar = role == normalized(kAXToolbarRole as String)
                    let isWebArea = role == "axwebarea"
                    if isWebArea,
                       pendingNode.webContentRootID == nil,
                       excludingWebContentRoots.contains(where: {
                           CFEqual($0, pendingNode.element)
                       }) {
                        continue
                    }
                    var webContentRootID = pendingNode.webContentRootID
                    var webContentTreeDepth = pendingNode.webContentTreeDepth
                    if isWebArea, webContentRootID == nil {
                        webContentRootID = traversals[windowIndex].nextWebContentRootID
                        traversals[windowIndex].nextWebContentRootID += 1
                        webContentTreeDepth = 0
                        if let webContentRootID {
                            traversals[windowIndex].webContentRoots[webContentRootID] =
                                pendingNode.element
                        }
                    }
                    let inWebContent = webContentRootID != nil
                    let inBrowserChrome = !inWebContent
                        && (pendingNode.insideBrowserChrome || isToolbar)
                    node.inBrowserChrome = inBrowserChrome
                    node.inBrowserWebContent = inWebContent
                    node.webContentRootID = webContentRootID
                    node.webContentTreeDepth = webContentTreeDepth
                    traversals[windowIndex].snapshots.append(node)
                    traversals[windowIndex].elements.append(pendingNode.element)

                    traversals[windowIndex].pending.append(
                        .children(
                            PendingAXChildrenPage(
                                parent: pendingNode.element,
                                startIndex: 0,
                                insideBrowserChrome: inBrowserChrome,
                                webContentRootID: webContentRootID,
                                webContentTreeDepth: webContentTreeDepth.map { $0 + 1 }
                            )
                        )
                    )

                    if let match = classifyWindow(traversals[windowIndex].snapshots) {
                        let endedAt = DispatchTime.now().uptimeNanoseconds
                        guard endedAt < deadline else {
                            timedOut = true
                            break traversal
                        }
                        guard traversals[windowIndex].elements.indices.contains(
                            match.controlNodeIndex
                        ),
                        let webContentRoot =
                            traversals[windowIndex].webContentRoots[match.webContentRootID]
                        else {
                            traversals[windowIndex].hadAXFailure = true
                            continue
                        }
                        let token = controlHandles.insert(
                            element: traversals[windowIndex].elements[match.controlNodeIndex],
                            webContentRoot: webContentRoot,
                            service: match.service,
                            sessionDiscriminator: match.sessionDiscriminator
                        )
                        return BrowserCallSurfaceInspection(
                            trustedOrigin: match.origin,
                            service: match.service,
                            sessionDiscriminator: match.sessionDiscriminator,
                            allowsCrossRootReconciliation:
                                match.allowsCrossRootReconciliation,
                            diagnostics: liveDiagnostics(
                                windows: windowsVisited,
                                nodes: nodesVisited,
                                startedAt: startedAt,
                                hitWindowLimit: hitWindowLimit,
                                hitNodeLimit: hitNodeLimit,
                                timedOut: false
                            ),
                            controlHandleToken: token
                        )
                    }

                case let .children(page):
                    let remainingGlobalCapacity = max(
                        0,
                        limits.maximumNodes - totalEnqueuedNodes
                    )
                    guard remainingGlobalCapacity > 0 else {
                        hitNodeLimit = true
                        traversals[windowIndex].hadAXFailure = true
                        continue
                    }
                    let requestedCount = min(childPageSize, remainingGlobalCapacity)
                    let childrenRead = elements(
                        attribute: kAXChildrenAttribute as CFString,
                        from: page.parent,
                        deadline: deadline,
                        messagingTimeoutSeconds: limits.messagingTimeoutSeconds,
                        startIndex: page.startIndex,
                        maximumCount: requestedCount
                    )
                    let children = childrenRead.elements
                    if !childrenRead.succeeded {
                        traversals[windowIndex].hadAXFailure = true
                    }
                    if reachedDeadline(deadline) {
                        timedOut = true
                        break traversal
                    }
                    traversals[windowIndex].pending.append(
                        contentsOf: children.map {
                            .node(
                                PendingAXNode(
                                    element: $0,
                                    insideBrowserChrome: page.insideBrowserChrome,
                                    webContentRootID: page.webContentRootID,
                                    webContentTreeDepth: page.webContentTreeDepth
                                )
                            )
                        }
                    )
                    totalEnqueuedNodes += children.count

                    if children.count == requestedCount {
                        if totalEnqueuedNodes < limits.maximumNodes {
                            traversals[windowIndex].pending.append(
                                .children(
                                    PendingAXChildrenPage(
                                        parent: page.parent,
                                        startIndex: page.startIndex + children.count,
                                        insideBrowserChrome: page.insideBrowserChrome,
                                        webContentRootID: page.webContentRootID,
                                        webContentTreeDepth: page.webContentTreeDepth
                                    )
                                )
                            )
                        } else {
                            hitNodeLimit = true
                            traversals[windowIndex].hadAXFailure = true
                        }
                    }
                }

                if nodesVisited >= limits.maximumNodes {
                    break traversal
                }
            }
            if !madeProgress { break }
        }
        hitNodeLimit = hitNodeLimit || (nodesVisited >= max(0, limits.maximumNodes)
            && traversals.contains { $0.nextIndex < $0.pending.count }
        )

        // See the deterministic seam above. The address bar is observed only as bounded browser
        // chrome evidence; it is never sufficient for automatic admission in 0.5.0.
        if !timedOut {
            for traversal in traversals
            where traversal.nextIndex >= traversal.pending.count
                && !traversal.hadAXFailure {
                guard !reachedDeadline(deadline) else {
                    timedOut = true
                    break
                }
                if let match = classifyWindow(
                    traversal.snapshots,
                    allowAddressBarFallback: false
                ) {
                    let endedAt = DispatchTime.now().uptimeNanoseconds
                    guard endedAt < deadline else {
                        timedOut = true
                        break
                    }
                    guard traversal.elements.indices.contains(match.controlNodeIndex),
                          let webContentRoot =
                            traversal.webContentRoots[match.webContentRootID]
                    else {
                        continue
                    }
                    let token = controlHandles.insert(
                        element: traversal.elements[match.controlNodeIndex],
                        webContentRoot: webContentRoot,
                        service: match.service,
                        sessionDiscriminator: match.sessionDiscriminator
                    )
                    return BrowserCallSurfaceInspection(
                        trustedOrigin: match.origin,
                        service: match.service,
                        sessionDiscriminator: match.sessionDiscriminator,
                        allowsCrossRootReconciliation:
                            match.allowsCrossRootReconciliation,
                        diagnostics: liveDiagnostics(
                            windows: windowsVisited,
                            nodes: nodesVisited,
                            startedAt: startedAt,
                            hitWindowLimit: hitWindowLimit,
                            hitNodeLimit: hitNodeLimit,
                            timedOut: false
                        ),
                        controlHandleToken: token
                    )
                }
            }
        }
        if reachedDeadline(deadline) {
            timedOut = true
        }

        let authoritativeNoMatch = !timedOut
            && !hitWindowLimit
            && !hitNodeLimit
            && windowCountRead.succeeded
            && traversals.allSatisfy {
                $0.nextIndex >= $0.pending.count && !$0.hadAXFailure
            }
        return BrowserCallSurfaceInspection(
            trustedOrigin: nil,
            service: nil,
            sessionDiscriminator: nil,
            diagnostics: liveDiagnostics(
                windows: windowsVisited,
                nodes: nodesVisited,
                startedAt: startedAt,
                hitWindowLimit: hitWindowLimit,
                hitNodeLimit: hitNodeLimit,
                timedOut: timedOut
            ),
            authoritativeNoMatch: authoritativeNoMatch
        )
    }

    /// Re-check only the already-admitted top-level AXWebArea. This lets Chromium replace a
    /// responsive/background toolbar without changing the opaque session token, while preventing
    /// another Teams `/v2/` tab or call from inheriting the old identity.
    private static func revalidateWithinRetainedRoot(
        _ entry: ControlHandleRegistry.Entry,
        deadline: UInt64,
        limits: Limits
    ) -> RetainedRootRevalidation {
        let rootRead = snapshot(
            entry.webContentRoot,
            deadline: deadline,
            messagingTimeoutSeconds: limits.messagingTimeoutSeconds
        )
        if rootRead.invalidElement {
            return .invalidated
        }
        guard rootRead.topologySucceeded, !reachedDeadline(deadline) else {
            return .unknown
        }
        guard normalized(rootRead.snapshot.role) == "axwebarea" else {
            return .ended
        }
        switch retainedDocumentState(
            rawDocument: rootRead.snapshot.authoritativePageURL,
            expectedService: entry.service,
            expectedSessionDiscriminator: entry.sessionDiscriminator
        ) {
        case .same:
            break
        case .replaced:
            // An explicit navigation from the retained call root is stronger than an exposed-tree
            // no-match: the old page itself is gone, even if Dia keeps its HAL session alive.
            return .replaced
        case .unknown:
            // Missing or malformed AXURL/AXDocument is uncertainty, never a call boundary.
            return .unknown
        }

        var pending: [PendingAXWork] = [
            .children(
                PendingAXChildrenPage(
                    parent: entry.webContentRoot,
                    startIndex: 0,
                    insideBrowserChrome: false,
                    webContentRootID: 0,
                    webContentTreeDepth: 1
                )
            ),
        ]
        var nextIndex = 0
        var enqueuedNodes = 1
        let childPageSize = 8

        while nextIndex < pending.count {
            guard !reachedDeadline(deadline) else { return .unknown }
            let work = pending[nextIndex]
            nextIndex += 1

            switch work {
            case let .node(node):
                let read = snapshot(
                    node.element,
                    deadline: deadline,
                    messagingTimeoutSeconds: limits.messagingTimeoutSeconds
                )
                guard read.topologySucceeded,
                      !read.invalidElement,
                      !reachedDeadline(deadline)
                else {
                    return .unknown
                }
                var candidate = read.snapshot
                candidate.inBrowserWebContent = true
                candidate.webContentRootID = 0
                candidate.webContentTreeDepth = node.webContentTreeDepth
                if isPersistentHardControl(candidate, for: entry.service) {
                    return .active(node.element)
                }
                pending.append(
                    .children(
                        PendingAXChildrenPage(
                            parent: node.element,
                            startIndex: 0,
                            insideBrowserChrome: false,
                            webContentRootID: 0,
                            webContentTreeDepth: node.webContentTreeDepth.map { $0 + 1 }
                        )
                    )
                )

            case let .children(page):
                let remaining = max(0, limits.maximumNodes - enqueuedNodes)
                guard remaining > 0 else { return .unknown }
                let requested = min(childPageSize, remaining)
                let read = elements(
                    attribute: kAXChildrenAttribute as CFString,
                    from: page.parent,
                    deadline: deadline,
                    messagingTimeoutSeconds: limits.messagingTimeoutSeconds,
                    startIndex: page.startIndex,
                    maximumCount: requested
                )
                guard read.succeeded, !reachedDeadline(deadline) else {
                    return .unknown
                }
                pending.append(contentsOf: read.elements.map {
                    .node(
                        PendingAXNode(
                            element: $0,
                            insideBrowserChrome: false,
                            webContentRootID: 0,
                            webContentTreeDepth: page.webContentTreeDepth
                        )
                    )
                })
                enqueuedNodes += read.elements.count

                if read.elements.count == requested {
                    guard enqueuedNodes < limits.maximumNodes else {
                        return .unknown
                    }
                    pending.append(
                        .children(
                            PendingAXChildrenPage(
                                parent: page.parent,
                                startIndex: page.startIndex + read.elements.count,
                                insideBrowserChrome: false,
                                webContentRootID: 0,
                                webContentTreeDepth: page.webContentTreeDepth
                            )
                        )
                    )
                }
            }
        }

        return .ended
    }

    private static func snapshot(
        _ element: AXUIElement,
        deadline: UInt64,
        messagingTimeoutSeconds: Float
    ) -> AXSnapshotRead {
        guard prepare(
            element,
            deadline: deadline,
            messagingTimeoutSeconds: messagingTimeoutSeconds
        ) else {
            return AXSnapshotRead(
                snapshot: NodeSnapshot(),
                topologySucceeded: false,
                invalidElement: false
            )
        }
        let attributes: [CFString] = [
            kAXRoleAttribute as CFString,
            kAXIdentifierAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString,
            kAXValueAttribute as CFString,
            kAXDocumentAttribute as CFString,
            "AXURL" as CFString,
            kAXEnabledAttribute as CFString,
            kAXHiddenAttribute as CFString,
        ]
        var rawValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &rawValues
        )
        let invalidElement = error == .invalidUIElement
        guard error == .success,
              !reachedDeadline(deadline),
              let values = rawValues as? [Any],
              values.count == attributes.count
        else {
            return AXSnapshotRead(
                snapshot: NodeSnapshot(),
                topologySucceeded: false,
                invalidElement: invalidElement
            )
        }

        let role = stringValue(values[0])
        let actions = actionNames(
            from: element,
            deadline: deadline,
            messagingTimeoutSeconds: messagingTimeoutSeconds
        )
        return AXSnapshotRead(
            snapshot: NodeSnapshot(
                role: role,
                identifier: stringValue(values[1]),
                title: stringValue(values[2]),
                description: stringValue(values[3]),
                help: stringValue(values[4]),
                value: stringValue(values[5]),
                document: stringValue(values[6]),
                url: stringValue(values[7]),
                isEnabled: boolValue(values[8]) ?? false,
                isVisible: !(boolValue(values[9]) ?? false),
                supportsPressAction: actions.names.contains(kAXPressAction as String)
            ),
            topologySucceeded: role != nil && actions.succeeded,
            invalidElement: actions.invalidElement
        )
    }

    private static func stringValue(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        if let url = value as? NSURL { return url.absoluteString }
        return nil
    }

    private static func boolValue(_ value: Any) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private static func prepare(
        _ element: AXUIElement,
        deadline: UInt64,
        messagingTimeoutSeconds: Float
    ) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return false }
        // AX messaging timeouts are exact-object only. Apply the bound to every app/window/child
        // immediately before querying it; setting it on the application does not cover descendants.
        let remainingSeconds = Float(Double(deadline - now) / 1_000_000_000)
        AXUIElementSetMessagingTimeout(
            element,
            min(messagingTimeoutSeconds, remainingSeconds)
        )
        return !reachedDeadline(deadline)
    }

    private static func elements(
        attribute: CFString,
        from element: AXUIElement,
        deadline: UInt64,
        messagingTimeoutSeconds: Float,
        startIndex: Int = 0,
        maximumCount: Int
    ) -> AXElementsRead {
        guard startIndex >= 0, maximumCount > 0 else {
            return AXElementsRead(elements: [], succeeded: true)
        }
        guard prepare(
            element,
            deadline: deadline,
            messagingTimeoutSeconds: messagingTimeoutSeconds
        ) else {
            return AXElementsRead(elements: [], succeeded: false)
        }
        var values: CFArray?
        let error = AXUIElementCopyAttributeValues(
            element,
            attribute,
            startIndex,
            maximumCount,
            &values
        )
        guard !reachedDeadline(deadline) else {
            return AXElementsRead(elements: [], succeeded: false)
        }
        if error == .noValue || error == .attributeUnsupported {
            return AXElementsRead(elements: [], succeeded: true)
        }
        guard error == .success,
              let elements = values as? [AXUIElement]
        else {
            return AXElementsRead(elements: [], succeeded: false)
        }
        return AXElementsRead(elements: elements, succeeded: true)
    }

    private static func attributeValueCount(
        attribute: CFString,
        from element: AXUIElement,
        deadline: UInt64,
        messagingTimeoutSeconds: Float
    ) -> AXCountRead {
        guard prepare(
            element,
            deadline: deadline,
            messagingTimeoutSeconds: messagingTimeoutSeconds
        ) else { return AXCountRead(count: 0, succeeded: false) }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, attribute, &count) == .success,
              !reachedDeadline(deadline)
        else { return AXCountRead(count: 0, succeeded: false) }
        return AXCountRead(count: max(0, count), succeeded: true)
    }

    private static func element(
        attribute: CFString,
        from element: AXUIElement,
        deadline: UInt64,
        messagingTimeoutSeconds: Float
    ) -> AXUIElement? {
        guard prepare(
            element,
            deadline: deadline,
            messagingTimeoutSeconds: messagingTimeoutSeconds
        ) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              !reachedDeadline(deadline),
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func actionNames(
        from element: AXUIElement,
        deadline: UInt64,
        messagingTimeoutSeconds: Float
    ) -> AXActionNamesRead {
        guard prepare(
            element,
            deadline: deadline,
            messagingTimeoutSeconds: messagingTimeoutSeconds
        ) else {
            return AXActionNamesRead(names: [], succeeded: false, invalidElement: false)
        }
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        guard !reachedDeadline(deadline) else {
            return AXActionNamesRead(names: [], succeeded: false, invalidElement: false)
        }
        if error == .actionUnsupported || error == .notImplemented {
            return AXActionNamesRead(names: [], succeeded: true, invalidElement: false)
        }
        guard error == .success,
              let result = names as? [String]
        else {
            return AXActionNamesRead(
                names: [],
                succeeded: false,
                invalidElement: error == .invalidUIElement
            )
        }
        return AXActionNamesRead(names: result, succeeded: true, invalidElement: false)
    }

    // MARK: Pure classification

    private static func classifyWindow(
        _ nodes: [NodeSnapshot],
        allowAddressBarFallback: Bool = false
    ) -> Match? {
        struct DocumentCandidate {
            let rootID: Int?
            let depth: Int
            let rawValue: String
        }

        var documents: [DocumentCandidate] = []
        var addressBarOrigins: [(TrustedCallOrigin, BrowserCallService, String)] = []
        var controlsByRoot: [Int: [(index: Int, node: NodeSnapshot)]] = [:]

        for (nodeIndex, node) in nodes.enumerated() {
            if normalized(node.role) == "axwebarea",
               let document = node.authoritativePageURL?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !document.isEmpty
            {
                documents.append(
                    DocumentCandidate(
                        rootID: node.webContentRootID,
                        depth: node.webContentTreeDepth ?? -1,
                        rawValue: document
                    )
                )
            }

            if isAddressBar(node),
               let value = node.value,
               let origin = TrustedCallOrigin.normalize(value),
               let service = service(for: origin)
            {
                addressBarOrigins.append((
                    origin,
                    service,
                    sessionDiscriminator(rawURL: value, origin: origin)
                ))
            }

            if isControl(node), let rootID = node.webContentRootID {
                controlsByRoot[rootID, default: []].append((nodeIndex, node))
            }
        }

        let topLevelDocuments = documents.filter {
            $0.rootID != nil && $0.depth == 0
        }
        if !topLevelDocuments.isEmpty {
            for (rootID, controls) in controlsByRoot {
                let authoritativeDocuments = topLevelDocuments.filter {
                    $0.rootID == rootID
                }

                // Only AXURL/AXDocument attached to the top-level AXWebArea is authoritative.
                // A trusted iframe, link, address bar, or side panel can never supply page origin.
                let normalizedDocuments = authoritativeDocuments.map {
                    (
                        rawValue: $0.rawValue,
                        origin: TrustedCallOrigin.normalize($0.rawValue)
                    )
                }
                guard normalizedDocuments.allSatisfy({ $0.origin != nil }) else {
                    continue
                }

                for document in normalizedDocuments {
                    guard let origin = document.origin,
                          let service = service(for: origin),
                          let control = controls.first(where: {
                              isHardControl($0.node, for: service)
                          })
                    else { continue }
                    return Match(
                        origin: origin,
                        service: service,
                        sessionDiscriminator: sessionDiscriminator(
                            rawURL: document.rawValue,
                            origin: origin
                        ),
                        allowsCrossRootReconciliation:
                            allowsCrossRootReconciliation(
                                rawURL: document.rawValue,
                                service: service
                            ),
                        controlNodeIndex: control.index,
                        webContentRootID: rootID
                    )
                }
            }
            return nil
        }

        guard allowAddressBarFallback else { return nil }

        // Without AXURL/AXDocument, the browser chrome can supply the origin only when the entire
        // window has exactly one web-content root. We deliberately fail closed for side panels,
        // background web roots, or any other ambiguous Chromium topology.
        let webContentRootIDs = Set(nodes.compactMap { node -> Int? in
            guard node.inBrowserWebContent else { return nil }
            return node.webContentRootID
        })
        guard webContentRootIDs.count == 1,
              let onlyRootID = webContentRootIDs.first,
              let rootControls = controlsByRoot[onlyRootID]
        else { return nil }

        let uniqueAddressCandidates = Dictionary(
            addressBarOrigins.map {
                ("\($0.1.rawValue)|\($0.2)", $0)
            },
            uniquingKeysWith: { first, _ in first }
        ).values
        guard uniqueAddressCandidates.count == 1,
              let (origin, service, discriminator) = uniqueAddressCandidates.first,
              let control = rootControls.first(where: {
                  isHardControl($0.node, for: service)
              })
        else { return nil }
        return Match(
            origin: origin,
            service: service,
            sessionDiscriminator: discriminator,
            allowsCrossRootReconciliation: allowsCrossRootReconciliation(
                rawURL: "\(origin.scheme)://\(origin.host)",
                service: service
            ),
            controlNodeIndex: control.index,
            webContentRootID: onlyRootID
        )
    }

    private static func sessionDiscriminator(
        rawURL: String,
        origin: TrustedCallOrigin
    ) -> String {
        var material = "\(origin.scheme)://\(origin.host)"
        if let components = URLComponents(string: rawURL) {
            if let port = components.port, port != 443 {
                material += ":\(port)"
            }
            var path = components.percentEncodedPath
            while path.count > 1, path.hasSuffix("/") {
                path.removeLast()
            }
            if !path.isEmpty, path != "/" {
                material += path
            }
        }
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func allowsCrossRootReconciliation(
        rawURL: String,
        service: BrowserCallService
    ) -> Bool {
        guard service == .microsoftTeams else { return true }
        guard let components = URLComponents(string: rawURL) else { return false }
        let path = components.percentEncodedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        // Teams exposes multiple calls at this generic SPA route. Without session-bearing URL
        // material, only the retained AX root is collision-safe.
        return !path.isEmpty && path != "v2"
    }

    private static func service(for origin: TrustedCallOrigin) -> BrowserCallService? {
        switch origin.host {
        case "meet.google.com":
            return .googleMeet
        case "zoom.us":
            return .zoom
        case let host where host.hasSuffix(".zoom.us"):
            return .zoom
        case "teams.microsoft.com", "teams.live.com":
            return .microsoftTeams
        default:
            return nil
        }
    }

    private static func isAddressBar(_ node: NodeSnapshot) -> Bool {
        guard node.inBrowserChrome, !node.inBrowserWebContent else { return false }
        let role = normalized(node.role)
        guard role == normalized(kAXTextFieldRole as String)
                || role == normalized(kAXComboBoxRole as String)
        else { return false }

        let identifier = normalized(node.identifier)
        let knownIdentifiers: Set<String> = [
            "address bar",
            "address-bar",
            "addressbar",
            "location bar",
            "location-bar",
            "omnibox",
        ]
        if knownIdentifiers.contains(identifier) {
            return true
        }

        let accessibleLabels = [node.title, node.description, node.help]
            .map(normalized)
            .filter { !$0.isEmpty }
        let labels = [
            "address bar",
            "address and search bar",
            "location bar",
            "omnibox",
            "адресная строка",
            "адрес и строка поиска",
        ]
        return accessibleLabels.contains { labels.contains($0) }
    }

    private static func isControl(_ node: NodeSnapshot) -> Bool {
        let role = normalized(node.role)
        return node.inBrowserWebContent
            && node.isEnabled
            && node.isVisible
            && node.supportsPressAction
            && (
                role == normalized(kAXButtonRole as String)
                    || role == normalized(kAXMenuButtonRole as String)
            )
    }

    private static func isHardControl(_ node: NodeSnapshot, for service: BrowserCallService) -> Bool {
        let identifier = normalized(node.identifier)
        if service == .microsoftTeams, identifier == "hangup-button" {
            return true
        }

        let labels = [node.title, node.description, node.help]
            .compactMap(normalized)

        let hardLabels: [String]
        switch service {
        case .googleMeet:
            hardLabels = [
                "leave call",
                "end call",
                "leave meeting",
                "покинуть звонок",
                "завершить звонок",
                "выйти из конференции",
            ]
        case .zoom:
            hardLabels = [
                "leave",
                "end",
                "leave meeting",
                "end meeting",
                "выйти",
                "завершить",
                "выйти из конференции",
                "завершить конференцию",
            ]
        case .microsoftTeams:
            hardLabels = [
                "leave",
                "hang up",
                "leave call",
                "end call",
                "покинуть",
                "завершить звонок",
                "положить трубку",
            ]
        }
        return labels.contains { label in
            hardLabels.contains { hardLabel in
                label == hardLabel
                    || label.hasPrefix("\(hardLabel) button")
                    || label.hasPrefix("\(hardLabel),")
                    || label.hasPrefix("\(hardLabel) (")
            }
        }
    }

    private static func isPersistentHardControl(
        _ node: NodeSnapshot,
        for service: BrowserCallService
    ) -> Bool {
        // Chromium may mark the already-confirmed control hidden when its tab moves to the
        // background. The opaque handle was admitted only after its web-content ancestry was
        // proven, so a direct re-read does not need to rediscover that lost ancestry bit.
        // Its role/action/label identity remains a valid continuity signal.
        var persistent = node
        persistent.inBrowserWebContent = true
        persistent.isVisible = true
        return isControl(persistent) && isHardControl(persistent, for: service)
    }

    private static func normalized(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Budgets and diagnostics

    private static func deadlineNanoseconds(startedAt: UInt64, seconds: TimeInterval) -> UInt64 {
        let duration = UInt64(max(0, seconds) * 1_000_000_000)
        return startedAt.addingReportingOverflow(duration).partialValue
    }

    private static func reachedDeadline(
        _ deadline: UInt64,
        clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) -> Bool {
        clock() >= deadline
    }

    private static func elapsedMilliseconds(startedAt: UInt64, endedAt: UInt64) -> Int {
        guard endedAt >= startedAt else { return 0 }
        return Int(min((endedAt - startedAt) / 1_000_000, UInt64(Int.max)))
    }

    private static func diagnostics(
        trusted: Bool,
        windows: Int,
        nodes: Int,
        startedAt: UInt64,
        endedAt: UInt64,
        hitWindowLimit: Bool,
        hitNodeLimit: Bool,
        timedOut: Bool
    ) -> BrowserCallInspectionDiagnostics {
        BrowserCallInspectionDiagnostics(
            accessibilityTrusted: trusted,
            windowsVisited: windows,
            nodesVisited: nodes,
            elapsedMilliseconds: elapsedMilliseconds(startedAt: startedAt, endedAt: endedAt),
            hitWindowLimit: hitWindowLimit,
            hitNodeLimit: hitNodeLimit,
            timedOut: timedOut
        )
    }

    private static func liveDiagnostics(
        windows: Int,
        nodes: Int,
        startedAt: UInt64,
        hitWindowLimit: Bool,
        hitNodeLimit: Bool,
        timedOut: Bool
    ) -> BrowserCallInspectionDiagnostics {
        BrowserCallInspectionDiagnostics(
            accessibilityTrusted: true,
            windowsVisited: windows,
            nodesVisited: nodes,
            elapsedMilliseconds: elapsedMilliseconds(
                startedAt: startedAt,
                endedAt: DispatchTime.now().uptimeNanoseconds
            ),
            hitWindowLimit: hitWindowLimit,
            hitNodeLimit: hitNodeLimit,
            timedOut: timedOut
        )
    }

    private static func emptyInspection(accessibilityTrusted: Bool) -> BrowserCallSurfaceInspection {
        BrowserCallSurfaceInspection(
            trustedOrigin: nil,
            service: nil,
            sessionDiscriminator: nil,
            diagnostics: BrowserCallInspectionDiagnostics(
                accessibilityTrusted: accessibilityTrusted,
                windowsVisited: 0,
                nodesVisited: 0,
                elapsedMilliseconds: 0,
                hitWindowLimit: false,
                hitNodeLimit: false,
                timedOut: false
            )
        )
    }
}
