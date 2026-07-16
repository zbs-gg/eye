import CryptoKit
import Foundation

enum CallRedactionPlanError: Error, Sendable, Equatable {
    case invalidRange
    case invalidChunk
    case stagedFileMismatch
}

struct CallRedactionChunkManifest: Codable, Sendable, Equatable {
    var sourceSpanID: Int64
    var source: CallAudioSource
    var epoch: Int
    var sequence: Int
    var startSample: Int64
    var endSample: Int64
    var startMs: Int64
    var endMs: Int64
    var sourceRelativePath: String
    var sourceOffsetBytes: Int64
    var relativePath: String
    var bytes: Int64
    var sha256: String
}

struct CallRedactionGapManifest: Codable, Sendable, Equatable {
    var source: CallAudioSource
    var startMs: Int64
    var endMs: Int64
}

struct CallRedactionManifestV1: Codable, Sendable, Equatable {
    static let formatVersion = 1

    var formatVersion: Int
    var callID: Int64
    var fromGeneration: Int
    var toGeneration: Int
    var fromMs: Int64
    var toMs: Int64
    var bytesRemoved: Int64
    var obsoleteRelativePaths: [String]
    var redactedGaps: [CallRedactionGapManifest]
    var survivors: [CallRedactionChunkManifest]

    func encodedJSON() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    static func decode(_ json: String) -> Self? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

struct CallRedactionPlanner: Sendable {
    private let secureRoot: SecureCallSpoolRoot

    init(mediaRoot: URL) throws {
        secureRoot = try SecureCallSpoolRoot(root: mediaRoot)
    }

    func makeManifest(
        snapshot: CallRedactionSourceSnapshot,
        fromMs requestedFromMs: Int64,
        toMs requestedToMs: Int64
    ) throws -> CallRedactionManifestV1 {
        guard let callID = snapshot.call.id,
              snapshot.call.state != .recording,
              let callEnd = snapshot.call.endTs,
              requestedFromMs < requestedToMs else {
            throw CallRedactionPlanError.invalidRange
        }
        let fromMs = max(snapshot.call.startTs, requestedFromMs)
        let toMs = min(callEnd, requestedToMs)
        guard fromMs < toMs else { throw CallRedactionPlanError.invalidRange }
        let nextGenerationResult = snapshot.call.mediaGeneration.addingReportingOverflow(1)
        guard !nextGenerationResult.overflow else { throw CallRedactionPlanError.invalidRange }
        let nextGeneration = nextGenerationResult.partialValue
        let spans = Dictionary(
            uniqueKeysWithValues: snapshot.spans.compactMap { span in
                span.id.map { ($0, span) }
            }
        )

        var survivors: [CallRedactionChunkManifest] = []
        var obsoletePaths: [String] = []
        var redactedGapsBySource: [String: CallRedactionGapManifest] = [:]
        var bytesRemoved: Int64 = 0
        for chunk in snapshot.chunks.sorted(by: Self.chunkOrder) {
            let sampleCount = chunk.endSample.subtractingReportingOverflow(chunk.startSample)
            let expectedBytes = sampleCount.partialValue.multipliedReportingOverflow(by: 2)
            guard chunk.finalized,
                  chunk.bytes > 0,
                  chunk.bytes <= Int64(Int.max),
                  chunk.bytes.isMultiple(of: 2),
                  chunk.mediaGeneration == snapshot.call.mediaGeneration,
                  !sampleCount.overflow,
                  sampleCount.partialValue > 0,
                  !expectedBytes.overflow,
                  chunk.bytes == expectedBytes.partialValue,
                  let span = spans[chunk.sourceSpanId],
                  span.sampleRate > 0 else {
                throw CallRedactionPlanError.invalidChunk
            }
            let original = try secureRoot.readRange(
                relativePath: chunk.relativePath,
                offset: 0,
                byteCount: Int(chunk.bytes)
            )
            guard original.count == Int(chunk.bytes) else {
                throw CallRedactionPlanError.invalidChunk
            }
            let originalHash = Self.digest(original)
            if let expected = chunk.sha256, !expected.isEmpty, expected != originalHash {
                throw CallRedactionPlanError.invalidChunk
            }

            let cutStart = max(
                chunk.startSample,
                Self.sampleFloor(atMs: fromMs, span: span)
            )
            let cutEnd = min(
                chunk.endSample,
                Self.sampleCeil(atMs: toMs, span: span)
            )
            guard cutStart < cutEnd,
                  chunk.endMs > fromMs,
                  chunk.startMs < toMs else {
                survivors.append(
                    Self.fragment(
                        chunk: chunk,
                        startSample: chunk.startSample,
                        endSample: chunk.endSample,
                        startMs: chunk.startMs,
                        endMs: chunk.endMs,
                        sourceOffsetBytes: 0,
                        relativePath: chunk.relativePath,
                        bytes: chunk.bytes,
                        sha256: originalHash
                    )
                )
                continue
            }

            obsoletePaths.append(chunk.relativePath)
            let actualGapStart = max(chunk.startMs, Self.timeMs(for: cutStart, span: span))
            let actualGapEnd = min(chunk.endMs, Self.timeMs(for: cutEnd, span: span))
            if let previous = redactedGapsBySource[chunk.source.rawValue] {
                redactedGapsBySource[chunk.source.rawValue] = CallRedactionGapManifest(
                    source: chunk.source,
                    startMs: min(previous.startMs, actualGapStart),
                    endMs: max(previous.endMs, actualGapEnd)
                )
            } else {
                redactedGapsBySource[chunk.source.rawValue] = CallRedactionGapManifest(
                    source: chunk.source,
                    startMs: actualGapStart,
                    endMs: actualGapEnd
                )
            }
            let removedBytes = (cutEnd - cutStart) * 2
            let removedTotal = bytesRemoved.addingReportingOverflow(removedBytes)
            bytesRemoved = removedTotal.overflow ? Int64.max : removedTotal.partialValue

            if cutStart > chunk.startSample {
                let length = (cutStart - chunk.startSample) * 2
                let data = original.prefix(Int(length))
                survivors.append(
                    Self.fragment(
                        chunk: chunk,
                        startSample: chunk.startSample,
                        endSample: cutStart,
                        startMs: chunk.startMs,
                        endMs: min(chunk.endMs, Self.timeMs(for: cutStart, span: span)),
                        sourceOffsetBytes: 0,
                        relativePath: Self.replacementPath(
                            chunk: chunk,
                            generation: nextGeneration,
                            suffix: "prefix"
                        ),
                        bytes: length,
                        sha256: Self.digest(Data(data))
                    )
                )
            }
            if cutEnd < chunk.endSample {
                let offset = (cutEnd - chunk.startSample) * 2
                let length = (chunk.endSample - cutEnd) * 2
                let range = Int(offset)..<Int(offset + length)
                survivors.append(
                    Self.fragment(
                        chunk: chunk,
                        startSample: cutEnd,
                        endSample: chunk.endSample,
                        startMs: max(chunk.startMs, Self.timeMs(for: cutEnd, span: span)),
                        endMs: chunk.endMs,
                        sourceOffsetBytes: offset,
                        relativePath: Self.replacementPath(
                            chunk: chunk,
                            generation: nextGeneration,
                            suffix: "suffix"
                        ),
                        bytes: length,
                        sha256: Self.digest(original.subdata(in: range))
                    )
                )
            }
        }

        survivors.sort {
            ($0.source.rawValue, $0.epoch, $0.startSample, $0.relativePath)
                < ($1.source.rawValue, $1.epoch, $1.startSample, $1.relativePath)
        }
        var nextSequence: [String: Int] = [:]
        for index in survivors.indices {
            let key = "\(survivors[index].source.rawValue):\(survivors[index].epoch)"
            survivors[index].sequence = nextSequence[key, default: 0]
            nextSequence[key, default: 0] += 1
        }

        let redactedGaps = redactedGapsBySource.values.sorted {
            ($0.source.rawValue, $0.startMs, $0.endMs)
                < ($1.source.rawValue, $1.startMs, $1.endMs)
        }
        return CallRedactionManifestV1(
            formatVersion: Self.formatVersion,
            callID: callID,
            fromGeneration: snapshot.call.mediaGeneration,
            toGeneration: nextGeneration,
            fromMs: fromMs,
            toMs: toMs,
            bytesRemoved: bytesRemoved,
            obsoleteRelativePaths: Array(Set(obsoletePaths)).sorted(),
            redactedGaps: redactedGaps,
            survivors: survivors
        )
    }

    private static let formatVersion = CallRedactionManifestV1.formatVersion

    private static func chunkOrder(_ lhs: CallAudioChunkRow, _ rhs: CallAudioChunkRow) -> Bool {
        (lhs.source.rawValue, lhs.epoch, lhs.sequence, lhs.id ?? 0)
            < (rhs.source.rawValue, rhs.epoch, rhs.sequence, rhs.id ?? 0)
    }

    private static func fragment(
        chunk: CallAudioChunkRow,
        startSample: Int64,
        endSample: Int64,
        startMs: Int64,
        endMs: Int64,
        sourceOffsetBytes: Int64,
        relativePath: String,
        bytes: Int64,
        sha256: String
    ) -> CallRedactionChunkManifest {
        CallRedactionChunkManifest(
            sourceSpanID: chunk.sourceSpanId,
            source: chunk.source,
            epoch: chunk.epoch,
            sequence: 0,
            startSample: startSample,
            endSample: endSample,
            startMs: startMs,
            endMs: endMs,
            sourceRelativePath: chunk.relativePath,
            sourceOffsetBytes: sourceOffsetBytes,
            relativePath: relativePath,
            bytes: bytes,
            sha256: sha256
        )
    }

    private static func replacementPath(
        chunk: CallAudioChunkRow,
        generation: Int,
        suffix: String
    ) -> String {
        "calls/\(chunk.callId)/\(chunk.source.rawValue)/epoch-\(String(format: "%04d", chunk.epoch))/redacted-g\(String(format: "%04d", generation))-c\(String(format: "%06d", chunk.sequence))-\(suffix).pcm"
    }

    private static func sampleFloor(atMs timeMs: Int64, span: CallSourceSpanRow) -> Int64 {
        guard timeMs > span.startedAtMs else { return span.startSample }
        let delta = timeMs - span.startedAtMs
        let scaled = delta.multipliedReportingOverflow(by: Int64(span.sampleRate))
        guard !scaled.overflow else { return Int64.max }
        let result = span.startSample.addingReportingOverflow(scaled.partialValue / 1_000)
        return result.overflow ? Int64.max : result.partialValue
    }

    private static func sampleCeil(atMs timeMs: Int64, span: CallSourceSpanRow) -> Int64 {
        guard timeMs > span.startedAtMs else { return span.startSample }
        let delta = timeMs - span.startedAtMs
        let scaled = delta.multipliedReportingOverflow(by: Int64(span.sampleRate))
        guard !scaled.overflow else { return Int64.max }
        let rounded = scaled.partialValue.addingReportingOverflow(999)
        guard !rounded.overflow else { return Int64.max }
        let result = span.startSample.addingReportingOverflow(rounded.partialValue / 1_000)
        return result.overflow ? Int64.max : result.partialValue
    }

    private static func timeMs(for sample: Int64, span: CallSourceSpanRow) -> Int64 {
        let delta = max(0, sample - span.startSample)
        let scaled = delta.multipliedReportingOverflow(by: 1_000)
        guard !scaled.overflow else { return Int64.max }
        let result = span.startedAtMs.addingReportingOverflow(
            scaled.partialValue / Int64(span.sampleRate)
        )
        return result.overflow ? Int64.max : result.partialValue
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct CallRedactionFileStore {
    private let secureRoot: SecureCallSpoolRoot

    init(mediaRoot: URL) throws {
        secureRoot = try SecureCallSpoolRoot(root: mediaRoot)
    }

    func stageAndVerify(_ manifest: CallRedactionManifestV1) throws {
        guard manifest.formatVersion == CallRedactionManifestV1.formatVersion else {
            throw CallRedactionPlanError.stagedFileMismatch
        }
        for survivor in manifest.survivors {
            let data = try secureRoot.readRange(
                relativePath: survivor.sourceRelativePath,
                offset: survivor.sourceOffsetBytes,
                byteCount: Int(survivor.bytes)
            )
            guard data.count == Int(survivor.bytes), Self.digest(data) == survivor.sha256 else {
                throw CallRedactionPlanError.stagedFileMismatch
            }
            if survivor.relativePath == survivor.sourceRelativePath { continue }
            try writeVerified(data, survivor: survivor)
        }
    }

    func removeObsolete(_ manifest: CallRedactionManifestV1) throws -> Int {
        let live = Set(manifest.survivors.map(\.relativePath))
        var removed = 0
        for path in manifest.obsoleteRelativePaths where !live.contains(path) {
            if try secureRoot.removeFile(relativePath: path) {
                removed += 1
            }
        }
        return removed
    }

    private func writeVerified(_ data: Data, survivor: CallRedactionChunkManifest) throws {
        do {
            let existing = try secureRoot.readRange(
                relativePath: survivor.relativePath,
                offset: 0,
                byteCount: Int(survivor.bytes)
            )
            if existing.count == Int(survivor.bytes), Self.digest(existing) == survivor.sha256 {
                return
            }
            _ = try secureRoot.removeFile(relativePath: survivor.relativePath)
        } catch let error as POSIXError where error.code == .ENOENT {
            // Expected on the first attempt.
        }
        let (_, handle) = try secureRoot.createWritableFile(relativePath: survivor.relativePath)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try secureRoot.synchronizeParent(relativePath: survivor.relativePath)
        } catch {
            try? handle.close()
            throw error
        }
        let written = try secureRoot.readRange(
            relativePath: survivor.relativePath,
            offset: 0,
            byteCount: Int(survivor.bytes)
        )
        guard written.count == Int(survivor.bytes), Self.digest(written) == survivor.sha256 else {
            throw CallRedactionPlanError.stagedFileMismatch
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

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
