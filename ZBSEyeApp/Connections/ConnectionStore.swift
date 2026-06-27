import Foundation
import Observation
import AppKit

/// State of "Connections" (Step 9): local LLM config + destination folder. Persisted in UserDefaults
/// (not secrets — endpoint/model/path), the folder bookmark lives there too. @MainActor: owns NSOpenPanel and
/// the form bindings. There are no secrets (local LLM with no key) — no Keychain needed; it will appear with a cloud flag.
@MainActor
@Observable
final class ConnectionStore {
    enum LLMTestStatus: Sendable, Equatable {
        case idle, testing
        case ok(models: [String])
        case failed(String)
    }

    var llm: LLMConfig { didSet { if llm != oldValue { persist() } } }
    var destination: DestinationConfig { didSet { if destination != oldValue { persist() } } }
    var llmStatus: LLMTestStatus = .idle
    /// Models reported by the server (`GET /v1/models` — LM Studio/Ollama/…). The source for the Picker in "Connections":
    /// the choices come FROM the models actually loaded in LM Studio, rather than being typed by hand.
    var availableModels: [String] = []

    /// Picker options: models from the server + the currently selected one (if it's somehow missing from the list — don't lose the choice).
    var modelOptions: [String] {
        var opts = availableModels
        if !llm.model.isEmpty, !opts.contains(llm.model) { opts.insert(llm.model, at: 0) }
        return opts
    }

    @ObservationIgnored private let client = LocalLLMClient()
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let llmKey = "zbseye.connections.llm"
    private static let destKey = "zbseye.connections.destination"

    init() {
        self.llm = Self.loadCodable(LLMConfig.self, key: Self.llmKey) ?? .default
        self.destination = Self.loadCodable(DestinationConfig.self, key: Self.destKey) ?? .default
    }

    /// Ready to start automation: an LLM (local) is configured AND a destination is chosen.
    var isReady: Bool { llm.isConfigured && llm.isLocalOnly && destination.isConfigured }

    // MARK: LLM test

    func testLLM() async {
        llmStatus = .testing
        let cfg = llm
        switch await client.listModels(cfg) {
        case .ok(let models):
            llmStatus = .ok(models: models)
            availableModels = models
            // auto-select: if no model is set OR the previous one is no longer loaded in LM Studio — take the first
            // available one, so "Ask" works right away with an actually running model.
            if !models.isEmpty, !models.contains(llm.model) { llm.model = models[0] }
        case .failed(let msg):
            llmStatus = .failed(msg)
            availableModels = []
        }
    }

    /// Quiet model loading when "Connections" is opened (no noisy status if the server is silent —
    /// manual entry just remains). Doesn't touch llmStatus, so it won't flash an "error" before an explicit test.
    func loadModels() async {
        guard llm.isConfigured, llm.isLocalOnly else { return }
        if case .ok(let models) = await client.listModels(llm) {
            availableModels = models
            if !models.isEmpty, !models.contains(llm.model) { llm.model = models[0] }
        }
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
        Self.saveCodable(llm, key: Self.llmKey, into: defaults)
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
