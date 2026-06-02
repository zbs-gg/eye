import SwiftUI
import Cocoa

public final class SlishuActivityMonitor {
    public static let shared = SlishuActivityMonitor()
    
    private var isPausedDueToInactivity = false
    private var isPausedDueToSleep = false
    private var inactivityTimer: Timer?
    
    private init() {}
    
    public func startMonitoring() {
        // Подписываемся на системные уведомления сна / блокировки Mac
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        notificationCenter.addObserver(self, selector: #selector(handleWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        
        // Каждую минуту проверяем неактивность пользователя (мышь/клавиатура)
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.checkInactivity()
        }
        print("🕒 Запущен умный мониторинг активности пользователя и сна Mac")
    }
    
    @objc private func handleSleep() {
        print("🕒 Экран Mac заблокирован / засыпает. Ставим захват на паузу...")
        isPausedDueToSleep = true
        pauseCaptureIfNeeded()
    }
    
    @objc private func handleWake() {
        print("🕒 Экран Mac активен. Возобновляем захват...")
        isPausedDueToSleep = false
        resumeCaptureIfNeeded()
    }
    
    private func checkInactivity() {
        let seconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        let thresholdSeconds: TimeInterval = 180.0 // 3 минуты порог неактивности
        
        if seconds >= thresholdSeconds {
            if !isPausedDueToInactivity {
                print("🕒 Пользователь неактивен \(Int(seconds)) сек. Переводим захват на паузу для экономии энергии...")
                isPausedDueToInactivity = true
                pauseCaptureIfNeeded()
            }
        } else {
            if isPausedDueToInactivity {
                print("🕒 Пользователь вернулся к работе. Возобновляем фоновый захват...")
                isPausedDueToInactivity = false
                resumeCaptureIfNeeded()
            }
        }
    }
    
    private func pauseCaptureIfNeeded() {
        if SlishuCapture.shared.isCapturing {
            SlishuCapture.shared.stopCapture()
        }
    }
    
    private func resumeCaptureIfNeeded() {
        // Запускаем только если нет сна и пользователь активен
        if !isPausedDueToSleep && !isPausedDueToInactivity {
            if !SlishuCapture.shared.isCapturing {
                SlishuCapture.shared.startCapture()
            }
        }
    }
}

@main
struct SlishuApp: App {
    init() {
        // Инициализируем умный мониторинг при старте приложения
        SlishuActivityMonitor.shared.startMonitoring()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        
        MenuBarExtra("Slishu", systemImage: "waveform") {
            Button("Открыть таймлайн...") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            
            Divider()
            
            Button("Завершить Slishu") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
