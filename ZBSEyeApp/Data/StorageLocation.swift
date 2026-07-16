import Foundation

enum StorageLocationError: LocalizedError, Equatable {
    case configuredRootUnavailable(String)
    case dataRootMissing(String)

    var errorDescription: String? {
        switch self {
        case .configuredRootUnavailable(let path):
            "Data folder unavailable: \(path). Connect the disk or volume and try again."
        case .dataRootMissing(let path):
            "Data folder not initialized: \(path). Open ZBS Eye once and try again."
        }
    }
}

/// Single source of the ZBS Eye data path for ALL processes (GUI, --mcp, --import-history,
/// --backup-now) and all modules. Previously the path was derived INDEPENDENTLY in 6 places — relocate
/// would have been impossible (helper processes would read the old location). Now relocate changes ONLY
/// UserDefaults, and on the next start all processes read the new root.
///
/// Non-sandboxed app: a security-scoped bookmark is not required (full access to $HOME), but a regular
/// bookmark survives renaming/remounting of the volume (an external SSD under a different /Volumes/...),
/// which a bare path cannot do. So we store both the bookmark and the path — the bookmark wins.
enum StorageLocation {
    static let bookmarkKey = "zbseye.dataRoot.bookmark"
    static let pathKey = "zbseye.dataRoot.path"

    /// Data root. Priority: bookmark → path → legacy ~/Library/Application Support/ZBS Eye.
    static func dataRoot() -> URL {
        let url = resolveConfiguredRoot() ?? legacyRoot()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Headless modes do not have AppEnvironment's startup guard. They must
    /// call this before resolving any DB/media path so an unplugged configured
    /// volume can never redirect work into a newly created legacy root.
    static func requireAvailableDataRoot() throws -> URL {
        let root = try resolveHeadlessRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Read-only helpers must never initialize a new root as a side effect of
    /// checking whether memory is available.
    static func requireExistingDataRoot() throws -> URL {
        let root = try resolveHeadlessRoot()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw StorageLocationError.dataRootMissing(root.path)
        }
        return root
    }

    /// Resolve configured state and the selected root from one defaults
    /// snapshot. Headless helpers must never perform a second resolution that
    /// could turn a disappeared configured volume into a legacy fallback.
    static func resolveHeadlessRoot(
        defaults: UserDefaults = .standard,
        legacy: URL? = nil
    ) throws -> URL {
        let bookmark = defaults.data(forKey: bookmarkKey)
        let path = defaults.string(forKey: pathKey)
        let configured = bookmark != nil || path != nil
        if let root = resolveConfiguredRoot(
            bookmarkData: bookmark,
            configuredPath: path,
            refreshingStaleBookmarkIn: defaults
        ) {
            return root
        }
        if configured {
            throw StorageLocationError.configuredRootUnavailable(
                path ?? "(external volume)"
            )
        }
        return legacy ?? legacyRoot()
    }

    static func validateConfiguredRootAvailability(_ unavailablePath: String?) throws {
        if let unavailablePath {
            throw StorageLocationError.configuredRootUnavailable(unavailablePath)
        }
    }

    static func databaseURL() -> URL { dataRoot().appendingPathComponent("zbseye.sqlite") }

    static func databaseURL(under dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("zbseye.sqlite")
    }

    static func mediaDirectory() -> URL {
        let dir = dataRoot().appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func mediaDirectory(under dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("media", isDirectory: true)
    }

    static func portURL() -> URL { dataRoot().appendingPathComponent("port") }
    static func portURL(under dataRoot: URL) -> URL { dataRoot.appendingPathComponent("port") }
    static func serverLogURL() -> URL { dataRoot().appendingPathComponent("server.log") }

    /// Generative assets remain below the same relocatable root as the DB and
    /// media, but outside both the SQLite-only backup and the bundled e5 model.
    /// Model services should receive a root pinned after the anti-split-brain
    /// startup guard and use the `under:` overloads for their entire lifetime.
    static func builtInModelRoot(under resolvedDataRoot: URL) -> URL {
        resolvedDataRoot
            .appendingPathComponent("ai", isDirectory: true)
            .appendingPathComponent("generative", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    /// Optional speech assets are independent from the generative provider
    /// model but relocate with the same authoritative data root.
    static func speechModelRoot(under resolvedDataRoot: URL) -> URL {
        resolvedDataRoot
            .appendingPathComponent("ai", isDirectory: true)
            .appendingPathComponent("speech", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    static func callEvidenceRoot(under resolvedDataRoot: URL) -> URL {
        resolvedDataRoot
            .appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent("calls", isDirectory: true)
    }

    static func callHelperRoot(under resolvedDataRoot: URL) -> URL {
        resolvedDataRoot
            .appendingPathComponent("call-helper", isDirectory: true)
    }

    /// Default (legacy) location — the same one that was hardcoded before relocate.
    static func legacyRoot() -> URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("ZBS Eye", isDirectory: true)
    }

    /// Whether a NON-default root is configured (for the "move back" UI).
    static func isRelocated() -> Bool {
        resolveConfiguredRoot() != nil
    }

    /// ANTI-SPLIT-BRAIN: relocate was configured, but the target volume is currently unavailable (external SSD unplugged).
    /// Returns the configured path — bootstrap on it REFUSES to start on legacy "from scratch"
    /// (otherwise the user would see an empty history, while new frames would land in a split). nil = all good.
    static func unavailableConfiguredPath() -> String? {
        let d = UserDefaults.standard
        let bookmark = d.data(forKey: bookmarkKey)
        let path = d.string(forKey: pathKey)
        let configured = bookmark != nil || path != nil
        guard configured,
              resolveConfiguredRoot(
                  bookmarkData: bookmark,
                  configuredPath: path,
                  refreshingStaleBookmarkIn: d
              ) == nil else { return nil }
        return path ?? "(external volume)"
    }

    /// Save the new root (AFTER a successful migration). Writes bookmark + path.
    static func setRoot(_ url: URL) {
        let d = UserDefaults.standard
        if let data = try? url.bookmarkData() { d.set(data, forKey: bookmarkKey) }
        d.set(url.path, forKey: pathKey)
    }

    /// Reset to legacy (move back into Application Support).
    static func resetToLegacy() {
        let d = UserDefaults.standard
        d.removeObject(forKey: bookmarkKey)
        d.removeObject(forKey: pathKey)
    }

    /// Human-readable path of the current root (for Settings).
    static func displayPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = dataRoot().path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private static func resolveConfiguredRoot() -> URL? {
        let d = UserDefaults.standard
        return resolveConfiguredRoot(
            bookmarkData: d.data(forKey: bookmarkKey),
            configuredPath: d.string(forKey: pathKey),
            refreshingStaleBookmarkIn: d
        )
    }

    private static func resolveConfiguredRoot(
        bookmarkData: Data?,
        configuredPath: String?,
        refreshingStaleBookmarkIn defaults: UserDefaults
    ) -> URL? {
        if let data = bookmarkData {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                if stale, let fresh = try? url.bookmarkData() {
                    defaults.set(fresh, forKey: bookmarkKey)
                }
                return url
            }
        }
        if let path = configuredPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil   // bookmark/path are set, but unavailable (volume unplugged) → do NOT silently fall back to legacy: see dataRoot fallback
    }
}
