import Darwin
import Foundation

struct BuiltInDownloadPlan: Sendable, Equatable {
    let sourceURL: URL
    let revision: String
    let manifestFingerprintSHA256: String
    let expectedBytes: Int64
    let partialFileURL: URL
}

struct BuiltInDownloadResumeState: Codable, Sendable, Equatable {
    var sourceURL: URL
    var revision: String
    var manifestFingerprintSHA256: String
    var expectedBytes: Int64
    var strongETag: String
    var receivedBytes: Int64
}

struct BuiltInDownloadCapacityProgress: Sendable, Equatable {
    let receivedBytes: Int64
    let remainingBytes: Int64
}

enum BuiltInDownloadCapacityDecision: Sendable, Equatable {
    case sufficient
    case insufficient(requiredBytes: Int64, availableBytes: Int64)
}

enum BuiltInDownloadOutcome: Sendable, Equatable {
    case completed(BuiltInDownloadResumeState)
    case paused(BuiltInDownloadResumeState?)
    case pausedLowDisk(
        BuiltInDownloadResumeState?,
        requiredBytes: Int64,
        availableBytes: Int64
    )
    case interrupted(BuiltInDownloadResumeState?)
    case cancelled
}

struct BuiltInDownloadDrainAcknowledgement: Sendable, Equatable {
    let hadActiveDownload: Bool
    let activeDownloads: Int
}

enum BuiltInDownloadError: Error, LocalizedError, Sendable, Equatable {
    case busy
    case suspended
    case invalidPlan
    case disallowedURL
    case tooManyRedirects
    case invalidRedirect
    case invalidStatus(Int)
    case missingOrInvalidETag
    case invalidContentLength(expected: Int64, actual: String?)
    case invalidContentRange
    case compressedResponse
    case bodyOverrun
    case shortBody(expected: Int64, actual: Int64)
    case unsafePartialFile
    case fileIO(Int32)

    var errorDescription: String? {
        switch self {
        case .busy: "Another built-in model download is already active."
        case .suspended: "Built-in model downloads are suspended."
        case .invalidPlan: "The built-in model download plan is invalid."
        case .disallowedURL: "The built-in model download URL is not allowed."
        case .tooManyRedirects: "The built-in model download redirected too many times."
        case .invalidRedirect: "The built-in model download returned an invalid redirect."
        case .invalidStatus(let status): "Unexpected model-download HTTP status: \(status)."
        case .missingOrInvalidETag: "The model download did not return a strong ETag."
        case .invalidContentLength(let expected, let actual):
            "Unexpected model-download length (expected \(expected), got \(actual ?? "missing"))."
        case .invalidContentRange: "The model download returned an invalid Content-Range."
        case .compressedResponse: "Compressed model-download responses are not accepted."
        case .bodyOverrun: "The model download exceeded its immutable manifest length."
        case .shortBody(let expected, let actual):
            "The model download ended early (expected \(expected), got \(actual))."
        case .unsafePartialFile: "The model staging file is not a safe regular file."
        case .fileIO(let code): "Model staging file I/O failed (errno \(code))."
        }
    }
}

struct BuiltInDownloadHTTPRequest: Sendable, Equatable {
    let url: URL
    let headers: [String: String]
}

struct BuiltInDownloadHTTPResponse: Sendable, Equatable {
    let url: URL
    let statusCode: Int
    let headers: [String: String]

    func value(forHeader name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

struct BuiltInDownloadStream: Sendable {
    let response: BuiltInDownloadHTTPResponse
    private let nextChunkClosure: @Sendable () async throws -> Data?
    private let cancelClosure: @Sendable () -> Void

    init(
        response: BuiltInDownloadHTTPResponse,
        nextChunk: @escaping @Sendable () async throws -> Data?,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.response = response
        self.nextChunkClosure = nextChunk
        self.cancelClosure = cancel
    }

    func nextChunk() async throws -> Data? { try await nextChunkClosure() }
    func cancel() { cancelClosure() }
}

protocol BuiltInDownloadTransport: Sendable {
    func open(_ request: BuiltInDownloadHTTPRequest) async throws -> BuiltInDownloadStream
    func cancelPendingRequests() async
}

extension BuiltInDownloadTransport {
    func cancelPendingRequests() async {}
}

/// Streaming, resumable download owner. It never accepts ambient credentials,
/// never uses URLSession resumeData, and owns at most one staging descriptor.
actor BuiltInDownloadClient {
    typealias CapacityCheck = @Sendable (
        BuiltInDownloadCapacityProgress
    ) async -> BuiltInDownloadCapacityDecision
    typealias ProgressObserver = @Sendable (BuiltInDownloadResumeState) async -> Void

    private enum Control {
        case running
        case suspendRequested
        case cancelRequested
        case interruptionRequested
    }

    private let transport: any BuiltInDownloadTransport
    private let allowedAssetHosts: Set<String>
    private let maximumRedirects: Int
    private let capacityCheck: CapacityCheck
    private let progressCheckpointBytes: Int64

    private var suspended = false
    private var activeID: UUID?
    private var control: Control = .running
    private var activeStreamCancel: (@Sendable () -> Void)?
    private var drainWaiters: [CheckedContinuation<BuiltInDownloadDrainAcknowledgement, Never>] = []

    init(
        transport: any BuiltInDownloadTransport = URLSessionBuiltInDownloadTransport(),
        allowedAssetHosts: Set<String>,
        maximumRedirects: Int = 3,
        progressCheckpointBytes: Int64 = 64 * 1024 * 1024,
        capacityCheck: @escaping CapacityCheck = { _ in .sufficient }
    ) {
        self.transport = transport
        self.allowedAssetHosts = Set(allowedAssetHosts.map { $0.lowercased() })
        self.maximumRedirects = maximumRedirects
        self.progressCheckpointBytes = max(1, progressCheckpointBytes)
        self.capacityCheck = capacityCheck
    }

    func download(
        plan: BuiltInDownloadPlan,
        resumeState: BuiltInDownloadResumeState? = nil,
        onProgress: @escaping ProgressObserver = { _ in }
    ) async throws -> BuiltInDownloadOutcome {
        guard !suspended else { throw BuiltInDownloadError.suspended }
        guard activeID == nil else { throw BuiltInDownloadError.busy }

        let id = UUID()
        activeID = id
        control = .running
        defer { finishActive(id: id) }

        return try await withTaskCancellationHandler {
            try await run(
                id: id,
                plan: plan,
                resumeState: resumeState,
                onProgress: onProgress
            )
        } onCancel: {
            Task { await self.requestInterruption(id: id) }
        }
    }

    /// Relocation/maintenance barrier. The acknowledgement is returned only
    /// after the active URLSession body and staging descriptor have drained.
    func suspendAndDrain() async -> BuiltInDownloadDrainAcknowledgement {
        suspended = true
        guard activeID != nil else {
            return BuiltInDownloadDrainAcknowledgement(
                hadActiveDownload: false,
                activeDownloads: 0
            )
        }
        if case .cancelRequested = control {
            // Explicit cancellation owns the stronger outcome.
        } else {
            control = .suspendRequested
        }
        return await waitForDrainAndCancelTransport()
    }

    /// Explicit user cancellation removes only the active unverified partial.
    func cancelAndDrain() async -> BuiltInDownloadDrainAcknowledgement {
        guard activeID != nil else {
            return BuiltInDownloadDrainAcknowledgement(
                hadActiveDownload: false,
                activeDownloads: 0
            )
        }
        control = .cancelRequested
        return await waitForDrainAndCancelTransport()
    }

    func resumeAfterDrain() {
        guard activeID == nil else { return }
        suspended = false
    }

    private func waitForDrainAndCancelTransport() async -> BuiltInDownloadDrainAcknowledgement {
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
            activeStreamCancel?()
            let transport = self.transport
            Task { await transport.cancelPendingRequests() }
        }
    }

    private func requestInterruption(id: UUID) {
        guard activeID == id else { return }
        if case .running = control { control = .interruptionRequested }
        activeStreamCancel?()
        let transport = self.transport
        Task { await transport.cancelPendingRequests() }
    }

    private func finishActive(id: UUID) {
        guard activeID == id else { return }
        activeStreamCancel?()
        activeStreamCancel = nil
        activeID = nil
        control = .running
        let acknowledgement = BuiltInDownloadDrainAcknowledgement(
            hadActiveDownload: true,
            activeDownloads: 0
        )
        let waiters = drainWaiters
        drainWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(returning: acknowledgement) }
    }

    private func run(
        id: UUID,
        plan: BuiltInDownloadPlan,
        resumeState suppliedResumeState: BuiltInDownloadResumeState?,
        onProgress: ProgressObserver
    ) async throws -> BuiltInDownloadOutcome {
        try validate(plan: plan)
        let partial = try SecurePartialFile(url: plan.partialFileURL)

        var offset: Int64 = 0
        var lastProgressCheckpoint: Int64 = 0
        var validator: String?
        let diskLength = try partial.length()
        if let suppliedResumeState,
           resumeMatches(
               suppliedResumeState,
               plan: plan,
               diskLength: diskLength
           ) {
            offset = suppliedResumeState.receivedBytes
            lastProgressCheckpoint = offset
            validator = suppliedResumeState.strongETag
            try partial.seek(to: offset)
        } else {
            try partial.truncate()
        }

        if offset == plan.expectedBytes, let validator {
            try partial.sync()
            return .completed(
                makeResumeState(plan: plan, validator: validator, receivedBytes: offset)
            )
        }

        var requestURL = plan.sourceURL
        var redirects = 0
        var stream: BuiltInDownloadStream

        responseLoop: while true {
            if let stopped = try stopOutcome(
                plan: plan,
                partial: partial,
                validator: validator,
                receivedBytes: offset
            ) {
                return stopped
            }

            let request = BuiltInDownloadHTTPRequest(
                url: requestURL,
                headers: requestHeaders(offset: offset, validator: validator)
            )
            do {
                stream = try await transport.open(request)
            } catch let error as BuiltInDownloadError {
                throw error
            } catch {
                if let stopped = try stopOutcome(
                    plan: plan,
                    partial: partial,
                    validator: validator,
                    receivedBytes: offset
                ) {
                    return stopped
                }
                try partial.sync()
                return .interrupted(
                    validator.map {
                        makeResumeState(plan: plan, validator: $0, receivedBytes: offset)
                    }
                )
            }
            activeStreamCancel = stream.cancel

            if let stopped = try stopOutcome(
                plan: plan,
                partial: partial,
                validator: validator,
                receivedBytes: offset
            ) {
                stream.cancel()
                activeStreamCancel = nil
                return stopped
            }

            try validateAllowedURL(stream.response.url)
            if Self.redirectStatuses.contains(stream.response.statusCode) {
                stream.cancel()
                activeStreamCancel = nil
                guard redirects < maximumRedirects else {
                    throw BuiltInDownloadError.tooManyRedirects
                }
                guard let location = stream.response.value(forHeader: "Location"),
                      let nextURL = URL(string: location, relativeTo: stream.response.url)?.absoluteURL
                else { throw BuiltInDownloadError.invalidRedirect }
                try validateAllowedURL(nextURL)
                redirects += 1
                requestURL = nextURL
                continue responseLoop
            }

            if offset > 0 {
                guard stream.response.statusCode == 200
                        || stream.response.statusCode == 206
                else {
                    throw BuiltInDownloadError.invalidStatus(stream.response.statusCode)
                }
            } else {
                guard stream.response.statusCode == 200 else {
                    throw BuiltInDownloadError.invalidStatus(stream.response.statusCode)
                }
            }

            let responseValidator = try Self.strongETag(
                stream.response.value(forHeader: "ETag")
            )
            try Self.validateIdentityEncoding(stream.response)

            if offset > 0 {
                switch stream.response.statusCode {
                case 206:
                    if responseValidator != validator {
                        // The partial belongs to another representation. Do
                        // not append a byte from it; restart from the immutable
                        // source URL with a fresh, headerless request.
                        stream.cancel()
                        activeStreamCancel = nil
                        try partial.truncate()
                        offset = 0
                        validator = nil
                        redirects = 0
                        requestURL = plan.sourceURL
                        continue responseLoop
                    }
                    try Self.validatePartialResponse(
                        stream.response,
                        start: offset,
                        expectedBytes: plan.expectedBytes
                    )
                case 200:
                    try Self.validateFullResponse(
                        stream.response,
                        expectedBytes: plan.expectedBytes
                    )
                    // A server may legally ignore Range. Its full response is
                    // accepted only after every full-response invariant passes.
                    try partial.truncate()
                    offset = 0
                    validator = responseValidator
                default:
                    preconditionFailure("status validated before dispatch")
                }
            } else {
                try Self.validateFullResponse(
                    stream.response,
                    expectedBytes: plan.expectedBytes
                )
                validator = responseValidator
            }
            validator = responseValidator
            break responseLoop
        }

        guard let validator else { throw BuiltInDownloadError.missingOrInvalidETag }
        let checkpointBytes = min(progressCheckpointBytes, plan.expectedBytes)

        while true {
            if let stopped = try stopOutcome(
                plan: plan,
                partial: partial,
                validator: validator,
                receivedBytes: offset
            ) {
                stream.cancel()
                activeStreamCancel = nil
                return stopped
            }

            let chunk: Data?
            do {
                chunk = try await stream.nextChunk()
            } catch {
                if let stopped = try stopOutcome(
                    plan: plan,
                    partial: partial,
                    validator: validator,
                    receivedBytes: offset
                ) {
                    activeStreamCancel = nil
                    return stopped
                }
                try partial.sync()
                activeStreamCancel = nil
                return .interrupted(
                    makeResumeState(
                        plan: plan,
                        validator: validator,
                        receivedBytes: offset
                    )
                )
            }

            guard let chunk else { break }
            if chunk.isEmpty { continue }

            if let stopped = try stopOutcome(
                plan: plan,
                partial: partial,
                validator: validator,
                receivedBytes: offset
            ) {
                stream.cancel()
                activeStreamCancel = nil
                return stopped
            }

            let capacityDecision = await capacityCheck(
                BuiltInDownloadCapacityProgress(
                    receivedBytes: offset,
                    remainingBytes: plan.expectedBytes - offset
                )
            )
            if let stopped = try stopOutcome(
                plan: plan,
                partial: partial,
                validator: validator,
                receivedBytes: offset
            ) {
                stream.cancel()
                activeStreamCancel = nil
                return stopped
            }
            switch capacityDecision {
            case .sufficient:
                break
            case .insufficient(let requiredBytes, let availableBytes):
                stream.cancel()
                activeStreamCancel = nil
                try partial.sync()
                return .pausedLowDisk(
                    makeResumeState(
                        plan: plan,
                        validator: validator,
                        receivedBytes: offset
                    ),
                    requiredBytes: requiredBytes,
                    availableBytes: availableBytes
                )
            }

            let remaining = plan.expectedBytes - offset
            guard Int64(chunk.count) <= remaining else {
                stream.cancel()
                activeStreamCancel = nil
                try partial.sync()
                throw BuiltInDownloadError.bodyOverrun
            }
            try partial.write(chunk)
            offset += Int64(chunk.count)
            if offset == plan.expectedBytes
                || offset - lastProgressCheckpoint >= checkpointBytes {
                // Persist payload bytes before the journal can claim them.
                // This bounds crash replay loss without fsyncing every network chunk.
                try partial.sync()
                await onProgress(
                    makeResumeState(
                        plan: plan,
                        validator: validator,
                        receivedBytes: offset
                    )
                )
                lastProgressCheckpoint = offset
            }
        }

        activeStreamCancel = nil
        guard offset == plan.expectedBytes else {
            try partial.sync()
            throw BuiltInDownloadError.shortBody(
                expected: plan.expectedBytes,
                actual: offset
            )
        }
        try partial.sync()
        return .completed(
            makeResumeState(plan: plan, validator: validator, receivedBytes: offset)
        )
    }

    private func stopOutcome(
        plan: BuiltInDownloadPlan,
        partial: SecurePartialFile,
        validator: String?,
        receivedBytes: Int64
    ) throws -> BuiltInDownloadOutcome? {
        let state = validator.map {
            makeResumeState(
                plan: plan,
                validator: $0,
                receivedBytes: receivedBytes
            )
        }
        switch control {
        case .running:
            if Task.isCancelled {
                try partial.sync()
                return .interrupted(state)
            }
            return nil
        case .suspendRequested:
            try partial.sync()
            return .paused(state)
        case .cancelRequested:
            try partial.remove()
            return .cancelled
        case .interruptionRequested:
            try partial.sync()
            return .interrupted(state)
        }
    }

    private func validate(plan: BuiltInDownloadPlan) throws {
        guard plan.expectedBytes > 0,
              !plan.revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !plan.manifestFingerprintSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              plan.partialFileURL.isFileURL,
              maximumRedirects >= 0,
              !allowedAssetHosts.isEmpty
        else { throw BuiltInDownloadError.invalidPlan }
        try validateAllowedURL(plan.sourceURL)
    }

    private func validateAllowedURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.port == nil || url.port == 443,
              let rawHost = url.host
        else { throw BuiltInDownloadError.disallowedURL }

        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        // Trust is exact HTTPS authority + URLSession's system certificate
        // validation. We intentionally do not perform a separate DNS preflight:
        // resolving here and connecting later would create a DNS-rebinding
        // TOCTOU window while adding no stronger binding than TLS. Literal and
        // local authorities remain rejected below.
        guard allowedAssetHosts.contains(host),
              host != "localhost",
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              !Self.isLiteralIPAddress(host)
        else { throw BuiltInDownloadError.disallowedURL }
    }

    private func resumeMatches(
        _ state: BuiltInDownloadResumeState,
        plan: BuiltInDownloadPlan,
        diskLength: Int64
    ) -> Bool {
        state.sourceURL == plan.sourceURL
            && state.revision == plan.revision
            && state.manifestFingerprintSHA256 == plan.manifestFingerprintSHA256
            && state.expectedBytes == plan.expectedBytes
            && state.receivedBytes == diskLength
            && state.receivedBytes > 0
            && state.receivedBytes <= plan.expectedBytes
            && (try? Self.strongETag(state.strongETag)) == state.strongETag
    }

    private func requestHeaders(offset: Int64, validator: String?) -> [String: String] {
        var headers = ["Accept-Encoding": "identity"]
        if offset > 0, let validator {
            headers["Range"] = "bytes=\(offset)-"
            headers["If-Range"] = validator
        }
        return headers
    }

    private func makeResumeState(
        plan: BuiltInDownloadPlan,
        validator: String,
        receivedBytes: Int64
    ) -> BuiltInDownloadResumeState {
        BuiltInDownloadResumeState(
            sourceURL: plan.sourceURL,
            revision: plan.revision,
            manifestFingerprintSHA256: plan.manifestFingerprintSHA256,
            expectedBytes: plan.expectedBytes,
            strongETag: validator,
            receivedBytes: receivedBytes
        )
    }

    private static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

    private static func strongETag(_ rawValue: String?) throws -> String {
        guard let rawValue else { throw BuiltInDownloadError.missingOrInvalidETag }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2,
              !value.lowercased().hasPrefix("w/"),
              value.first == "\"",
              value.last == "\"",
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { throw BuiltInDownloadError.missingOrInvalidETag }
        return value
    }

    private static func validateIdentityEncoding(
        _ response: BuiltInDownloadHTTPResponse
    ) throws {
        guard let encoding = response.value(forHeader: "Content-Encoding") else { return }
        guard encoding.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("identity") == .orderedSame
        else { throw BuiltInDownloadError.compressedResponse }
    }

    private static func validateFullResponse(
        _ response: BuiltInDownloadHTTPResponse,
        expectedBytes: Int64
    ) throws {
        guard response.value(forHeader: "Content-Range") == nil else {
            throw BuiltInDownloadError.invalidContentRange
        }
        try validateContentLength(response, expected: expectedBytes)
    }

    private static func validatePartialResponse(
        _ response: BuiltInDownloadHTTPResponse,
        start: Int64,
        expectedBytes: Int64
    ) throws {
        guard let rawRange = response.value(forHeader: "Content-Range"),
              let parsed = parseContentRange(rawRange),
              parsed.start == start,
              parsed.end == expectedBytes - 1,
              parsed.total == expectedBytes
        else { throw BuiltInDownloadError.invalidContentRange }
        try validateContentLength(response, expected: expectedBytes - start)
    }

    private static func validateContentLength(
        _ response: BuiltInDownloadHTTPResponse,
        expected: Int64
    ) throws {
        let raw = response.value(forHeader: "Content-Length")
        guard let raw,
              let actual = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              actual == expected
        else {
            throw BuiltInDownloadError.invalidContentLength(
                expected: expected,
                actual: raw
            )
        }
    }

    private static func parseContentRange(
        _ raw: String
    ) -> (start: Int64, end: Int64, total: Int64)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let total = Int64(parts[1])
        else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start,
              total > end
        else { return nil }
        return (start, end, total)
    }

    private static func isLiteralIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }
}

private final class SecurePartialFile {
    private let url: URL
    private var descriptor: Int32

    init(url: URL) throws {
        self.url = url
        descriptor = Darwin.open(
            url.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            if errno == ELOOP { throw BuiltInDownloadError.unsafePartialFile }
            throw BuiltInDownloadError.fileIO(errno)
        }

        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw BuiltInDownloadError.fileIO(errno)
            }
            guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  metadata.st_nlink == 1
            else { throw BuiltInDownloadError.unsafePartialFile }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw BuiltInDownloadError.fileIO(errno)
            }
        } catch {
            Darwin.close(descriptor)
            descriptor = -1
            throw error
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func length() throws -> Int64 {
        var metadata = stat()
        guard descriptor >= 0, fstat(descriptor, &metadata) == 0 else {
            throw BuiltInDownloadError.fileIO(errno)
        }
        return metadata.st_size
    }

    func seek(to offset: Int64) throws {
        guard descriptor >= 0,
              lseek(descriptor, off_t(offset), SEEK_SET) == off_t(offset)
        else { throw BuiltInDownloadError.fileIO(errno) }
    }

    func truncate() throws {
        guard descriptor >= 0,
              ftruncate(descriptor, 0) == 0,
              lseek(descriptor, 0, SEEK_SET) == 0
        else { throw BuiltInDownloadError.fileIO(errno) }
    }

    func write(_ data: Data) throws {
        guard descriptor >= 0 else { throw BuiltInDownloadError.fileIO(EBADF) }
        try data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, base, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw BuiltInDownloadError.fileIO(errno) }
                remaining -= written
                base = base.advanced(by: written)
            }
        }
    }

    func sync() throws {
        guard descriptor >= 0, fsync(descriptor) == 0 else {
            throw BuiltInDownloadError.fileIO(errno)
        }
    }

    func remove() throws {
        if descriptor >= 0 {
            guard fsync(descriptor) == 0 else { throw BuiltInDownloadError.fileIO(errno) }
            guard Darwin.close(descriptor) == 0 else {
                descriptor = -1
                throw BuiltInDownloadError.fileIO(errno)
            }
            descriptor = -1
        }
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw BuiltInDownloadError.fileIO(errno)
        }
    }
}

/// Default production transport. It disables URLSession redirect/cookie/auth
/// behavior and streams delegate chunks through a small back-pressured queue.
actor URLSessionBuiltInDownloadTransport: BuiltInDownloadTransport {
    private var pending: [UUID: BuiltInURLSessionStreamState] = [:]

    func open(_ request: BuiltInDownloadHTTPRequest) async throws -> BuiltInDownloadStream {
        let id = UUID()
        let state = BuiltInURLSessionStreamState()
        pending[id] = state
        state.setTerminalObserver { [weak self] in
            guard let self else { return }
            Task { await self.removeFinishedRequest(id) }
        }

        let delegate = BuiltInURLSessionDownloadDelegate(state: state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [:]

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: queue
        )
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        urlRequest.httpMethod = "GET"
        urlRequest.httpShouldHandleCookies = false
        urlRequest.allHTTPHeaderFields = request.headers

        let task = session.dataTask(with: urlRequest)
        state.attach(session: session, task: task)
        task.resume()

        do {
            let response = try await withTaskCancellationHandler {
                try await state.waitForResponse()
            } onCancel: {
                state.cancel()
            }
            return BuiltInDownloadStream(
                response: response,
                nextChunk: { try await state.nextChunk() },
                cancel: { state.cancel() }
            )
        } catch {
            state.cancel()
            throw error
        }
    }

    func cancelPendingRequests() async {
        let states = Array(pending.values)
        for state in states { state.cancel() }
    }

    private func removeFinishedRequest(_ id: UUID) {
        pending.removeValue(forKey: id)
    }
}

final class BuiltInURLSessionDownloadDelegate: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let state: BuiltInURLSessionStreamState

    init(state: BuiltInURLSessionStreamState) {
        self.state = state
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            state.failBeforeResponse(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        publish(http)
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        state.receive(data: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        state.complete(error: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Redirects are data-plane policy, so the actor validates Location and
        // creates a brand-new credential-free request itself.
        // URLSession does not guarantee a subsequent data-task response callback
        // when the redirect is declined, so publish the original 3xx here.
        publish(response)
        completionHandler(nil)
    }

    private func publish(_ response: HTTPURLResponse) {
        guard let url = response.url else {
            state.failBeforeResponse(URLError(.badServerResponse))
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        state.receive(
            response: BuiltInDownloadHTTPResponse(
                url: url,
                statusCode: response.statusCode,
                headers: headers
            )
        )
    }
}

final class BuiltInURLSessionStreamState: @unchecked Sendable {
    private enum Completion {
        case open
        case finished
        case failed(any Error)
    }

    private let lock = NSLock()
    private let highWaterChunks = 2
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var taskSuspended = false
    private var chunks: [Data] = []
    private var completion: Completion = .open
    private var nextWaiter: CheckedContinuation<Data?, any Error>?
    private var response: BuiltInDownloadHTTPResponse?
    private var responseWaiter: CheckedContinuation<BuiltInDownloadHTTPResponse, any Error>?
    private var terminalObserver: (@Sendable () -> Void)?

    func setTerminalObserver(_ observer: @escaping @Sendable () -> Void) {
        lock.lock()
        switch completion {
        case .open:
            terminalObserver = observer
            lock.unlock()
        case .finished, .failed:
            lock.unlock()
            observer()
        }
    }

    func attach(session: URLSession, task: URLSessionDataTask) {
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
    }

    func waitForResponse() async throws -> BuiltInDownloadHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let response {
                lock.unlock()
                continuation.resume(returning: response)
                return
            }
            switch completion {
            case .failed(let error):
                lock.unlock()
                continuation.resume(throwing: error)
            case .finished:
                lock.unlock()
                continuation.resume(throwing: URLError(.badServerResponse))
            case .open:
                responseWaiter = continuation
                lock.unlock()
            }
        }
    }

    func receive(response: BuiltInDownloadHTTPResponse) {
        lock.lock()
        guard case .open = completion, self.response == nil else {
            lock.unlock()
            return
        }
        self.response = response
        let waiter = responseWaiter
        responseWaiter = nil
        lock.unlock()
        waiter?.resume(returning: response)
    }

    func failBeforeResponse(_ error: any Error) {
        complete(error: error)
    }

    func receive(data: Data) {
        lock.lock()
        guard case .open = completion else {
            lock.unlock()
            return
        }
        if let waiter = nextWaiter {
            nextWaiter = nil
            lock.unlock()
            waiter.resume(returning: data)
            return
        }
        chunks.append(data)
        if chunks.count >= highWaterChunks, !taskSuspended {
            taskSuspended = true
            task?.suspend()
        }
        lock.unlock()
    }

    func nextChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !chunks.isEmpty {
                let data = chunks.removeFirst()
                if taskSuspended, chunks.count < highWaterChunks {
                    taskSuspended = false
                    task?.resume()
                }
                lock.unlock()
                continuation.resume(returning: data)
                return
            }
            switch completion {
            case .finished:
                lock.unlock()
                continuation.resume(returning: nil)
            case .failed(let error):
                lock.unlock()
                continuation.resume(throwing: error)
            case .open:
                nextWaiter = continuation
                lock.unlock()
            }
        }
    }

    func complete(error: (any Error)?) {
        lock.lock()
        guard case .open = completion else {
            lock.unlock()
            return
        }
        completion = error.map(Completion.failed) ?? .finished
        let next = nextWaiter
        nextWaiter = nil
        let responseContinuation = responseWaiter
        responseWaiter = nil
        let hasResponse = response != nil
        let session = self.session
        self.session = nil
        task = nil
        let terminalObserver = self.terminalObserver
        self.terminalObserver = nil
        lock.unlock()

        if let error {
            next?.resume(throwing: error)
            responseContinuation?.resume(throwing: error)
        } else {
            next?.resume(returning: nil)
            if !hasResponse {
                responseContinuation?.resume(throwing: URLError(.badServerResponse))
            }
        }
        session?.finishTasksAndInvalidate()
        terminalObserver?()
    }

    func cancel() {
        lock.lock()
        guard case .open = completion else {
            lock.unlock()
            return
        }
        completion = .failed(CancellationError())
        let next = nextWaiter
        nextWaiter = nil
        let responseContinuation = responseWaiter
        responseWaiter = nil
        let task = self.task
        self.task = nil
        let session = self.session
        self.session = nil
        let terminalObserver = self.terminalObserver
        self.terminalObserver = nil
        lock.unlock()

        task?.cancel()
        next?.resume(throwing: CancellationError())
        responseContinuation?.resume(throwing: CancellationError())
        session?.invalidateAndCancel()
        terminalObserver?()
    }
}
