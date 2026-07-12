import CryptoKit
import Darwin
import Foundation
import GRDB

enum ScreenUnderstandingDatasetError: Error, LocalizedError, Equatable {
    case invalidPolicy(String)
    case invalidMedia(String)
    case existingCorpus(String)
    case sourceChanged(String)

    var errorDescription: String? {
        switch self {
        case .invalidPolicy(let message), .invalidMedia(let message),
             .existingCorpus(let message), .sourceChanged(let message):
            message
        }
    }
}

struct ScreenUnderstandingDatasetPolicy {
    static func validate(
        sourceRoot: URL,
        outputRoot: URL,
        repositoryRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let source = canonical(sourceRoot)
        let output = canonical(outputRoot)
        let repository = canonical(repositoryRoot)

        guard source != output,
              !contains(source, output),
              !contains(output, source) else {
            throw ScreenUnderstandingDatasetError.invalidPolicy(
                "Source and output roots must be disjoint"
            )
        }
        let outputPath = output.path.lowercased()
        guard !outputPath.contains("/library/mobile documents/"),
              !outputPath.contains("/cloudstorage/") else {
            throw ScreenUnderstandingDatasetError.invalidPolicy(
                "Cloud-synchronized destinations are forbidden"
            )
        }
        if contains(repository, output) {
            let relative = output.path.dropFirst(repository.path.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard relative == "build" || relative.hasPrefix("build/") else {
                throw ScreenUnderstandingDatasetError.invalidPolicy(
                    "Repository destinations must remain below gitignored build/"
                )
            }
        }
        let parent = output.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path) else {
            throw ScreenUnderstandingDatasetError.invalidPolicy(
                "Output parent must already exist"
            )
        }
        let values = try parent.resourceValues(forKeys: [.volumeIsLocalKey])
        guard values.volumeIsLocal != false else {
            throw ScreenUnderstandingDatasetError.invalidPolicy(
                "Network-volume destinations are forbidden"
            )
        }
    }

    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let lhs = canonical(parent).pathComponents.map { $0.lowercased() }
        let rhs = canonical(child).pathComponents.map { $0.lowercased() }
        guard lhs.count <= rhs.count else { return false }
        return Array(rhs.prefix(lhs.count)) == lhs
    }

    static func resolvedMediaURL(mediaRoot: URL, relativePath: String) throws -> URL {
        let components = NSString(string: relativePath).pathComponents
        guard !relativePath.hasPrefix("/"),
              !components.contains(".."),
              !components.contains("."),
              !relativePath.contains("\\") else {
            throw ScreenUnderstandingDatasetError.invalidMedia("Media traversal is forbidden")
        }
        let root = canonical(mediaRoot)
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard contains(root, candidate) else {
            throw ScreenUnderstandingDatasetError.invalidMedia("Media escaped its root")
        }
        return candidate
    }
}

struct ScreenUnderstandingDatasetManifest: Codable, Equatable, Sendable {
    struct Case: Codable, Equatable, Sendable {
        let id: String
        let contextSHA256: String
        let mediaFile: String?
        let mediaSHA256: String?
        let strata: [String]
        let baselineOnly: Bool
    }

    let protocolID: String
    let revision: Int
    let snapshotSHA256: String
    let cases: [Case]
    let naturalisticTraceSHA256: String
    let labelsLockedBeforeOutputs: Bool
    let purgeAfterDecisionDays: Int
}

struct ScreenUnderstandingPrivateContext: Codable, Equatable, Sendable {
    let appName: String?
    let windowTitle: String?
    let browserURL: String?
    let monitorID: String
    let text: String
    let textSources: [String]
    let timestampMs: Int64
}

struct ScreenUnderstandingTraceEntry: Codable, Equatable, Sendable {
    let id: String
    let deltaMs: Int64
    let monitorIDHash: String
    let hasPixels: Bool
    let hasAX: Bool
    let hasOCR: Bool
}

struct ScreenUnderstandingDatasetCandidate: Sendable, Equatable {
    let sourceID: Int64
    let timestampMs: Int64
    let appName: String?
    let windowTitle: String?
    let browserURL: String?
    let monitorID: String
    let relativePath: String?
    let text: String
    let textSources: [String]

    var baselineOnly: Bool { relativePath == nil }

    var strata: [String] {
        var value: [String] = []
        value.append(baselineOnly ? "context-only" : "image-bearing")
        if text.count >= 240 { value.append("text-rich") }
        if text.isEmpty { value.append("visual-sparse") }
        if text.unicodeScalars.contains(where: { $0.value > 0x7F }) {
            value.append("mixed-script")
        }
        if textSources.contains("ax") { value.append("ax") }
        if textSources.contains("ocr") { value.append("ocr") }
        return value.sorted()
    }

    var primaryStratum: String {
        if baselineOnly { return "context-only" }
        if text.isEmpty { return "visual-sparse" }
        if text.count >= 240 { return "text-rich" }
        return "mixed"
    }
}

enum ScreenUnderstandingDatasetSampler {
    static func balanced(
        _ candidates: [ScreenUnderstandingDatasetCandidate],
        limit: Int
    ) -> [ScreenUnderstandingDatasetCandidate] {
        guard limit > 0 else { return [] }
        var groups = Dictionary(grouping: candidates, by: \.primaryStratum)
            .mapValues { $0.sorted { lhs, rhs in
                if lhs.timestampMs == rhs.timestampMs { return lhs.sourceID < rhs.sourceID }
                return lhs.timestampMs < rhs.timestampMs
            } }
        let keys = groups.keys.sorted()
        var result: [ScreenUnderstandingDatasetCandidate] = []
        while result.count < limit {
            var progressed = false
            for key in keys where result.count < limit {
                guard var group = groups[key], !group.isEmpty else { continue }
                result.append(group.removeFirst())
                groups[key] = group
                progressed = true
            }
            if !progressed { break }
        }
        return result
    }

    static func validTemporalPair(
        before: ScreenUnderstandingDatasetCandidate,
        after: ScreenUnderstandingDatasetCandidate,
        maximumGapMs: Int64
    ) -> Bool {
        after.timestampMs > before.timestampMs
            && after.timestampMs - before.timestampMs <= maximumGapMs
            && before.monitorID == after.monitorID
            && before.appName == after.appName
            && before.relativePath != nil
            && after.relativePath != nil
    }
}

struct ScreenUnderstandingDatasetPreparer {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepare(
        sourceRoot: URL,
        outputRoot: URL,
        repositoryRoot: URL,
        labeledLimit: Int = 200
    ) throws -> ScreenUnderstandingDatasetManifest {
        try ScreenUnderstandingDatasetPolicy.validate(
            sourceRoot: sourceRoot,
            outputRoot: outputRoot,
            repositoryRoot: repositoryRoot,
            fileManager: fileManager
        )
        let source = ScreenUnderstandingDatasetPolicy.canonical(sourceRoot)
        let output = ScreenUnderstandingDatasetPolicy.canonical(outputRoot)
        guard !fileManager.fileExists(atPath: output.path) else {
            throw ScreenUnderstandingDatasetError.existingCorpus(
                "A sealed corpus already exists at the output root"
            )
        }
        let sourceDatabase = source.appendingPathComponent("zbseye.sqlite")
        let sourceMedia = source.appendingPathComponent("media", isDirectory: true)
        guard fileManager.fileExists(atPath: sourceDatabase.path),
              fileManager.fileExists(atPath: sourceMedia.path) else {
            throw ScreenUnderstandingDatasetError.invalidPolicy(
                "Explicit source root must contain zbseye.sqlite and media/"
            )
        }

        let staging = output.deletingLastPathComponent().appendingPathComponent(
            ".\(output.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var sealed = false
        defer {
            if !sealed { try? fileManager.removeItem(at: staging) }
        }
        try applyPrivateExclusions(to: staging)
        try Task.checkCancellation()

        let snapshotURL = staging.appendingPathComponent("source.sqlite")
        var configuration = Configuration()
        configuration.readonly = true
        configuration.maximumReaderCount = 1
        let sourcePool = try DatabasePool(
            path: sourceDatabase.path,
            configuration: configuration
        )
        var snapshot: DatabaseQueue? = try DatabaseQueue(path: snapshotURL.path)
        try sourcePool.backup(to: snapshot!)
        let candidates = try fetchCandidates(from: snapshot!)
        snapshot = nil
        let snapshotData = try Data(contentsOf: snapshotURL, options: [.mappedIfSafe])
        let snapshotHash = Self.sha256(snapshotData)
        try fileManager.removeItem(at: snapshotURL)

        let selected = ScreenUnderstandingDatasetSampler.balanced(
            candidates,
            limit: labeledLimit
        )
        let casesRoot = staging.appendingPathComponent("cases", isDirectory: true)
        try fileManager.createDirectory(
            at: casesRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var manifestCases: [ScreenUnderstandingDatasetManifest.Case] = []
        for candidate in selected {
            try Task.checkCancellation()
            let caseID = Self.opaqueID(for: candidate.sourceID)
            let caseRoot = casesRoot.appendingPathComponent(caseID, isDirectory: true)
            try fileManager.createDirectory(
                at: caseRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let context = ScreenUnderstandingPrivateContext(
                appName: candidate.appName,
                windowTitle: candidate.windowTitle,
                browserURL: candidate.browserURL,
                monitorID: candidate.monitorID,
                text: candidate.text,
                textSources: candidate.textSources,
                timestampMs: candidate.timestampMs
            )
            let contextData = try Self.encoder.encode(context)
            let contextURL = caseRoot.appendingPathComponent("context.json")
            try Self.writePrivate(contextData, to: contextURL)

            var mediaFile: String?
            var mediaHash: String?
            if let relativePath = candidate.relativePath {
                let sourceURL = try ScreenUnderstandingDatasetPolicy.resolvedMediaURL(
                    mediaRoot: sourceMedia,
                    relativePath: relativePath
                )
                let data = try securelyReadRegularFile(at: sourceURL)
                let destinationName = "image.heic"
                try Self.writePrivate(
                    data,
                    to: caseRoot.appendingPathComponent(destinationName)
                )
                mediaFile = "cases/\(caseID)/\(destinationName)"
                mediaHash = Self.sha256(data)
            }
            manifestCases.append(.init(
                id: caseID,
                contextSHA256: Self.sha256(contextData),
                mediaFile: mediaFile,
                mediaSHA256: mediaHash,
                strata: candidate.strata,
                baselineOnly: candidate.baselineOnly
            ))
        }

        let traceCandidates = naturalisticDay(from: candidates)
        let trace = makeTrace(traceCandidates)
        let traceData = try Self.encoder.encode(trace)
        try Self.writePrivate(
            traceData,
            to: staging.appendingPathComponent("naturalistic-trace.json")
        )
        let manifest = ScreenUnderstandingDatasetManifest(
            protocolID: "screen-understanding-v1",
            revision: 1,
            snapshotSHA256: snapshotHash,
            cases: manifestCases.sorted { $0.id < $1.id },
            naturalisticTraceSHA256: Self.sha256(traceData),
            labelsLockedBeforeOutputs: true,
            purgeAfterDecisionDays: 30
        )
        let manifestData = try Self.encoder.encode(manifest)
        try Self.writePrivate(
            manifestData,
            to: staging.appendingPathComponent("manifest.json")
        )
        try verifyManifestHasNoSourcePaths(manifestData, sourceRoot: source)
        try fileManager.moveItem(at: staging, to: output)
        sealed = true
        return manifest
    }

    private func fetchCandidates(
        from snapshot: DatabaseQueue
    ) throws -> [ScreenUnderstandingDatasetCandidate] {
        try snapshot.read { database in
            try Row.fetchAll(database, sql: """
                SELECT c.id, c.ts, a.name AS appName, c.windowTitle, c.browserUrl,
                       c.monitorId, c.relativePath,
                       COALESCE((SELECT group_concat(tb.text, ' ') FROM text_blocks tb
                                 WHERE tb.captureId = c.id), '') AS text,
                       COALESCE((SELECT group_concat(DISTINCT tb.source) FROM text_blocks tb
                                 WHERE tb.captureId = c.id), '') AS sources
                FROM screen_captures c
                LEFT JOIN apps a ON a.id = c.appId
                ORDER BY c.ts ASC, c.id ASC
                """).map { row in
                let sources: String = row["sources"]
                return ScreenUnderstandingDatasetCandidate(
                    sourceID: row["id"],
                    timestampMs: row["ts"],
                    appName: row["appName"],
                    windowTitle: row["windowTitle"],
                    browserURL: row["browserUrl"],
                    monitorID: row["monitorId"],
                    relativePath: row["relativePath"],
                    text: row["text"],
                    textSources: sources.split(separator: ",").map(String.init).sorted()
                )
            }
        }
    }

    private func naturalisticDay(
        from candidates: [ScreenUnderstandingDatasetCandidate]
    ) -> [ScreenUnderstandingDatasetCandidate] {
        let dayMs: Int64 = 86_400_000
        let grouped = Dictionary(grouping: candidates) { $0.timestampMs / dayMs }
        guard let day = grouped.keys.sorted().last else { return [] }
        return (grouped[day] ?? []).sorted { $0.timestampMs < $1.timestampMs }
    }

    private func makeTrace(
        _ candidates: [ScreenUnderstandingDatasetCandidate]
    ) -> [ScreenUnderstandingTraceEntry] {
        var previous: Int64?
        return candidates.map { candidate in
            defer { previous = candidate.timestampMs }
            return ScreenUnderstandingTraceEntry(
                id: Self.opaqueID(for: candidate.sourceID),
                deltaMs: previous.map { candidate.timestampMs - $0 } ?? 0,
                monitorIDHash: Self.sha256(Data(candidate.monitorID.utf8)),
                hasPixels: candidate.relativePath != nil,
                hasAX: candidate.textSources.contains("ax"),
                hasOCR: candidate.textSources.contains("ocr")
            )
        }
    }

    private func securelyReadRegularFile(at url: URL) throws -> Data {
        var pathStat = stat()
        guard lstat(url.path, &pathStat) == 0,
              (pathStat.st_mode & S_IFMT) == S_IFREG else {
            throw ScreenUnderstandingDatasetError.invalidMedia(
                "Selected media must be a regular non-symlink file"
            )
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var openedStat = stat()
        guard fstat(handle.fileDescriptor, &openedStat) == 0,
              openedStat.st_dev == pathStat.st_dev,
              openedStat.st_ino == pathStat.st_ino,
              openedStat.st_size == pathStat.st_size else {
            throw ScreenUnderstandingDatasetError.sourceChanged(
                "Media identity changed while opening"
            )
        }
        let data = try handle.readToEnd() ?? Data()
        var finalStat = stat()
        guard lstat(url.path, &finalStat) == 0,
              finalStat.st_dev == openedStat.st_dev,
              finalStat.st_ino == openedStat.st_ino,
              finalStat.st_size == openedStat.st_size,
              Int64(data.count) == openedStat.st_size else {
            throw ScreenUnderstandingDatasetError.sourceChanged(
                "Media was replaced or truncated during export"
            )
        }
        return data
    }

    private func applyPrivateExclusions(to root: URL) throws {
        let marker = root.appendingPathComponent(".metadata_never_index")
        try Self.writePrivate(Data(), to: marker)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try mutableRoot.setResourceValues(values)
    }

    private func verifyManifestHasNoSourcePaths(_ data: Data, sourceRoot: URL) throws {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.contains(sourceRoot.path),
              !text.contains("relativePath"),
              !text.contains("timestampMs") else {
            throw ScreenUnderstandingDatasetError.invalidPolicy(
                "Portable manifest contains source path or timestamp material"
            )
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func opaqueID(for sourceID: Int64) -> String {
        String(sha256(Data("screen-understanding-v1:\(sourceID)".utf8)).prefix(24))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
