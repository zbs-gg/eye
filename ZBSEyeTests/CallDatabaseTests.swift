import XCTest
import GRDB

final class CallDatabaseTests: XCTestCase {
    func testV14RemovesMoreThanOneThousandProtectedDerivedRowsAndPreservesSources() async throws {
        let store = try CallDatabaseTestStore(runMigrations: false)
        try ZBSEyeDatabase.migrator.migrate(
            store.database.pool,
            upTo: "v13_call_processing_ready_event"
        )
        let protectedCount = 1_001
        let vector = floatBlob(
            [1] + Array(repeating: 0, count: ZBSEyeDatabase.embeddingDim - 1)
        )

        let fixture = try await store.database.pool.write { db -> (protectedIDs: [Int64], visibleID: Int64) in
            try db.execute(
                sql: "INSERT INTO apps(bundleId, name) VALUES (?, ?)",
                arguments: ["com.apple.LocalAuthentication.UIAgent", "LocalAuthentication UIAgent"]
            )
            let protectedAppID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO apps(bundleId, name) VALUES (?, ?)",
                arguments: ["com.example.visible", "Visible Editor"]
            )
            let visibleAppID = db.lastInsertedRowID

            var protectedIDs: [Int64] = []
            protectedIDs.reserveCapacity(protectedCount)
            for index in 0..<protectedCount {
                try db.execute(
                    sql: "INSERT INTO screen_captures(ts, appId, monitorId) VALUES (?, ?, 'main')",
                    arguments: [Int64(index + 1) * 1_000, protectedAppID]
                )
                let captureID = db.lastInsertedRowID
                protectedIDs.append(captureID)
                try db.execute(
                    sql: "INSERT INTO text_blocks(captureId, source, text) VALUES (?, 'ocr', ?)",
                    arguments: [captureID, "protected source \(index)"]
                )
                try db.execute(
                    sql: "INSERT INTO embed_queue(row_id, kind, ts) VALUES (?, 0, ?)",
                    arguments: [captureID, Int64(index + 1) * 1_000]
                )
                try db.execute(
                    sql: "INSERT INTO vec_screen(capture_id, bucket_month, embedding) VALUES (?, 197001, ?)",
                    arguments: [captureID, vector]
                )
            }

            try db.execute(
                sql: "INSERT INTO screen_captures(ts, appId, monitorId) VALUES (2000000, ?, 'main')",
                arguments: [visibleAppID]
            )
            let visibleID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO text_blocks(captureId, source, text) VALUES (?, 'ocr', 'visible source')",
                arguments: [visibleID]
            )
            try db.execute(
                sql: "INSERT INTO embed_queue(row_id, kind, ts) VALUES (?, 0, 2000000)",
                arguments: [visibleID]
            )
            try db.execute(
                sql: "INSERT INTO vec_screen(capture_id, bucket_month, embedding) VALUES (?, 197001, ?)",
                arguments: [visibleID, vector]
            )
            return (protectedIDs, visibleID)
        }

        try ZBSEyeDatabase.migrator.migrate(store.database.pool)

        let snapshot = try await store.database.pool.read { db in
            (
                captureCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screen_captures") ?? -1,
                textCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM text_blocks") ?? -1,
                vectorIDs: try Int64.fetchAll(db, sql: "SELECT capture_id FROM vec_screen ORDER BY capture_id"),
                queueIDs: try Int64.fetchAll(
                    db,
                    sql: "SELECT row_id FROM embed_queue WHERE kind = 0 ORDER BY row_id"
                )
            )
        }

        XCTAssertEqual(snapshot.captureCount, protectedCount + 1)
        XCTAssertEqual(snapshot.textCount, protectedCount + 1)
        XCTAssertEqual(snapshot.vectorIDs, [fixture.visibleID])
        XCTAssertEqual(snapshot.queueIDs, [fixture.visibleID])
        XCTAssertEqual(fixture.protectedIDs.count, protectedCount)
    }

    func testVectorBackfillRejectsProtectedTextAndReattestsBeforeVectorWrite() async throws {
        let store = try CallDatabaseTestStore()
        let vector = floatBlob(
            [1] + Array(repeating: 0, count: ZBSEyeDatabase.embeddingDim - 1)
        )
        let fixture = try await store.database.pool.write { db -> (protectedID: Int64, visibleID: Int64) in
            // Exercise the process-name fallback too: legacy rows may not carry a canonical auth bundle id.
            try db.execute(
                sql: "INSERT INTO apps(bundleId, name) VALUES (?, ?)",
                arguments: ["com.example.legacy-auth", "SecurityAgent"]
            )
            let protectedAppID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO apps(bundleId, name) VALUES (?, ?)",
                arguments: ["com.example.notes", "Notes"]
            )
            let visibleAppID = db.lastInsertedRowID

            try db.execute(
                sql: "INSERT INTO screen_captures(ts, appId, monitorId) VALUES (1000, ?, 'main')",
                arguments: [protectedAppID]
            )
            let protectedID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO text_blocks(captureId, source, text) VALUES (?, 'ocr', 'private auth words')",
                arguments: [protectedID]
            )
            try db.execute(
                sql: "INSERT INTO vec_screen(capture_id, bucket_month, embedding) VALUES (?, 197001, ?)",
                arguments: [protectedID, vector]
            )

            try db.execute(
                sql: "INSERT INTO screen_captures(ts, appId, monitorId) VALUES (2000, ?, 'main')",
                arguments: [visibleAppID]
            )
            let visibleID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO text_blocks(captureId, source, text) VALUES (?, 'ocr', 'ordinary notes')",
                arguments: [visibleID]
            )
            return (protectedID, visibleID)
        }

        let result = try await store.database.pool.write { db in
            let protectedText = try ZBSEyeDatabase.screenTextForSemanticIndexing(
                captureID: fixture.protectedID,
                in: db
            )
            let visibleText = try ZBSEyeDatabase.screenTextForSemanticIndexing(
                captureID: fixture.visibleID,
                in: db
            )
            let protectedInserted = try ZBSEyeDatabase.replaceScreenSemanticVectorIfVisible(
                captureID: fixture.protectedID,
                bucket: 197001,
                blob: vector,
                in: db
            )
            let visibleInserted = try ZBSEyeDatabase.replaceScreenSemanticVectorIfVisible(
                captureID: fixture.visibleID,
                bucket: 197001,
                blob: vector,
                in: db
            )
            return (
                protectedText,
                visibleText,
                protectedInserted,
                visibleInserted,
                vectorIDs: try Int64.fetchAll(db, sql: "SELECT capture_id FROM vec_screen ORDER BY capture_id"),
                sourceCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screen_captures") ?? -1,
                textCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM text_blocks") ?? -1
            )
        }

        XCTAssertNil(result.0)
        XCTAssertEqual(result.1, "ordinary notes")
        XCTAssertFalse(result.2)
        XCTAssertTrue(result.3)
        XCTAssertEqual(result.vectorIDs, [fixture.visibleID])
        XCTAssertEqual(result.sourceCount, 2)
        XCTAssertEqual(result.textCount, 2)
    }

    func testFreshAndV6StoresMigrateWithoutLosingExistingRows() async throws {
        let fresh = try CallDatabaseTestStore()
        let freshTables = try await fresh.database.pool.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))
        }
        XCTAssertTrue([
            "calls", "call_source_spans", "call_audio_chunks", "call_bookmarks",
            "call_transcript_jobs", "call_transcript_revisions",
            "call_transcript_segments", "call_transcript_projection_gaps",
            "call_media_mutations", "call_source_gaps", "call_transcript_fts",
            "call_automation_config", "call_automation_outbox",
            "call_context", "call_speaker_revisions", "call_speaker_clusters",
            "call_speaker_intervals", "capture_coverage_intervals",
        ].allSatisfy(freshTables.contains))

        let upgraded = try CallDatabaseTestStore(runMigrations: false)
        try ZBSEyeDatabase.migrator.migrate(upgraded.database.pool, upTo: "v6_embed_queue")
        try await upgraded.database.pool.write { db in
            try db.execute(sql: "INSERT INTO apps(id, bundleId, name) VALUES (17, 'fixture.app', 'Fixture')")
        }

        try ZBSEyeDatabase.migrator.migrate(upgraded.database.pool)

        let snapshot = try await upgraded.database.pool.read { db in
            (
                appCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM apps") ?? 0,
                migrations: try String.fetchAll(
                    db,
                    sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
                ),
                triggerCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'call_%'"
                ) ?? 0
            )
        }
        XCTAssertEqual(snapshot.appCount, 1)
        XCTAssertEqual(snapshot.migrations.last, "v16_activity_day_summary")
        XCTAssertGreaterThanOrEqual(snapshot.triggerCount, 6)
    }

    func testAutomaticCallContextEnrichmentOnlyFillsMissingTrustedEvidence() async throws {
        let store = try CallDatabaseTestStore()
        let repository = CallRepository(database: store.database)

        let confirmedCall = try await repository.createCall(
            startedAtMs: 900,
            idempotencyKey: "automatic-context-confirmed"
        )
        let confirmedCallID = try XCTUnwrap(confirmedCall.id)

        try await repository.enrichAutomaticCallContext(
            callID: confirmedCallID,
            detectorFingerprint: "sha256:first-detector-fingerprint",
            sourceAppBundleID: nil,
            sourceAppName: nil,
            trustedOriginHost: nil,
            nowMs: 1_000
        )
        try await repository.enrichAutomaticCallContext(
            callID: confirmedCallID,
            detectorFingerprint: "sha256:synthetic-event-must-not-replace-fingerprint",
            sourceAppBundleID: "process-pid:412",
            sourceAppName: "Unknown Helper",
            trustedOriginHost: nil,
            nowMs: 1_050
        )
        try await repository.enrichAutomaticCallContext(
            callID: confirmedCallID,
            detectorFingerprint: "sha256:generic-owner",
            sourceAppBundleID: "ai.krisp.krispMac",
            sourceAppName: "Krisp",
            trustedOriginHost: nil,
            nowMs: 1_075
        )
        try await repository.updateCallCaptureContext(
            callID: confirmedCallID,
            owner: .automatic,
            disposition: .confirmed,
            nowMs: 1_100
        )
        try await repository.enrichAutomaticCallContext(
            callID: confirmedCallID,
            detectorFingerprint: "sha256:late-event-must-not-replace-fingerprint",
            sourceAppBundleID: "com.google.Chrome",
            sourceAppName: "Google Chrome",
            trustedOriginHost: "meet.google.com",
            replaceExistingSource: true,
            nowMs: 1_200
        )
        try await repository.enrichAutomaticCallContext(
            callID: confirmedCallID,
            detectorFingerprint: "sha256:conflicting-event",
            sourceAppBundleID: "us.zoom.xos",
            sourceAppName: "Zoom",
            trustedOriginHost: "zoom.us",
            nowMs: 1_300
        )

        let confirmedContext = try await store.database.pool.read { db in
            try CallContextRow.fetchOne(db, key: confirmedCallID)
        }
        XCTAssertEqual(confirmedContext?.captureOwner, .automatic)
        XCTAssertEqual(confirmedContext?.disposition, .confirmed)
        XCTAssertEqual(
            confirmedContext?.detectorFingerprintHash,
            "sha256:first-detector-fingerprint"
        )
        XCTAssertEqual(confirmedContext?.sourceAppBundleID, "com.google.Chrome")
        XCTAssertEqual(confirmedContext?.sourceAppName, "Google Chrome")
        XCTAssertEqual(confirmedContext?.trustedOriginHost, "meet.google.com")
        XCTAssertEqual(confirmedContext?.createdAtMs, 1_000)
        XCTAssertEqual(confirmedContext?.updatedAtMs, 1_300)

        _ = try await repository.endCall(
            callID: confirmedCallID,
            idempotencyKey: "automatic-context-confirmed-end",
            endedAtMs: 1_400
        )

        let rejectedCall = try await repository.createCall(
            startedAtMs: 1_900,
            idempotencyKey: "automatic-context-rejected"
        )
        let rejectedCallID = try XCTUnwrap(rejectedCall.id)
        try await repository.enrichAutomaticCallContext(
            callID: rejectedCallID,
            detectorFingerprint: "sha256:rejected-fingerprint",
            sourceAppBundleID: "process:unknown",
            sourceAppName: "Unknown Process",
            trustedOriginHost: nil,
            nowMs: 2_000
        )
        try await repository.updateCallCaptureContext(
            callID: rejectedCallID,
            owner: .claimed,
            disposition: .rejected,
            nowMs: 2_100
        )
        try await repository.enrichAutomaticCallContext(
            callID: rejectedCallID,
            detectorFingerprint: "sha256:rejected-late-event",
            sourceAppBundleID: "com.openai.codex",
            sourceAppName: "ChatGPT",
            trustedOriginHost: "chatgpt.com",
            nowMs: 2_200
        )

        let rejectedContext = try await store.database.pool.read { db in
            try CallContextRow.fetchOne(db, key: rejectedCallID)
        }
        XCTAssertEqual(rejectedContext?.captureOwner, .claimed)
        XCTAssertEqual(rejectedContext?.disposition, .rejected)
        XCTAssertEqual(rejectedContext?.detectorFingerprintHash, "sha256:rejected-fingerprint")
        XCTAssertEqual(rejectedContext?.sourceAppBundleID, "process:unknown")
        XCTAssertEqual(rejectedContext?.sourceAppName, "Unknown Process")
        XCTAssertNil(rejectedContext?.trustedOriginHost)
        XCTAssertEqual(rejectedContext?.createdAtMs, 2_000)
        XCTAssertEqual(rejectedContext?.updatedAtMs, 2_100)
    }

    func testCallContextAndSpeakerRevisionAreGenerationBoundRevisionedAndCascading() async throws {
        let store = try CallDatabaseTestStore()
        let repository = CallRepository(database: store.database)
        let call = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "speaker-call")
        let callID = try XCTUnwrap(call.id)

        let context = CallContextRow(
            callId: callID,
            captureOwner: .automatic,
            disposition: .confirmed,
            detectorFingerprintHash: "sha256:fixture",
            sourceAppBundleID: "us.zoom.xos",
            sourceAppName: "Zoom",
            trustedOriginHost: nil,
            title: "Client call",
            participantsJSON: "[\"Olga\"]",
            createdAtMs: 1_000,
            updatedAtMs: 1_100
        )
        try await repository.upsertCallContext(context)

        let first = try await repository.createSpeakerRevision(
            callID: callID,
            mediaGeneration: 0,
            engine: "fixture",
            modelRevision: "fixture-v1",
            clusters: [
                CallSpeakerClusterDraft(
                    clusterKey: "speaker-1",
                    displayName: "Olga",
                    namingProvenance: .manual,
                    intervals: [
                        CallSpeakerIntervalDraft(
                            source: .system,
                            startMs: 1_100,
                            endMs: 1_500
                        ),
                    ]
                ),
            ],
            nowMs: 2_000
        )
        try await repository.setPreferredSpeakerRevision(callID: callID, revisionID: try XCTUnwrap(first.id))

        let second = try await repository.createSpeakerRevision(
            callID: callID,
            mediaGeneration: 0,
            engine: "manual",
            modelRevision: "annotation-v1",
            clusters: [
                CallSpeakerClusterDraft(
                    clusterKey: "speaker-1",
                    displayName: "Olga Makhova",
                    namingProvenance: .manual,
                    intervals: [
                        CallSpeakerIntervalDraft(
                            source: .system,
                            startMs: 1_100,
                            endMs: 1_500
                        ),
                    ]
                ),
            ],
            nowMs: 2_100
        )
        try await repository.setPreferredSpeakerRevision(callID: callID, revisionID: try XCTUnwrap(second.id))

        try await store.database.pool.write { db in
            try db.execute(
                sql: "UPDATE calls SET preferredSpeakerRevisionId = NULL, mediaGeneration = 1 WHERE id = ?",
                arguments: [callID]
            )
        }
        await XCTAssertThrowsAsync {
            try await repository.setPreferredSpeakerRevision(callID: callID, revisionID: try XCTUnwrap(first.id))
        }

        let beforeErase = try await store.database.pool.read { db in
            (
                context: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_context WHERE callId = ?", arguments: [callID]) ?? 0,
                revisions: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_speaker_revisions WHERE callId = ?", arguments: [callID]) ?? 0,
                clusters: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_speaker_clusters") ?? 0,
                intervals: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_speaker_intervals") ?? 0
            )
        }
        XCTAssertEqual(beforeErase.context, 1)
        XCTAssertEqual(beforeErase.revisions, 2, "Undo needs the previous immutable revision")
        XCTAssertEqual(beforeErase.clusters, 2)
        XCTAssertEqual(beforeErase.intervals, 2)

        try await store.database.pool.write { db in
            try db.execute(sql: "DELETE FROM calls WHERE id = ?", arguments: [callID])
        }
        let afterErase = try await store.database.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM call_context) +
                        (SELECT COUNT(*) FROM call_speaker_revisions) +
                        (SELECT COUNT(*) FROM call_speaker_clusters) +
                        (SELECT COUNT(*) FROM call_speaker_intervals)
                    """
            ) ?? -1
        }
        XCTAssertEqual(afterErase, 0)
    }

    func testTranscriptSpeakerAlignmentUsesUniqueMaximumOverlapAndPreservesSource() {
        let transcript = [
            CallTranscriptSegmentDraft(source: .system, startMs: 100, endMs: 200, text: "tie"),
            CallTranscriptSegmentDraft(source: .system, startMs: 200, endMs: 300, text: "winner"),
            CallTranscriptSegmentDraft(source: .system, startMs: 300, endMs: 500, text: "несколько окон"),
            CallTranscriptSegmentDraft(source: .me, startMs: 100, endMs: 200, text: "my source"),
            CallTranscriptSegmentDraft(source: .system, startMs: 600, endMs: 700, text: "silence"),
        ]
        let clusters = [
            CallSpeakerClusterDraft(
                clusterKey: "system:S1",
                displayName: nil,
                namingProvenance: .anonymous,
                intervals: [
                    .init(source: .system, startMs: 100, endMs: 150),
                    .init(source: .system, startMs: 200, endMs: 260),
                    .init(source: .system, startMs: 340, endMs: 400),
                ]
            ),
            CallSpeakerClusterDraft(
                clusterKey: "system:S2",
                displayName: nil,
                namingProvenance: .anonymous,
                intervals: [
                    .init(source: .system, startMs: 150, endMs: 200),
                    .init(source: .system, startMs: 260, endMs: 300),
                    .init(source: .system, startMs: 300, endMs: 340),
                    .init(source: .system, startMs: 460, endMs: 500),
                ]
            ),
            CallSpeakerClusterDraft(
                clusterKey: "me:S1",
                displayName: nil,
                namingProvenance: .anonymous,
                intervals: [.init(source: .me, startMs: 100, endMs: 200)]
            ),
        ]

        let aligned = CallTranscriptSpeakerAligner.align(transcript, to: clusters)

        XCTAssertEqual(aligned.map(\.segment.source), transcript.map(\.source))
        XCTAssertEqual(
            aligned.map(\.speakerClusterKey),
            [nil, "system:S1", "system:S2", "me:S1", nil]
        )
    }

    func testSpeakerRenameReassignmentAndUndoCreateImmutablePreferredRevisions() async throws {
        let store = try CallDatabaseTestStore()
        let repository = CallRepository(database: store.database)
        let callID = try await makeEndedCorrectionCall(repository: repository)
        let initial = try await makeInitialSpeakerRevision(repository: repository, callID: callID)

        let renamed = try await repository.renameSpeakerCluster(
            callID: callID,
            clusterKey: "system:S1",
            displayName: "  Olga  ",
            nowMs: 3_000
        )
        let renamedID = try XCTUnwrap(renamed.id)
        XCTAssertEqual(renamed.previousRevisionId, initial.id)
        let renamedSnapshot = try await speakerRevisionSnapshot(
            database: store.database,
            revisionID: renamedID
        )
        XCTAssertEqual(renamedSnapshot.names["system:S1"], "Olga")
        XCTAssertEqual(renamedSnapshot.provenance["system:S1"], .manual)
        XCTAssertEqual(
            renamedSnapshot.intervals,
            [
                .init(clusterKey: "me:S1", source: .me, startMs: 100, endMs: 400),
                .init(clusterKey: "system:S1", source: .system, startMs: 100, endMs: 200),
                .init(clusterKey: "system:S1", source: .system, startMs: 300, endMs: 400),
                .init(clusterKey: "system:S2", source: .system, startMs: 200, endMs: 300),
            ]
        )

        let reassigned = try await repository.reassignSpeakerInterval(
            callID: callID,
            selection: .init(source: .system, startMs: 150, endMs: 250),
            target: .newNamedSpeaker(" Dima "),
            nowMs: 3_100
        )
        let reassignedID = try XCTUnwrap(reassigned.id)
        XCTAssertEqual(reassigned.previousRevisionId, renamed.id)
        let reassignedSnapshot = try await speakerRevisionSnapshot(
            database: store.database,
            revisionID: reassignedID
        )
        XCTAssertEqual(reassignedSnapshot.names["manual:S1"], "Dima")
        XCTAssertEqual(reassignedSnapshot.provenance["manual:S1"], .manual)
        XCTAssertEqual(
            reassignedSnapshot.intervals,
            [
                .init(clusterKey: "manual:S1", source: .system, startMs: 150, endMs: 250),
                .init(clusterKey: "me:S1", source: .me, startMs: 100, endMs: 400),
                .init(clusterKey: "system:S1", source: .system, startMs: 100, endMs: 150),
                .init(clusterKey: "system:S1", source: .system, startMs: 300, endMs: 400),
                .init(clusterKey: "system:S2", source: .system, startMs: 250, endMs: 300),
            ]
        )

        let restored = try await repository.undoSpeakerCorrection(callID: callID, nowMs: 3_200)
        XCTAssertEqual(restored.id, renamed.id)
        let databaseState = try await store.database.pool.read { db in
            (
                preferred: try Int64.fetchOne(
                    db,
                    sql: "SELECT preferredSpeakerRevisionId FROM calls WHERE id = ?",
                    arguments: [callID]
                ),
                revisionCount: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_speaker_revisions WHERE callId = ?",
                    arguments: [callID]
                ) ?? -1,
                originalName: try String.fetchOne(
                    db,
                    sql: """
                        SELECT displayName FROM call_speaker_clusters
                        WHERE revisionId = ? AND clusterKey = 'system:S1'
                        """,
                    arguments: [initial.id]
                )
            )
        }
        XCTAssertEqual(databaseState.preferred, renamed.id)
        XCTAssertEqual(databaseState.revisionCount, 3)
        XCTAssertNil(databaseState.originalName, "Earlier revisions must remain immutable")
    }

    func testIntervalReassignmentCanTargetExistingClusterWithoutChangingAudioSource() async throws {
        let store = try CallDatabaseTestStore()
        let repository = CallRepository(database: store.database)
        let callID = try await makeEndedCorrectionCall(repository: repository)
        _ = try await makeInitialSpeakerRevision(repository: repository, callID: callID)

        let revision = try await repository.reassignSpeakerInterval(
            callID: callID,
            selection: .init(source: .system, startMs: 150, endMs: 250),
            target: .existingCluster(clusterKey: "system:S2"),
            nowMs: 3_000
        )
        let snapshot = try await speakerRevisionSnapshot(
            database: store.database,
            revisionID: try XCTUnwrap(revision.id)
        )

        XCTAssertEqual(
            snapshot.intervals,
            [
                .init(clusterKey: "me:S1", source: .me, startMs: 100, endMs: 400),
                .init(clusterKey: "system:S1", source: .system, startMs: 100, endMs: 150),
                .init(clusterKey: "system:S1", source: .system, startMs: 300, endMs: 400),
                .init(clusterKey: "system:S2", source: .system, startMs: 150, endMs: 300),
            ]
        )
    }

    func testEnabledCallTransitionsEnqueueEndedAndPreferredFinalAtomically() async throws {
        let store = try CallDatabaseTestStore()
        try await store.database.pool.write { db in
            try db.execute(
                sql: """
                    UPDATE call_automation_config
                    SET enabled = 1,
                        endpointURL = 'http://127.0.0.1:7777/events',
                        endpointFingerprint = 'receiver-a',
                        updatedAtMs = 900
                    WHERE id = 1
                    """
            )
        }
        let repository = CallRepository(database: store.database)
        let call = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "hook-call")
        let callID = try XCTUnwrap(call.id)
        let finalJob = try await repository.endCall(
            callID: callID,
            idempotencyKey: "hook-end",
            endedAtMs: 2_000
        )

        let endedEvents = try await store.database.pool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT eventType FROM call_automation_outbox WHERE callId = ? ORDER BY sequence",
                arguments: [callID]
            )
        }
        XCTAssertEqual(endedEvents, ["call.ended"])

        let claim = try await repository.claimNextTranscriptJob(nowMs: 2_100)
        XCTAssertEqual(claim?.id, finalJob.id)
        _ = try await repository.commitTranscriptJob(
            jobID: try XCTUnwrap(claim?.id),
            segments: [.init(source: .me, startMs: 1_100, endMs: 1_900, text: "private")],
            language: "en",
            engine: "fixture",
            modelRevision: "fixture-v1",
            degraded: false,
            nowMs: 2_200
        )

        let snapshot = try await store.database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT eventType, payloadJSON
                    FROM call_automation_outbox
                    WHERE callId = ?
                    ORDER BY sequence
                    """,
                arguments: [callID]
            )
        }
        XCTAssertEqual(snapshot.map { $0["eventType"] as String }, [
            "call.ended", "call.transcript.ready",
        ])
        XCTAssertTrue(snapshot.allSatisfy { row in
            let payload: String = row["payloadJSON"]
            return !payload.contains("private")
        })
    }

    func testPreferredRevisionAcceptsReadyProjectionThenFinalAndCleansStaleSearchState() async throws {
        let store = try CallDatabaseTestStore()
        let repository = CallRepository(database: store.database)
        let first = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "call-a")
        let firstFinal = try await repository.endCall(
            callID: try XCTUnwrap(first.id),
            idempotencyKey: "end-a",
            endedAtMs: 2_000
        )
        let second = try await repository.createCall(startedAtMs: 3_000, idempotencyKey: "call-b")
        let secondFinal = try await repository.endCall(
            callID: try XCTUnwrap(second.id),
            idempotencyKey: "end-b",
            endedAtMs: 4_000
        )

        let ids = try await store.database.pool.write { db -> (Int64, Int64, Int64, Int64) in
            var firstReady = CallTranscriptRevisionRow(
                id: nil,
                callId: try XCTUnwrap(first.id),
                jobId: try XCTUnwrap(firstFinal.id),
                projectionKey: nil,
                kind: .final,
                mediaGeneration: 0,
                state: .ready,
                text: "first",
                language: "en",
                engine: "fixture",
                modelRevision: "fixture",
                logicalStartMs: 1_000,
                logicalEndMs: 2_000,
                createdAtMs: 5_000
            )
            try firstReady.insert(db)
            var firstNotReady = CallTranscriptRevisionRow(
                id: nil,
                callId: try XCTUnwrap(first.id),
                jobId: nil,
                projectionKey: "draft-a",
                kind: .final,
                mediaGeneration: 0,
                state: .writing,
                text: "draft",
                language: "en",
                engine: "fixture",
                modelRevision: "fixture",
                logicalStartMs: 1_000,
                logicalEndMs: 2_000,
                createdAtMs: 5_001
            )
            try firstNotReady.insert(db)
            var secondReady = CallTranscriptRevisionRow(
                id: nil,
                callId: try XCTUnwrap(second.id),
                jobId: try XCTUnwrap(secondFinal.id),
                projectionKey: nil,
                kind: .final,
                mediaGeneration: 0,
                state: .ready,
                text: "second",
                language: "en",
                engine: "fixture",
                modelRevision: "fixture",
                logicalStartMs: 3_000,
                logicalEndMs: 4_000,
                createdAtMs: 5_002
            )
            try secondReady.insert(db)
            var firstProjection = CallTranscriptRevisionRow(
                id: nil,
                callId: try XCTUnwrap(first.id),
                jobId: nil,
                projectionKey: "projection-a",
                kind: .projection,
                mediaGeneration: 0,
                state: .ready,
                text: "provisional",
                language: "en",
                engine: "fixture",
                modelRevision: "fixture",
                logicalStartMs: 1_000,
                logicalEndMs: 1_500,
                createdAtMs: 4_999
            )
            try firstProjection.insert(db)
            return (
                try XCTUnwrap(firstReady.id),
                try XCTUnwrap(firstNotReady.id),
                try XCTUnwrap(secondReady.id),
                try XCTUnwrap(firstProjection.id)
            )
        }

        await XCTAssertThrowsAsync {
            try await repository.setPreferredRevision(callID: try XCTUnwrap(first.id), revisionID: ids.2)
        }
        await XCTAssertThrowsAsync {
            try await repository.setPreferredRevision(callID: try XCTUnwrap(first.id), revisionID: ids.1)
        }
        try await repository.setPreferredRevision(callID: try XCTUnwrap(first.id), revisionID: ids.3)
        let vector = Data(count: ZBSEyeDatabase.embeddingDim * MemoryLayout<Float>.size)
        try await store.database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO vec_call_transcripts(revision_id, bucket_month, embedding) VALUES (?, 202607, ?)",
                arguments: [ids.3, vector]
            )
            try db.execute(
                sql: "UPDATE calls SET preferredRevisionId = preferredRevisionId WHERE id = ?",
                arguments: [first.id]
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM vec_call_transcripts WHERE revision_id = ?",
                    arguments: [ids.3]
                ),
                1,
                "an unchanged preferred revision must keep its semantic vector"
            )
        }
        try await repository.setPreferredRevision(callID: try XCTUnwrap(first.id), revisionID: ids.0)

        let projection = try await store.database.pool.read { db in
            (
                preferred: try Int64.fetchOne(
                    db,
                    sql: "SELECT preferredRevisionId FROM calls WHERE id = ?",
                    arguments: [first.id]
                ),
                indexed: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_fts WHERE revision_id = ?",
                    arguments: [ids.0]
                ) ?? 0,
                staleFTS: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_fts WHERE revision_id = ?",
                    arguments: [ids.3]
                ) ?? 0,
                staleVectors: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM vec_call_transcripts WHERE revision_id = ?",
                    arguments: [ids.3]
                ) ?? 0
            )
        }
        XCTAssertEqual(projection.preferred, ids.0)
        XCTAssertEqual(projection.indexed, 1)
        XCTAssertEqual(projection.staleFTS, 0)
        XCTAssertEqual(projection.staleVectors, 0)
    }

    func testChunkOwnershipAndFinalizedImmutabilityAreEnforcedBySchema() async throws {
        let store = try CallDatabaseTestStore()
        let repository = CallRepository(database: store.database)
        let first = try await repository.createCall(startedAtMs: 1_000, idempotencyKey: "owner-a")
        let firstID = try XCTUnwrap(first.id)
        let firstBookmark = try await repository.createBookmark(
            callID: firstID,
            idempotencyKey: "owner-a-bookmark",
            acceptedAtMs: 1_500,
            meIngressTarget: 1,
            systemIngressTarget: nil,
            logicalStartMs: 1_000,
            logicalEndMs: 1_500,
            contextStartMs: 1_000
        )
        let firstFinal = try await repository.endCall(
            callID: firstID,
            idempotencyKey: "owner-a-end",
            endedAtMs: 2_000
        )
        let second = try await repository.createCall(startedAtMs: 3_000, idempotencyKey: "owner-b")
        let secondID = try XCTUnwrap(second.id)
        _ = try await repository.endCall(
            callID: secondID,
            idempotencyKey: "owner-b-end",
            endedAtMs: 4_000
        )
        let firstSpan = try await repository.recordSourceSpan(
            CallSourceSpanDraft(
                callId: firstID,
                source: .me,
                epoch: 0,
                sampleRate: 16_000,
                startedAtMs: 1_000,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .available
            )
        )
        let secondSpan = try await repository.recordSourceSpan(
            CallSourceSpanDraft(
                callId: secondID,
                source: .system,
                epoch: 0,
                sampleRate: 16_000,
                startedAtMs: 3_000,
                startSample: 0,
                startHostTimeNs: 0,
                availability: .available
            )
        )

        await XCTAssertThrowsAsync {
            _ = try await repository.recordAudioChunk(
                CallAudioChunkDraft(
                    callId: secondID,
                    sourceSpanId: try XCTUnwrap(firstSpan.id),
                    source: .system,
                    epoch: 0,
                    sequence: 0,
                    mediaGeneration: 0,
                    startSample: 0,
                    endSample: 1,
                    startMs: 3_000,
                    endMs: 3_001,
                    relativePath: "calls/cross-owner.pcm",
                    bytes: 2,
                    sha256: "fixture",
                    finalized: true
                )
            )
        }

        let chunk = try await repository.recordAudioChunk(
            CallAudioChunkDraft(
                callId: secondID,
                sourceSpanId: try XCTUnwrap(secondSpan.id),
                source: .system,
                epoch: 0,
                sequence: 0,
                mediaGeneration: 0,
                startSample: 0,
                endSample: 1,
                startMs: 3_000,
                endMs: 3_001,
                relativePath: "calls/owned.pcm",
                bytes: 2,
                sha256: "fixture",
                finalized: true
            )
        )
        await XCTAssertThrowsAsync {
            try await store.database.pool.write { db in
                try db.execute(
                    sql: "UPDATE call_audio_chunks SET relativePath = 'calls/mutated.pcm' WHERE id = ?",
                    arguments: [chunk.id]
                )
            }
        }
        await XCTAssertThrowsAsync {
            try await store.database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO call_transcript_jobs(
                            identity, callId, bookmarkId, kind, mediaGeneration, state, priority,
                            logicalStartMs, logicalEndMs, contextStartMs, coverageFrozen,
                            attempts, createdAtMs, updatedAtMs
                        ) VALUES ('cross-bookmark', ?, ?, 'checkpoint', 0, 'preparing', 100,
                            3_000, 3_500, 3_000, 0, 0, 3_500, 3_500)
                        """,
                    arguments: [secondID, firstBookmark.bookmark.id]
                )
            }
        }
        await XCTAssertThrowsAsync {
            try await store.database.pool.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO call_transcript_revisions(
                            callId, jobId, projectionKey, kind, mediaGeneration, state, text,
                            language, engine, modelRevision, logicalStartMs, logicalEndMs, createdAtMs
                        ) VALUES (?, ?, NULL, 'final', 0, 'ready', 'cross', 'en', 'fixture',
                            'fixture', 3_000, 4_000, 5_000)
                        """,
                    arguments: [secondID, firstFinal.id]
                )
            }
        }
    }

    func testBookmarkAndCurrentGenerationFinalJobAreTransactionallyIdempotent() async throws {
        let store = try CallDatabaseTestStore()
        let repository = CallRepository(database: store.database)
        let call = try await repository.createCall(startedAtMs: 10_000, idempotencyKey: "call")
        let callID = try XCTUnwrap(call.id)

        let first = try await repository.createBookmark(
            callID: callID,
            idempotencyKey: "bookmark-1",
            acceptedAtMs: 11_000,
            meIngressTarget: 41,
            systemIngressTarget: 92,
            logicalStartMs: 10_000,
            logicalEndMs: 11_000,
            contextStartMs: 10_000
        )
        let repeated = try await repository.createBookmark(
            callID: callID,
            idempotencyKey: "bookmark-1",
            acceptedAtMs: 99_000,
            meIngressTarget: 999,
            systemIngressTarget: 999,
            logicalStartMs: 98_000,
            logicalEndMs: 99_000,
            contextStartMs: 97_000
        )
        XCTAssertEqual(first.bookmark.id, repeated.bookmark.id)
        XCTAssertEqual(first.job.id, repeated.job.id)
        XCTAssertEqual(repeated.bookmark.acceptedAtMs, 11_000)
        XCTAssertEqual(repeated.job.state, .preparing)

        let final = try await repository.endCall(
            callID: callID,
            idempotencyKey: "end-1",
            endedAtMs: 12_000
        )
        let repeatedFinal = try await repository.endCall(
            callID: callID,
            idempotencyKey: "end-1",
            endedAtMs: 99_000
        )
        XCTAssertEqual(final.id, repeatedFinal.id)

        let counts = try await store.database.pool.read { db in
            (
                bookmarks: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_bookmarks") ?? 0,
                checkpointJobs: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_jobs WHERE kind = 'checkpoint'"
                ) ?? 0,
                finalJobs: try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM call_transcript_jobs WHERE kind = 'final'"
                ) ?? 0,
                endedAt: try Int64.fetchOne(
                    db,
                    sql: "SELECT endTs FROM calls WHERE id = ?",
                    arguments: [callID]
                )
            )
        }
        XCTAssertEqual(counts.bookmarks, 1)
        XCTAssertEqual(counts.checkpointJobs, 1)
        XCTAssertEqual(counts.finalJobs, 1)
        XCTAssertEqual(counts.endedAt, 12_000)
    }
}

private struct SpeakerIntervalProjection: Equatable {
    let clusterKey: String
    let source: CallAudioSource
    let startMs: Int64
    let endMs: Int64
}

private struct SpeakerRevisionSnapshot {
    let names: [String: String]
    let provenance: [String: CallSpeakerNamingProvenance]
    let intervals: [SpeakerIntervalProjection]
}

private func makeEndedCorrectionCall(repository: CallRepository) async throws -> Int64 {
    let call = try await repository.createCall(
        startedAtMs: 100,
        idempotencyKey: "speaker-correction-call"
    )
    let callID = try XCTUnwrap(call.id)
    _ = try await repository.endCall(
        callID: callID,
        idempotencyKey: "speaker-correction-end",
        endedAtMs: 500
    )
    return callID
}

private func makeInitialSpeakerRevision(
    repository: CallRepository,
    callID: Int64
) async throws -> CallSpeakerRevisionRow {
    let revision = try await repository.createSpeakerRevision(
        callID: callID,
        mediaGeneration: 0,
        engine: "fixture",
        modelRevision: "fixture-v1",
        clusters: [
            .init(
                clusterKey: "system:S1",
                displayName: nil,
                namingProvenance: .anonymous,
                intervals: [
                    .init(source: .system, startMs: 100, endMs: 200),
                    .init(source: .system, startMs: 300, endMs: 400),
                ]
            ),
            .init(
                clusterKey: "system:S2",
                displayName: nil,
                namingProvenance: .anonymous,
                intervals: [.init(source: .system, startMs: 200, endMs: 300)]
            ),
            .init(
                clusterKey: "me:S1",
                displayName: nil,
                namingProvenance: .anonymous,
                intervals: [.init(source: .me, startMs: 100, endMs: 400)]
            ),
        ],
        nowMs: 2_000
    )
    try await repository.setPreferredSpeakerRevision(
        callID: callID,
        revisionID: try XCTUnwrap(revision.id)
    )
    return revision
}

private func speakerRevisionSnapshot(
    database: ZBSEyeDatabase,
    revisionID: Int64
) async throws -> SpeakerRevisionSnapshot {
    try await database.pool.read { db in
        let clusters = try CallSpeakerClusterRow.fetchAll(
            db,
            sql: "SELECT * FROM call_speaker_clusters WHERE revisionId = ? ORDER BY ordinal",
            arguments: [revisionID]
        )
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.clusterKey, i.source, i.startMs, i.endMs
                FROM call_speaker_intervals i
                JOIN call_speaker_clusters c ON c.id = i.clusterId
                WHERE i.revisionId = ?
                ORDER BY c.clusterKey, i.source, i.startMs, i.endMs
                """,
            arguments: [revisionID]
        )
        return SpeakerRevisionSnapshot(
            names: Dictionary(uniqueKeysWithValues: clusters.compactMap { cluster in
                cluster.displayName.map { (cluster.clusterKey, $0) }
            }),
            provenance: Dictionary(uniqueKeysWithValues: clusters.map {
                ($0.clusterKey, $0.namingProvenance)
            }),
            intervals: rows.map { row in
                SpeakerIntervalProjection(
                    clusterKey: row["clusterKey"],
                    source: row["source"],
                    startMs: row["startMs"],
                    endMs: row["endMs"]
                )
            }
        )
    }
}

private final class CallDatabaseTestStore {
    let root: URL
    let database: ZBSEyeDatabase

    init(runMigrations: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "zbseye-call-db-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try ZBSEyeDatabase(
            path: root.appending(path: "eye.sqlite").path,
            runMigrations: runMigrations
        )
    }

    deinit {
        try? database.pool.close()
        try? FileManager.default.removeItem(at: root)
    }
}

private func XCTAssertThrowsAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
