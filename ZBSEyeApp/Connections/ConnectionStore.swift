import Foundation
import Observation
import AppKit

/// State of the summaries destination folder (the card lives in "Automations" — it belongs to
/// export/daily-summary, not to agent access). Persisted in UserDefaults (not secrets — path +
/// bookmark). @MainActor: owns NSOpenPanel and the form bindings.
/// The LLM half moved to AIProviderStore ("AI Models" section); the legacy "zbseye.connections.llm"
/// value is left in defaults on purpose — AIProviderStore migrates from it once and never writes it.
@MainActor
@Observable
final class ConnectionStore {
    var destination: DestinationConfig { didSet { if destination != oldValue { persist() } } }

    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let destKey = "zbseye.connections.destination"

    init() {
        self.destination = Self.loadCodable(DestinationConfig.self, key: Self.destKey) ?? .default
    }

    // MARK: destination folder selection

    /// Opens NSOpenPanel, saves the bookmark + a displayable path. Without App Sandbox the security scope
    /// isn't required, but the bookmark survives renaming/moving the folder (an Obsidian vault migrates).
    func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Folder for summaries (for example, your Obsidian vault folder)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bm = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            destination.bookmark = bm
            destination.displayPath = url.path
        } catch {
            // the bookmark didn't work out — at least keep the path (without sandbox, writing by path still works)
            destination.displayPath = url.path
        }
    }

    /// Resolves the bookmark → URL for writing. Returns (url, whether stopAccessing is needed).
    func resolveDestinationURL() -> URL? {
        if let bm = destination.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bm, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    destination.bookmark = fresh   // refresh the stale bookmark
                }
                return url
            }
        }
        if let p = destination.displayPath { return URL(fileURLWithPath: p) }
        return nil
    }

    // MARK: persistence

    private func persist() {
        Self.saveCodable(destination, key: Self.destKey, into: defaults)
    }

    private static func loadCodable<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private static func saveCodable<T: Encodable>(_ value: T, key: String, into defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
