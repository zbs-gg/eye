import Foundation

enum BuiltInModelVerificationError: Error, Sendable, Equatable {
    case invalidManifestPath(String)
    case duplicateManifestPath(String)
    case missingFile(String)
    case unexpectedFile(String)
    case nonRegularFile(String)
    case byteCountMismatch(path: String, expected: Int64, actual: Int64)
    case digestMismatch(path: String, expected: String, actual: String)
    case unreadableFile(String)
}

struct BuiltInModelVerification: Sendable, Equatable {
    let manifestID: String
    let aggregateFingerprintSHA256: String
    let verifiedFileCount: Int
    let verifiedBytes: Int64
}

/// Offline-only integrity gate for a local model directory.
///
/// Verification is deliberately exact: every manifest file must be present,
/// no unlisted files or directories are accepted, symbolic links are rejected,
/// hard-linked files are rejected, and bytes are streamed through SHA-256 from
/// an `O_NOFOLLOW` descriptor.
/// The runtime must never load a directory before this gate succeeds.
enum BuiltInModelVerifier {
    static func verify(
        directory: URL,
        manifest: BuiltInModelManifest,
        fileManager: FileManager = .default
    ) throws -> BuiltInModelVerification {
        try Task.checkCancellation()
        let root = directory.standardizedFileURL
        let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues?.isDirectory == true, rootValues?.isSymbolicLink != true else {
            throw BuiltInModelVerificationError.nonRegularFile(".")
        }

        let paths = manifest.files.map(\.relativePath)
        var expectedPaths = Set<String>()
        var allowedDirectories = Set<String>()
        for path in paths {
            try Task.checkCancellation()
            guard isSafeRelativePath(path) else {
                throw BuiltInModelVerificationError.invalidManifestPath(path)
            }
            guard expectedPaths.insert(path).inserted else {
                throw BuiltInModelVerificationError.duplicateManifestPath(path)
            }
            var parent = NSString(string: path).deletingLastPathComponent
            while !parent.isEmpty, parent != "." {
                allowedDirectories.insert(parent)
                parent = NSString(string: parent).deletingLastPathComponent
            }
        }

        var verifiedBytes: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(file.relativePath, isDirectory: false)
            guard fileManager.fileExists(atPath: url.path) else {
                throw BuiltInModelVerificationError.missingFile(file.relativePath)
            }
            try rejectSymlinkComponents(from: root, relativePath: file.relativePath)
            do {
                _ = try ManagedAssetVerifier.verifyFile(
                    root: root,
                    relativePath: file.relativePath,
                    expectedBytes: file.expectedBytes,
                    sha256: file.sha256
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw map(error)
            }
            verifiedBytes += file.expectedBytes
            try Task.checkCancellation()
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw BuiltInModelVerificationError.unreadableFile(".")
        }

        for case let item as URL in enumerator {
            try Task.checkCancellation()
            let path = relativePath(of: item, under: root)
            let values = try? item.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                guard allowedDirectories.contains(path) else {
                    throw BuiltInModelVerificationError.unexpectedFile(path)
                }
            } else {
                guard expectedPaths.contains(path) else {
                    throw BuiltInModelVerificationError.unexpectedFile(path)
                }
            }
        }

        return BuiltInModelVerification(
            manifestID: manifest.id,
            aggregateFingerprintSHA256: manifest.aggregateFingerprintSHA256,
            verifiedFileCount: manifest.files.count,
            verifiedBytes: verifiedBytes
        )
    }

    private static func rejectSymlinkComponents(from root: URL, relativePath: String) throws {
        var current = root
        for component in NSString(string: relativePath).pathComponents {
            try Task.checkCancellation()
            current.appendPathComponent(component)
            let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw BuiltInModelVerificationError.nonRegularFile(relativePath)
            }
        }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = NSString(string: path).pathComponents
        return !components.contains("..") && !components.contains(".")
    }

    private static func relativePath(of item: URL, under root: URL) -> String {
        String(item.standardizedFileURL.path.dropFirst(root.path.count + 1))
    }

    private static func map(_ error: Error) -> BuiltInModelVerificationError {
        guard let error = error as? ManagedAssetVerificationError else {
            return .unreadableFile(".")
        }
        return switch error {
        case .invalidRelativePath(let path): .invalidManifestPath(path)
        case .nonRegularFile(let path): .nonRegularFile(path)
        case .byteCountMismatch(let path, let expected, let actual):
            .byteCountMismatch(path: path, expected: expected, actual: actual)
        case .digestMismatch(let path, let expected, let actual):
            .digestMismatch(path: path, expected: expected, actual: actual)
        case .unreadableFile(let path): .unreadableFile(path)
        }
    }
}
