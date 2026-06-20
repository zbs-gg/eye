import AppKit

/// Перезапуск приложения — нужен после выдачи Screen Recording (TCC применяет право только к новому
/// процессу; без релонча SCK отдаёт -3801 при «выданном» праве).
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }
}
