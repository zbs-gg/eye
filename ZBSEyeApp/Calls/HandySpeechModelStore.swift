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

/// Discovers an already-installed Handy speech model without copying it into Eye's storage.
/// Discovery is explicit and local: Handy's documented headless model-list command returns only
/// catalog metadata, never recordings or transcript text.
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
    static let maximumCatalogBytes = 2 * 1_024 * 1_024
    static let maximumProbeSeconds: TimeInterval = 20

    struct ModelInfo: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let isDownloaded: Bool
        let engineType: String

        enum CodingKeys: String, CodingKey {
            case id, name
            case isDownloaded = "is_downloaded"
            case engineType = "engine_type"
        }
    }

    static func discover(fileManager: FileManager = .default) -> HandySpeechModelSnapshot {
        guard let executable = executableURL(fileManager: fileManager),
              let appBundle = Bundle(url: executable
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()),
              appBundle.bundleIdentifier == bundleIdentifier,
              let version = appBundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              let data = modelCatalog(executable: executable, fileManager: fileManager),
              let models = try? JSONDecoder().decode([ModelInfo].self, from: data),
              let selected = preferredDownloadedModel(models)
        else { return .unavailable }

        let identity = SHA256.hash(data: Data(selected.id.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return HandySpeechModelSnapshot(
            state: .ready,
            backend: HandySpeechBackendReference(
                modelID: selected.id,
                displayName: selected.name,
                identitySHA256: identity,
                runtimeRelease: "handy-\(version)/transcribe-cpp"
            )
        )
    }

    static func executableURL(fileManager: FileManager = .default) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/Handy.app/Contents/MacOS/handy"),
            home.appendingPathComponent("Applications/Handy.app/Contents/MacOS/handy"),
        ]
        return candidates.first { candidate in
            fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    static func preferredDownloadedModel(_ models: [ModelInfo]) -> ModelInfo? {
        let compatible = models.filter {
            $0.isDownloaded
                && $0.engineType == "TranscribeCpp"
                && $0.id.lowercased().contains("whisper")
        }
        return compatible.sorted { lhs, rhs in
            (rank(lhs), lhs.id) < (rank(rhs), rhs.id)
        }.first
    }

    private static func rank(_ model: ModelInfo) -> Int {
        let id = model.id.lowercased()
        if id.contains("large-v3-turbo") && id.contains("q8") { return 0 }
        if id.contains("large-v3-turbo") { return 1 }
        return 2
    }

    private static func modelCatalog(
        executable: URL,
        fileManager: FileManager
    ) -> Data? {
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("zbs-eye-handy-models-\(UUID().uuidString).json")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ),
        let output = try? FileHandle(forWritingTo: temporary) else { return nil }
        defer {
            try? output.close()
            try? fileManager.removeItem(at: temporary)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--list-models", "--json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        if exited.wait(timeout: .now() + maximumProbeSeconds) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            return nil
        }
        guard process.terminationStatus == 0,
              let size = try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0,
              size <= maximumCatalogBytes else { return nil }
        try? output.synchronize()
        return try? Data(contentsOf: temporary)
    }
}
