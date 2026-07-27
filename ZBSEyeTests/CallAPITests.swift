import CoreFoundation
import GRDB
import XCTest

final class CallAPITests: XCTestCase {
    func testOpenAPIContractDeclaresTypedCallInputsAndResponses() throws {
        let root = try loadCallOpenAPI()
        let info = try XCTUnwrap(root["info"] as? [String: Any])
        XCTAssertEqual(info["version"] as? String, "0.5.1")
        let paths = try XCTUnwrap(root["paths"] as? [String: Any])
        let callPath = try XCTUnwrap(paths["/v1/call"] as? [String: Any])
        let callGet = try XCTUnwrap(callPath["get"] as? [String: Any])
        let callParameters = try XCTUnwrap(callGet["parameters"] as? [[String: Any]])
        XCTAssertEqual(callParameters.first?["$ref"] as? String, "#/components/parameters/CallId")
        let transcriptPath = try XCTUnwrap(paths["/v1/call/transcript"] as? [String: Any])
        let transcriptGet = try XCTUnwrap(transcriptPath["get"] as? [String: Any])
        let transcriptParameters = try XCTUnwrap(
            transcriptGet["parameters"] as? [[String: Any]]
        )
        XCTAssertTrue(transcriptParameters.contains { $0["name"] as? String == "selector" })
        XCTAssertTrue(transcriptParameters.contains { $0["name"] as? String == "bookmark_id" })
        let components = try XCTUnwrap(root["components"] as? [String: Any])
        let schemas = try XCTUnwrap(components["schemas"] as? [String: Any])
        let expectedResponses = [
            "/v1/calls": "CallListPage",
            "/v1/call": "CallEnvelope",
            "/v1/call/bookmarks": "BookmarkPage",
            "/v1/call/transcript": "TranscriptPage",
        ]
        for (path, schema) in expectedResponses {
            XCTAssertEqual(
                try successSchemaReference(path: path, paths: paths),
                "#/components/schemas/\(schema)"
            )
            XCTAssertNotNil(schemas[schema])
            _ = try resolveOpenAPIReference("#/components/schemas/\(schema)", root: root)
        }
        for reference in [
            "#/components/parameters/CallId",
            "#/components/parameters/EvidenceId",
            "#/components/responses/BadRequest",
            "#/components/responses/NotFound",
            "#/components/responses/Failure",
        ] {
            _ = try resolveOpenAPIReference(reference, root: root)
        }
        let evidencePath = try XCTUnwrap(paths["/v1/call/evidence"] as? [String: Any])
        let evidenceGet = try XCTUnwrap(evidencePath["get"] as? [String: Any])
        let evidenceResponses = try XCTUnwrap(evidenceGet["responses"] as? [String: Any])
        let evidence200 = try XCTUnwrap(evidenceResponses["200"] as? [String: Any])
        let evidenceContent = try XCTUnwrap(evidence200["content"] as? [String: Any])
        let binary = try XCTUnwrap(evidenceContent["application/octet-stream"] as? [String: Any])
        let binarySchema = try XCTUnwrap(binary["schema"] as? [String: Any])
        XCTAssertEqual(binarySchema["format"] as? String, "binary")
    }

    func testSharedContractListsAndReadsReadyMicOnlyCallWithoutLeakingPaths() async throws {
        let fixture = try CallAgentFixture()
        let ids = try await fixture.makeReadyCall(segmentCount: 3, micOnly: true)

        let list = try await fixture.service.listCalls(query: "line", limit: 10, offset: 0)
        XCTAssertEqual(list.calls.map(\.callId), [CallEvidenceIdentifier.call(ids.callID)])
        XCTAssertEqual(list.calls.first?.status, .degraded)
        XCTAssertFalse(list.calls.first?.retryable ?? true)

        let envelopeCandidate = try await fixture.service.envelope(callID: ids.callID)
        let envelope = try XCTUnwrap(envelopeCandidate)
        XCTAssertEqual(envelope.callId, CallEvidenceIdentifier.call(ids.callID))
        XCTAssertEqual(envelope.preferredRevision?.kind, .final)
        XCTAssertEqual(envelope.sources.first(where: { $0.source == .me })?.health, .available)
        XCTAssertEqual(envelope.sources.first(where: { $0.source == .system })?.health, .missing)
        XCTAssertEqual(envelope.speakerStatus, .unavailable)
        XCTAssertNil(envelope.preferredSpeakerRevision)
        XCTAssertEqual(envelope.bookmarkCount, 1)
        XCTAssertFalse(envelope.evidence.isEmpty)

        let bookmarks = try await fixture.service.bookmarks(callID: ids.callID, limit: 10, offset: 0)
        XCTAssertEqual(bookmarks.bookmarks.map(\.bookmarkId), [CallEvidenceIdentifier.bookmark(ids.bookmarkID)])

        let transcript = try await fixture.service.transcript(
            callID: ids.callID,
            selector: .preferred,
            bookmarkID: nil,
            limit: 2,
            offset: 0
        )
        XCTAssertEqual(transcript.segments.map(\.text), ["line 0", "line 1"])
        XCTAssertTrue(transcript.hasMore)
        XCTAssertEqual(transcript.nextOffset, 2)

        let checkpoint = try await fixture.service.transcript(
            callID: ids.callID,
            selector: .bookmark,
            bookmarkID: ids.bookmarkID,
            limit: 10,
            offset: 0
        )
        XCTAssertEqual(checkpoint.revision?.kind, .interval)
        XCTAssertEqual(checkpoint.segments.map(\.text), ["bookmark"])

        let openAPI = try loadCallOpenAPI()
        try validateOpenAPIValue(try encodedJSONObject(list), schemaName: "CallListPage", root: openAPI)
        try validateOpenAPIValue(try encodedJSONObject(envelope), schemaName: "CallEnvelope", root: openAPI)
        try validateOpenAPIValue(try encodedJSONObject(bookmarks), schemaName: "BookmarkPage", root: openAPI)
        try validateOpenAPIValue(try encodedJSONObject(transcript), schemaName: "TranscriptPage", root: openAPI)
        try validateOpenAPIValue(
            try encodedJSONObject(
                APIDTO.ErrorResponse(
                    error: .init(code: "bad_request", message: "invalid")
                )
            ),
            schemaName: "ErrorResponse",
            root: openAPI
        )
        XCTAssertThrowsError(
            try validateOpenAPIValue(
                1.5,
                schema: ["type": "integer"],
                root: openAPI,
                path: "fractional"
            )
        )

        let evidenceID = try XCTUnwrap(envelope.evidence.first?.evidenceId)
        let resolvedEvidence = try await fixture.service.audioEvidence(reference: evidenceID)
        XCTAssertNotNil(resolvedEvidence)
        let forgedEvidence = try await fixture.service.audioEvidence(reference: "call-audio-chunk:999999")
        XCTAssertNil(forgedEvidence)

        let encoded = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains(fixture.root.path))
        XCTAssertFalse(json.contains("relativePath"))
        XCTAssertFalse(json.contains("preferredSpeakerRevision"))
    }

    func testContractRejectsForgedIDsUnknownSelectorsOversizedPagesAndUnsafeMediaPaths() throws {
        XCTAssertEqual(CallEvidenceIdentifier.parseCall("call:42"), 42)
        XCTAssertNil(CallEvidenceIdentifier.parseCall("42"))
        XCTAssertNil(CallEvidenceIdentifier.parseCall("call:-1"))
        XCTAssertNil(CallEvidenceIdentifier.parseBookmark("call:42"))
        XCTAssertNil(CallTranscriptSelector(rawValue: "latest"))
        XCTAssertThrowsError(try CallEvidencePageRequest(limit: 101, offset: 0))
        XCTAssertThrowsError(try CallEvidencePageRequest(limit: 10, offset: -1))
        XCTAssertThrowsError(try CallEvidencePageRequest(limit: 10, offset: Int.max))

        let root = URL(fileURLWithPath: "/tmp/managed-media", isDirectory: true)
        XCTAssertNil(ManagedMediaResolver.url(relativePath: "../secret", mediaRoot: root))
        XCTAssertNil(ManagedMediaResolver.url(relativePath: "/tmp/secret", mediaRoot: root))
        XCTAssertNotNil(ManagedMediaResolver.url(relativePath: "calls/1/chunk.pcm", mediaRoot: root))

        XCTAssertTrue(APILocalAuthorization.allows(
            hostHeader: "127.0.0.1:8731",
            authorizationHeader: "Bearer secret",
            token: "secret"
        ))
        XCTAssertFalse(APILocalAuthorization.allows(
            hostHeader: "127.0.0.1:8731",
            authorizationHeader: nil,
            token: "secret"
        ))
        XCTAssertFalse(APILocalAuthorization.allows(
            hostHeader: "127.0.0.1:8731",
            authorizationHeader: "Bearer wrong",
            token: "secret"
        ))
        XCTAssertFalse(APILocalAuthorization.allows(
            hostHeader: "example.com",
            authorizationHeader: "Bearer secret",
            token: "secret"
        ))
    }

    func testStatusMatrixIsHonestForRecordingProcessingFailedReadyAndDegraded() async throws {
        let recording = try CallAgentFixture()
        let processing = try CallAgentFixture()
        let failed = try CallAgentFixture()
        let ready = try CallAgentFixture()
        let degraded = try CallAgentFixture()

        let recordingID = try await recording.makeRecordingCall()
        let recordingStatus = try await recording.status(callID: recordingID)
        XCTAssertEqual(recordingStatus, .recording)
        let processingID = try await processing.makeProcessingCall()
        let processingStatus = try await processing.status(callID: processingID)
        XCTAssertEqual(processingStatus, .processing)
        let failedID = try await failed.makeFailedCall()
        let failedStatus = try await failed.status(callID: failedID)
        XCTAssertEqual(failedStatus, .retryable)
        let readyID = try await ready.makeReadyCall(segmentCount: 1, micOnly: false).callID
        let readyStatus = try await ready.status(callID: readyID)
        XCTAssertEqual(readyStatus, .ready)
        let degradedID = try await degraded.makeReadyCall(segmentCount: 1, micOnly: true).callID
        let degradedStatus = try await degraded.status(callID: degradedID)
        XCTAssertEqual(degradedStatus, .degraded)
    }
}

final class CallAgentFixture {
    let root: URL
    let database: ZBSEyeDatabase
    let repository: CallRepository
    let service: CallEvidenceQueryService

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-call-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(path: root.appendingPathComponent("eye.sqlite").path)
        repository = CallRepository(database: database)
        service = CallEvidenceQueryService(database: database)
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }

    func makeReadyCall(segmentCount: Int, micOnly: Bool) async throws -> (callID: Int64, bookmarkID: Int64) {
        let call = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: UUID().uuidString)
        let callID = try XCTUnwrap(call.id)
        let span = try await repository.recordSourceSpan(CallSourceSpanDraft(
            callId: callID,
            source: .me,
            epoch: 0,
            sampleRate: 16_000,
            startedAtMs: 1_000,
            startSample: 0,
            startHostTimeNs: 0,
            availability: .available
        ))
        _ = try await repository.recordAudioChunk(CallAudioChunkDraft(
            callId: callID,
            sourceSpanId: try XCTUnwrap(span.id),
            source: .me,
            epoch: 0,
            sequence: 0,
            mediaGeneration: 0,
            startSample: 0,
            endSample: 32_000,
            startMs: 1_000,
            endMs: 3_000,
            relativePath: "calls/\(callID)/me/chunk.pcm",
            bytes: 64_000,
            sha256: nil,
            finalized: true
        ))
        if micOnly {
            _ = try await repository.recordSourceSpan(CallSourceSpanDraft(
                callId: callID,
                source: .system,
                epoch: 0,
                sampleRate: 16_000,
                startedAtMs: 1_000,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .unavailable,
                gapReason: "permission_denied"
            ))
        }
        let created = try await repository.createBookmark(
            callID: callID,
            idempotencyKey: UUID().uuidString,
            acceptedAtMs: 2_000,
            meIngressTarget: 16_000,
            systemIngressTarget: nil,
            logicalStartMs: 1_000,
            logicalEndMs: 2_000,
            contextStartMs: 1_000
        )
        let bookmarkID = try XCTUnwrap(created.bookmark.id)
        _ = try await repository.freezeBookmarkCoverage(
            bookmarkID: bookmarkID,
            jobID: try XCTUnwrap(created.job.id),
            meEndSample: 16_000,
            systemEndSample: nil,
            degraded: micOnly,
            nowMs: 2_000
        )
        let checkpointCandidate = try await repository.claimNextTranscriptJob(nowMs: 2_001)
        let checkpoint = try XCTUnwrap(checkpointCandidate)
        _ = try await repository.commitTranscriptJob(
            jobID: try XCTUnwrap(checkpoint.id),
            segments: [CallTranscriptSegmentDraft(source: .me, startMs: 1_100, endMs: 1_900, text: "bookmark")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture",
            degraded: micOnly,
            nowMs: 2_100
        )
        _ = try await repository.endCall(callID: callID, idempotencyKey: UUID().uuidString, endedAtMs: 3_000)
        let finalCandidate = try await repository.claimNextTranscriptJob(nowMs: 3_001)
        let final = try XCTUnwrap(finalCandidate)
        let segments = (0..<segmentCount).map {
            CallTranscriptSegmentDraft(
                source: .me,
                startMs: 1_000 + Int64($0 * 10),
                endMs: 1_009 + Int64($0 * 10),
                text: "line \($0)"
            )
        }
        _ = try await repository.commitTranscriptJob(
            jobID: try XCTUnwrap(final.id),
            segments: segments,
            language: "en",
            engine: "fixture",
            modelRevision: "fixture",
            degraded: micOnly,
            nowMs: 3_100
        )
        return (callID, bookmarkID)
    }

    func makeRecordingCall() async throws -> Int64 {
        let call = try await repository.createCall(
            startedAtMs: Int64.random(in: 10_000...20_000),
            idempotencyKey: UUID().uuidString
        )
        return try XCTUnwrap(call.id)
    }

    func makeProcessingCall() async throws -> Int64 {
        let callID = try await makeRecordingCall()
        _ = try await repository.endCall(
            callID: callID,
            idempotencyKey: UUID().uuidString,
            endedAtMs: 21_000
        )
        return callID
    }

    func makeFailedCall() async throws -> Int64 {
        let callID = try await makeProcessingCall()
        let candidate = try await repository.claimNextTranscriptJob(nowMs: 22_000)
        let job = try XCTUnwrap(candidate)
        try await repository.failTranscriptJob(
            jobID: try XCTUnwrap(job.id),
            errorCode: "fixture_failed",
            retryable: false,
            nowMs: 22_100
        )
        return callID
    }

    func status(callID: Int64) async throws -> CallEvidenceStatus {
        let envelope = try await service.envelope(callID: callID)
        return try XCTUnwrap(envelope).status
    }
}

private enum OpenAPITestError: Error {
    case invalidContract(String)
}

private func loadCallOpenAPI() throws -> [String: Any] {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "ZBSEyeApp/Server/ZBSEyeHTTPServer.swift"
        ),
        encoding: .utf8
    )
    let prefix = "static let openAPISpec = #\"\"\"\n"
    let suffix = "\n    \"\"\"#"
    guard let start = source.range(of: prefix)?.upperBound,
          let end = source.range(of: suffix, range: start..<source.endIndex)?.lowerBound,
          let data = String(source[start..<end]).data(using: .utf8),
          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw OpenAPITestError.invalidContract("embedded OpenAPI JSON")
    }
    return root
}

private func successSchemaReference(
    path: String,
    paths: [String: Any]
) throws -> String {
    guard let pathItem = paths[path] as? [String: Any],
          let get = pathItem["get"] as? [String: Any],
          let responses = get["responses"] as? [String: Any],
          let success = responses["200"] as? [String: Any],
          let content = success["content"] as? [String: Any],
          let json = content["application/json"] as? [String: Any],
          let schema = json["schema"] as? [String: Any],
          let reference = schema["$ref"] as? String else {
        throw OpenAPITestError.invalidContract("missing 200 schema for \(path)")
    }
    return reference
}

private func resolveOpenAPIReference(
    _ reference: String,
    root: [String: Any]
) throws -> [String: Any] {
    guard reference.hasPrefix("#/") else {
        throw OpenAPITestError.invalidContract("unresolved reference \(reference)")
    }
    var current: Any = root
    for part in reference.dropFirst(2).split(separator: "/") {
        guard let dictionary = current as? [String: Any] else {
            throw OpenAPITestError.invalidContract("unresolved reference \(reference)")
        }
        let key = part.replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
        guard let next = dictionary[key] else {
            throw OpenAPITestError.invalidContract("unresolved reference \(reference)")
        }
        current = next
    }
    guard let resolved = current as? [String: Any] else {
        throw OpenAPITestError.invalidContract("unresolved reference \(reference)")
    }
    return resolved
}

private func encodedJSONObject<Value: Encodable>(_ value: Value) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}

private func validateOpenAPIValue(
    _ value: Any,
    schemaName: String,
    root: [String: Any]
) throws {
    try validateOpenAPIValue(
        value,
        schema: resolveOpenAPIReference("#/components/schemas/\(schemaName)", root: root),
        root: root,
        path: schemaName
    )
}

private func validateOpenAPIValue(
    _ value: Any,
    schema: [String: Any],
    root: [String: Any],
    path: String
) throws {
    if value is NSNull, schema["nullable"] as? Bool == true { return }
    if let reference = schema["$ref"] as? String {
        return try validateOpenAPIValue(
            value,
            schema: resolveOpenAPIReference(reference, root: root),
            root: root,
            path: path
        )
    }
    if let allOf = schema["allOf"] as? [[String: Any]] {
        for child in allOf {
            try validateOpenAPIValue(value, schema: child, root: root, path: path)
        }
    }
    guard let type = schema["type"] as? String else { return }
    switch type {
    case "object":
        guard let object = value as? [String: Any] else {
            throw OpenAPITestError.invalidContract("\(path) must be object")
        }
        for key in schema["required"] as? [String] ?? [] where object[key] == nil {
            throw OpenAPITestError.invalidContract("\(path).\(key) is required")
        }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        for (key, childValue) in object {
            guard let childSchema = properties[key] as? [String: Any] else {
                throw OpenAPITestError.invalidContract("\(path).\(key) is undocumented")
            }
            try validateOpenAPIValue(
                childValue,
                schema: childSchema,
                root: root,
                path: "\(path).\(key)"
            )
        }
    case "array":
        guard let array = value as? [Any],
              let itemSchema = schema["items"] as? [String: Any] else {
            throw OpenAPITestError.invalidContract("\(path) must be typed array")
        }
        for (index, item) in array.enumerated() {
            try validateOpenAPIValue(
                item,
                schema: itemSchema,
                root: root,
                path: "\(path)[\(index)]"
            )
        }
    case "string":
        guard let string = value as? String else {
            throw OpenAPITestError.invalidContract("\(path) must be string")
        }
        if let allowed = schema["enum"] as? [String], !allowed.contains(string) {
            throw OpenAPITestError.invalidContract("\(path) is outside enum")
        }
    case "integer":
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else {
            throw OpenAPITestError.invalidContract("\(path) must be integer")
        }
    case "boolean":
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw OpenAPITestError.invalidContract("\(path) must be boolean")
        }
    default:
        throw OpenAPITestError.invalidContract("unsupported schema type \(type)")
    }
}
