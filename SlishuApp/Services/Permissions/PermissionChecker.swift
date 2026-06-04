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

/// Чистые пробы статуса TCC-прав (по дизайну онбординга, Pro выделил как высший приоритет).
/// `screenRecording` отличает `.needsRestart` (право выдано, но SCStream вернул -3801) на стороне
/// capture-слоя; здесь — базовая проба `CGPreflightScreenCaptureAccess`.
enum PermissionChecker {
    static func screenRecording() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }
    static func accessibility() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
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

    // ── запросы (показывают системный промпт) ──
    static func requestScreenRecording() { CGRequestScreenCaptureAccess() }

    static func requestAccessibility() {
        // kAXTrustedCheckOptionPrompt — глобальная var (не Sendable в Swift 6); значение стабильно.
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

    /// Deep-link в нужную панель System Settings, напр. "Privacy_ScreenCapture".
    @MainActor
    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
