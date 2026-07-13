import Darwin
import Foundation

enum ScreenUnderstandingAdapterError: Error, LocalizedError {
    case launch(String)
    case timeout
    case nonzeroExit(Int32, String)
    case malformedOutput(String)
    case responseMismatch
    case retainedDescendants

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
        }
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

struct ScreenUnderstandingNormalizedAdapterResult: Codable, Sendable, Equatable {
    var summary: String?
    var atomicFacts: [String]
    var visibleText: [String]
    var labels: [String]
}

struct ScreenUnderstandingAdapterResponse: Codable, Sendable, Equatable {
    var id: String
    var status: String
    var normalized: ScreenUnderstandingNormalizedAdapterResult?
    var error: String?
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
            throw ScreenUnderstandingAdapterError.timeout
        }

        if processGroupExists(process.processIdentifier) {
            terminateProcessGroup(process.processIdentifier, signal: SIGKILL)
            throw ScreenUnderstandingAdapterError.retainedDescendants
        }

        let outputData = try output.fileHandleForReading.readToEnd() ?? Data()
        let errorData = try errors.fileHandleForReading.readToEnd() ?? Data()
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

        guard responses.map(\.id) == messages.prefix(responses.count).map(\.id),
              responses.count == messages.count || responses.last?.status == "unsupported" else {
            throw ScreenUnderstandingAdapterError.responseMismatch
        }
        return responses
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
