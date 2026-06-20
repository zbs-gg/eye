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
    /// CGPreflight/AXIsProcessTrusted не различают denied и notDetermined (оба false). Различаем сами:
    /// пока мы ни разу не запрашивали право — это notDetermined (кнопка «Запросить» осмыслена);
    /// после запроса false = denied (осмыслена кнопка «Настройки»).
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

    // ── запросы (показывают системный промпт) ──
    static func requestScreenRecording() {
        UserDefaults.standard.set(true, forKey: requestedScreenKey)
        CGRequestScreenCaptureAccess()
    }

    static func requestAccessibility() {
        UserDefaults.standard.set(true, forKey: requestedAXKey)
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
