import Foundation
import Observation
import AppKit

/// Privacy-исключения: список приложений, которые НЕ записываются. Дефолт — пустой («писать всё» —
/// позиция продукта); исключения — осознанный opt-in для 1Password/банка. Persist в UserDefaults.
@MainActor
@Observable
final class PrivacyStore {
    private(set) var ignoredBundleIds: [String] {
        didSet { UserDefaults.standard.set(ignoredBundleIds, forKey: Self.key) }
    }
    /// Имена для UI (bundleId → отображаемое имя, лениво из установленного приложения).
    private(set) var displayNames: [String: String] = [:]

    @ObservationIgnored private static let key = "zbseye.privacy.ignoredApps"

    init() {
        ignoredBundleIds = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        for id in ignoredBundleIds { displayNames[id] = Self.lookupName(id) ?? id }
    }

    func isIgnored(_ bundleId: String) -> Bool { ignoredBundleIds.contains(bundleId) }

    /// Выбор .app через NSOpenPanel → bundleId.
    func addAppViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Исключить"
        panel.message = "Экран и текст этого приложения не будут записываться (звук — не гасится)"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        guard !ignoredBundleIds.contains(id) else { return }
        ignoredBundleIds.append(id)
        displayNames[id] = (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    func remove(_ bundleId: String) {
        ignoredBundleIds.removeAll { $0 == bundleId }
    }

    private static func lookupName(_ bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return Bundle(url: url)?.infoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}
