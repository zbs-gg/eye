import Foundation
import Observation
import AppKit

/// Состояние «Подключений» (Шаг 9): конфиг локальной LLM + папка-назначение. Persist в UserDefaults
/// (не секреты — endpoint/модель/путь), bookmark папки тоже там. @MainActor: владеет NSOpenPanel и
/// биндингами формы. Секретов нет (локальная LLM без ключа) — Keychain не нужен; появится при cloud-флаге.
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

    @ObservationIgnored private let client = LocalLLMClient()
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let llmKey = "zbseye.connections.llm"
    private static let destKey = "zbseye.connections.destination"

    init() {
        self.llm = Self.loadCodable(LLMConfig.self, key: Self.llmKey) ?? .default
        self.destination = Self.loadCodable(DestinationConfig.self, key: Self.destKey) ?? .default
    }

    /// Готовность к запуску pipe: настроена LLM (локальная) И выбрано назначение.
    var isReady: Bool { llm.isConfigured && llm.isLocalOnly && destination.isConfigured }

    // MARK: проверка LLM

    func testLLM() async {
        llmStatus = .testing
        let cfg = llm
        switch await client.listModels(cfg) {
        case .ok(let models):   llmStatus = .ok(models: models)
        case .failed(let msg):  llmStatus = .failed(msg)
        }
    }

    // MARK: выбор папки назначения

    /// Открывает NSOpenPanel, сохраняет bookmark + отображаемый путь. Без App Sandbox security-scope
    /// не обязателен, но bookmark переживает переименование/перенос папки (Obsidian vault мигрирует).
    func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.message = "Папка для саммари (например, папка Obsidian vault)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bm = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            destination.bookmark = bm
            destination.displayPath = url.path
        } catch {
            // bookmark не вышел — хотя бы путь (без sandbox запись по пути всё равно сработает)
            destination.displayPath = url.path
        }
    }

    /// Резолвит bookmark → URL для записи. Возвращает (url, нужен ли stopAccessing).
    func resolveDestinationURL() -> URL? {
        if let bm = destination.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bm, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    destination.bookmark = fresh   // обновляем протухший bookmark
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
