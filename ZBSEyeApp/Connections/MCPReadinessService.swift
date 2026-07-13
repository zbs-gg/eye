import Darwin
import Foundation
import Security

enum MCPReadinessDependencyError: Error, Equatable {
    case applicationMissing
    case identityMismatch
    case dataRootUnavailable
}

enum MCPSelfTestError: Error, Equatable {
    case timedOut
    case outputLimitExceeded
    case initializationFailed
    case retrievalFailed
}

enum MCPReadinessFailure: Sendable, Equatable {
    case applicationMissing
    case identityMismatch
    case dataRootUnavailable
    case initializationTimedOut
    case outputLimitExceeded
    case initializationFailed
    case toolContractMismatch
    case retrievalFailed

    var correctiveAction: String {
        switch self {
        case .applicationMissing:
            "Install ZBS Eye in Applications."
        case .identityMismatch:
            "Replace the app with the signed ZBS Eye release."
        case .dataRootUnavailable:
            "Connect the data drive or open ZBS Eye to initialize storage."
        case .initializationTimedOut, .outputLimitExceeded, .initializationFailed,
             .toolContractMismatch, .retrievalFailed:
            "Quit and reopen ZBS Eye, then check again."
        }
    }
}

enum MCPReadinessState: Sendable, Equatable {
    case readyToConnect(String)
    case notReady(MCPReadinessFailure)
}

struct MCPExecutableFileIdentity: Sendable, Hashable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64

    static func capture(at url: URL) throws -> Self {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw MCPReadinessDependencyError.applicationMissing
        }
        return Self(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: metadata.st_size,
            modifiedSeconds: Int64(metadata.st_mtimespec.tv_sec)
        )
    }
}

struct MCPInstalledApplicationIdentity: Sendable, Hashable {
    let applicationURL: URL
    let executableURL: URL
    let bundleIdentifier: String
    let teamIdentifier: String
    let codeHash: String
    let fileIdentity: MCPExecutableFileIdentity
}

struct MCPDataRootIdentity: Sendable, Hashable {
    let url: URL
    let device: UInt64
    let inode: UInt64
    let databaseIdentity: MCPExecutableFileIdentity
}

struct MCPSelfTestRequest: Sendable {
    let identity: MCPInstalledApplicationIdentity
    let dataRoot: MCPDataRootIdentity
    let profile: MCPAccessProfile
    let timeout: Duration
    let maximumOutputBytes: Int
}

struct MCPSelfTestResult: Sendable, Equatable {
    let toolNames: [String]
    let retrievalSucceeded: Bool
}

protocol MCPInstalledApplicationInspecting: Sendable {
    func inspect(applicationURL: URL) async throws -> MCPInstalledApplicationIdentity
}

protocol MCPDataRootResolving: Sendable {
    func resolve() async throws -> MCPDataRootIdentity
}

protocol MCPSelfTesting: Sendable {
    func run(_ request: MCPSelfTestRequest) async throws -> MCPSelfTestResult
}

actor MCPReadinessService {
    private struct Key: Sendable, Hashable {
        let identity: MCPInstalledApplicationIdentity
        let dataRoot: MCPDataRootIdentity
    }

    private let applicationURL: URL
    private let identityInspector: any MCPInstalledApplicationInspecting
    private let dataRootResolver: any MCPDataRootResolving
    private let selfTester: any MCPSelfTesting
    private var cached: (key: Key, state: MCPReadinessState)?

    init(
        applicationURL: URL = URL(fileURLWithPath: "/Applications/ZBS Eye.app"),
        identityInspector: any MCPInstalledApplicationInspecting = SystemMCPInstalledApplicationInspector(),
        dataRootResolver: any MCPDataRootResolving = SystemMCPDataRootResolver(),
        selfTester: any MCPSelfTesting = SystemMCPSelfTester()
    ) {
        self.applicationURL = applicationURL
        self.identityInspector = identityInspector
        self.dataRootResolver = dataRootResolver
        self.selfTester = selfTester
    }

    func check(force: Bool = false) async -> MCPReadinessState {
        let identity: MCPInstalledApplicationIdentity
        do {
            identity = try await identityInspector.inspect(applicationURL: applicationURL)
        } catch let error as MCPReadinessDependencyError {
            return .notReady(Self.map(error))
        } catch {
            return .notReady(.identityMismatch)
        }

        let dataRoot: MCPDataRootIdentity
        do {
            dataRoot = try await dataRootResolver.resolve()
        } catch {
            return .notReady(.dataRootUnavailable)
        }

        let key = Key(identity: identity, dataRoot: dataRoot)
        if !force, let cached, cached.key == key { return cached.state }

        let state: MCPReadinessState
        do {
            let result = try await selfTester.run(
                MCPSelfTestRequest(
                    identity: identity,
                    dataRoot: dataRoot,
                    profile: .memoryReadOnly,
                    timeout: .seconds(5),
                    maximumOutputBytes: 256 * 1_024
                )
            )
            let expected = MCPToolPolicy.toolNames(for: .memoryReadOnly)
            if result.toolNames == expected, result.retrievalSucceeded {
                state = .readyToConnect(identity.executableURL.path)
            } else if result.toolNames != expected {
                state = .notReady(.toolContractMismatch)
            } else {
                state = .notReady(.retrievalFailed)
            }
        } catch let error as MCPSelfTestError {
            state = .notReady(Self.map(error))
        } catch {
            state = .notReady(.initializationFailed)
        }
        cached = (key, state)
        return state
    }

    func invalidate() {
        cached = nil
    }

    private static func map(_ error: MCPReadinessDependencyError) -> MCPReadinessFailure {
        switch error {
        case .applicationMissing: .applicationMissing
        case .identityMismatch: .identityMismatch
        case .dataRootUnavailable: .dataRootUnavailable
        }
    }

    private static func map(_ error: MCPSelfTestError) -> MCPReadinessFailure {
        switch error {
        case .timedOut: .initializationTimedOut
        case .outputLimitExceeded: .outputLimitExceeded
        case .initializationFailed: .initializationFailed
        case .retrievalFailed: .retrievalFailed
        }
    }
}

struct SystemMCPInstalledApplicationInspector: MCPInstalledApplicationInspecting {
    static let expectedBundleIdentifier = "gg.zbs.eye"
    static let expectedTeamIdentifier = "44N4NZ86S5"

    func inspect(applicationURL: URL) async throws -> MCPInstalledApplicationIdentity {
        try await Task.detached(priority: .utility) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: applicationURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                throw MCPReadinessDependencyError.applicationMissing
            }
            guard let bundle = Bundle(url: applicationURL),
                  bundle.bundleIdentifier == Self.expectedBundleIdentifier,
                  let executableURL = bundle.executableURL else {
                throw MCPReadinessDependencyError.identityMismatch
            }

            var staticCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(applicationURL as CFURL, [], &staticCode) == errSecSuccess,
                  let staticCode else {
                throw MCPReadinessDependencyError.identityMismatch
            }
            let requirementText = "anchor apple generic and identifier \"\(Self.expectedBundleIdentifier)\" and certificate leaf[subject.OU] = \"\(Self.expectedTeamIdentifier)\""
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(
                requirementText as CFString,
                [],
                &requirement
            ) == errSecSuccess,
                  let requirement,
                  SecStaticCodeCheckValidity(
                    staticCode,
                    SecCSFlags(rawValue: kSecCSStrictValidate),
                    requirement
                  ) == errSecSuccess else {
                throw MCPReadinessDependencyError.identityMismatch
            }

            var rawInformation: CFDictionary?
            guard SecCodeCopySigningInformation(
                staticCode,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &rawInformation
            ) == errSecSuccess,
                  let information = rawInformation as? [CFString: Any],
                  let identifier = information[kSecCodeInfoIdentifier] as? String,
                  let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String,
                  let unique = information[kSecCodeInfoUnique] as? Data,
                  identifier == Self.expectedBundleIdentifier,
                  teamIdentifier == Self.expectedTeamIdentifier else {
                throw MCPReadinessDependencyError.identityMismatch
            }
            let codeHash = unique.map { String(format: "%02x", $0) }.joined()
            return MCPInstalledApplicationIdentity(
                applicationURL: applicationURL,
                executableURL: executableURL,
                bundleIdentifier: identifier,
                teamIdentifier: teamIdentifier,
                codeHash: codeHash,
                fileIdentity: try MCPExecutableFileIdentity.capture(at: executableURL)
            )
        }.value
    }
}

struct SystemMCPDataRootResolver: MCPDataRootResolving {
    func resolve() async throws -> MCPDataRootIdentity {
        try await Task.detached(priority: .utility) {
            let root = try StorageLocation.requireExistingDataRoot()
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let databaseURL = StorageLocation.databaseURL(under: root)
            var databaseMetadata = stat()
            guard lstat(databaseURL.path, &databaseMetadata) == 0,
                  databaseMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw MCPReadinessDependencyError.dataRootUnavailable
            }
            var rootMetadata = stat()
            guard lstat(root.path, &rootMetadata) == 0,
                  rootMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw MCPReadinessDependencyError.dataRootUnavailable
            }
            return MCPDataRootIdentity(
                url: root,
                device: UInt64(rootMetadata.st_dev),
                inode: UInt64(rootMetadata.st_ino),
                databaseIdentity: try MCPExecutableFileIdentity.capture(at: databaseURL)
            )
        }.value
    }
}

struct SystemMCPSelfTester: MCPSelfTesting {
    static let expectedRootEnvironmentKey = "ZBS_EYE_MCP_EXPECTED_DATA_ROOT"

    func run(_ request: MCPSelfTestRequest) async throws -> MCPSelfTestResult {
        guard request.timeout > .zero, request.maximumOutputBytes > 0,
              try MCPExecutableFileIdentity.capture(at: request.identity.executableURL)
                == request.identity.fileIdentity else {
            throw MCPSelfTestError.initializationFailed
        }

        let specification = CodexLaunchSpecification(
            executableURL: request.identity.executableURL,
            arguments: [request.profile.cliArgument],
            environment: [
                "HOME": NSHomeDirectory(),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": NSTemporaryDirectory(),
                Self.expectedRootEnvironmentKey: request.dataRoot.url.path,
            ],
            workingDirectoryURL: request.dataRoot.url,
            createsDedicatedProcessGroup: true,
            usesLoginShell: false,
            maximumStdoutBytes: request.maximumOutputBytes,
            maximumStderrBytes: 64 * 1_024
        )
        let spawned: CodexSpawnedProcess
        do {
            spawned = try CodexPOSIXSpawner.spawn(specification)
        } catch {
            throw MCPSelfTestError.initializationFailed
        }
        let connection = CodexPOSIXConnection(
            processIdentifier: spawned.processIdentifier,
            stdinFileDescriptor: spawned.stdinFileDescriptor,
            stdoutFileDescriptor: spawned.stdoutFileDescriptor,
            stderrFileDescriptor: spawned.stderrFileDescriptor,
            maximumStdoutBytes: request.maximumOutputBytes,
            maximumStderrBytes: 64 * 1_024
        )
        await connection.startMonitoring()
        guard getpgid(spawned.processIdentifier) == spawned.processIdentifier else {
            await connection.terminateProcessGroup(gracePeriod: .zero)
            throw MCPSelfTestError.initializationFailed
        }

        do {
            let deadline = ContinuousClock.now.advanced(by: request.timeout)
            let handshake = try Self.handshakeMessages()
            try await connection.send(handshake.initialize, promptAdmission: nil)
            let initialize = try await Self.receiveResponse(
                id: 1,
                connection: connection,
                deadline: deadline
            )
            try Self.validateInitialize(initialize)

            for message in handshake.afterInitialization {
                try await connection.send(message, promptAdmission: nil)
            }
            var responses: [Int: [String: Any]] = [:]
            while responses.count < 2 {
                let remaining = deadline - ContinuousClock.now
                guard remaining > .zero else { throw MCPSelfTestError.timedOut }
                let frame = try await connection.receive(
                    maximumLineBytes: 64 * 1_024,
                    timeout: remaining
                )
                guard let object = try JSONSerialization.jsonObject(with: frame.stdoutLine)
                        as? [String: Any],
                      let id = object["id"] as? Int else {
                    throw MCPSelfTestError.initializationFailed
                }
                responses[id] = object
            }
            let result = try Self.validatePostInitialize(responses)
            await connection.terminateProcessGroup(gracePeriod: .milliseconds(100))
            return result
        } catch {
            await connection.terminateProcessGroup(gracePeriod: .milliseconds(100))
            if let selfTestError = error as? MCPSelfTestError { throw selfTestError }
            if let processError = error as? CodexAppServerError {
                switch processError {
                case .timedOut: throw MCPSelfTestError.timedOut
                case .outputLimitExceeded: throw MCPSelfTestError.outputLimitExceeded
                default: throw MCPSelfTestError.initializationFailed
                }
            }
            throw MCPSelfTestError.initializationFailed
        }
    }

    struct HandshakeMessages: Sendable {
        let initialize: Data
        let afterInitialization: [Data]
    }

    static func handshakeMessages(nowMs: Int64? = nil) throws -> HandshakeMessages {
        let nowMs = nowMs ?? Int64(Date().timeIntervalSince1970 * 1_000)
        let objects: [[String: Any]] = [
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [:],
                    "clientInfo": ["name": "zbseye-readiness", "version": "1"],
                ],
            ],
            [
                "jsonrpc": "2.0", "method": "notifications/initialized",
                "params": [:],
            ],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]],
            [
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": [
                    "name": "get_context_at",
                    "arguments": ["time": String(nowMs)],
                ],
            ],
        ]
        let messages = try objects.map {
            let data = try JSONSerialization.data(withJSONObject: $0)
            guard !data.contains(0x0A) else { throw MCPSelfTestError.initializationFailed }
            return data
        }
        return HandshakeMessages(
            initialize: messages[0],
            afterInitialization: Array(messages.dropFirst())
        )
    }

    private static func receiveResponse(
        id expectedID: Int,
        connection: CodexPOSIXConnection,
        deadline: ContinuousClock.Instant
    ) async throws -> [String: Any] {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { throw MCPSelfTestError.timedOut }
        let frame = try await connection.receive(
            maximumLineBytes: 64 * 1_024,
            timeout: remaining
        )
        guard let object = try JSONSerialization.jsonObject(with: frame.stdoutLine)
                as? [String: Any],
              object["id"] as? Int == expectedID else {
            throw MCPSelfTestError.initializationFailed
        }
        return object
    }

    private static func validateInitialize(_ initialize: [String: Any]) throws {
        guard initialize["error"] == nil,
              let initializeResult = initialize["result"] as? [String: Any],
              let serverInfo = initializeResult["serverInfo"] as? [String: Any],
              serverInfo["name"] as? String == "zbseye" else {
            throw MCPSelfTestError.initializationFailed
        }
    }

    private static func validatePostInitialize(
        _ responses: [Int: [String: Any]]
    ) throws -> MCPSelfTestResult {
        guard let list = responses[2], list["error"] == nil,
              let listResult = list["result"] as? [String: Any],
              let tools = listResult["tools"] as? [[String: Any]] else {
            throw MCPSelfTestError.initializationFailed
        }
        let names = tools.compactMap { $0["name"] as? String }
        guard names.count == tools.count else {
            throw MCPSelfTestError.initializationFailed
        }
        guard let retrieval = responses[3], retrieval["error"] == nil,
              let retrievalResult = retrieval["result"] as? [String: Any],
              retrievalResult["isError"] as? Bool != true,
              let content = retrievalResult["content"] as? [[String: Any]],
              !content.isEmpty else {
            throw MCPSelfTestError.retrievalFailed
        }
        return MCPSelfTestResult(toolNames: names, retrievalSucceeded: true)
    }
}
