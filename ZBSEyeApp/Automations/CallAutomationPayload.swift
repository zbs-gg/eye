import CryptoKit
import Foundation

enum CallAutomationPayloadError: Error, Sendable, Equatable {
    case invalidStoredData
    case invalidEvent
    case bodyTooLarge
}

/// Encodes the public webhook contract from an explicit allowlist. `payloadJSON` is durable
/// internal state, so unknown keys must never flow to the receiver by accident.
enum CallAutomationPayload {
    static let maximumBodyBytes = 64 * 1_024

    static func encode(event: CallAutomationOutboxRow) throws -> Data {
        guard event.callId > 0, !event.eventID.isEmpty else {
            throw CallAutomationPayloadError.invalidEvent
        }
        let stored = try storedData(event.payloadJSON)
        switch event.eventType {
        case .callEnded:
            return try encodeEnvelope(
                event: event,
                data: decode(CallEndedAutomationData.self, from: stored)
            )
        case .transcriptReady:
            return try encodeEnvelope(
                event: event,
                data: decode(CallTranscriptReadyAutomationData.self, from: stored)
            )
        case .transcriptFailed:
            let decoded = try decode(CallTranscriptFailedAutomationData.self, from: stored)
            return try encodeEnvelope(
                event: event,
                data: CallTranscriptFailedAutomationData(
                    state: decoded.state,
                    errorCode: safeErrorCode(decoded.errorCode),
                    attempt: decoded.attempt
                )
            )
        }
    }

    static func encodeTest(eventID: String, occurredAtMs: Int64) throws -> Data {
        guard !eventID.isEmpty else { throw CallAutomationPayloadError.invalidEvent }
        return try encodeEnvelope(
            eventID: eventID,
            type: "call.automation.test",
            subject: nil,
            occurredAtMs: occurredAtMs,
            data: CallAutomationTestData(status: "test")
        )
    }

    private static func storedData(_ json: String) throws -> Data {
        guard let bytes = json.data(using: .utf8) else {
            throw CallAutomationPayloadError.invalidStoredData
        }
        return bytes
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CallAutomationPayloadError.invalidStoredData
        }
    }

    private static func safeErrorCode(_ candidate: String?) -> String {
        guard let candidate,
              (1...64).contains(candidate.utf8.count),
              candidate.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || byte == UInt8(ascii: "_")
                      || byte == UInt8(ascii: "-")
                      || byte == UInt8(ascii: ".")
              }) else { return "transcription_failed" }
        return candidate
    }

    private static func encodeEnvelope<Payload: Encodable>(
        event: CallAutomationOutboxRow,
        data: Payload
    ) throws -> Data {
        try encodeEnvelope(
            eventID: event.eventID,
            type: event.eventType.rawValue,
            subject: "call:\(event.callId)",
            occurredAtMs: event.occurredAtMs,
            data: data
        )
    }

    private static func encodeEnvelope<Payload: Encodable>(
        eventID: String,
        type: String,
        subject: String?,
        occurredAtMs: Int64,
        data: Payload
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(
            CallAutomationEnvelope(
                specversion: "1.0",
                dataschema: "zbseye://schemas/call-automation/v1",
                id: eventID,
                source: "zbseye://calls",
                type: type,
                subject: subject,
                time: timestamp(occurredAtMs),
                data: data
            )
        )
        guard body.count <= maximumBodyBytes else {
            throw CallAutomationPayloadError.bodyTooLarge
        }
        return body
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
}

private struct CallAutomationTestData: Encodable {
    let status: String
}

private struct CallAutomationEnvelope<Payload: Encodable>: Encodable {
    let specversion: String
    let dataschema: String
    let id: String
    let source: String
    let type: String
    let subject: String?
    let time: String
    let data: Payload
}

enum CallAutomationSignature {
    static func make(secret: String, timestampSeconds: Int64, body: Data) -> String {
        let code = authenticationCode(
            secret: secret,
            timestampSeconds: timestampSeconds,
            body: body
        )
        return "sha256=" + code.map { String(format: "%02x", $0) }.joined()
    }

    private static func authenticationCode(
        secret: String,
        timestampSeconds: Int64,
        body: Data
    ) -> HMAC<SHA256>.MAC {
        HMAC<SHA256>.authenticationCode(
            for: signedMessage(timestampSeconds: timestampSeconds, body: body),
            using: SymmetricKey(data: Data(secret.utf8))
        )
    }

    private static func signedMessage(timestampSeconds: Int64, body: Data) -> Data {
        var message = Data("\(timestampSeconds).".utf8)
        message.append(body)
        return message
    }

}
