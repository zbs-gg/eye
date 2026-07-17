import Foundation
import GRDB

enum CallAutomationEventType: String, Codable, DatabaseValueConvertible, Sendable {
    case callEnded = "call.ended"
    case transcriptReady = "call.transcript.ready"
    case transcriptFailed = "call.transcript.failed"
}

enum CallAutomationDeliveryState: String, Codable, DatabaseValueConvertible, Sendable {
    case pending
    case sending
    case delivered
    case blocked
}

struct CallAutomationConfigRow: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_automation_config"

    var id: Int64
    var enabled: Bool
    var endpointURL: String?
    var endpointFingerprint: String?
    var updatedAtMs: Int64
}

struct CallAutomationOutboxRow: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "call_automation_outbox"

    var sequence: Int64
    var eventID: String
    var semanticIdentity: String
    var callId: Int64
    var eventType: CallAutomationEventType
    var occurredAtMs: Int64
    var endpointFingerprint: String
    var payloadJSON: String
    var state: CallAutomationDeliveryState
    var attempts: Int
    var nextAttemptAtMs: Int64
    var leaseExpiresAtMs: Int64?
    var httpStatus: Int?
    var lastErrorCode: String?
    var deliveredAtMs: Int64?
    var createdAtMs: Int64
    var updatedAtMs: Int64
}

struct CallEndedAutomationData: Codable, Sendable, Equatable {
    let state: String
    let interrupted: Bool
    let degraded: Bool
}

struct CallTranscriptReadyAutomationData: Codable, Sendable, Equatable {
    let state: String
    let degraded: Bool
    let revisionID: Int64

    enum CodingKeys: String, CodingKey {
        case state
        case degraded
        case revisionID = "revisionId"
    }
}

struct CallTranscriptFailedAutomationData: Codable, Sendable, Equatable {
    let state: String
    let errorCode: String
    let attempt: Int
}

enum CallAutomationOutbox {
    static func enqueueIfEnabled<Payload: Encodable>(
        eventType: CallAutomationEventType,
        semanticIdentity: String,
        callID: Int64,
        occurredAtMs: Int64,
        data: Payload,
        db: Database
    ) throws {
        guard let config = try CallAutomationConfigRow.fetchOne(db, key: 1),
              config.enabled,
              let fingerprint = config.endpointFingerprint else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadData = try encoder.encode(data)
        guard let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            throw DatabaseError(message: "call automation payload is not UTF-8")
        }
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO call_automation_outbox(
                    eventID, semanticIdentity, callId, eventType, occurredAtMs,
                    endpointFingerprint, payloadJSON, state, attempts,
                    nextAttemptAtMs, createdAtMs, updatedAtMs
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?, ?)
                """,
            arguments: [
                UUID().uuidString.lowercased(), semanticIdentity, callID, eventType.rawValue,
                occurredAtMs, fingerprint, payloadJSON, occurredAtMs, occurredAtMs, occurredAtMs,
            ]
        )
    }
}
