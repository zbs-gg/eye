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

    struct TemporalPair: Codable, Equatable, Sendable {
        let id: String
        let beforeCaseID: String
        let afterCaseID: String
        let deltaMs: Int64
        let strata: [String]
    }

    let protocolID: String
    let revision: Int
    let snapshotSHA256: String
    let sourceImageRows: Int
    let availableImageRows: Int
    let missingMediaRows: Int
    let cases: [Case]
    let singleFrameCaseIDs: [String]
    let baselineOnlyCaseIDs: [String]
    let temporalPairs: [TemporalPair]
    let splits: ScreenUnderstandingDatasetSplits
    let splitSHA256: String
    let naturalisticTraceSHA256: String
    let labelsLockedBeforeOutputs: Bool
    let purgeAfterDecisionDays: Int
}

struct ScreenUnderstandingDatasetSplits: Codable, Equatable, Sendable {
    let tuneSingleFrames: [String]
    let validationSingleFrames: [String]
    let testSingleFrames: [String]
    let tuneTemporalPairs: [String]
    let validationTemporalPairs: [String]
    let testTemporalPairs: [String]
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

struct ScreenUnderstandingNaturalisticTrace: Codable, Equatable, Sendable {
    let schema: String
    let calendarIdentifier: String
    let timeZoneIdentifier: String
    let localDayStartMs: Int64
    let localDayEndMs: Int64
    let minimumElapsedCoverageMs: Int64
    let minimumActivityCount: Int
    let observedElapsedMs: Int64
    let activityCount: Int
    let entries: [ScreenUnderstandingTraceEntry]
}

struct ScreenUnderstandingNaturalisticTracePolicy: Sendable {
    let calendar: Calendar
    let now: Date
    let minimumElapsedCoverageMs: Int64
    let minimumActivityCount: Int
}

struct ScreenUnderstandingMediaFingerprint: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        size = Int64(metadata.st_size)
        modificationSeconds = Int64(metadata.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
        changeSeconds = Int64(metadata.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
    }
}

struct ScreenUnderstandingDatasetCandidate: Sendable, Equatable {
    let sourceID: Int64
    let timestampMs: Int64
    let appName: String?
    let windowTitle: String?
    let browserURL: String?
    let monitorID: String
    let relativePath: String?
    let mediaFingerprint: ScreenUnderstandingMediaFingerprint?
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

    var sceneKey: String {
        [appName ?? "", windowTitle ?? "", browserURL ?? "", monitorID]
            .joined(separator: "\u{1F}")
    }
}

struct ScreenUnderstandingTemporalCandidatePair: Sendable, Equatable {
    let before: ScreenUnderstandingDatasetCandidate
    let after: ScreenUnderstandingDatasetCandidate

    var deltaMs: Int64 { after.timestampMs - before.timestampMs }

    var strata: [String] {
        var value = Set(before.strata + after.strata)
        value.insert("temporal-change")
        return value.sorted()
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
            && before.sceneKey == after.sceneKey
            && before.relativePath != nil
            && after.relativePath != nil
    }

    static func temporalPairs(
        _ candidates: [ScreenUnderstandingDatasetCandidate],
        limit: Int,
        maximumGapMs: Int64
    ) -> [ScreenUnderstandingTemporalCandidatePair] {
        guard limit > 0 else { return [] }
        let imageBearing = candidates.filter { $0.relativePath != nil }
        let groups = Dictionary(grouping: imageBearing, by: \.sceneKey)
        let pairs = groups.values.flatMap { group -> [ScreenUnderstandingTemporalCandidatePair] in
            let ordered = group.sorted {
                if $0.timestampMs == $1.timestampMs { return $0.sourceID < $1.sourceID }
                return $0.timestampMs < $1.timestampMs
            }
            guard ordered.count > 1 else { return [] }
            return zip(ordered, ordered.dropFirst()).compactMap { before, after in
                guard validTemporalPair(
                    before: before,
                    after: after,
                    maximumGapMs: maximumGapMs
                ) else { return nil }
                return ScreenUnderstandingTemporalCandidatePair(before: before, after: after)
            }
        }.sorted {
            if $0.after.timestampMs == $1.after.timestampMs {
                return $0.after.sourceID < $1.after.sourceID
            }
            return $0.after.timestampMs < $1.after.timestampMs
        }
        return Array(pairs.prefix(limit))
    }
}

struct ScreenUnderstandingDatasetPreparer {
    private let fileManager: FileManager
    private let tracePolicy: ScreenUnderstandingNaturalisticTracePolicy
    private let beforeMediaCopy: ((URL) throws -> Void)?

    init(
        fileManager: FileManager = .default,
        tracePolicy: ScreenUnderstandingNaturalisticTracePolicy,
        beforeMediaCopy: ((URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.tracePolicy = tracePolicy
        self.beforeMediaCopy = beforeMediaCopy
    }

    func prepare(
        sourceRoot: URL,
        outputRoot: URL,
        repositoryRoot: URL,
        labeledLimit: Int = 200,
        temporalPairLimit: Int = 100,
        baselineOnlyLimit: Int = 30
    ) throws -> ScreenUnderstandingDatasetManifest {
        guard tracePolicy.minimumElapsedCoverageMs > 0,
              tracePolicy.minimumActivityCount > 0 else {
            throw ScreenUnderstandingDatasetError.invalidPolicy(
                "Naturalistic trace coverage minimums must be positive"
            )
        }
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
        let snapshotCandidates = try fetchCandidates(from: snapshot!)
        try snapshot!.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try database.execute(sql: "PRAGMA journal_mode=DELETE")
        }
        snapshot = nil
        let snapshotData = try Data(contentsOf: snapshotURL, options: [.mappedIfSafe])
        let snapshotHash = Self.sha256(snapshotData)
        try fileManager.removeItem(at: snapshotURL)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: snapshotURL.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.removeItem(at: sidecar)
            }
        }
        guard try fileManager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        ).allSatisfy({ !$0.lastPathComponent.hasPrefix("source.sqlite") }) else {
            throw ScreenUnderstandingDatasetError.invalidPolicy(
                "Private database snapshot sidecar survived cleanup"
            )
        }

        let reconciliation = try reconcileCandidates(
            snapshotCandidates,
            mediaRoot: sourceMedia
        )
        let candidates = reconciliation.candidates
        let trace = try naturalisticTrace(from: candidates)
        let traceData = try Self.encoder.encode(trace)
        let selected = ScreenUnderstandingDatasetSampler.balanced(
            candidates.filter { !$0.baselineOnly },
            limit: labeledLimit
        )
        let selectedBaselineOnly = ScreenUnderstandingDatasetSampler.balanced(
            candidates.filter(\.baselineOnly),
            limit: baselineOnlyLimit
        )
        let temporalPairs = ScreenUnderstandingDatasetSampler.temporalPairs(
            candidates,
            limit: temporalPairLimit,
            maximumGapMs: 300_000
        )
        var selectedByID = Dictionary(
            uniqueKeysWithValues: (selected + selectedBaselineOnly).map { ($0.sourceID, $0) }
        )
        for pair in temporalPairs {
            selectedByID[pair.before.sourceID] = pair.before
            selectedByID[pair.after.sourceID] = pair.after
        }
        let allSelected = selectedByID.values.sorted {
            if $0.timestampMs == $1.timestampMs { return $0.sourceID < $1.sourceID }
            return $0.timestampMs < $1.timestampMs
        }
        let casesRoot = staging.appendingPathComponent("cases", isDirectory: true)
        try fileManager.createDirectory(
            at: casesRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var manifestCases: [ScreenUnderstandingDatasetManifest.Case] = []
        for candidate in allSelected {
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
                guard let expectedFingerprint = candidate.mediaFingerprint else {
                    throw ScreenUnderstandingDatasetError.sourceChanged(
                        "Selected media has no reconciled source fingerprint"
                    )
                }
                try beforeMediaCopy?(sourceURL)
                let data = try securelyReadRegularFile(
                    at: sourceURL,
                    expectedFingerprint: expectedFingerprint
                )
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

        try Self.writePrivate(
            traceData,
            to: staging.appendingPathComponent("naturalistic-trace.json")
        )
        let manifestPairs = temporalPairs.map { pair in
            let beforeID = Self.opaqueID(for: pair.before.sourceID)
            let afterID = Self.opaqueID(for: pair.after.sourceID)
            return ScreenUnderstandingDatasetManifest.TemporalPair(
                id: Self.temporalPairID(beforeID: beforeID, afterID: afterID),
                beforeCaseID: beforeID,
                afterCaseID: afterID,
                deltaMs: pair.deltaMs,
                strata: pair.strata
            )
        }
        let singleFrameCaseIDs = selected.map { Self.opaqueID(for: $0.sourceID) }.sorted()
        let baselineOnlyCaseIDs = selectedBaselineOnly
            .map { Self.opaqueID(for: $0.sourceID) }.sorted()
        let splits = Self.makeSplits(
            singleFrameIDs: singleFrameCaseIDs,
            temporalPairIDs: manifestPairs.map(\.id)
        )
        let splitData = try Self.encoder.encode(splits)
        let manifest = ScreenUnderstandingDatasetManifest(
            protocolID: "screen-understanding-v1",
            revision: 1,
            snapshotSHA256: snapshotHash,
            sourceImageRows: reconciliation.sourceImageRows,
            availableImageRows: reconciliation.availableImageRows,
            missingMediaRows: reconciliation.missingMediaRows,
            cases: manifestCases.sorted { $0.id < $1.id },
            singleFrameCaseIDs: singleFrameCaseIDs,
            baselineOnlyCaseIDs: baselineOnlyCaseIDs,
            temporalPairs: manifestPairs,
            splits: splits,
            splitSHA256: Self.sha256(splitData),
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
                    mediaFingerprint: nil,
                    text: row["text"],
                    textSources: sources.split(separator: ",").map(String.init).sorted()
                )
            }
        }
    }

    private func reconcileCandidates(
        _ candidates: [ScreenUnderstandingDatasetCandidate],
        mediaRoot: URL
    ) throws -> (
        candidates: [ScreenUnderstandingDatasetCandidate],
        sourceImageRows: Int,
        availableImageRows: Int,
        missingMediaRows: Int
    ) {
        var sourceImageRows = 0
        var availableImageRows = 0
        var missingMediaRows = 0
        let reconciled = try candidates.map { candidate in
            guard let relativePath = candidate.relativePath else { return candidate }
            sourceImageRows += 1
            let mediaURL = try ScreenUnderstandingDatasetPolicy.resolvedMediaURL(
                mediaRoot: mediaRoot,
                relativePath: relativePath
            )
            var mediaStat = stat()
            if lstat(mediaURL.path, &mediaStat) != 0 {
                guard errno == ENOENT else {
                    throw ScreenUnderstandingDatasetError.invalidMedia(
                        "Selected media could not be reconciled"
                    )
                }
                missingMediaRows += 1
                return ScreenUnderstandingDatasetCandidate(
                    sourceID: candidate.sourceID,
                    timestampMs: candidate.timestampMs,
                    appName: candidate.appName,
                    windowTitle: candidate.windowTitle,
                    browserURL: candidate.browserURL,
                    monitorID: candidate.monitorID,
                    relativePath: nil,
                    mediaFingerprint: nil,
                    text: candidate.text,
                    textSources: candidate.textSources
                )
            }
            guard (mediaStat.st_mode & S_IFMT) == S_IFREG else {
                throw ScreenUnderstandingDatasetError.invalidMedia(
                    "Reconciled media must be a regular non-symlink file"
                )
            }
            availableImageRows += 1
            return ScreenUnderstandingDatasetCandidate(
                sourceID: candidate.sourceID,
                timestampMs: candidate.timestampMs,
                appName: candidate.appName,
                windowTitle: candidate.windowTitle,
                browserURL: candidate.browserURL,
                monitorID: candidate.monitorID,
                relativePath: candidate.relativePath,
                mediaFingerprint: ScreenUnderstandingMediaFingerprint(mediaStat),
                text: candidate.text,
                textSources: candidate.textSources
            )
        }
        return (reconciled, sourceImageRows, availableImageRows, missingMediaRows)
    }

    private func naturalisticTrace(
        from candidates: [ScreenUnderstandingDatasetCandidate]
    ) throws -> ScreenUnderstandingNaturalisticTrace {
        let calendar = tracePolicy.calendar
        let grouped = Dictionary(grouping: candidates) { candidate in
            calendar.startOfDay(for: Date(
                timeIntervalSince1970: Double(candidate.timestampMs) / 1_000
            ))
        }
        for dayStart in grouped.keys.sorted(by: >) {
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
                  dayEnd <= tracePolicy.now else { continue }
            let ordered = (grouped[dayStart] ?? []).sorted {
                if $0.timestampMs == $1.timestampMs { return $0.sourceID < $1.sourceID }
                return $0.timestampMs < $1.timestampMs
            }
            guard let first = ordered.first, let last = ordered.last else { continue }
            let elapsed = last.timestampMs - first.timestampMs
            guard elapsed >= tracePolicy.minimumElapsedCoverageMs,
                  ordered.count >= tracePolicy.minimumActivityCount else { continue }
            return ScreenUnderstandingNaturalisticTrace(
                schema: "screen-understanding-naturalistic-trace-v1",
                calendarIdentifier: Self.calendarIdentifier(calendar.identifier),
                timeZoneIdentifier: calendar.timeZone.identifier,
                localDayStartMs: Self.milliseconds(dayStart),
                localDayEndMs: Self.milliseconds(dayEnd),
                minimumElapsedCoverageMs: tracePolicy.minimumElapsedCoverageMs,
                minimumActivityCount: tracePolicy.minimumActivityCount,
                observedElapsedMs: elapsed,
                activityCount: ordered.count,
                entries: makeTrace(ordered)
            )
        }
        throw ScreenUnderstandingDatasetError.invalidPolicy(
            "No completed local calendar day meets naturalistic trace coverage"
        )
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

    private func securelyReadRegularFile(
        at url: URL,
        expectedFingerprint: ScreenUnderstandingMediaFingerprint
    ) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ScreenUnderstandingDatasetError.sourceChanged(
                "Selected media changed before descriptor-bound copy"
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var openedStat = stat()
        guard fstat(handle.fileDescriptor, &openedStat) == 0,
              (openedStat.st_mode & S_IFMT) == S_IFREG,
              ScreenUnderstandingMediaFingerprint(openedStat) == expectedFingerprint else {
            throw ScreenUnderstandingDatasetError.sourceChanged(
                "Media identity changed while opening"
            )
        }
        let data = try handle.readToEnd() ?? Data()
        var finalDescriptorStat = stat()
        var finalPathStat = stat()
        guard fstat(handle.fileDescriptor, &finalDescriptorStat) == 0,
              lstat(url.path, &finalPathStat) == 0,
              (finalPathStat.st_mode & S_IFMT) == S_IFREG,
              ScreenUnderstandingMediaFingerprint(finalDescriptorStat) == expectedFingerprint,
              ScreenUnderstandingMediaFingerprint(finalPathStat) == expectedFingerprint,
              Int64(data.count) == expectedFingerprint.size else {
            throw ScreenUnderstandingDatasetError.sourceChanged(
                "Media was replaced, rewritten, or truncated during export"
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

    private static func temporalPairID(beforeID: String, afterID: String) -> String {
        String(sha256(Data("screen-understanding-v1-pair:\(beforeID):\(afterID)".utf8)).prefix(24))
    }

    private static func calendarIdentifier(_ identifier: Calendar.Identifier) -> String {
        switch identifier {
        case .gregorian: "gregorian"
        case .iso8601: "iso8601"
        default: String(describing: identifier)
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func makeSplits(
        singleFrameIDs: [String],
        temporalPairIDs: [String]
    ) -> ScreenUnderstandingDatasetSplits {
        let single = split(singleFrameIDs)
        let temporal = split(temporalPairIDs)
        return .init(
            tuneSingleFrames: single.tune,
            validationSingleFrames: single.validation,
            testSingleFrames: single.test,
            tuneTemporalPairs: temporal.tune,
            validationTemporalPairs: temporal.validation,
            testTemporalPairs: temporal.test
        )
    }

    private static func split(_ identifiers: [String]) -> (
        tune: [String],
        validation: [String],
        test: [String]
    ) {
        let ordered = identifiers.sorted {
            sha256(Data("screen-understanding-v1-split:\($0)".utf8))
                < sha256(Data("screen-understanding-v1-split:\($1)".utf8))
        }
        let testCount = Int(Double(ordered.count) * 0.30)
        let validationCount = Int(Double(ordered.count) * 0.20)
        let test = Array(ordered.prefix(testCount)).sorted()
        let validation = Array(
            ordered.dropFirst(testCount).prefix(validationCount)
        ).sorted()
        let tune = Array(ordered.dropFirst(testCount + validationCount)).sorted()
        return (tune, validation, test)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
