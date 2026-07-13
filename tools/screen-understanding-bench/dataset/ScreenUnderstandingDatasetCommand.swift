import Foundation

struct ScreenUnderstandingDatasetReceipt: Codable, Equatable, Sendable {
    let schema: String
    let status: String
    let protocolID: String
    let revision: Int
    let caseCount: Int
    let temporalPairCount: Int
    let baselineOnlyCaseCount: Int
    let sourceImageRows: Int
    let availableImageRows: Int
    let missingMediaRows: Int
    let splitSHA256: String
    let naturalisticTraceSHA256: String

    init(manifest: ScreenUnderstandingDatasetManifest) {
        schema = "screen-understanding-dataset-receipt-v1"
        status = "prepared"
        protocolID = manifest.protocolID
        revision = manifest.revision
        caseCount = manifest.cases.count
        temporalPairCount = manifest.temporalPairs.count
        baselineOnlyCaseCount = manifest.baselineOnlyCaseIDs.count
        sourceImageRows = manifest.sourceImageRows
        availableImageRows = manifest.availableImageRows
        missingMediaRows = manifest.missingMediaRows
        splitSHA256 = manifest.splitSHA256
        naturalisticTraceSHA256 = manifest.naturalisticTraceSHA256
    }
}

enum ScreenUnderstandingDatasetCommandError: Error, LocalizedError, Equatable {
    case missingOption(String)
    case duplicateOption(String)
    case invalidOption(String)
    case unknownOption

    var errorDescription: String? {
        switch self {
        case .missingOption(let option): "Missing required option: \(option)"
        case .duplicateOption(let option): "Duplicate option: \(option)"
        case .invalidOption(let option): "Invalid value for option: \(option)"
        case .unknownOption: "Unknown option"
        }
    }
}

struct ScreenUnderstandingDatasetCommand {
    static let helpText = """
    Usage: ScreenUnderstandingDatasetCLI [required options]

      --source-root PATH                    Read-only ZBS Eye data root.
      --output-root PATH                    New private corpus destination.
      --repository-root PATH                Repository root used for safety checks.
      --trace-calendar gregorian            Locked local calendar identifier.
      --trace-time-zone IANA                Locked IANA local time-zone identifier.
      --trace-now-ms UNIX_MS                Locked preparation cutoff in Unix milliseconds.
      --trace-minimum-elapsed-ms N          Locked minimum elapsed local-day coverage.
      --trace-minimum-activity-count N      Locked minimum activity count for that day.
      -h, --help                            Show this help.
    """

    private static let requiredOptions = [
        "--source-root",
        "--output-root",
        "--repository-root",
        "--trace-calendar",
        "--trace-time-zone",
        "--trace-now-ms",
        "--trace-minimum-elapsed-ms",
        "--trace-minimum-activity-count",
    ]

    func run(
        arguments: [String],
        writeStandardOutput: (Data) throws -> Void
    ) throws -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            try writeStandardOutput(Data((Self.helpText + "\n").utf8))
            return 0
        }

        let values = try Self.parse(arguments)
        let sourceRoot = try Self.absoluteURL(values, option: "--source-root")
        let outputRoot = try Self.absoluteURL(values, option: "--output-root")
        let repositoryRoot = try Self.absoluteURL(values, option: "--repository-root")
        guard values["--trace-calendar"] == "gregorian" else {
            throw ScreenUnderstandingDatasetCommandError.invalidOption("--trace-calendar")
        }
        guard let timeZoneName = values["--trace-time-zone"],
              let timeZone = TimeZone(identifier: timeZoneName) else {
            throw ScreenUnderstandingDatasetCommandError.invalidOption("--trace-time-zone")
        }
        let nowMs = try Self.positiveInt64(values, option: "--trace-now-ms")
        let minimumElapsedMs = try Self.positiveInt64(
            values,
            option: "--trace-minimum-elapsed-ms"
        )
        let minimumActivityCount = try Self.positiveInt(
            values,
            option: "--trace-minimum-activity-count"
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let manifest = try ScreenUnderstandingDatasetPreparer(
            tracePolicy: .init(
                calendar: calendar,
                now: Date(timeIntervalSince1970: Double(nowMs) / 1_000),
                minimumElapsedCoverageMs: minimumElapsedMs,
                minimumActivityCount: minimumActivityCount
            )
        ).prepare(
            sourceRoot: sourceRoot,
            outputRoot: outputRoot,
            repositoryRoot: repositoryRoot,
            labeledLimit: 200,
            temporalPairLimit: 100,
            baselineOnlyLimit: 30
        )
        let receipt = ScreenUnderstandingDatasetReceipt(manifest: manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var receiptData = try encoder.encode(receipt)
        receiptData.append(0x0A)
        try writeStandardOutput(receiptData)
        return 0
    }

    private static func parse(_ arguments: [String]) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard requiredOptions.contains(option) else {
                throw ScreenUnderstandingDatasetCommandError.unknownOption
            }
            guard values[option] == nil else {
                throw ScreenUnderstandingDatasetCommandError.duplicateOption(option)
            }
            index += 1
            guard index < arguments.count else {
                throw ScreenUnderstandingDatasetCommandError.missingOption(option)
            }
            values[option] = arguments[index]
            index += 1
        }
        for option in requiredOptions where values[option] == nil {
            throw ScreenUnderstandingDatasetCommandError.missingOption(option)
        }
        return values
    }

    private static func absoluteURL(
        _ values: [String: String],
        option: String
    ) throws -> URL {
        guard let value = values[option], value.hasPrefix("/") else {
            throw ScreenUnderstandingDatasetCommandError.invalidOption(option)
        }
        return URL(fileURLWithPath: value, isDirectory: true)
    }

    private static func positiveInt64(
        _ values: [String: String],
        option: String
    ) throws -> Int64 {
        guard let value = values[option], let parsed = Int64(value), parsed > 0 else {
            throw ScreenUnderstandingDatasetCommandError.invalidOption(option)
        }
        return parsed
    }

    private static func positiveInt(
        _ values: [String: String],
        option: String
    ) throws -> Int {
        guard let value = values[option], let parsed = Int(value), parsed > 0 else {
            throw ScreenUnderstandingDatasetCommandError.invalidOption(option)
        }
        return parsed
    }
}
