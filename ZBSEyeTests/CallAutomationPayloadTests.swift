import XCTest

final class CallAutomationPayloadTests: XCTestCase {
    func testReadyEventEncodingIsDeterministicAndDropsUnapprovedContent() throws {
        let event = CallAutomationOutboxRow(
            sequence: 1,
            eventID: "018f0000-0000-7000-8000-000000000001",
            semanticIdentity: "transcript-ready:7",
            callId: 42,
            eventType: .transcriptReady,
            occurredAtMs: 1_234,
            endpointFingerprint: "receiver-a",
            payloadJSON: #"{"degraded":false,"revisionId":7,"state":"ready","transcript":"PRIVATE TRANSCRIPT","path":"/Users/private/call.wav","token":"bearer-secret","title":"Private meeting"}"#,
            state: .pending,
            attempts: 0,
            nextAttemptAtMs: 1_234,
            leaseExpiresAtMs: nil,
            httpStatus: nil,
            lastErrorCode: nil,
            deliveredAtMs: nil,
            createdAtMs: 1_234,
            updatedAtMs: 1_234
        )

        let body = try CallAutomationPayload.encode(event: event)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertEqual(
            text,
            #"{"data":{"degraded":false,"revisionId":7,"state":"ready"},"dataschema":"zbseye://schemas/call-automation/v1","id":"018f0000-0000-7000-8000-000000000001","source":"zbseye://calls","specversion":"1.0","subject":"call:42","time":"1970-01-01T00:00:01.234Z","type":"call.transcript.ready"}"#
        )
        for canary in ["PRIVATE TRANSCRIPT", "/Users/private", "bearer-secret", "Private meeting"] {
            XCTAssertFalse(text.contains(canary), "leaked \(canary)")
        }
    }

    func testTestEventContainsNoCallSubjectOrCallData() throws {
        let body = try CallAutomationPayload.encodeTest(
            eventID: "018f0000-0000-7000-8000-000000000002",
            occurredAtMs: 1_234
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertEqual(object["type"] as? String, "call.automation.test")
        XCTAssertEqual(
            object["dataschema"] as? String,
            "zbseye://schemas/call-automation/v1"
        )
        XCTAssertNil(object["subject"])
        XCTAssertEqual((object["data"] as? [String: Any])?["status"] as? String, "test")
    }

    func testProcessingReadyIsHintOnlyAndDropsPrivateContent() throws {
        let event = CallAutomationOutboxRow(
            sequence: 2,
            eventID: "018f0000-0000-7000-8000-000000000003",
            semanticIdentity: "processing-ready:42:0:7:8",
            callId: 42,
            eventType: .processingReady,
            occurredAtMs: 1_234,
            endpointFingerprint: "receiver-a",
            payloadJSON: #"{"speakerRevisionId":8,"state":"ready","transcriptRevisionId":7,"transcript":"PRIVATE TRANSCRIPT","speakerName":"Olga","path":"/Users/private/call.wav"}"#,
            state: .pending,
            attempts: 0,
            nextAttemptAtMs: 1_234,
            leaseExpiresAtMs: nil,
            httpStatus: nil,
            lastErrorCode: nil,
            deliveredAtMs: nil,
            createdAtMs: 1_234,
            updatedAtMs: 1_234
        )

        let body = try CallAutomationPayload.encode(event: event)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertEqual(
            text,
            #"{"data":{"speakerRevisionId":8,"state":"ready","transcriptRevisionId":7},"dataschema":"zbseye://schemas/call-automation/v1","id":"018f0000-0000-7000-8000-000000000003","source":"zbseye://calls","specversion":"1.0","subject":"call:42","time":"1970-01-01T00:00:01.234Z","type":"call.processing.ready"}"#
        )
        for canary in ["PRIVATE TRANSCRIPT", "Olga", "/Users/private"] {
            XCTAssertFalse(text.contains(canary), "leaked \(canary)")
        }
    }

    func testFailureErrorCodeCannotCarryPrivateFreeformContent() throws {
        var event = Self.failureEvent(
            errorCode: "helper failed at /Users/private/call.wav with bearer-secret"
        )

        let body = try CallAutomationPayload.encode(event: event)
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertFalse(text.contains("/Users/private"))
        XCTAssertFalse(text.contains("bearer-secret"))
        XCTAssertTrue(text.contains(#""errorCode":"transcription_failed""#))

        event.payloadJSON = #"{"attempt":3,"errorCode":"helper_timeout","state":"failed"}"#
        let typedBody = try CallAutomationPayload.encode(event: event)
        XCTAssertTrue(
            try XCTUnwrap(String(data: typedBody, encoding: .utf8))
                .contains(#""errorCode":"helper_timeout""#)
        )
    }

    func testSignatureMatchesIndependentStableFixture() {
        let body = Data("{}".utf8)
        let signature = CallAutomationSignature.make(
            secret: "test-secret",
            timestampSeconds: 1_700_000_000,
            body: body
        )

        XCTAssertEqual(
            signature,
            "sha256=87d3ed18b9b403e7da0fc3a3ae8b9394303805a049ea06f87c2ef4380b521fa9"
        )
    }

    private static func failureEvent(errorCode: String) -> CallAutomationOutboxRow {
        CallAutomationOutboxRow(
            sequence: 1,
            eventID: "018f0000-0000-7000-8000-000000000004",
            semanticIdentity: "transcript-failed:7:3",
            callId: 42,
            eventType: .transcriptFailed,
            occurredAtMs: 1_234,
            endpointFingerprint: "receiver-a",
            payloadJSON: #"{"attempt":3,"errorCode":"\#(errorCode)","state":"failed"}"#,
            state: .pending,
            attempts: 0,
            nextAttemptAtMs: 1_234,
            leaseExpiresAtMs: nil,
            httpStatus: nil,
            lastErrorCode: nil,
            deliveredAtMs: nil,
            createdAtMs: 1_234,
            updatedAtMs: 1_234
        )
    }
}
