import AppKit
import CoreGraphics
import Foundation

enum ScreenshotHotkeyPolicy {
    // ANSI 3, 4, and 5 on the top keyboard row. Using hardware key codes keeps
    // the system shortcuts recognizable under a non-Latin input source.
    static let screenshotKeyCodes: Set<CGKeyCode> = [20, 21, 23]

    static func isNativeScreenshotHotkey(
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> Bool {
        guard screenshotKeyCodes.contains(keyCode) else { return false }
        let relevant = flags.intersection([
            .maskCommand,
            .maskShift,
            .maskControl,
            .maskAlternate,
        ])
        return relevant == [.maskCommand, .maskShift]
            || relevant == [.maskCommand, .maskShift, .maskControl]
    }
}

enum CaptureInputEventAction: Sendable, Equatable {
    case nativeScreenshot
    case meaningful(MeaningfulCaptureInput)
    case ignore
}

/// Routes raw event primitives before anything is retained. Screenshot
/// shortcuts win over ordinary typing, so Shift-Command-3/4/5 synchronously
/// open the native-screenshot gate and emit no capture trigger.
enum CaptureInputEventPolicy {
    static func action(
        type: CGEventType,
        keyCode: CGKeyCode,
        flags: CGEventFlags
    ) -> CaptureInputEventAction {
        switch type {
        case .keyDown:
            if ScreenshotHotkeyPolicy.isNativeScreenshotHotkey(
                keyCode: keyCode,
                flags: flags
            ) {
                return .nativeScreenshot
            }
            return .meaningful(.typingActivity)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .meaningful(.click)
        case .scrollWheel:
            return .meaningful(.scrollActivity)
        default:
            return .ignore
        }
    }
}

/// A listen-only observer for coarse input activity plus Shift-Command-3/4/5
/// and their Control variants. It cannot consume, replace, or delay-deliver a
/// system event. Creating the tap is best-effort: failure leaves native input
/// untouched and never triggers a TCC prompt or opens System Settings.
@MainActor
final class ScreenshotHotkeyMonitor {
    enum StartResult: Sendable, Equatable {
        case monitoring
        case unavailable
        case alreadyStarted
    }

    private let gate: ScreenshotPriorityYieldGate
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var runningApplicationsObservation: NSKeyValueObservation?
    private var isStarted = false

    /// Emits only an opaque semantic activity kind. Raw event content and
    /// positions never leave the callback and are never retained.
    var onMeaningfulInput: (@MainActor (MeaningfulCaptureInput) -> Void)?

    init(gate: ScreenshotPriorityYieldGate) {
        self.gate = gate
    }

    @discardableResult
    func start() -> StartResult {
        guard !isStarted else { return .alreadyStarted }
        isStarted = true
        startScreenshotProcessObservation()

        // This probe never prompts. If the existing Accessibility/Input
        // Monitoring grant does not cover listen events, process-lifecycle
        // observation remains active and native screenshots continue normally.
        guard CGPreflightListenEventAccess() else {
            Log.capture.notice("screenshot_hotkey_monitor_unavailable")
            return .unavailable
        }
        let eventMask = [
            CGEventType.keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
        ].reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: screenshotPriorityEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.capture.notice("screenshot_hotkey_monitor_unavailable")
            return .unavailable
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            Log.capture.notice("screenshot_hotkey_monitor_unavailable")
            return .unavailable
        }
        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return .monitoring
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
        runningApplicationsObservation?.invalidate()
        runningApplicationsObservation = nil
        gate.replaceActiveScreenshotProcesses([])
    }

    func handleEventTap(
        typeRawValue: UInt32,
        keyCode: CGKeyCode,
        flagsRawValue: UInt64
    ) {
        let type = CGEventType(rawValue: typeRawValue)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard let type else { return }
        switch CaptureInputEventPolicy.action(
            type: type,
            keyCode: keyCode,
            flags: CGEventFlags(rawValue: flagsRawValue)
        ) {
        case .nativeScreenshot:
            // No Task or queue hop here: suppression is open before this
            // listen-only callback returns and no typing trigger is emitted.
            gate.openSuppression()
        case .meaningful(let input):
            onMeaningfulInput?(input)
        case .ignore:
            break
        }
    }

    private func startScreenshotProcessObservation() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileRunningScreenshotProcesses() }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileRunningScreenshotProcesses() }
        })
        // didLaunch/didTerminate intentionally omit background and LSUIElement
        // applications. Both native Screenshot helpers use that activation
        // policy on current macOS, so observe the KVO-compliant complete
        // inventory as the primary no-prompt fallback. Delivery is reconciled
        // on MainActor before the KVO callback returns.
        runningApplicationsObservation = NSWorkspace.shared.observe(
            \.runningApplications,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            runCaptureObservationOnMainActorSynchronously {
                self?.reconcileRunningScreenshotProcesses()
            }
        }
    }

    private func reconcileRunningScreenshotProcesses() {
        let processIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap { application -> Int32? in
                let identity = ScreenshotPriorityProcessIdentity(
                    processIdentifier: Int32(application.processIdentifier),
                    bundleIdentifier: application.bundleIdentifier,
                    executablePath: application.executableURL?.path
                )
                return ScreenshotPriorityProcessPolicy.isNativeScreenshotProcess(identity)
                    ? identity.processIdentifier
                    : nil
            }
        )
        gate.replaceActiveScreenshotProcesses(processIDs)
    }
}

/// NSWorkspace may publish its KVO inventory from a non-main thread. Capture
/// admission lives on MainActor, so close it synchronously at the observation
/// boundary instead of leaving a transient Screenshot helper behind an async
/// queue hop.
nonisolated func runCaptureObservationOnMainActorSynchronously(
    _ operation: @escaping @MainActor @Sendable () -> Void
) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { operation() }
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { operation() }
        }
    }
}

private func screenshotPriorityEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // The source is installed only on CFRunLoopGetMain(). If that invariant is
    // ever violated, fail open and return the original event untouched.
    guard Thread.isMainThread, let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<ScreenshotHotkeyMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    // CGEvent is non-Sendable. Extract only primitive values before entering
    // MainActor isolation; the event itself is returned untouched below.
    let typeRawValue = type.rawValue
    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flagsRawValue = event.flags.rawValue
    MainActor.assumeIsolated {
        monitor.handleEventTap(
            typeRawValue: typeRawValue,
            keyCode: keyCode,
            flagsRawValue: flagsRawValue
        )
    }
    return Unmanaged.passUnretained(event)
}
