import CryptoKit
import Foundation

enum HandySpeechModelState: String, Sendable, Equatable {
    case checking
    case unavailable
    case ready
}

struct HandySpeechBackendReference: Codable, Sendable, Equatable {
    let modelID: String
    let displayName: String
    let identitySHA256: String
    let runtimeRelease: String
}

struct HandySpeechModelSnapshot: Sendable, Equatable {
    let state: HandySpeechModelState
    let backend: HandySpeechBackendReference?

    static let checking = HandySpeechModelSnapshot(state: .checking, backend: nil)
    static let unavailable = HandySpeechModelSnapshot(state: .unavailable, backend: nil)
}

/// Discovers the Whisper model Handy has already downloaded without starting
/// Handy or copying its weights. The helper process later resolves the same
/// immutable Hugging Face snapshot and loads it with Eye's bundled runtime.
actor HandySpeechModelStore {
    private(set) var current: HandySpeechModelSnapshot = .checking

    func snapshot() -> HandySpeechModelSnapshot { current }

    @discardableResult
    func refresh() async -> HandySpeechModelSnapshot {
        current = .checking
        let discovered = await Task.detached(priority: .utility) {
            HandySpeechModelProbe.discover()
        }.value
        current = discovered
        return discovered
    }
}

enum HandySpeechModelProbe {
    static let bundleIdentifier = "com.pais.handy"
    static let runtimeRelease = "transcribe.cpp-v0.1.3"
    static let maximumSettingsBytes = 1 * 1_024 * 1_024
    static let minimumModelBytes: Int64 = 1 * 1_024 * 1_024

    private struct SelectedModelSettings: Decodable {
        let selectedModel: String?

        enum CodingKeys: String, CodingKey {
            case selectedModel = "selected_model"
        }
    }

    /// Handy's current settings store wraps preferences in a `settings`
    /// object. Older releases wrote the same fields at the top level. Accept
    /// either immutable shape, but fail closed if both disagree.
    private struct SettingsEnvelope: Decodable {
        let selectedModel: String?
        let settings: SelectedModelSettings?

        enum CodingKeys: String, CodingKey {
            case selectedModel = "selected_model"
            case settings
        }

        var effectiveSelectedModel: String? {
            switch (selectedModel, settings?.selectedModel) {
            case let (direct?, nested?) where direct == nested:
                direct
            case let (direct?, nil):
                direct
            case let (nil, nested?):
                nested
            default:
                nil
            }
        }
    }

    private struct ResolvedModel {
        let url: URL
        let modelID: String
        let revision: String
        let size: Int64
    }

    static func discover(fileManager: FileManager = .default) -> HandySpeechModelSnapshot {
        discover(
            settingsURL: defaultSettingsURL(fileManager: fileManager),
            hubRoot: defaultHubRoot(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    static func discover(
        settingsURL: URL,
        hubRoot: URL,
        fileManager: FileManager = .default
    ) -> HandySpeechModelSnapshot {
        guard let values = try? settingsURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= maximumSettingsBytes,
              let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(SettingsEnvelope.self, from: data),
              let selectedModel = settings.effectiveSelectedModel,
              selectedModel.lowercased().contains("whisper"),
              let resolved = resolve(
                  modelID: selectedModel,
                  hubRoot: hubRoot,
                  fileManager: fileManager
              )
        else { return .unavailable }

        let identity = identitySHA256(for: resolved)
        return HandySpeechModelSnapshot(
            state: .ready,
            backend: HandySpeechBackendReference(
                modelID: resolved.modelID,
                displayName: displayName(for: resolved.modelID),
                identitySHA256: identity,
                runtimeRelease: runtimeRelease
            )
        )
    }

    static func resolvedModelURL(
        for reference: HandySpeechBackendReference,
        hubRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        guard reference.runtimeRelease == runtimeRelease,
              reference.identitySHA256.count == 64,
              let resolved = resolve(
                  modelID: reference.modelID,
                  hubRoot: hubRoot ?? defaultHubRoot(fileManager: fileManager),
                  fileManager: fileManager
              ),
              identitySHA256(for: resolved) == reference.identitySHA256 else {
            return nil
        }
        return resolved.url
    }

    static func defaultSettingsURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.pais.handy")
            .appendingPathComponent("settings_store.json")
    }

    static func defaultHubRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    private static func resolve(
        modelID: String,
        hubRoot: URL,
        fileManager: FileManager
    ) -> ResolvedModel? {
        guard modelID.utf8.count <= 512 else { return nil }
        let components = modelID.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components.count >= 3,
              components.allSatisfy(isSafeComponent) else { return nil }

        let repository = "models--\(components[0])--\(components[1])"
        let canonicalHub = hubRoot.standardizedFileURL.resolvingSymlinksInPath()
        let repositoryRoot = hubRoot.appendingPathComponent(repository, isDirectory: true)
        let referenceURL = repositoryRoot.appendingPathComponent("refs/main")
        guard let referenceValues = try? referenceURL.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .fileSizeKey,
              ]),
              referenceValues.isRegularFile == true,
              let referenceSize = referenceValues.fileSize,
              referenceSize > 0,
              referenceSize <= 128,
              let referenceData = try? Data(contentsOf: referenceURL),
              referenceData.count <= 128,
              let rawRevision = String(data: referenceData, encoding: .utf8) else { return nil }
        let revision = rawRevision.trimmingCharacters(in: .whitespacesAndNewlines)
        guard revision.count >= 7,
              revision.count <= 64,
              revision.unicodeScalars.allSatisfy({
                  "0123456789abcdefABCDEF".unicodeScalars.contains($0)
              })
        else { return nil }

        var candidate = repositoryRoot
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
        for component in components.dropFirst(2) {
            candidate.appendPathComponent(component)
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard isContained(resolved, in: canonicalHub),
              let values = try? resolved.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .fileSizeKey,
              ]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              Int64(fileSize) >= minimumModelBytes else { return nil }

        return ResolvedModel(
            url: resolved,
            modelID: modelID,
            revision: revision,
            size: Int64(fileSize)
        )
    }

    private static func identitySHA256(for model: ResolvedModel) -> String {
        let value = "\(model.modelID)\u{0}\(model.revision)\u{0}\(model.size)"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isSafeComponent(_ component: String) -> Bool {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              component.utf8.count <= 255 else { return false }
        return component.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
    }

    private static func isContained(_ child: URL, in parent: URL) -> Bool {
        let root = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return child.path.hasPrefix(root)
    }

    private static func displayName(for modelID: String) -> String {
        let lowercased = modelID.lowercased()
        if lowercased.contains("large-v3-turbo") { return "Whisper Large V3 Turbo (Handy)" }
        return modelID.split(separator: "/").last.map(String.init) ?? "Handy Whisper"
    }
}
