import CryptoKit
import Darwin
import Foundation

enum ManagedAssetVerificationError: Error, Sendable, Equatable {
    case invalidRelativePath(String)
    case nonRegularFile(String)
    case byteCountMismatch(path: String, expected: Int64, actual: Int64)
    case digestMismatch(path: String, expected: String, actual: String)
    case unreadableFile(String)
}

struct ManagedAssetVerification: Sendable, Equatable {
    let relativePath: String
    let verifiedBytes: Int64
    let sha256: String
}

/// Shared offline integrity primitive for large managed assets. It rejects
/// traversal, symlinks, hard links, wrong byte counts, and wrong digests while
/// hashing from an O_NOFOLLOW descriptor in bounded memory.
enum ManagedAssetVerifier {
    static func verifyFile(
        root: URL,
        relativePath: String,
        expectedBytes: Int64,
        sha256 expectedSHA256: String
    ) throws -> ManagedAssetVerification {
        let url = try containedURL(root: root, relativePath: relativePath)
        let actual = try digestAndValidateFile(
            url,
            relativePath: relativePath,
            expectedBytes: expectedBytes
        )
        guard actual == expectedSHA256.lowercased() else {
            throw ManagedAssetVerificationError.digestMismatch(
                path: relativePath,
                expected: expectedSHA256.lowercased(),
                actual: actual
            )
        }
        return ManagedAssetVerification(
            relativePath: relativePath,
            verifiedBytes: expectedBytes,
            sha256: actual
        )
    }

    static func containedURL(root: URL, relativePath: String) throws -> URL {
        guard isSafeRelativePath(relativePath) else {
            throw ManagedAssetVerificationError.invalidRelativePath(relativePath)
        }
        let standardizedRoot = root.standardizedFileURL
        let result = standardizedRoot
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        guard result.path.hasPrefix(standardizedRoot.path + "/") else {
            throw ManagedAssetVerificationError.invalidRelativePath(relativePath)
        }
        try rejectSymlinkComponents(from: standardizedRoot, relativePath: relativePath)
        return result
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = NSString(string: path).pathComponents
        return !components.contains("..") && !components.contains(".")
    }

    static func digestAndValidateFile(
        _ url: URL,
        relativePath: String,
        expectedBytes: Int64
    ) throws -> String {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw ManagedAssetVerificationError.nonRegularFile(relativePath)
            }
            throw ManagedAssetVerificationError.unreadableFile(relativePath)
        }
        defer { Darwin.close(descriptor) }

        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else {
            throw ManagedAssetVerificationError.unreadableFile(relativePath)
        }
        guard (attributes.st_mode & S_IFMT) == S_IFREG, attributes.st_nlink == 1 else {
            throw ManagedAssetVerificationError.nonRegularFile(relativePath)
        }

        let actualBytes = Int64(attributes.st_size)
        guard actualBytes == expectedBytes else {
            throw ManagedAssetVerificationError.byteCountMismatch(
                path: relativePath,
                expected: expectedBytes,
                actual: actualBytes
            )
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                let count = Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                if count > 0 {
                    hasher.update(
                        bufferPointer: UnsafeRawBufferPointer(
                            start: bytes.baseAddress,
                            count: count
                        )
                    )
                }
                return count
            }
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw ManagedAssetVerificationError.unreadableFile(relativePath)
            }
        }
        try Task.checkCancellation()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func rejectSymlinkComponents(from root: URL, relativePath: String) throws {
        var current = root
        for component in NSString(string: relativePath).pathComponents {
            current.appendPathComponent(component)
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw ManagedAssetVerificationError.nonRegularFile(relativePath)
            }
        }
    }
}
