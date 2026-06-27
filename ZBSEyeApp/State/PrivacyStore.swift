import Foundation
import Observation
import AppKit

/// Privacy exclusions: the list of apps that are NOT recorded. Default is empty (“record everything” —
/// the product stance); exclusions are a deliberate opt-in for 1Password/banking. Persisted in UserDefaults.
@MainActor
@Observable
final class PrivacyStore {
    private(set) var ignoredBundleIds: [String] {
        didSet { UserDefaults.standard.set(ignoredBundleIds, forKey: Self.key) }
    }
    /// Names for the UI (bundleId → display name, fetched lazily from the installed app).
    private(set) var displayNames: [String: String] = [:]

    @ObservationIgnored private static let key = "zbseye.privacy.ignoredApps"

    init() {
        ignoredBundleIds = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        for id in ignoredBundleIds { displayNames[id] = Self.lookupName(id) ?? id }
    }

    func isIgnored(_ bundleId: String) -> Bool { ignoredBundleIds.contains(bundleId) }

    /// Pick a .app via NSOpenPanel → bundleId.
    func addAppViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.message = "This app’s screen and text won’t be recorded (audio is not muted)"
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
