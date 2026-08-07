import Darwin
import Dispatch
import Foundation

struct CallPrivacyIntentReceipt: Sendable, Equatable {
    let callID: Int64
    let detectorFingerprint: String
    let relativePath: String
}

enum CallPrivacyIntentJournalError: LocalizedError, Sendable, Equatable {
    case invalidReceipt
    case unsafeReceipt

    var errorDescription: String? {
        switch self {
        case .invalidReceipt:
            "A call privacy receipt is invalid. Call processing remains paused."
        case .unsafeReceipt:
            "A call privacy receipt is not a regular local file. Call processing remains paused."
        }
    }
}

/// A DB-independent, crash-forward receipt for "Not a call".
///
/// The empty marker lives inside the call's media directory, so relocation copies it with the
/// evidence it governs. The filename contains only the numeric call ID and the already-opaque
/// detector SHA-256; no URL, title, participant, or transcript material is written.
///
/// `@unchecked Sendable` is limited to Foundation's thread-safe `FileManager` reference. Every
/// operation is synchronous and filesystem containment is enforced by the descriptor-pinned
/// `SecureCallSpoolRoot`, not by mutable FileManager state.
struct CallPrivacyIntentJournal: @unchecked Sendable {
    private static let prefix = ".privacy-reject-v1-"
    private static let suffix = ".intent"

    private let mediaRoot: URL
    private let secureRoot: SecureCallSpoolRoot
    private let fileManager: FileManager
    private let afterMarkerCreated: @Sendable () throws -> Void

    init(
        mediaRoot: URL,
        fileManager: FileManager = .default,
        afterMarkerCreated: @escaping @Sendable () throws -> Void = {}
    ) throws {
        self.mediaRoot = mediaRoot.standardizedFileURL
        secureRoot = try SecureCallSpoolRoot(root: self.mediaRoot)
        self.fileManager = fileManager
        self.afterMarkerCreated = afterMarkerCreated
    }

    func persistAutomaticRejection(
        callID: Int64,
        detectorFingerprint: String
    ) throws -> CallPrivacyIntentReceipt {
        let receipt = try makeReceipt(
            callID: callID,
            detectorFingerprint: detectorFingerprint
        )
        var markerCreated = false
        do {
            let (_, handle) = try secureRoot.createWritableFile(
                relativePath: receipt.relativePath
            )
            markerCreated = true
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try afterMarkerCreated()
            // Persist both the marker and a newly-created calls/<id> directory entry.
            try secureRoot.synchronizeParent(relativePath: receipt.relativePath)
            try secureRoot.synchronizeParent(relativePath: "calls/\(callID)")
            try secureRoot.synchronizeParent(relativePath: "calls")
        } catch CallSpoolError.fileAlreadyExists {
            guard try validateExisting(receipt) else {
                throw CallPrivacyIntentJournalError.unsafeReceipt
            }
        } catch {
            if markerCreated {
                // Never report a failed privacy preflight while a live canonical receipt remains.
                // `removeFile` fsyncs the call directory. If an external volume is temporarily
                // unavailable, stay on the blocking utility queue until absence is durably known;
                // the MainActor remains responsive and physical audio teardown has not begun.
                durablyRollbackIncompleteReceipt(receipt)
            }
            throw error
        }
        return receipt
    }

    func contains(_ receipt: CallPrivacyIntentReceipt) throws -> Bool {
        guard try makeReceipt(
            callID: receipt.callID,
            detectorFingerprint: receipt.detectorFingerprint
        ) == receipt else {
            throw CallPrivacyIntentJournalError.invalidReceipt
        }
        guard fileManager.fileExists(
            atPath: mediaRoot.appendingPathComponent(receipt.relativePath).path
        ) else { return false }
        return try validateExisting(receipt)
    }

    func pendingAutomaticRejections() throws -> [CallPrivacyIntentReceipt] {
        let callsRoot = mediaRoot.appendingPathComponent("calls", isDirectory: true)
        var callsRootInfo = stat()
        let callsRootStatus = callsRoot.path.withCString {
            lstat($0, &callsRootInfo)
        }
        if callsRootStatus != 0 {
            if errno == ENOENT { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (callsRootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw CallPrivacyIntentJournalError.unsafeReceipt
        }

        var receipts: [CallPrivacyIntentReceipt] = []
        var seenCallIDs: Set<Int64> = []
        for callEntry in try secureRoot.directoryEntries(relativePath: "calls") {
            guard callEntry.kind != .symbolicLink else {
                throw CallPrivacyIntentJournalError.unsafeReceipt
            }
            guard let callID = Int64(callEntry.name), callID > 0 else { continue }
            guard callEntry.kind == .directory else {
                throw CallPrivacyIntentJournalError.unsafeReceipt
            }
            let callRelativePath = "calls/\(callID)"
            for entry in try secureRoot.directoryEntries(relativePath: callRelativePath) {
                guard entry.kind != .symbolicLink else {
                    throw CallPrivacyIntentJournalError.unsafeReceipt
                }
                let name = entry.name
                guard name.hasPrefix(".privacy-reject-") else { continue }
                guard entry.kind == .regularFile,
                      name.hasPrefix(Self.prefix),
                      name.hasSuffix(Self.suffix)
                else {
                    throw CallPrivacyIntentJournalError.invalidReceipt
                }
                let fingerprintStart = name.index(
                    name.startIndex,
                    offsetBy: Self.prefix.count
                )
                let fingerprintEnd = name.index(
                    name.endIndex,
                    offsetBy: -Self.suffix.count
                )
                let fingerprint = String(name[fingerprintStart..<fingerprintEnd])
                let receipt = try makeReceipt(
                    callID: callID,
                    detectorFingerprint: fingerprint
                )
                guard receipt.relativePath == "\(callRelativePath)/\(name)",
                      seenCallIDs.insert(callID).inserted,
                      try validateExisting(receipt)
                else {
                    throw CallPrivacyIntentJournalError.unsafeReceipt
                }
                receipts.append(receipt)
            }
        }
        return receipts.sorted { $0.callID < $1.callID }
    }

    func remove(_ receipt: CallPrivacyIntentReceipt) throws {
        guard try makeReceipt(
            callID: receipt.callID,
            detectorFingerprint: receipt.detectorFingerprint
        ) == receipt else {
            throw CallPrivacyIntentJournalError.invalidReceipt
        }
        _ = try secureRoot.removeFile(relativePath: receipt.relativePath)
    }

    private func makeReceipt(
        callID: Int64,
        detectorFingerprint: String
    ) throws -> CallPrivacyIntentReceipt {
        guard callID > 0,
              detectorFingerprint.count == 64,
              detectorFingerprint.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              })
        else {
            throw CallPrivacyIntentJournalError.invalidReceipt
        }
        let filename = "\(Self.prefix)\(detectorFingerprint)\(Self.suffix)"
        return CallPrivacyIntentReceipt(
            callID: callID,
            detectorFingerprint: detectorFingerprint,
            relativePath: "calls/\(callID)/\(filename)"
        )
    }

    private func validateExisting(_ receipt: CallPrivacyIntentReceipt) throws -> Bool {
        let isEmpty = try secureRoot.readPrefix(
            relativePath: receipt.relativePath,
            byteCount: 1
        ).isEmpty
        guard isEmpty else { return false }
        try secureRoot.synchronizeFile(relativePath: receipt.relativePath)
        try secureRoot.synchronizeParent(relativePath: receipt.relativePath)
        try secureRoot.synchronizeParent(relativePath: "calls/\(receipt.callID)")
        try secureRoot.synchronizeParent(relativePath: "calls")
        return true
    }

    private func durablyRollbackIncompleteReceipt(
        _ receipt: CallPrivacyIntentReceipt
    ) {
        var retryDelay: TimeInterval = 0.05
        while true {
            do {
                let removed = try secureRoot.removeFile(
                    relativePath: receipt.relativePath
                )
                if !removed {
                    // A previous unlink may have succeeded before its fsync failed.
                    try secureRoot.synchronizeParent(
                        relativePath: receipt.relativePath
                    )
                }
                return
            } catch {
                Thread.sleep(forTimeInterval: retryDelay)
                retryDelay = min(retryDelay * 2, 1)
            }
        }
    }
}

/// All privacy-journal filesystem work runs on one blocking utility queue. This keeps fsync,
/// directory traversal, and slow external-volume I/O off MainActor and Swift's cooperative pool.
/// `FileManager` is captured only by that serial queue and never mutated by Eye.
struct CallPrivacyIntentJournalExecutor: @unchecked Sendable {
    private static let queue = DispatchQueue(
        label: "gg.zbs.eye.call-privacy-intent-journal",
        qos: .utility
    )

    private let mediaRoot: URL
    private let fileManager: FileManager

    init(mediaRoot: URL, fileManager: FileManager = .default) {
        self.mediaRoot = mediaRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    func persistAutomaticRejection(
        callID: Int64,
        detectorFingerprint: String
    ) async throws -> CallPrivacyIntentReceipt {
        try await perform {
            try $0.persistAutomaticRejection(
                callID: callID,
                detectorFingerprint: detectorFingerprint
            )
        }
    }

    func pendingAutomaticRejections() async throws -> [CallPrivacyIntentReceipt] {
        try await perform { try $0.pendingAutomaticRejections() }
    }

    func contains(_ receipt: CallPrivacyIntentReceipt) async throws -> Bool {
        try await perform { try $0.contains(receipt) }
    }

    func remove(_ receipt: CallPrivacyIntentReceipt) async throws {
        try await perform { try $0.remove(receipt) }
    }

    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable (CallPrivacyIntentJournal) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do {
                    let journal = try CallPrivacyIntentJournal(
                        mediaRoot: self.mediaRoot,
                        fileManager: self.fileManager
                    )
                    continuation.resume(returning: try operation(journal))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
