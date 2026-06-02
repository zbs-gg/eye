import Foundation
import AppKit

enum SystemContext {

    static func macOSVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // VoiceOver обычно работает как процесс com.apple.VoiceOver. Дополнительно читаем universalaccess default.
    static func isVoiceOverRunning() -> Bool {
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.VoiceOver"
        }
        if running { return true }
        // best-effort через defaults
        let out = shell("/usr/bin/defaults", ["read", "com.apple.universalaccess", "voiceOverOnOffKey"])
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    // Известные оконные менеджеры — их присутствие важно, т.к. AXEnhancedUserInterface может ломать snapping.
    static func detectWindowManagers() -> [String] {
        let known: [String: String] = [
            "com.knollsoft.Rectangle": "Rectangle",
            "com.knollsoft.Hookshot": "Rectangle Pro",
            "com.divisiblebyzero.Spectacle": "Spectacle",
            "com.crowdcafe.windowmagnet": "Magnet",
            "com.amethyst.Amethyst": "Amethyst",
            "com.lwouis.alt-tab-macos": "AltTab",
            "com.surteesstudios.Bartender": "Bartender",
            "com.raycast.macos": "Raycast",
        ]
        var found: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier, let name = known[bid] { found.append(name) }
        }
        // yabai — это не .app, ловим по процессу
        if !shell("/usr/bin/pgrep", ["yabai"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.append("yabai")
        }
        return found
    }

    // Запущенные инструменты, которые сами дёргают AX и могут ГЛОБАЛЬНО держать accessibility
    // включённой — это загрязняет эксперимент (дерево «уже доступно» не из-за наших флагов).
    static func detectAXConsumers() -> [String] {
        let knownBundles: [String: String] = [
            "com.apple.VoiceOver": "VoiceOver",
            "org.hammerspoon.Hammerspoon": "Hammerspoon",
            "com.raycast.macos": "Raycast",
            "com.superduper.superwhisper": "superwhisper",
            "ai.superwhisper.app": "superwhisper",
            "com.limitless.desktop": "Limitless",
            "com.dexterleng.Shortcat": "Shortcat",
            "com.lowtechguys.rcmd": "rcmd",
            "com.knollsoft.Hookshot": "Rectangle Pro",
            "com.electron.realtime-stt": "krisp",
        ]
        var found: Set<String> = []
        for app in NSWorkspace.shared.runningApplications {
            let bid = app.bundleIdentifier ?? ""
            let name = (app.localizedName ?? "").lowercased()
            if let n = knownBundles[bid] { found.insert(n) }
            // по имени — ловим то, что не угадали по bundleId
            for needle in ["screenpipe", "krisp", "limitless", "superwhisper", "rewind", "hammerspoon", "voiceover", "shortcat", "homerow", "vimac"] {
                if name.contains(needle) || bid.lowercased().contains(needle) { found.insert(needle) }
            }
        }
        return found.sorted()
    }

    // Electron-эвристика: наличие "Electron Framework.framework" или app.asar в бандле.
    static func electronInfo(bundleURL: URL?) -> (isElectron: Bool, version: String?) {
        guard let bundleURL else { return (false, nil) }
        let fm = FileManager.default
        let fw = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        if fm.fileExists(atPath: fw.path) {
            let info = fw.appendingPathComponent("Resources/Info.plist")
            if let dict = NSDictionary(contentsOf: info),
               let v = dict["CFBundleShortVersionString"] as? String {
                return (true, v)
            }
            return (true, nil)
        }
        // app.asar — частый признак Electron
        let asar = bundleURL.appendingPathComponent("Contents/Resources/app.asar")
        if fm.fileExists(atPath: asar.path) { return (true, nil) }
        return (false, nil)
    }

    static func appVersion(bundleURL: URL?) -> String? {
        guard let bundleURL, let b = Bundle(url: bundleURL) else { return nil }
        return (b.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? (b.infoDictionary?["CFBundleVersion"] as? String)
    }

    @discardableResult
    static func shell(_ launchPath: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// CPU-время процесса в секундах через proc_pid_rusage (user+system, наносекунды → секунды).
func processCPUSeconds(_ pid: pid_t) -> Double? {
    var usage = rusage_info_current()
    let rc = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
            proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
        }
    }
    guard rc == 0 else { return nil }
    let ns = Double(usage.ri_user_time) + Double(usage.ri_system_time)
    return ns / 1_000_000_000.0
}

// Замер %CPU процесса за интервал: дельта cpu-времени / wall-интервал * 100.
func sampleCPUPercent(_ pid: pid_t, intervalSec: Double) -> Double? {
    guard let t0 = processCPUSeconds(pid) else { return nil }
    Thread.sleep(forTimeInterval: intervalSec)
    guard let t1 = processCPUSeconds(pid) else { return nil }
    return ((t1 - t0) / intervalSec) * 100.0
}
