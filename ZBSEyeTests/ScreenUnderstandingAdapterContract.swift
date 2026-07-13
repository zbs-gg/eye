import Darwin
import Foundation

enum ScreenUnderstandingAdapterError: Error, LocalizedError {
    case launch(String)
    case timeout
    case nonzeroExit(Int32, String)
    case malformedOutput(String)
    case responseMismatch
    case retainedDescendants
    case outputLimit

    var errorDescription: String? {
        switch self {
        case .launch(let message):
            "adapter launch failed: \(message)"
        case .timeout:
            "adapter timeout"
        case .nonzeroExit(let status, let stderr):
            "adapter exited with status \(status): \(stderr)"
        case .malformedOutput(let line):
            "adapter returned malformed output: \(line)"
        case .responseMismatch:
            "adapter response count or identifiers did not match the request"
        case .retainedDescendants:
            "adapter retained descendant processes after exit"
        case .outputLimit:
            "adapter output exceeded the bounded capture limit"
        }
    }
}

private final class ScreenUnderstandingPipeDrain: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var data = Data()
    private var overflowed = false

    init(maximumBytes: Int = 4 * 1_024 * 1_024) {
        self.maximumBytes = maximumBytes
    }

    func start(_ handle: FileHandle) {
        handle.readabilityHandler = { [self] readable in
            let chunk = readable.availableData
            guard !chunk.isEmpty else {
                readable.readabilityHandler = nil
                finished.signal()
                return
            }
            lock.lock()
            defer { lock.unlock() }
            let available = max(0, maximumBytes - data.count)
            data.append(chunk.prefix(available))
            if chunk.count > available { overflowed = true }
        }
    }

    func result() -> (data: Data, overflowed: Bool, complete: Bool) {
        let complete = finished.wait(timeout: .now() + 5) == .success
        lock.lock()
        defer { lock.unlock() }
        return (data, overflowed, complete)
    }
}

struct ScreenUnderstandingAdapterMessage: Codable, Sendable, Equatable {
    var id: String
    var type: String
    var protocolID: String?
    var caseID: String?
    var imagePath: String?

    static func hello(id: String, protocolID: String) -> Self {
        Self(id: id, type: "hello", protocolID: protocolID)
    }

    static func caseRequest(id: String, caseID: String, imagePath: String) -> Self {
        Self(id: id, type: "case", caseID: caseID, imagePath: imagePath)
    }

    static func shutdown(id: String) -> Self {
        Self(id: id, type: "shutdown")
    }
}

indirect enum ScreenUnderstandingJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([ScreenUnderstandingJSONValue])
    case object([String: ScreenUnderstandingJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ScreenUnderstandingJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ScreenUnderstandingJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct ScreenUnderstandingNormalizedAdapterResult: Codable, Sendable, Equatable {
    var methodID: String
    var capabilities: [String]
    var summary: String?
    var atomicFacts: [String]?
    var visibleText: [String]?
    var labels: [String]?
    var regions: [[String: ScreenUnderstandingJSONValue]]?
    var changeFacts: [String]?
    var confidence: Double?
    var abstention: Bool?
    var errors: [String]?
    var runtimeMetadata: [String: ScreenUnderstandingJSONValue]
}

private struct ScreenUnderstandingAnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer {
    func decodePresent<T: Decodable>(
        _ type: T.Type,
        forKey key: Key
    ) throws -> T? {
        guard contains(key) else { return nil }
        guard try !decodeNil(forKey: key) else {
            throw DecodingError.valueNotFound(
                type,
                .init(codingPath: codingPath + [key], debugDescription: "Explicit null is forbidden")
            )
        }
        return try decode(type, forKey: key)
    }
}

extension ScreenUnderstandingNormalizedAdapterResult {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case methodID
        case capabilities
        case summary
        case atomicFacts
        case visibleText
        case labels
        case regions
        case changeFacts
        case confidence
        case abstention
        case errors
        case runtimeMetadata
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: ScreenUnderstandingAnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown normalized result key")
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        methodID = try container.decode(String.self, forKey: .methodID)
        capabilities = try container.decode([String].self, forKey: .capabilities)
        runtimeMetadata = try container.decode(
            [String: ScreenUnderstandingJSONValue].self,
            forKey: .runtimeMetadata
        )
        guard !methodID.isEmpty, Set(capabilities).count == capabilities.count else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid result identity")
            )
        }

        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        atomicFacts = try container.decodePresent([String].self, forKey: .atomicFacts)
        visibleText = try container.decodePresent([String].self, forKey: .visibleText)
        labels = try container.decodePresent([String].self, forKey: .labels)
        regions = try container.decodePresent(
            [[String: ScreenUnderstandingJSONValue]].self,
            forKey: .regions
        )
        changeFacts = try container.decodePresent([String].self, forKey: .changeFacts)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        abstention = try container.decodeIfPresent(Bool.self, forKey: .abstention)
        errors = try container.decodePresent([String].self, forKey: .errors)
        guard confidence.map({ 0.0 ... 1.0 ~= $0 }) ?? true else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Confidence is outside 0...1")
            )
        }
    }
}

enum ScreenUnderstandingAdapterStatus: String, Codable, Sendable, Equatable {
    case ready
    case ok
    case bye
    case unsupported
    case error
}

struct ScreenUnderstandingAdapterResponse: Codable, Sendable, Equatable {
    var id: String
    var status: ScreenUnderstandingAdapterStatus
    var normalized: ScreenUnderstandingNormalizedAdapterResult?
    var error: String?
}

extension ScreenUnderstandingAdapterResponse {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case status
        case normalized
        case error
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: ScreenUnderstandingAnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        guard Set(raw.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown adapter response key")
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(ScreenUnderstandingAdapterStatus.self, forKey: .status)
        normalized = try container.decodeIfPresent(
            ScreenUnderstandingNormalizedAdapterResult.self,
            forKey: .normalized
        )
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

struct ScreenUnderstandingAdapterProcess: Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var processGroupLauncher: URL

    func run(
        messages: [ScreenUnderstandingAdapterMessage],
        timeoutSeconds: TimeInterval
    ) throws -> [ScreenUnderstandingAdapterResponse] {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [processGroupLauncher.path, executable.path] + arguments
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw ScreenUnderstandingAdapterError.launch(error.localizedDescription)
        }
        let outputDrain = ScreenUnderstandingPipeDrain()
        let errorDrain = ScreenUnderstandingPipeDrain()
        outputDrain.start(output.fileHandleForReading)
        errorDrain.start(errors.fileHandleForReading)

        let encoder = JSONEncoder()
        for message in messages {
            var line = try encoder.encode(message)
            line.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: line)
        }
        try input.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: min(0.01, max(0, deadline.timeIntervalSinceNow)))
        }
        if process.isRunning {
            terminateProcessGroup(process.processIdentifier, signal: SIGTERM)
            Thread.sleep(forTimeInterval: 0.05)
            if processGroupExists(process.processIdentifier) {
                terminateProcessGroup(process.processIdentifier, signal: SIGKILL)
            }
            if process.isRunning { process.waitUntilExit() }
            _ = outputDrain.result()
            _ = errorDrain.result()
            throw ScreenUnderstandingAdapterError.timeout
        }

        if processGroupExists(process.processIdentifier) {
            terminateProcessGroup(process.processIdentifier, signal: SIGKILL)
            _ = outputDrain.result()
            _ = errorDrain.result()
            throw ScreenUnderstandingAdapterError.retainedDescendants
        }

        let capturedOutput = outputDrain.result()
        let capturedErrors = errorDrain.result()
        if capturedOutput.overflowed || capturedErrors.overflowed
                || !capturedOutput.complete || !capturedErrors.complete {
            throw ScreenUnderstandingAdapterError.outputLimit
        }
        let outputData = capturedOutput.data
        let errorData = capturedErrors.data
        guard process.terminationStatus == 0 else {
            throw ScreenUnderstandingAdapterError.nonzeroExit(
                process.terminationStatus,
                String(decoding: errorData, as: UTF8.self)
            )
        }

        let lines = String(decoding: outputData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        let decoder = JSONDecoder()
        let responses = try lines.map { line -> ScreenUnderstandingAdapterResponse in
            do {
                return try decoder.decode(
                    ScreenUnderstandingAdapterResponse.self,
                    from: Data(line.utf8)
                )
            } catch {
                throw ScreenUnderstandingAdapterError.malformedOutput(String(line))
            }
        }

        try validate(messages: messages, responses: responses)
        return responses
    }

    func validate(
        messages: [ScreenUnderstandingAdapterMessage],
        responses: [ScreenUnderstandingAdapterResponse]
    ) throws {
        guard responses.map(\.id) == messages.prefix(responses.count).map(\.id) else {
            throw ScreenUnderstandingAdapterError.responseMismatch
        }
        if responses.last?.status == .unsupported {
            guard responses.count == 1,
                  responses[0].normalized == nil,
                  !(responses[0].error ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ScreenUnderstandingAdapterError.responseMismatch
            }
            return
        }
        guard responses.count == messages.count else {
            throw ScreenUnderstandingAdapterError.responseMismatch
        }
        for (message, response) in zip(messages, responses) {
            switch message.type {
            case "hello":
                guard response.status == .ready,
                      response.normalized == nil,
                      response.error == nil else {
                    throw ScreenUnderstandingAdapterError.responseMismatch
                }
            case "case":
                guard response.status == .ok,
                      let normalized = response.normalized,
                      !normalized.methodID.isEmpty,
                      !normalized.capabilities.isEmpty,
                      normalized.confidence.map({ 0.0 ... 1.0 ~= $0 }) ?? true,
                      response.error == nil else {
                    throw ScreenUnderstandingAdapterError.responseMismatch
                }
            case "shutdown":
                guard response.status == .bye,
                      response.normalized == nil,
                      response.error == nil else {
                    throw ScreenUnderstandingAdapterError.responseMismatch
                }
            default:
                throw ScreenUnderstandingAdapterError.responseMismatch
            }
        }
    }

    private func processGroupExists(_ identifier: Int32) -> Bool {
        errno = 0
        if Darwin.kill(-identifier, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func terminateProcessGroup(_ identifier: Int32, signal: Int32) {
        _ = Darwin.kill(-identifier, signal)
    }
}

enum ScreenUnderstandingAdapterEnvironment {
    static func make(ephemeralHome: URL) -> [String: String] {
        [
            "HOME": ephemeralHome.path,
            "TMPDIR": ephemeralHome.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "NO_PROXY": "*",
            "no_proxy": "*",
        ]
    }
}

struct ScreenUnderstandingAdapterManifest: Codable, Sendable, Equatable {
    struct Adapter: Codable, Sendable, Equatable {
        var id: String
        var artifactRevision: String
        var artifactIdentitySHA256: String
        var license: String
        var remote: Bool
        var retryCount: Int
        var allowsRemoteCode: Bool
        var status: String
        var reason: String?
    }

    var protocolID: String
    var adapters: [Adapter]

    static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func validate() throws {
        guard protocolID == "screen-understanding-v1",
              adapters.count == 9,
              Set(adapters.map(\.id)).count == adapters.count else {
            throw ScreenUnderstandingProtocolError.invalid("Adapter manifest identity is invalid")
        }
        for adapter in adapters {
            let revision = adapter.artifactRevision.lowercased()
            guard !adapter.remote,
                  adapter.retryCount == 0,
                  !adapter.allowsRemoteCode,
                  !["", "main", "master", "latest"].contains(revision),
                  adapter.artifactIdentitySHA256.count == 64,
                  !adapter.artifactIdentitySHA256.contains(where: { !$0.isHexDigit }),
                  !adapter.license.isEmpty else {
                throw ScreenUnderstandingProtocolError.invalid(
                    "Unsafe or unpinned adapter: \(adapter.id)"
                )
            }
        }
    }
}
