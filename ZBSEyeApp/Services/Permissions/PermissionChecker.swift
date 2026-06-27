import Foundation
import ApplicationServices
import AVFoundation
import CoreGraphics
import Speech
import AppKit

enum PermissionStatus: String, Sendable {
    case granted, denied, notDetermined, needsRestart
}

struct PermissionSnapshot: Sendable {
    var screenRecording: PermissionStatus = .notDetermined
    var accessibility: PermissionStatus = .notDetermined
    var microphone: PermissionStatus = .notDetermined
    var speech: PermissionStatus = .notDetermined
}

/// Pure probes of TCC permission status (per onboarding design, Pro flagged it as top priority).
/// `screenRecording` distinguishes `.needsRestart` (permission granted, but SCStream returned -3801) on the
/// capture layer's side; here — the basic `CGPreflightScreenCaptureAccess` probe.
enum PermissionChecker {
    /// CGPreflight/AXIsProcessTrusted don't distinguish denied from notDetermined (both false). We distinguish ourselves:
    /// while we've never requested the permission — it's notDetermined (the "Request" button makes sense);
    /// after a request, false = denied (the "Settings" button makes sense).
    private static let requestedScreenKey = "zbseye.requested.screenRecording"
    private static let requestedAXKey = "zbseye.requested.accessibility"

    static func screenRecording() -> PermissionStatus {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return UserDefaults.standard.bool(forKey: requestedScreenKey) ? .denied : .notDetermined
    }
    static func accessibility() -> PermissionStatus {
        if AXIsProcessTrusted() { return .granted }
        return UserDefaults.standard.bool(forKey: requestedAXKey) ? .denied : .notDetermined
    }
    static func microphone() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:           return .granted
        case .denied, .restricted:  return .denied
        case .notDetermined:        return .notDetermined
        @unknown default:           return .notDetermined
        }
    }
    static func speech() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:           return .granted
        case .denied, .restricted:  return .denied
        case .notDetermined:        return .notDetermined
        @unknown default:           return .notDetermined
        }
    }

    static func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(screenRecording: screenRecording(),
                           accessibility: accessibility(),
                           microphone: microphone(),
                           speech: speech())
    }

    // ── requests (show the system prompt) ──
    static func requestScreenRecording() {
        UserDefaults.standard.set(true, forKey: requestedScreenKey)
        CGRequestScreenCaptureAccess()
    }

    static func requestAccessibility() {
        UserDefaults.standard.set(true, forKey: requestedAXKey)
        // kAXTrustedCheckOptionPrompt — a global var (not Sendable in Swift 6); the value is stable.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func requestSpeech() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
        }
    }

    /// Deep-link to the relevant System Settings pane, e.g. "Privacy_ScreenCapture".
    @MainActor
    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
