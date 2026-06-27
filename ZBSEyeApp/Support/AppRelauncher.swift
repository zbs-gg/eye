import AppKit

/// Restart the app — needed after Screen Recording is granted (TCC applies the permission only to a new
/// process; without a relaunch SCK returns -3801 even though the permission is "granted").
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
