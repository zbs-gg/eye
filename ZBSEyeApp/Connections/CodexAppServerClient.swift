import CryptoKit
import Darwin
import Dispatch
import Foundation
import Security

enum CodexAppServerError: Error, Sendable, Hashable {
    case executableMissing
    case unavailable
    case untrustedBinary
    case capabilityMismatch
    case notAuthenticatedWithChatGPT
    case selectedModelUnavailable
    case protocolViolation
    case forbiddenEvent
    case outputLimitExceeded
    case invalidOutput
    case unexpectedStateFile
    case staleSelection
    case timedOut
    case cancelled
    case transportUnavailable

    var poisonsClient: Bool {
        switch self {
        case .untrustedBinary, .capabilityMismatch, .protocolViolation,
                .forbiddenEvent, .outputLimitExceeded, .invalidOutput,
                .unexpectedStateFile, .transportUnavailable:
            return true
        case .executableMissing, .unavailable, .notAuthenticatedWithChatGPT,
                .selectedModelUnavailable, .staleSelection, .timedOut, .cancelled:
            return false
        }
    }
}

// MARK: - Exact executable identity

enum CodexBinaryFormat: String, Sendable, Equatable {
    case machOArm64
    case machOX86_64
    case javaScript
    case other
}

struct CodexFileIdentity: Sendable, Equatable {
    let deviceID: UInt64
    let fileID: UInt64
    let byteCount: Int64
    let mode: mode_t
    let ownerUID: uid_t
    let linkCount: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    static func capture(at url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.standardizedFileURL.path, &info) == 0 else {
            throw CodexAppServerError.untrustedBinary
        }
        return Self(
            deviceID: UInt64(bitPattern: Int64(info.st_dev)),
            fileID: UInt64(info.st_ino),
            byteCount: Int64(info.st_size),
            mode: info.st_mode,
            ownerUID: info.st_uid,
            linkCount: UInt64(info.st_nlink),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }
}

struct CodexBinaryInspection: Sendable, Equatable {
    let url: URL
    let fileIdentity: CodexFileIdentity
    let format: CodexBinaryFormat
    let isSymlink: Bool
    let isRegularFile: Bool
    let linkCount: UInt64
    let ownerUID: uid_t
    let mode: mode_t
    let packageLayoutIsCanonical: Bool
    let version: String
    let sha256: String
    let teamIdentifier: String
    let signingAuthority: String
}

enum CodexBinaryPolicy {
    static let allowedVersion = "0.136.0"
    static let allowedSHA256 = "2c056bf3bd3a0ba04cdaa6d1db84c81974e6785f5fd72deaa2a3fcdcfb573d10"
    static let allowedTeamIdentifier = "2DC432GLL2"
    static let allowedSigningAuthority = "Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)"

    static func validate(
        _ inspection: CodexBinaryInspection,
        currentUID: uid_t = getuid()
    ) throws {
        let normalizedVersion = inspection.version
            .replacingOccurrences(of: "-darwin-arm64", with: "")
        guard inspection.format == .machOArm64,
              !inspection.isSymlink,
              inspection.isRegularFile,
              inspection.linkCount == 1,
              inspection.ownerUID == currentUID || inspection.ownerUID == 0,
              inspection.fileIdentity.linkCount == inspection.linkCount,
              inspection.fileIdentity.ownerUID == inspection.ownerUID,
              inspection.fileIdentity.mode == inspection.mode,
              inspection.mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              inspection.mode & mode_t(S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0,
              inspection.mode & mode_t(S_IXUSR) != 0,
              inspection.packageLayoutIsCanonical,
              normalizedVersion == allowedVersion,
              inspection.sha256 == allowedSHA256,
              inspection.teamIdentifier == allowedTeamIdentifier,
              inspection.signingAuthority == allowedSigningAuthority else {
            throw CodexAppServerError.untrustedBinary
        }
    }
}

enum CodexNativeBinaryLocator {
    private static let nativeRelativeComponents = [
        "node_modules", "@openai", "codex-darwin-arm64", "vendor",
        "aarch64-apple-darwin", "bin", "codex",
    ]
    private static let nativeSuffix = nativeRelativeComponents.joined(separator: "/")

    static func nativeCandidate(fromCanonicalLauncher launcher: URL) -> URL? {
        let standardized = launcher.standardizedFileURL
        if standardized.path.hasSuffix("/\(nativeSuffix)") {
            return standardized
        }
        guard standardized.lastPathComponent == "codex.js",
              standardized.deletingLastPathComponent().lastPathComponent == "bin",
              standardized.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent == "codex" else {
            return nil
        }
        let packageRoot = standardized.deletingLastPathComponent()
            .deletingLastPathComponent()
        return packageRoot.appending(path: nativeSuffix).standardizedFileURL
    }

    static func packageRoot(fromNativeCandidate candidate: URL) -> URL? {
        var cursor = candidate.standardizedFileURL
        for expectedComponent in nativeRelativeComponents.reversed() {
            guard cursor.lastPathComponent == expectedComponent else { return nil }
            cursor.deleteLastPathComponent()
        }
        guard cursor.lastPathComponent == "codex",
              cursor.deletingLastPathComponent().lastPathComponent == "@openai" else {
            return nil
        }
        return cursor.standardizedFileURL
    }
}

struct CodexVerifiedExecutable: Sendable, Equatable {
    let trustedInspection: CodexBinaryInspection

    var url: URL { trustedInspection.url }
    var version: String {
        trustedInspection.version.replacingOccurrences(
            of: "-darwin-arm64",
            with: ""
        )
    }
}

protocol CodexExecutableResolving: Sendable {
    func resolve() async throws -> CodexVerifiedExecutable
}

protocol CodexExecutableVerifying: Sendable {
    func revalidate(
        _ executable: CodexVerifiedExecutable
    ) async throws -> CodexVerifiedExecutable
}

struct CodexResolverBackedExecutableVerifier: CodexExecutableVerifying {
    let resolver: any CodexExecutableResolving

    func revalidate(
        _ executable: CodexVerifiedExecutable
    ) async throws -> CodexVerifiedExecutable {
        do {
            try Task.checkCancellation()
            let current = try await resolver.resolve()
            try Task.checkCancellation()
            guard current == executable else {
                throw CodexAppServerError.untrustedBinary
            }
            return current
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerError.untrustedBinary
        }
    }
}

struct CodexSystemExecutableVerifier: CodexExecutableVerifying {
    let inspector: any CodexBinaryInspecting

    init(inspector: any CodexBinaryInspecting = CodexSystemBinaryInspector()) {
        self.inspector = inspector
    }

    func revalidate(
        _ executable: CodexVerifiedExecutable
    ) async throws -> CodexVerifiedExecutable {
        do {
            try Task.checkCancellation()
            let inspection = try await inspector.inspect(executable.url)
            try CodexBinaryPolicy.validate(inspection)
            let current = CodexVerifiedExecutable(trustedInspection: inspection)
            guard current == executable else {
                throw CodexAppServerError.untrustedBinary
            }
            try Task.checkCancellation()
            return current
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CodexAppServerError.untrustedBinary
        }
    }
}

protocol CodexBinaryInspecting: Sendable {
    func inspect(_ url: URL) async throws -> CodexBinaryInspection
}

struct CodexSystemExecutableResolver: CodexExecutableResolving {
    let launcherURLs: [URL]
    let inspector: any CodexBinaryInspecting
    private let launcherExists: @Sendable (URL) -> Bool

    static func defaultLauncherURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            homeDirectory.appending(path: ".local/bin/codex"),
            homeDirectory.appending(path: ".npm-global/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
        ]
    }

    init(
        launcherURLs: [URL]? = nil,
        inspector: any CodexBinaryInspecting = CodexSystemBinaryInspector(),
        launcherExists: @escaping @Sendable (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        }
    ) {
        self.launcherURLs = launcherURLs ?? Self.defaultLauncherURLs()
        self.inspector = inspector
        self.launcherExists = launcherExists
    }

    func resolve() async throws -> CodexVerifiedExecutable {
        var foundInstalledLauncher = false
        for launcher in launcherURLs {
            guard launcherExists(launcher) else { continue }
            foundInstalledLauncher = true
            let canonicalLauncher = launcher.resolvingSymlinksInPath().standardizedFileURL
            guard let candidate = CodexNativeBinaryLocator.nativeCandidate(
                fromCanonicalLauncher: canonicalLauncher
            ) else { continue }
            do {
                let inspection = try await inspector.inspect(candidate)
                try CodexBinaryPolicy.validate(inspection)
                return CodexVerifiedExecutable(trustedInspection: inspection)
            } catch {
                continue
            }
        }
        guard foundInstalledLauncher else {
            throw CodexAppServerError.executableMissing
        }
        throw CodexAppServerError.untrustedBinary
    }
}

struct CodexSystemBinaryInspector: CodexBinaryInspecting {
    func inspect(_ url: URL) async throws -> CodexBinaryInspection {
        let standardized = url.standardizedFileURL
        let before = try CodexFileIdentity.capture(at: standardized)
        let isSymlink = before.mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
        let isRegular = before.mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        guard !isSymlink, isRegular else {
            throw CodexAppServerError.untrustedBinary
        }

        let format = try binaryFormat(at: standardized)
        guard let packageRoot = CodexNativeBinaryLocator.packageRoot(
            fromNativeCandidate: standardized
        ) else {
            throw CodexAppServerError.untrustedBinary
        }
        let canonicalSuffix = "/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
        let layoutIsCanonical = standardized.path.hasSuffix(canonicalSuffix)
            && safePackageTree(from: packageRoot, through: standardized)
        let version = try packageVersion(at: packageRoot)
        let sha256 = try streamedSHA256(at: standardized)
        let signature = try signingIdentity(at: standardized)
        let after = try CodexFileIdentity.capture(at: standardized)
        guard after == before else {
            throw CodexAppServerError.untrustedBinary
        }

        return CodexBinaryInspection(
            url: standardized,
            fileIdentity: before,
            format: format,
            isSymlink: isSymlink,
            isRegularFile: isRegular,
            linkCount: before.linkCount,
            ownerUID: before.ownerUID,
            mode: before.mode,
            packageLayoutIsCanonical: layoutIsCanonical,
            version: version,
            sha256: sha256,
            teamIdentifier: signature.team,
            signingAuthority: signature.authority
        )
    }

    private func binaryFormat(at url: URL) throws -> CodexBinaryFormat {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 8) ?? Data()
        guard header.count == 8 else { return .other }
        let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let cpu = header.dropFirst(4).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
        guard magic == UInt32(MH_MAGIC_64) else {
            if header.starts(with: Data("#!/usr/bin/env node".utf8).prefix(8)) {
                return .javaScript
            }
            return .other
        }
        if cpu == UInt32(bitPattern: CPU_TYPE_ARM64) { return .machOArm64 }
        if cpu == UInt32(bitPattern: CPU_TYPE_X86_64) { return .machOX86_64 }
        return .other
    }

    private func packageVersion(at root: URL) throws -> String {
        let data = try Data(contentsOf: root.appending(path: "package.json"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["name"] as? String == "@openai/codex",
              let version = object["version"] as? String else {
            throw CodexAppServerError.untrustedBinary
        }
        return version
    }

    private func streamedSHA256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func safePackageTree(from root: URL, through file: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        var current = file.standardizedFileURL
        while current.path.hasPrefix(rootPath) {
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK),
                  (info.st_uid == getuid() || info.st_uid == 0),
                  info.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
                return false
            }
            if current.path == rootPath { return true }
            current.deleteLastPathComponent()
        }
        return false
    }

    private func signingIdentity(at url: URL) throws -> (team: String, authority: String) {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw CodexAppServerError.untrustedBinary
        }
        let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(staticCode, validationFlags, nil) == errSecSuccess else {
            throw CodexAppServerError.untrustedBinary
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let dictionary = information as? [String: Any],
            let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first else {
            throw CodexAppServerError.untrustedBinary
        }
        var commonName: CFString?
        guard SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess,
              let authority = commonName as String? else {
            throw CodexAppServerError.untrustedBinary
        }
        return (team, authority)
    }
}

// MARK: - Isolated CODEX_HOME

struct CodexPreparedHome: Sendable, Equatable {
    let leaseID: UUID
    let homeURL: URL
    let configURL: URL
    let workingDirectoryURL: URL
    let temporaryDirectoryURL: URL
}

enum CodexHomeAuditPhase: Sendable, Equatable {
    case beforeLaunch
    case afterMessage
    case beforeDestroy
}

protocol CodexHomeManaging: Sendable {
    func prepareSession() async throws -> CodexPreparedHome
    func audit(_ home: CodexPreparedHome, phase: CodexHomeAuditPhase) async throws
    func destroy(_ home: CodexPreparedHome) async
}

actor CodexSystemHomeManager: CodexHomeManaging {
    let rootURL: URL
    private var activeSessionID: UUID?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    static let minimalConfig = """
    approval_policy = "never"
    sandbox_mode = "read-only"
    web_search = "disabled"
    forced_login_method = "chatgpt"
    cli_auth_credentials_store = "keyring"
    mcp_oauth_credentials_store = "keyring"
    check_for_update_on_startup = false
    include_apps_instructions = false
    include_collaboration_mode_instructions = false
    include_environment_context = false
    include_permissions_instructions = false

    [history]
    persistence = "none"

    [analytics]
    enabled = false

    [apps._default]
    enabled = false
    destructive_enabled = false
    open_world_enabled = false

    [features]
    apps = false
    browser_use = false
    browser_use_external = false
    computer_use = false
    enable_mcp_apps = false
    goals = false
    guardian_approval = false
    hooks = false
    image_generation = false
    in_app_browser = false
    memories = false
    multi_agent = false
    plugins = false
    request_permissions_tool = false
    shell_snapshot = false
    shell_tool = false
    skill_mcp_dependency_install = false
    tool_suggest = false
    unified_exec = false
    workspace_dependencies = false
    """

    func prepareSession() async throws -> CodexPreparedHome {
        guard activeSessionID == nil else {
            throw CodexAppServerError.unavailable
        }
        try makePrivateDirectory(rootURL)
        // Codex hashes the canonical CODEX_HOME path into its Keychain account.
        // Keep that identity stable across login, probe, and generation while
        // deleting every file-backed session artifact between processes.
        let session = rootURL.appending(path: "session")
        if FileManager.default.fileExists(atPath: session.path) {
            try FileManager.default.removeItem(at: session)
        }
        let work = session.appending(path: "work")
        let temporary = session.appending(path: "tmp")
        let leaseID = UUID()
        do {
            try makePrivateDirectory(session)
            try makePrivateDirectory(work)
            try makePrivateDirectory(temporary)
            let config = session.appending(path: "config.toml")
            try Data(Self.minimalConfig.utf8).write(to: config, options: [.atomic])
            guard chmod(config.path, S_IRUSR | S_IWUSR) == 0 else {
                throw CodexAppServerError.unexpectedStateFile
            }
            let prepared = CodexPreparedHome(
                leaseID: leaseID,
                homeURL: session,
                configURL: config,
                workingDirectoryURL: work,
                temporaryDirectoryURL: temporary
            )
            activeSessionID = leaseID
            try await audit(prepared, phase: .beforeLaunch)
            return prepared
        } catch {
            activeSessionID = nil
            try? FileManager.default.removeItem(at: session)
            throw error
        }
    }

    func audit(_ home: CodexPreparedHome, phase: CodexHomeAuditPhase) async throws {
        guard activeSessionID == home.leaseID else {
            throw CodexAppServerError.unavailable
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: home.homeURL,
            includingPropertiesForKeys: nil
        )
        for entry in entries {
            let name = entry.lastPathComponent
            switch name {
            case "config.toml", "work", "tmp":
                break
            case "installation_id", ".personality_migration", "models_cache.json":
                try validatePrivateRegularFile(entry, maximumBytes: 2_097_152)
            case "skills":
                guard phase != .beforeLaunch else {
                    throw CodexAppServerError.unexpectedStateFile
                }
                try validateGeneratedSystemSkills(at: entry)
                try FileManager.default.removeItem(at: entry)
            default:
                guard isKnownEphemeralDatabaseName(name) else {
                    throw CodexAppServerError.unexpectedStateFile
                }
                try validatePrivateRegularFile(entry, maximumBytes: 33_554_432)
            }
        }
        guard try Data(contentsOf: home.configURL) == Data(Self.minimalConfig.utf8),
              !FileManager.default.fileExists(
                  atPath: home.homeURL.appending(path: "auth.json").path
              ) else {
                throw CodexAppServerError.unexpectedStateFile
        }
        try validatePrivateDirectory(home.homeURL)
        try validatePrivateDirectory(home.workingDirectoryURL, mustBeEmpty: true)
        try validateTemporaryDirectory(home.temporaryDirectoryURL, phase: phase)
    }

    func destroy(_ home: CodexPreparedHome) async {
        guard activeSessionID == home.leaseID else { return }
        try? FileManager.default.removeItem(at: home.homeURL)
        activeSessionID = nil
    }

    private func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw CodexAppServerError.unexpectedStateFile
        }
    }

    private func validatePrivateDirectory(
        _ url: URL,
        mustBeEmpty: Bool = false
    ) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_mode & 0o077 == 0,
              info.st_uid == getuid() else {
            throw CodexAppServerError.unexpectedStateFile
        }
        if mustBeEmpty {
            guard try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty else {
                throw CodexAppServerError.unexpectedStateFile
            }
        }
    }

    private func validateTemporaryDirectory(
        _ url: URL,
        phase: CodexHomeAuditPhase
    ) throws {
        try validatePrivateDirectory(url)
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
        guard entries.count <= 1 else {
            throw CodexAppServerError.unexpectedStateFile
        }
        if let entry = entries.first {
            guard phase != .beforeLaunch,
                  entry.lastPathComponent == "arg0" else {
                throw CodexAppServerError.unexpectedStateFile
            }
            try validatePrivateDirectory(entry)
            let generated = try FileManager.default.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: nil
            )
            guard generated.count <= 1 else {
                throw CodexAppServerError.unexpectedStateFile
            }
            if let generatedDirectory = generated.first {
                let name = generatedDirectory.lastPathComponent
                guard name.hasPrefix("codex-arg0"),
                      name.count == "codex-arg0".count + 6 else {
                    throw CodexAppServerError.unexpectedStateFile
                }
                try validateOwnedReadOnlyDirectory(generatedDirectory)
                let generatedEntries = try FileManager.default.contentsOfDirectory(
                    at: generatedDirectory,
                    includingPropertiesForKeys: nil
                )
                let expectedNames: Set<String> = [
                    ".lock", "applypatch", "apply_patch", "codex-execve-wrapper",
                ]
                guard Set(generatedEntries.map(\.lastPathComponent)) == expectedNames else {
                    throw CodexAppServerError.unexpectedStateFile
                }
                for generatedEntry in generatedEntries {
                    var info = stat()
                    guard lstat(generatedEntry.path, &info) == 0,
                          info.st_uid == getuid(),
                          info.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
                        throw CodexAppServerError.unexpectedStateFile
                    }
                    if generatedEntry.lastPathComponent == ".lock" {
                        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                              info.st_size == 0 else {
                            throw CodexAppServerError.unexpectedStateFile
                        }
                    } else {
                        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                              info.st_size <= 512 else {
                            throw CodexAppServerError.unexpectedStateFile
                        }
                    }
                }
                try FileManager.default.removeItem(at: generatedDirectory)
            }
        }
    }

    private func validatePrivateRegularFile(
        _ url: URL,
        maximumBytes: Int64
    ) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & mode_t(S_IWGRP | S_IWOTH | S_IXUSR | S_IXGRP | S_IXOTH) == 0,
              info.st_uid == getuid(),
              info.st_size >= 0,
              info.st_size <= maximumBytes else {
            throw CodexAppServerError.unexpectedStateFile
        }
    }

    private func isKnownEphemeralDatabaseName(_ name: String) -> Bool {
        let bases = ["state_5.sqlite", "logs_2.sqlite", "memories_1.sqlite", "goals_1.sqlite"]
        return bases.contains { base in
            name == base || name == "\(base)-wal" || name == "\(base)-shm"
        }
    }

    private func validateGeneratedSystemSkills(at skillsURL: URL) throws {
        try validateOwnedReadOnlyDirectory(skillsURL)
        let system = skillsURL.appending(path: ".system")
        try validateOwnedReadOnlyDirectory(system)
        let topLevel = try FileManager.default.contentsOfDirectory(
            at: skillsURL,
            includingPropertiesForKeys: nil
        )
        guard topLevel.map(\.lastPathComponent) == [".system"] else {
            throw CodexAppServerError.unexpectedStateFile
        }
        let expectedSystemEntries: Set<String> = [
            ".codex-system-skills.marker", "imagegen", "openai-docs",
            "plugin-creator", "skill-creator", "skill-installer",
        ]
        let systemEntries = try FileManager.default.contentsOfDirectory(
            at: system,
            includingPropertiesForKeys: nil
        )
        guard Set(systemEntries.map(\.lastPathComponent)) == expectedSystemEntries else {
            throw CodexAppServerError.unexpectedStateFile
        }

        let rootPath = skillsURL.standardizedFileURL.path + "/"
        let enumerator = FileManager.default.enumerator(
            at: skillsURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false }
        )
        var totalBytes: Int64 = 0
        while let entry = enumerator?.nextObject() as? URL {
            guard entry.standardizedFileURL.path.hasPrefix(rootPath) else {
                throw CodexAppServerError.unexpectedStateFile
            }
            var info = stat()
            guard lstat(entry.path, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK),
                  info.st_uid == getuid(),
                  info.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0 else {
                throw CodexAppServerError.unexpectedStateFile
            }
            if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) {
                totalBytes += info.st_size
                guard totalBytes <= 2_097_152 else {
                    throw CodexAppServerError.unexpectedStateFile
                }
            } else if info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR) {
                throw CodexAppServerError.unexpectedStateFile
            }
        }
    }

    private func validateOwnedReadOnlyDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0,
              info.st_uid == getuid() else {
            throw CodexAppServerError.unexpectedStateFile
        }
    }
}

// MARK: - Injected process boundary

struct CodexLaunchSpecification: Sendable, Equatable {
    let executableURL: URL
    let trustedExecutable: CodexVerifiedExecutable?
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL
    let createsDedicatedProcessGroup: Bool
    let usesLoginShell: Bool
    let maximumStdoutBytes: Int
    let maximumStderrBytes: Int

    init(
        executableURL: URL,
        trustedExecutable: CodexVerifiedExecutable? = nil,
        arguments: [String],
        environment: [String: String],
        workingDirectoryURL: URL,
        createsDedicatedProcessGroup: Bool,
        usesLoginShell: Bool,
        maximumStdoutBytes: Int,
        maximumStderrBytes: Int
    ) {
        self.executableURL = executableURL
        self.trustedExecutable = trustedExecutable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.createsDedicatedProcessGroup = createsDedicatedProcessGroup
        self.usesLoginShell = usesLoginShell
        self.maximumStdoutBytes = maximumStdoutBytes
        self.maximumStderrBytes = maximumStderrBytes
    }
}

struct CodexProcessFrame: Sendable, Equatable {
    let stdoutLine: Data
    let totalStdoutBytes: Int
    let totalStderrBytes: Int
}

protocol CodexAppServerConnection: Sendable {
    func send(_ line: Data, promptAdmission: CodexPromptAdmission?) async throws
    func receive(maximumLineBytes: Int, timeout: Duration) async throws -> CodexProcessFrame
    func terminateProcessGroup(gracePeriod: Duration) async
}

struct CodexPromptAdmission: Sendable {
    let snapshotProvider: any LLMSelectionSnapshotProviding
    let selection: ProviderSelectionSnapshot
    let consumer: AIConsumer
    private let state = CodexPromptAdmissionState()

    init(
        snapshotProvider: any LLMSelectionSnapshotProviding,
        selection: ProviderSelectionSnapshot,
        consumer: AIConsumer
    ) {
        self.snapshotProvider = snapshotProvider
        self.selection = selection
        self.consumer = consumer
    }

    func cancel() { state.cancel() }

    func checkCancellation() throws { try state.checkCancellation() }

    func validate() async throws {
        try state.checkCancellation()
        guard await snapshotProvider.currentSnapshot(for: consumer) == selection else {
            throw CodexAppServerError.staleSelection
        }
        try state.checkCancellation()
    }
}

private final class CodexPromptAdmissionState: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let cancelled = isCancelled
        lock.unlock()
        if cancelled { throw CancellationError() }
    }
}

protocol CodexAppServerProcessTransport: Sendable {
    func open(_ specification: CodexLaunchSpecification) async throws -> any CodexAppServerConnection
}

struct CodexPOSIXProcessTransport: CodexAppServerProcessTransport {
    let executableVerifier: any CodexExecutableVerifying

    init(
        executableVerifier: any CodexExecutableVerifying = CodexSystemExecutableVerifier()
    ) {
        self.executableVerifier = executableVerifier
    }

    func open(
        _ specification: CodexLaunchSpecification
    ) async throws -> any CodexAppServerConnection {
        guard specification.createsDedicatedProcessGroup,
              !specification.usesLoginShell,
              specification.executableURL.isFileURL,
              specification.arguments.allSatisfy({ !$0.contains("\0") }),
              specification.environment.allSatisfy({ key, value in
                  !key.isEmpty && !key.contains("=") && !key.contains("\0")
                    && !value.contains("\0")
              }) else {
            throw CodexAppServerError.transportUnavailable
        }
        guard let trustedExecutable = specification.trustedExecutable,
              trustedExecutable.url == specification.executableURL else {
            throw CodexAppServerError.untrustedBinary
        }
        let currentExecutable = try await executableVerifier.revalidate(trustedExecutable)
        guard currentExecutable == trustedExecutable,
              currentExecutable.url == specification.executableURL else {
            throw CodexAppServerError.untrustedBinary
        }
        try Task.checkCancellation()
        // macOS exposes no fd-bound exec here; keep the remaining pathname
        // window to the synchronous lstat immediately adjacent to posix_spawn.
        let finalIdentity = try CodexFileIdentity.capture(at: currentExecutable.url)
        guard finalIdentity == currentExecutable.trustedInspection.fileIdentity else {
            throw CodexAppServerError.untrustedBinary
        }
        let spawned = try CodexPOSIXSpawner.spawn(specification)
        let connection = CodexPOSIXConnection(
            processIdentifier: spawned.processIdentifier,
            stdinFileDescriptor: spawned.stdinFileDescriptor,
            stdoutFileDescriptor: spawned.stdoutFileDescriptor,
            stderrFileDescriptor: spawned.stderrFileDescriptor,
            maximumStdoutBytes: specification.maximumStdoutBytes,
            maximumStderrBytes: specification.maximumStderrBytes
        )
        await connection.startMonitoring()
        guard getpgid(spawned.processIdentifier) == spawned.processIdentifier else {
            await connection.terminateProcessGroup(gracePeriod: .zero)
            throw CodexAppServerError.transportUnavailable
        }
        return connection
    }
}

struct CodexSpawnedProcess {
    let processIdentifier: pid_t
    let stdinFileDescriptor: Int32
    let stdoutFileDescriptor: Int32
    let stderrFileDescriptor: Int32
}

enum CodexPOSIXSpawner {
    static func spawn(_ specification: CodexLaunchSpecification) throws -> CodexSpawnedProcess {
        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard makePipe(&stdinPipe), makePipe(&stdoutPipe), makePipe(&stderrPipe) else {
            closePipe(stdinPipe)
            closePipe(stdoutPipe)
            closePipe(stderrPipe)
            throw CodexAppServerError.transportUnavailable
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            closePipe(stdinPipe)
            closePipe(stdoutPipe)
            closePipe(stderrPipe)
            throw CodexAppServerError.transportUnavailable
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        let fileActionStatus = specification.workingDirectoryURL.path.withCString { cwd in
            posix_spawn_file_actions_addchdir_np(&actions, cwd)
        }
        guard fileActionStatus == 0,
              posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO) == 0,
              addCloseActions(
                  &actions,
                  descriptors: stdinPipe + stdoutPipe + stderrPipe
              ),
              posix_spawnattr_setflags(
                  &attributes,
                  Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
              ) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            closePipe(stdinPipe)
            closePipe(stdoutPipe)
            closePipe(stderrPipe)
            throw CodexAppServerError.transportUnavailable
        }

        let arguments = [specification.executableURL.path] + specification.arguments
        let environment = specification.environment
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
        var processIdentifier: pid_t = 0
        let status = withMutableCStringArray(arguments) { argv in
            withMutableCStringArray(environment) { envp in
                specification.executableURL.path.withCString { executablePath in
                    posix_spawn(
                        &processIdentifier,
                        executablePath,
                        &actions,
                        &attributes,
                        argv,
                        envp
                    )
                }
            }
        }
        guard status == 0 else {
            closePipe(stdinPipe)
            closePipe(stdoutPipe)
            closePipe(stderrPipe)
            throw CodexAppServerError.transportUnavailable
        }

        Darwin.close(stdinPipe[0])
        Darwin.close(stdoutPipe[1])
        Darwin.close(stderrPipe[1])
        setCloseOnExec(stdinPipe[1])
        setCloseOnExec(stdoutPipe[0])
        setCloseOnExec(stderrPipe[0])
        _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)
        setNonBlocking(stdinPipe[1])
        setNonBlocking(stdoutPipe[0])
        setNonBlocking(stderrPipe[0])
        return CodexSpawnedProcess(
            processIdentifier: processIdentifier,
            stdinFileDescriptor: stdinPipe[1],
            stdoutFileDescriptor: stdoutPipe[0],
            stderrFileDescriptor: stderrPipe[0]
        )
    }

    private static func makePipe(_ descriptors: inout [Int32]) -> Bool {
        descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!) == 0
        }
    }

    private static func closePipe(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }

    private static func addCloseActions(
        _ actions: inout posix_spawn_file_actions_t?,
        descriptors: [Int32]
    ) -> Bool {
        descriptors.allSatisfy {
            posix_spawn_file_actions_addclose(&actions, $0) == 0
        }
    }

    private static func setCloseOnExec(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFD)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) }
    }

    private static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let duplicated: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { duplicated.forEach { free($0) } }
        var pointers = duplicated
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

private final class CodexFrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [CodexProcessFrame] = []
    private var waiters: [UUID: CheckedContinuation<CodexProcessFrame, Error>] = [:]
    private var cancelledWaiters: Set<UUID> = []
    private var terminalError: CodexAppServerError?

    func next() async throws -> CodexProcessFrame {
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var immediate: Result<CodexProcessFrame, Error>?
                lock.withLock {
                    if cancelledWaiters.remove(identifier) != nil {
                        immediate = .failure(CancellationError())
                    } else if let terminalError {
                        immediate = .failure(terminalError)
                    } else if !frames.isEmpty {
                        immediate = .success(frames.removeFirst())
                    } else {
                        waiters[identifier] = continuation
                    }
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            var waiter: CheckedContinuation<CodexProcessFrame, Error>?
            self.lock.withLock {
                waiter = self.waiters.removeValue(forKey: identifier)
                if waiter == nil { self.cancelledWaiters.insert(identifier) }
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func yield(_ frame: CodexProcessFrame) {
        var waiter: CheckedContinuation<CodexProcessFrame, Error>?
        lock.withLock {
            if terminalError == nil, let identifier = waiters.keys.first {
                waiter = waiters.removeValue(forKey: identifier)
            } else if terminalError == nil {
                frames.append(frame)
            }
        }
        waiter?.resume(returning: frame)
    }

    func finish(_ error: CodexAppServerError) {
        var pending: [CheckedContinuation<CodexProcessFrame, Error>] = []
        lock.withLock {
            guard terminalError == nil else { return }
            terminalError = error
            frames.removeAll(keepingCapacity: false)
            pending = Array(waiters.values)
            waiters.removeAll()
        }
        pending.forEach { $0.resume(throwing: error) }
    }
}

private final class CodexProcessCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBytes = 0
    private var stderrBytes = 0

    func addStdout(_ count: Int) -> (stdout: Int, stderr: Int) {
        lock.withLock {
            stdoutBytes += count
            return (stdoutBytes, stderrBytes)
        }
    }

    func addStderr(_ count: Int) -> (stdout: Int, stderr: Int) {
        lock.withLock {
            stderrBytes += count
            return (stdoutBytes, stderrBytes)
        }
    }
}

private final class CodexPipePump: @unchecked Sendable {
    enum StreamKind { case stdout, stderr }

    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let kind: StreamKind
    private let queue: CodexFrameQueue
    private let counters: CodexProcessCounters
    private let maximumStdoutBytes: Int
    private let maximumStderrBytes: Int
    private var lineBuffer = Data()

    init(
        descriptor: Int32,
        kind: StreamKind,
        queue: CodexFrameQueue,
        counters: CodexProcessCounters,
        maximumStdoutBytes: Int,
        maximumStderrBytes: Int
    ) {
        self.descriptor = descriptor
        self.kind = kind
        self.queue = queue
        self.counters = counters
        self.maximumStdoutBytes = maximumStdoutBytes
        self.maximumStderrBytes = maximumStderrBytes
        source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: DispatchQueue(label: "gg.zbs.eye.codex.pipe.\(descriptor)")
        )
        source.setEventHandler { [weak self] in self?.readAvailableBytes() }
        source.setCancelHandler { Darwin.close(descriptor) }
    }

    func start() { source.resume() }
    func cancel() { source.cancel() }

    private func readAvailableBytes() {
        var scratch = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(descriptor, &scratch, scratch.count)
            if count > 0 {
                let data = Data(scratch.prefix(count))
                switch kind {
                case .stdout: consumeStdout(data)
                case .stderr: consumeStderr(data)
                }
                continue
            }
            if count == 0 {
                if kind == .stdout, !lineBuffer.isEmpty {
                    queue.finish(.protocolViolation)
                }
                source.cancel()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            queue.finish(.transportUnavailable)
            source.cancel()
            return
        }
    }

    private func consumeStdout(_ data: Data) {
        let totals = counters.addStdout(data.count)
        guard totals.stdout <= maximumStdoutBytes else {
            queue.finish(.outputLimitExceeded)
            source.cancel()
            return
        }
        lineBuffer.append(data)
        guard lineBuffer.count <= CodexAppServerClient.maximumLineBytes
                || lineBuffer.contains(0x0A) else {
            queue.finish(.outputLimitExceeded)
            source.cancel()
            return
        }
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            var line = Data(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty,
                  line.count <= CodexAppServerClient.maximumLineBytes else {
                queue.finish(.protocolViolation)
                source.cancel()
                return
            }
            queue.yield(
                CodexProcessFrame(
                    stdoutLine: line,
                    totalStdoutBytes: totals.stdout,
                    totalStderrBytes: totals.stderr
                )
            )
        }
        if lineBuffer.count > CodexAppServerClient.maximumLineBytes {
            queue.finish(.outputLimitExceeded)
            source.cancel()
        }
    }

    private func consumeStderr(_ data: Data) {
        let totals = counters.addStderr(data.count)
        if totals.stderr > maximumStderrBytes {
            queue.finish(.outputLimitExceeded)
            source.cancel()
        }
    }
}

private final class CodexPromptValidationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Void, Error>?

    func store(_ result: Result<Void, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func load() -> Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class CodexStdinWriter: @unchecked Sendable {
    private let workQueue = DispatchQueue(label: "gg.zbs.eye.codex.stdin")
    private var descriptor: Int32?

    init(descriptor: Int32) { self.descriptor = descriptor }

    func write(
        _ data: Data,
        promptAdmission: CodexPromptAdmission?
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                workQueue.async {
                    guard let descriptor = self.descriptor else {
                        return continuation.resume(
                            throwing: CodexAppServerError.transportUnavailable
                        )
                    }
                    // The JSON-RPC message is already serialized before it
                    // enters this queue. The dedicated writer thread waits for
                    // the async authority check, then performs no queue hop or
                    // suspension before the first fd byte can leave.
                    if let promptAdmission {
                        let result = CodexPromptValidationResult()
                        let ready = DispatchSemaphore(value: 0)
                        Task {
                            do {
                                try await promptAdmission.validate()
                                result.store(.success(()))
                            } catch {
                                result.store(.failure(error))
                            }
                            ready.signal()
                        }
                        ready.wait()
                        guard let validation = result.load() else {
                            return continuation.resume(
                                throwing: CodexAppServerError.transportUnavailable
                            )
                        }
                        if case .failure(let error) = validation {
                            return continuation.resume(throwing: error)
                        }
                    }
                    let writeResult: Result<Void, Error> = data.withUnsafeBytes { bytes in
                        guard let base = bytes.baseAddress else { return .success(()) }
                        var offset = 0
                        let maximumChunkBytes = 4 * 1_024
                        while offset < bytes.count {
                            do {
                                try promptAdmission?.checkCancellation()
                            } catch {
                                return .failure(error)
                            }
                            let chunkBytes = min(maximumChunkBytes, bytes.count - offset)
                            let count = Darwin.write(
                                descriptor,
                                base.advanced(by: offset),
                                chunkBytes
                            )
                            if count > 0 { offset += count; continue }
                            if count < 0, errno == EINTR { continue }
                            return .failure(CodexAppServerError.transportUnavailable)
                        }
                        return .success(())
                    }
                    continuation.resume(with: writeResult)
                }
            }
        } onCancel: {
            promptAdmission?.cancel()
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            workQueue.async {
                if let descriptor = self.descriptor {
                    self.descriptor = nil
                    Darwin.close(descriptor)
                }
                continuation.resume()
            }
        }
    }
}

enum CodexProcessGroupSafety {
    static func signalTarget(
        processIdentifier: pid_t,
        reportedGroupIdentifier: pid_t
    ) -> pid_t? {
        guard processIdentifier > 1 else { return nil }
        if reportedGroupIdentifier == processIdentifier { return -processIdentifier }
        if reportedGroupIdentifier > 0 { return processIdentifier }
        return nil
    }
}

actor CodexPOSIXConnection: CodexAppServerConnection {
    let processIdentifier: pid_t
    private let frames = CodexFrameQueue()
    private let counters = CodexProcessCounters()
    private let writer: CodexStdinWriter
    private let stdoutPump: CodexPipePump
    private let stderrPump: CodexPipePump
    private var monitoringStarted = false
    private var processExited = false
    private var terminationStarted = false

    init(
        processIdentifier: pid_t,
        stdinFileDescriptor: Int32,
        stdoutFileDescriptor: Int32,
        stderrFileDescriptor: Int32,
        maximumStdoutBytes: Int,
        maximumStderrBytes: Int
    ) {
        self.processIdentifier = processIdentifier
        writer = CodexStdinWriter(descriptor: stdinFileDescriptor)
        stdoutPump = CodexPipePump(
            descriptor: stdoutFileDescriptor,
            kind: .stdout,
            queue: frames,
            counters: counters,
            maximumStdoutBytes: maximumStdoutBytes,
            maximumStderrBytes: maximumStderrBytes
        )
        stderrPump = CodexPipePump(
            descriptor: stderrFileDescriptor,
            kind: .stderr,
            queue: frames,
            counters: counters,
            maximumStdoutBytes: maximumStdoutBytes,
            maximumStderrBytes: maximumStderrBytes
        )
        stdoutPump.start()
        stderrPump.start()
    }

    func startMonitoring() {
        guard !monitoringStarted else { return }
        monitoringStarted = true
        let pid = processIdentifier
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
            guard let self else { return }
            Task { await self.didExit() }
        }
    }

    func send(
        _ line: Data,
        promptAdmission: CodexPromptAdmission?
    ) async throws {
        guard !terminationStarted,
              !line.contains(0x0A),
              line.count <= CodexAppServerClient.maximumLineBytes else {
            throw CodexAppServerError.transportUnavailable
        }
        var framed = line
        framed.append(0x0A)
        try await writer.write(framed, promptAdmission: promptAdmission)
    }

    func receive(
        maximumLineBytes: Int,
        timeout: Duration
    ) async throws -> CodexProcessFrame {
        guard maximumLineBytes > 0, timeout > .zero else {
            throw CodexAppServerError.protocolViolation
        }
        return try await withThrowingTaskGroup(of: CodexProcessFrame.self) { group in
            group.addTask { try await self.frames.next() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CodexAppServerError.timedOut
            }
            defer { group.cancelAll() }
            guard let frame = try await group.next(),
                  frame.stdoutLine.count <= maximumLineBytes else {
                throw CodexAppServerError.outputLimitExceeded
            }
            return frame
        }
    }

    func terminateProcessGroup(gracePeriod: Duration) async {
        guard !terminationStarted else {
            await waitBrieflyForExit()
            return
        }
        terminationStarted = true
        await writer.close()
        if !processExited {
            signalProcessGroup(SIGTERM)
            let deadline = ContinuousClock.now.advanced(by: max(.zero, gracePeriod))
            while !processExited, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        if !processExited { signalProcessGroup(SIGKILL) }
        await waitBrieflyForExit()
        stdoutPump.cancel()
        stderrPump.cancel()
    }

    private func didExit() async {
        processExited = true
        frames.finish(.transportUnavailable)
        await writer.close()
        stdoutPump.cancel()
        stderrPump.cancel()
    }

    private func signalProcessGroup(_ signal: Int32) {
        let reportedGroup = getpgid(processIdentifier)
        guard let target = CodexProcessGroupSafety.signalTarget(
            processIdentifier: processIdentifier,
            reportedGroupIdentifier: reportedGroup
        ) else { return }
        _ = Darwin.kill(target, signal)
    }

    private func waitBrieflyForExit() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !processExited, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

struct CodexLoginChallenge: Sendable, Equatable {
    let loginID: String
    let authorizationURL: URL
}

/// Prompt-free connection state exposed to the provider store. `ready` means
/// the exact release-pinned native App Server initialized successfully but no
/// first-party ChatGPT account is available. Only `authenticated` carries an
/// authoritative current model catalog and is eligible for adapter registration.
enum CodexConnectionState: Sendable, Equatable {
    case unknown
    case checking
    case missing
    case untrusted
    case ready(version: String)
    case loginPending(loginID: String, authorizationURL: URL)
    case authenticated(version: String, models: [String])
    case error(String)
}

// MARK: - Strict JSON-RPC adapter

actor CodexAppServerClient: LLMAdapter {
    static let maximumLineBytes = 65_536
    static let maximumStdoutBytes = 1_048_576
    static let maximumStderrBytes = 65_536
    static let processTerminationGrace: Duration = .milliseconds(250)

    private struct Session {
        let connection: any CodexAppServerConnection
        let home: CodexPreparedHome
        var nextRequestID: Int
    }

    private struct LoginSession {
        var session: Session
        let loginID: String
    }

    private let executableResolver: any CodexExecutableResolving
    private let executableVerifier: any CodexExecutableVerifying
    private let homeManager: any CodexHomeManaging
    private let processTransport: any CodexAppServerProcessTransport
    private let snapshotProvider: any LLMSelectionSnapshotProviding
    private var loginSession: LoginSession?
    private(set) var isUnavailable = false

    init(
        executableResolver: any CodexExecutableResolving,
        executableVerifier: (any CodexExecutableVerifying)? = nil,
        homeManager: any CodexHomeManaging,
        processTransport: any CodexAppServerProcessTransport,
        snapshotProvider: any LLMSelectionSnapshotProviding
    ) {
        self.executableResolver = executableResolver
        self.executableVerifier = executableVerifier
            ?? CodexResolverBackedExecutableVerifier(resolver: executableResolver)
        self.homeManager = homeManager
        self.processTransport = processTransport
        self.snapshotProvider = snapshotProvider
    }

    func generate(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot
    ) async throws -> LLMResponse {
        guard !isUnavailable else { throw CodexAppServerError.unavailable }
        guard request.maximumOutputTokens > 0, request.timeout > .zero else {
            throw CodexAppServerError.protocolViolation
        }
        guard await snapshotProvider.currentSnapshot(for: request.consumer) == selection else {
            throw CodexAppServerError.staleSelection
        }
        let promptAdmission = CodexPromptAdmission(
            snapshotProvider: snapshotProvider,
            selection: selection,
            consumer: request.consumer
        )

        var session: Session?
        var threadID: String?
        var turnID: String?
        do {
            var opened = try await openSession(timeout: remainingTimeout(request.timeout))
            session = opened
            try await requireChatGPTAccount(session: &opened, timeout: request.timeout)
            try await requireSelectedModel(
                selection.modelID,
                session: &opened,
                timeout: request.timeout
            )
            threadID = try await startThread(
                request: request,
                selection: selection,
                promptAdmission: promptAdmission,
                session: &opened,
                timeout: request.timeout
            )
            turnID = try await startTurn(
                request: request,
                selection: selection,
                threadID: threadID!,
                promptAdmission: promptAdmission,
                session: &opened,
                timeout: request.timeout
            )
            session = opened
            let content = try await consumeTurn(
                request: request,
                threadID: threadID!,
                turnID: turnID!,
                session: &opened,
                timeout: request.timeout
            )
            session = opened
            guard await snapshotProvider.currentSnapshot(for: request.consumer) == selection else {
                throw CodexAppServerError.staleSelection
            }
            try await finish(&opened)
            session = nil
            return LLMResponse(
                content: content,
                truncated: false,
                provenance: AIExecutionProvenance(
                    providerID: selection.providerID,
                    modelID: selection.modelID,
                    executedLocally: false,
                    generatedAt: Date(),
                    brokerUpstream: "OpenAI via Codex login"
                )
            )
        } catch {
            let mapped = map(error)
            if var session {
                if let threadID, let turnID {
                    await bestEffortInterrupt(
                        threadID: threadID,
                        turnID: turnID,
                        session: &session
                    )
                }
                await abort(session)
            }
            if mapped.poisonsClient { isUnavailable = true }
            throw mapped
        }
    }

    /// Initializes the exact App Server and reads only account/catalog state.
    /// This path never creates a thread, starts a turn, or sends prompt/history
    /// bytes. Every probe owns a fresh isolated home and always tears it down.
    func probeConnection(
        timeout: Duration = .seconds(10)
    ) async throws -> CodexConnectionState {
        guard !isUnavailable, timeout > .zero else {
            throw CodexAppServerError.unavailable
        }
        var session: Session?
        do {
            var opened = try await openSession(timeout: timeout)
            session = opened
            let account = try await rpc(
                method: "account/read",
                params: ["refreshToken": false],
                session: &opened,
                timeout: timeout
            )
            do {
                try validateChatGPTAccount(account)
            } catch CodexAppServerError.notAuthenticatedWithChatGPT {
                try await finish(&opened)
                session = nil
                return .ready(version: CodexBinaryPolicy.allowedVersion)
            }
            let models = try await readCurrentModels(
                session: &opened,
                timeout: timeout
            )
            try await finish(&opened)
            session = nil
            return .authenticated(
                version: CodexBinaryPolicy.allowedVersion,
                models: models
            )
        } catch {
            if let session { await abort(session) }
            let mapped = map(error)
            if mapped.poisonsClient { isUnavailable = true }
            throw mapped
        }
    }

    /// Returns only a live App Server catalog proven to belong to an exact,
    /// authenticated ChatGPT connection. A merely installed/ready Codex is not
    /// catalog authority.
    func currentModelCatalog(
        timeout: Duration = .seconds(10)
    ) async throws -> [String] {
        switch try await probeConnection(timeout: timeout) {
        case .authenticated(_, let models):
            return models
        case .ready:
            throw CodexAppServerError.notAuthenticatedWithChatGPT
        case .missing:
            throw CodexAppServerError.executableMissing
        case .untrusted:
            throw CodexAppServerError.untrustedBinary
        case .unknown, .checking, .loginPending, .error:
            throw CodexAppServerError.unavailable
        }
    }

    func startLogin() async throws -> CodexLoginChallenge {
        guard !isUnavailable, loginSession == nil else {
            throw CodexAppServerError.unavailable
        }
        var session: Session?
        do {
            var opened = try await openSession(timeout: .seconds(10))
            session = opened
            let result = try await rpc(
                method: "account/login/start",
                params: ["type": "chatgpt", "codexStreamlinedLogin": true],
                session: &opened,
                timeout: .seconds(10)
            )
            guard result["type"] as? String == "chatgpt",
                  let loginID = result["loginId"] as? String,
                  !loginID.isEmpty,
                  let urlString = result["authUrl"] as? String,
                  let url = URL(string: urlString),
                  url.scheme == "https",
                  ["auth.openai.com", "chatgpt.com"].contains(url.host ?? "") else {
                throw CodexAppServerError.capabilityMismatch
            }
            loginSession = LoginSession(session: opened, loginID: loginID)
            return CodexLoginChallenge(loginID: loginID, authorizationURL: url)
        } catch {
            if let session { await abort(session) }
            let mapped = map(error)
            if mapped.poisonsClient { isUnavailable = true }
            throw mapped
        }
    }

    func cancelLogin(loginID: String) async throws {
        guard var login = loginSession, login.loginID == loginID else {
            throw CodexAppServerError.protocolViolation
        }
        loginSession = nil
        do {
            let result = try await rpc(
                method: "account/login/cancel",
                params: ["loginId": loginID],
                session: &login.session,
                timeout: .seconds(10)
            )
            guard result["status"] as? String == "canceled" else {
                throw CodexAppServerError.protocolViolation
            }
            try await finish(&login.session)
        } catch {
            await abort(login.session)
            let mapped = map(error)
            if mapped.poisonsClient { isUnavailable = true }
            throw mapped
        }
    }

    func completeLogin(
        loginID: String,
        timeout: Duration = .seconds(120)
    ) async throws {
        guard timeout > .zero,
              var login = loginSession,
              login.loginID == loginID else {
            throw CodexAppServerError.protocolViolation
        }
        loginSession = nil
        do {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            try await waitForLoginCompletion(
                loginID: loginID,
                session: &login.session,
                deadline: deadline
            )
            let account = try await readAccountAfterLogin(
                loginID: loginID,
                session: &login.session,
                deadline: deadline
            )
            try validateChatGPTAccount(account)
            try await finish(&login.session)
        } catch {
            await abort(login.session)
            let mapped = map(error)
            if mapped.poisonsClient { isUnavailable = true }
            throw mapped
        }
    }

    func shutdown() async {
        if let login = loginSession {
            loginSession = nil
            await abort(login.session)
        }
    }

    private func openSession(timeout: Duration) async throws -> Session {
        let executable = try await executableResolver.resolve()
        guard executable.version == CodexBinaryPolicy.allowedVersion else {
            throw CodexAppServerError.untrustedBinary
        }
        let home = try await homeManager.prepareSession()
        var openedConnection: (any CodexAppServerConnection)?
        do {
            try await homeManager.audit(home, phase: .beforeLaunch)
            let launchExecutable = try await executableVerifier.revalidate(executable)
            let launch = CodexLaunchSpecification(
                executableURL: launchExecutable.url,
                trustedExecutable: launchExecutable,
                arguments: ["app-server", "--stdio", "--strict-config"],
                environment: [
                    "CODEX_HOME": home.homeURL.path,
                    // Security.framework resolves the user's default Keychain
                    // through HOME. CODEX_HOME remains isolated, so Codex still
                    // cannot load the user's config, tools, MCP servers, or
                    // conversation state.
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    "PATH": "/usr/bin:/bin",
                    "LANG": "en_US.UTF-8",
                    "LC_ALL": "en_US.UTF-8",
                    "TMPDIR": home.temporaryDirectoryURL.path,
                ],
                workingDirectoryURL: home.workingDirectoryURL,
                createsDedicatedProcessGroup: true,
                usesLoginShell: false,
                maximumStdoutBytes: Self.maximumStdoutBytes,
                maximumStderrBytes: Self.maximumStderrBytes
            )
            let connection = try await processTransport.open(launch)
            openedConnection = connection
            var session = Session(connection: connection, home: home, nextRequestID: 0)
            let result = try await rpc(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "zbs-eye",
                        "title": "ZBS Eye",
                        "version": "1",
                    ],
                    "capabilities": [
                        "experimentalApi": false,
                        "requestAttestation": false,
                        "optOutNotificationMethods": Self.suppressedNotificationMethods,
                    ],
                ],
                session: &session,
                timeout: timeout
            )
            try validateInitialize(result, home: home)
            try await sendNotification(method: "initialized", session: &session)
            return session
        } catch {
            if let openedConnection {
                await openedConnection.terminateProcessGroup(
                    gracePeriod: Self.processTerminationGrace
                )
            }
            await homeManager.destroy(home)
            throw error
        }
    }

    private static let suppressedNotificationMethods = [
        "thread/started", "thread/status/changed", "thread/tokenUsage/updated",
        "turn/started", "account/rateLimits/updated",
        "app/list/updated", "remoteControl/status/changed", "skills/changed",
        "thread/name/updated", "configWarning", "warning", "deprecationNotice",
        "model/verification",
    ]

    private func validateInitialize(
        _ result: [String: Any],
        home: CodexPreparedHome
    ) throws {
        guard let userAgent = result["userAgent"] as? String,
              userAgent.contains("zbs-eye/0.136.0 ("),
              result["platformFamily"] as? String == "unix",
              result["platformOs"] as? String == "macos",
              let reportedHome = result["codexHome"] as? String,
              canonicalPath(reportedHome) == canonicalPath(home.homeURL.path) else {
            throw CodexAppServerError.capabilityMismatch
        }
    }

    private func requireChatGPTAccount(
        session: inout Session,
        timeout: Duration
    ) async throws {
        let result = try await rpc(
            method: "account/read",
            params: ["refreshToken": false],
            session: &session,
            timeout: timeout
        )
        try validateChatGPTAccount(result)
    }

    private func validateChatGPTAccount(_ result: [String: Any]) throws {
        guard result["requiresOpenaiAuth"] as? Bool == true,
              let account = result["account"] as? [String: Any],
              account["type"] as? String == "chatgpt",
              account["email"] is String,
              account["planType"] is String else {
            throw CodexAppServerError.notAuthenticatedWithChatGPT
        }
    }

    private func waitForLoginCompletion(
        loginID: String,
        session: inout Session,
        deadline: ContinuousClock.Instant
    ) async throws {
        for _ in 0..<16 {
            let object = try await receiveObject(
                session: &session,
                timeout: try remaining(until: deadline)
            )
            guard object["id"] == nil,
                  let method = object["method"] as? String,
                  let params = object["params"] as? [String: Any] else {
                throw CodexAppServerError.protocolViolation
            }
            switch method {
            case "account/updated":
                try validateAccountUpdated(params)
            case "account/login/completed":
                try validateLoginCompletion(params, loginID: loginID)
                return
            default:
                throw CodexAppServerError.protocolViolation
            }
        }
        throw CodexAppServerError.outputLimitExceeded
    }

    private func readAccountAfterLogin(
        loginID: String,
        session: inout Session,
        deadline: ContinuousClock.Instant
    ) async throws -> [String: Any] {
        session.nextRequestID += 1
        let requestID = session.nextRequestID
        try await send(
            [
                "method": "account/read",
                "id": requestID,
                "params": ["refreshToken": true],
            ],
            session: &session,
            promptAdmission: nil
        )
        for _ in 0..<16 {
            let object = try await receiveObject(
                session: &session,
                timeout: try remaining(until: deadline)
            )
            if object["method"] == nil {
                guard (object["id"] as? NSNumber)?.intValue == requestID,
                      object["error"] == nil,
                      let result = object["result"] as? [String: Any] else {
                    throw CodexAppServerError.protocolViolation
                }
                return result
            }
            guard object["id"] == nil,
                  let method = object["method"] as? String,
                  let params = object["params"] as? [String: Any] else {
                throw CodexAppServerError.protocolViolation
            }
            switch method {
            case "account/updated":
                try validateAccountUpdated(params)
            case "account/login/completed":
                try validateLoginCompletion(params, loginID: loginID)
            default:
                throw CodexAppServerError.protocolViolation
            }
        }
        throw CodexAppServerError.outputLimitExceeded
    }

    private func validateAccountUpdated(_ params: [String: Any]) throws {
        guard Set(params.keys).isSubset(of: ["authMode", "planType"]),
              params["authMode"] == nil
                || params["authMode"] is NSNull
                || params["authMode"] as? String == "chatgpt",
              params["planType"] == nil
                || params["planType"] is NSNull
                || params["planType"] is String else {
            throw CodexAppServerError.capabilityMismatch
        }
    }

    private func validateLoginCompletion(
        _ params: [String: Any],
        loginID: String
    ) throws {
        guard Set(params.keys).isSubset(of: ["loginId", "success", "error"]),
              params["loginId"] as? String == loginID,
              params["success"] as? Bool == true,
              params["error"] == nil || params["error"] is NSNull else {
            throw CodexAppServerError.notAuthenticatedWithChatGPT
        }
    }

    private func remaining(until deadline: ContinuousClock.Instant) throws -> Duration {
        let duration = ContinuousClock.now.duration(to: deadline)
        guard duration > .zero else { throw CodexAppServerError.timedOut }
        return duration
    }

    private func requireSelectedModel(
        _ selectedModel: String,
        session: inout Session,
        timeout: Duration
    ) async throws {
        let models = try await readCurrentModels(
            session: &session,
            timeout: timeout
        )
        guard models.contains(selectedModel) else {
            throw CodexAppServerError.selectedModelUnavailable
        }
    }

    private func readCurrentModels(
        session: inout Session,
        timeout: Duration
    ) async throws -> [String] {
        let result = try await rpc(
            method: "model/list",
            params: ["cursor": NSNull(), "limit": 100, "includeHidden": false],
            session: &session,
            timeout: timeout
        )
        guard let models = result["data"] as? [[String: Any]],
              result["nextCursor"] is NSNull else {
            throw CodexAppServerError.protocolViolation
        }
        var seen = Set<String>()
        var identifiers: [String] = []
        identifiers.reserveCapacity(models.count)
        for model in models {
            guard let identifier = model["id"] as? String,
                  !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  model["model"] as? String == identifier,
                  model["hidden"] as? Bool == false else {
                throw CodexAppServerError.protocolViolation
            }
            if seen.insert(identifier).inserted {
                identifiers.append(identifier)
            }
        }
        return identifiers
    }

    private func startThread(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot,
        promptAdmission: CodexPromptAdmission,
        session: inout Session,
        timeout: Duration
    ) async throws -> String {
        guard await snapshotProvider.currentSnapshot(for: request.consumer) == selection else {
            throw CodexAppServerError.staleSelection
        }
        try Task.checkCancellation()
        let result = try await rpc(
            method: "thread/start",
            params: [
                "model": selection.modelID,
                "modelProvider": "openai",
                "cwd": session.home.workingDirectoryURL.path,
                "runtimeWorkspaceRoots": [],
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "config": [
                    "include_apps_instructions": false,
                    "include_collaboration_mode_instructions": false,
                    "include_environment_context": false,
                    "include_permissions_instructions": false,
                    "web_search": "disabled",
                ],
                "baseInstructions": "Return only the requested JSON object. Do not use tools, files, shell, web, apps, plugins, MCP, memories, images, or child agents.",
                "developerInstructions": request.systemPrompt,
                "ephemeral": true,
                "environments": [],
                "dynamicTools": [],
                "experimentalRawEvents": false,
                "persistExtendedHistory": false,
            ],
            session: &session,
            timeout: timeout,
            promptAdmission: promptAdmission
        )
        guard let thread = result["thread"] as? [String: Any],
              let threadID = thread["id"] as? String,
              !threadID.isEmpty,
              thread["ephemeral"] as? Bool == true,
              thread["path"] is NSNull,
              thread["modelProvider"] as? String == "openai",
              thread["cliVersion"] as? String == CodexBinaryPolicy.allowedVersion,
              let threadCWD = thread["cwd"] as? String,
              canonicalPath(threadCWD) == canonicalPath(session.home.workingDirectoryURL.path),
              result["model"] as? String == selection.modelID,
              result["modelProvider"] as? String == "openai",
              let cwd = result["cwd"] as? String,
              canonicalPath(cwd) == canonicalPath(session.home.workingDirectoryURL.path),
              let roots = result["runtimeWorkspaceRoots"] as? [Any], roots.isEmpty,
              let instructions = result["instructionSources"] as? [Any], instructions.isEmpty else {
            throw CodexAppServerError.capabilityMismatch
        }
        return threadID
    }

    private func startTurn(
        request: LLMRequest,
        selection: ProviderSelectionSnapshot,
        threadID: String,
        promptAdmission: CodexPromptAdmission,
        session: inout Session,
        timeout: Duration
    ) async throws -> String {
        let outputCharacterLimit = min(262_144, max(4_096, request.maximumOutputTokens * 16))
        guard await snapshotProvider.currentSnapshot(for: request.consumer) == selection else {
            throw CodexAppServerError.staleSelection
        }
        try Task.checkCancellation()
        let result = try await rpc(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "clientUserMessageId": request.id.uuidString.lowercased(),
                "input": [[
                    "type": "text",
                    "text": request.userPrompt,
                    "text_elements": [],
                ]],
                "responsesapiClientMetadata": [:],
                "additionalContext": [:],
                "environments": [],
                "cwd": session.home.workingDirectoryURL.path,
                "runtimeWorkspaceRoots": [],
                "approvalPolicy": "never",
                "model": selection.modelID,
                "outputSchema": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["content"],
                    "properties": [
                        "content": ["type": "string", "minLength": 1, "maxLength": outputCharacterLimit],
                    ],
                ],
            ],
            session: &session,
            timeout: timeout,
            promptAdmission: promptAdmission
        )
        guard let turn = result["turn"] as? [String: Any],
              let turnID = turn["id"] as? String,
              !turnID.isEmpty,
              turn["status"] as? String == "inProgress" else {
            throw CodexAppServerError.protocolViolation
        }
        return turnID
    }

    private func consumeTurn(
        request: LLMRequest,
        threadID: String,
        turnID: String,
        session: inout Session,
        timeout: Duration
    ) async throws -> String {
        var accumulatedDeltaBytes = 0
        while true {
            let object = try await receiveObject(session: &session, timeout: timeout)
            guard object["id"] == nil,
                  let method = object["method"] as? String,
                  let params = object["params"] as? [String: Any] else {
                if object["method"] != nil && object["id"] != nil {
                    throw CodexAppServerError.forbiddenEvent
                }
                throw CodexAppServerError.protocolViolation
            }

            switch method {
            case "item/agentMessage/delta":
                try validateIDs(params, threadID: threadID, turnID: turnID)
                guard let delta = params["delta"] as? String else {
                    throw CodexAppServerError.protocolViolation
                }
                accumulatedDeltaBytes += delta.utf8.count
                guard accumulatedDeltaBytes <= Self.maximumStdoutBytes else {
                    throw CodexAppServerError.outputLimitExceeded
                }

            case "item/started", "item/completed":
                try validateIDs(params, threadID: threadID, turnID: turnID)
                guard let item = params["item"] as? [String: Any] else {
                    throw CodexAppServerError.protocolViolation
                }
                _ = try inspectAllowedItem(item)

            case "turn/completed":
                guard params["threadId"] as? String == threadID,
                      let turn = params["turn"] as? [String: Any],
                      turn["id"] as? String == turnID,
                      turn["status"] as? String == "completed",
                      turn["error"] is NSNull,
                      let items = turn["items"] as? [[String: Any]] else {
                    throw CodexAppServerError.protocolViolation
                }
                var finalMessages: [String] = []
                for item in items {
                    if let message = try inspectAllowedItem(item) {
                        finalMessages.append(message)
                    }
                }
                guard finalMessages.count == 1 else {
                    throw CodexAppServerError.invalidOutput
                }
                return try parseStrictOutput(
                    finalMessages[0],
                    maximumOutputTokens: request.maximumOutputTokens
                )

            default:
                if Self.forbiddenMethodFragments.contains(where: method.contains) {
                    throw CodexAppServerError.forbiddenEvent
                }
                throw CodexAppServerError.protocolViolation
            }
        }
    }

    private static let forbiddenMethodFragments = [
        "command", "exec", "process", "file", "patch", "image", "web",
        "mcp", "tool", "hook", "collab", "app/", "plugin", "skill", "memory",
    ]

    private func inspectAllowedItem(_ item: [String: Any]) throws -> String? {
        guard let type = item["type"] as? String else {
            throw CodexAppServerError.protocolViolation
        }
        switch type {
        case "userMessage":
            if let content = item["content"] as? [[String: Any]] {
                guard content.allSatisfy({ $0["type"] as? String == "text" }) else {
                    throw CodexAppServerError.forbiddenEvent
                }
            }
            return nil
        case "reasoning":
            return nil
        case "agentMessage":
            guard item["memoryCitation"] == nil || item["memoryCitation"] is NSNull,
                  let text = item["text"] as? String,
                  text.utf8.count <= Self.maximumStdoutBytes else {
                throw CodexAppServerError.forbiddenEvent
            }
            return text
        case "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall",
                "collabAgentToolCall", "webSearch", "imageView", "imageGeneration",
                "hookPrompt":
            throw CodexAppServerError.forbiddenEvent
        default:
            throw CodexAppServerError.protocolViolation
        }
    }

    private func parseStrictOutput(
        _ text: String,
        maximumOutputTokens: Int
    ) throws -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == ["content"],
              let content = dictionary["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.utf8.count <= min(262_144, max(4_096, maximumOutputTokens * 16)) else {
            throw CodexAppServerError.invalidOutput
        }
        return content
    }

    private func validateIDs(
        _ params: [String: Any],
        threadID: String,
        turnID: String
    ) throws {
        guard params["threadId"] as? String == threadID,
              params["turnId"] as? String == turnID else {
            throw CodexAppServerError.protocolViolation
        }
    }

    private func rpc(
        method: String,
        params: [String: Any],
        session: inout Session,
        timeout: Duration,
        promptAdmission: CodexPromptAdmission? = nil
    ) async throws -> [String: Any] {
        session.nextRequestID += 1
        let requestID = session.nextRequestID
        try await send(
            ["method": method, "id": requestID, "params": params],
            session: &session,
            promptAdmission: promptAdmission
        )
        let object = try await receiveObject(session: &session, timeout: timeout)
        guard object["method"] == nil,
              (object["id"] as? NSNumber)?.intValue == requestID,
              object["error"] == nil,
              let result = object["result"] as? [String: Any] else {
            throw CodexAppServerError.protocolViolation
        }
        return result
    }

    private func sendNotification(
        method: String,
        session: inout Session
    ) async throws {
        try await send(
            ["method": method],
            session: &session,
            promptAdmission: nil
        )
    }

    private func send(
        _ object: [String: Any],
        session: inout Session,
        promptAdmission: CodexPromptAdmission?
    ) async throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexAppServerError.protocolViolation
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= Self.maximumLineBytes else {
            throw CodexAppServerError.outputLimitExceeded
        }
        try await session.connection.send(data, promptAdmission: promptAdmission)
    }

    private func receiveObject(
        session: inout Session,
        timeout: Duration
    ) async throws -> [String: Any] {
        let frame = try await session.connection.receive(
            maximumLineBytes: Self.maximumLineBytes,
            timeout: timeout
        )
        guard frame.stdoutLine.count <= Self.maximumLineBytes,
              frame.totalStdoutBytes <= Self.maximumStdoutBytes,
              frame.totalStderrBytes <= Self.maximumStderrBytes else {
            throw CodexAppServerError.outputLimitExceeded
        }
        try await homeManager.audit(session.home, phase: .afterMessage)
        guard let object = try JSONSerialization.jsonObject(
            with: frame.stdoutLine,
            options: [.fragmentsAllowed]
        ) as? [String: Any] else {
            throw CodexAppServerError.protocolViolation
        }
        return object
    }

    private func bestEffortInterrupt(
        threadID: String,
        turnID: String,
        session: inout Session
    ) async {
        session.nextRequestID += 1
        try? await send(
            [
                "method": "turn/interrupt",
                "id": session.nextRequestID,
                "params": ["threadId": threadID, "turnId": turnID],
            ],
            session: &session,
            promptAdmission: nil
        )
    }

    private func finish(_ session: inout Session) async throws {
        try await homeManager.audit(session.home, phase: .beforeDestroy)
        await session.connection.terminateProcessGroup(
            gracePeriod: Self.processTerminationGrace
        )
        await homeManager.destroy(session.home)
    }

    private func abort(_ session: Session) async {
        await session.connection.terminateProcessGroup(
            gracePeriod: Self.processTerminationGrace
        )
        await homeManager.destroy(session.home)
    }

    private func map(_ error: Error) -> CodexAppServerError {
        if let error = error as? CodexAppServerError { return error }
        if error is CancellationError { return .cancelled }
        return .transportUnavailable
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }

    private func remainingTimeout(_ timeout: Duration) -> Duration { timeout }
}
