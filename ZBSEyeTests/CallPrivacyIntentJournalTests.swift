import XCTest

final class CallPrivacyIntentJournalTests: XCTestCase {
    private let fingerprint = String(repeating: "a", count: 64)

    func testReceiptPersistsIdempotentlyAndCanBeRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let journal = try CallPrivacyIntentJournal(mediaRoot: fixture.mediaRoot)

        let first = try journal.persistAutomaticRejection(
            callID: 42,
            detectorFingerprint: fingerprint
        )
        let second = try journal.persistAutomaticRejection(
            callID: 42,
            detectorFingerprint: fingerprint
        )

        XCTAssertEqual(first, second)
        XCTAssertTrue(try journal.contains(first))
        XCTAssertEqual(try journal.pendingAutomaticRejections(), [first])
        try journal.remove(first)
        XCTAssertFalse(try journal.contains(first))
        XCTAssertEqual(try journal.pendingAutomaticRejections(), [])
    }

    func testReceiptRejectsNonCanonicalFingerprint() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let journal = try CallPrivacyIntentJournal(mediaRoot: fixture.mediaRoot)

        XCTAssertThrowsError(
            try journal.persistAutomaticRejection(
                callID: 1,
                detectorFingerprint: String(repeating: "A", count: 64)
            )
        )
        XCTAssertThrowsError(
            try journal.persistAutomaticRejection(
                callID: 1,
                detectorFingerprint: "abc"
            )
        )
    }

    func testFailedDurabilityStepDurablyRemovesCanonicalReceipt() throws {
        enum InjectedFailure: Error {
            case afterCreate
        }

        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let journal = try CallPrivacyIntentJournal(
            mediaRoot: fixture.mediaRoot,
            afterMarkerCreated: {
                throw InjectedFailure.afterCreate
            }
        )

        XCTAssertThrowsError(
            try journal.persistAutomaticRejection(
                callID: 2,
                detectorFingerprint: fingerprint
            )
        )

        XCTAssertEqual(try journal.pendingAutomaticRejections(), [])
        let callDirectory = fixture.mediaRoot
            .appendingPathComponent("calls/2", isDirectory: true)
        let remaining = try FileManager.default.contentsOfDirectory(
            at: callDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remaining.isEmpty)
    }

    func testFutureOrMalformedReceiptFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let journal = try CallPrivacyIntentJournal(mediaRoot: fixture.mediaRoot)
        let root = try SecureCallSpoolRoot(root: fixture.mediaRoot)
        let relative = "calls/7/.privacy-reject-v2-\(fingerprint).intent"
        let (_, handle) = try root.createWritableFile(relativePath: relative)
        try handle.synchronize()
        try handle.close()
        try root.synchronizeParent(relativePath: relative)

        XCTAssertThrowsError(try journal.pendingAutomaticRejections())
    }

    func testSymlinkReceiptFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let journal = try CallPrivacyIntentJournal(mediaRoot: fixture.mediaRoot)
        let callRoot = fixture.mediaRoot
            .appendingPathComponent("calls/9", isDirectory: true)
        try FileManager.default.createDirectory(
            at: callRoot,
            withIntermediateDirectories: true
        )
        let outside = fixture.root.appendingPathComponent("outside")
        try Data().write(to: outside)
        let marker = callRoot.appendingPathComponent(
            ".privacy-reject-v1-\(fingerprint).intent"
        )
        try FileManager.default.createSymbolicLink(
            at: marker,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try journal.pendingAutomaticRejections())
    }

    func testSymlinkedCallsRootFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let journal = try CallPrivacyIntentJournal(mediaRoot: fixture.mediaRoot)
        let outsideCalls = fixture.root.appendingPathComponent(
            "outside-calls",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideCalls,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.mediaRoot.appendingPathComponent("calls"),
            withDestinationURL: outsideCalls
        )

        XCTAssertThrowsError(try journal.pendingAutomaticRejections())
    }

    func testSymlinkedCallDirectoryFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let journal = try CallPrivacyIntentJournal(mediaRoot: fixture.mediaRoot)
        let callsRoot = fixture.mediaRoot.appendingPathComponent(
            "calls",
            isDirectory: true
        )
        let outsideCall = fixture.root.appendingPathComponent(
            "outside-call",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: callsRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideCall,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: callsRoot.appendingPathComponent("7"),
            withDestinationURL: outsideCall
        )

        XCTAssertThrowsError(try journal.pendingAutomaticRejections())
    }

    func testUnreadableCallDirectoryFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let journal = try CallPrivacyIntentJournal(mediaRoot: fixture.mediaRoot)
        _ = try journal.persistAutomaticRejection(
            callID: 11,
            detectorFingerprint: fingerprint
        )
        let callRoot = fixture.mediaRoot.appendingPathComponent(
            "calls/11",
            isDirectory: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: callRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: callRoot.path
            )
        }

        XCTAssertThrowsError(try journal.pendingAutomaticRejections())
    }

    func testPendingScanDoesNotTraverseDeepEvidenceTree() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let journal = try CallPrivacyIntentJournal(mediaRoot: fixture.mediaRoot)
        let receipt = try journal.persistAutomaticRejection(
            callID: 12,
            detectorFingerprint: fingerprint
        )
        let epochRoot = fixture.mediaRoot
            .appendingPathComponent("calls/12/me/epoch-0001", isDirectory: true)
        try FileManager.default.createDirectory(
            at: epochRoot,
            withIntermediateDirectories: true
        )
        let outside = fixture.root.appendingPathComponent("outside")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: epochRoot.appendingPathComponent("deep-link"),
            withDestinationURL: outside
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: epochRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: epochRoot.path
            )
        }

        XCTAssertEqual(try journal.pendingAutomaticRejections(), [receipt])
    }

    func testExecutorRoundTripsReceiptOffTheCaller() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let executor = CallPrivacyIntentJournalExecutor(mediaRoot: fixture.mediaRoot)

        let receipt = try await executor.persistAutomaticRejection(
            callID: 13,
            detectorFingerprint: fingerprint
        )

        let pending = try await executor.pendingAutomaticRejections()
        XCTAssertEqual(pending, [receipt])
        try await executor.remove(receipt)
        let empty = try await executor.pendingAutomaticRejections()
        XCTAssertEqual(empty, [])
    }
}

private final class Fixture {
    let root: URL
    let mediaRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "zbseye-call-privacy-journal-\(UUID().uuidString)",
                isDirectory: true
            )
        mediaRoot = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(
            at: mediaRoot,
            withIntermediateDirectories: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
