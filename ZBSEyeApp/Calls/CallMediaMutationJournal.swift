import Foundation

enum CallHelperScratchError: Error, LocalizedError, Sendable, Equatable {
    case unsafeEntry
    case globalLimitExceeded

    var errorDescription: String? {
        switch self {
        case .unsafeEntry:
            "Call transcription scratch contained an unsafe filesystem entry."
        case .globalLimitExceeded:
            "Call transcription scratch exceeded its 64 MB safety limit."
        }
    }
}

struct CallHelperScratchInventory: Sendable, Equatable {
    let jobDirectories: Int
    let bytes: Int64
}

/// Ephemeral helper results live outside retained evidence. The worker is
/// serial, so every directory except the currently launching helper is an
/// abandoned crash artifact and can be reclaimed deterministically.
struct CallHelperScratchStore: @unchecked Sendable {
    static let maximumResultBytes: Int64 = 32 * 1_024 * 1_024
    static let maximumGlobalBytes: Int64 = 64 * 1_024 * 1_024

    let dataRoot: URL
    private let fileManager: FileManager

    init(dataRoot: URL, fileManager: FileManager = .default) {
        self.dataRoot = dataRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    var jobsRoot: URL {
        StorageLocation.callHelperRoot(under: dataRoot)
            .appendingPathComponent("jobs", isDirectory: true)
    }

    func prepareForJob(_ jobID: String) throws {
        guard UUID(uuidString: jobID)?.uuidString.lowercased() == jobID else {
            throw CallHelperScratchError.unsafeEntry
        }
        try scavenge(excluding: jobID)
        let inventory = try inventory()
        guard inventory.bytes <= Self.maximumGlobalBytes else {
            throw CallHelperScratchError.globalLimitExceeded
        }
    }

    @discardableResult
    func scavenge(excluding jobID: String? = nil) throws -> CallHelperScratchInventory {
        try fileManager.createDirectory(
            at: jobsRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: jobsRoot.path
        )
        for url in try fileManager.contentsOfDirectory(
            at: jobsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            if url.lastPathComponent == jobID { continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                try fileManager.removeItem(at: url)
                continue
            }
            guard values.isDirectory == true else {
                try fileManager.removeItem(at: url)
                continue
            }
            try fileManager.removeItem(at: url)
        }
        return try inventory()
    }

    func inventory() throws -> CallHelperScratchInventory {
        guard fileManager.fileExists(atPath: jobsRoot.path) else {
            return CallHelperScratchInventory(jobDirectories: 0, bytes: 0)
        }
        let roots = try fileManager.contentsOfDirectory(
            at: jobsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        var bytes: Int64 = 0
        var directories = 0
        for root in roots {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CallHelperScratchError.unsafeEntry
            }
            directories += 1
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                ],
                options: []
            ) else { continue }
            for case let url as URL in enumerator {
                let item = try url.resourceValues(
                    forKeys: [
                        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                    ]
                )
                guard item.isSymbolicLink != true else {
                    throw CallHelperScratchError.unsafeEntry
                }
                if item.isRegularFile == true {
                    let size = Int64(item.fileSize ?? 0)
                    let next = bytes.addingReportingOverflow(size)
                    guard !next.overflow else {
                        throw CallHelperScratchError.globalLimitExceeded
                    }
                    bytes = next.partialValue
                } else if item.isDirectory != true {
                    throw CallHelperScratchError.unsafeEntry
                }
            }
        }
        return CallHelperScratchInventory(jobDirectories: directories, bytes: bytes)
    }
}
