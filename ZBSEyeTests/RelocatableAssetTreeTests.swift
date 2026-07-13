import XCTest

final class RelocatableAssetTreeTests: XCTestCase {
    func testNestedModelTreeCopiesWithExactRelativeByteParity() throws {
        let fixture = try AssetTreeFixture()
        defer { fixture.remove() }
        try fixture.write("journal", at: "journal.json")
        try fixture.write("weights", at: "installed/a/payload/model.safetensors")
        try fixture.write("partial", at: "staging/b/payload/model.part")

        let copied = try RelocatableAssetTree.copyIfPresent(
            from: fixture.source,
            to: fixture.destination
        )

        XCTAssertEqual(copied?.files.map(\.relativePath), [
            "installed/a/payload/model.safetensors",
            "journal.json",
            "staging/b/payload/model.part",
        ])
        XCTAssertEqual(copied?.totalBytes, 21)
        XCTAssertEqual(
            try RelocatableAssetTree.inventoryIfPresent(at: fixture.source),
            try RelocatableAssetTree.inventoryIfPresent(at: fixture.destination)
        )
    }

    func testMissingSourceIsAnHonestNoAssetResult() throws {
        let fixture = try AssetTreeFixture(createSource: false)
        defer { fixture.remove() }

        XCTAssertNil(
            try RelocatableAssetTree.copyIfPresent(
                from: fixture.source,
                to: fixture.destination
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testSymlinkAndOccupiedDestinationFailClosed() throws {
        let fixture = try AssetTreeFixture()
        defer { fixture.remove() }
        try fixture.write("outside", at: "outside.txt", underRoot: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appending(path: "link"),
            withDestinationURL: fixture.root.appending(path: "outside.txt")
        )
        XCTAssertThrowsError(try RelocatableAssetTree.inventoryIfPresent(at: fixture.source)) {
            XCTAssertEqual($0 as? RelocatableAssetTreeError, .unsafeEntry("link"))
        }

        try FileManager.default.removeItem(at: fixture.source.appending(path: "link"))
        try fixture.write("source", at: "model.bin")
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try RelocatableAssetTree.copyIfPresent(
                from: fixture.source,
                to: fixture.destination
            )
        ) {
            XCTAssertEqual($0 as? RelocatableAssetTreeError, .destinationOccupied)
        }
    }

    func testInventoryFailsClosedWhenSourceEnumerationFails() throws {
        let fixture = try AssetTreeFixture()
        defer { fixture.remove() }
        try fixture.write("frame", at: "screen.heic")
        let fileManager = AssetEnumerationFailingFileManager(
            failingPath: fixture.source.path
        )

        XCTAssertThrowsError(
            try RelocatableAssetTree.inventoryIfPresent(
                at: fixture.source,
                fileManager: fileManager
            )
        ) { error in
            guard case RelocatableAssetTreeError.unsafeEntry = error else {
                return XCTFail("expected unsafeEntry, got \(error)")
            }
        }
    }

    func testCopyRejectsSameLengthDestinationCorruption() throws {
        let fixture = try AssetTreeFixture()
        defer { fixture.remove() }
        try fixture.write("trusted-model-bytes", at: "installed/a/model.bin")
        let fileManager = SameLengthCorruptingFileManager(
            relativePath: "installed/a/model.bin"
        )

        XCTAssertThrowsError(
            try RelocatableAssetTree.copyIfPresent(
                from: fixture.source,
                to: fixture.destination,
                fileManager: fileManager
            )
        ) { error in
            XCTAssertEqual(
                error as? RelocatableAssetTreeError,
                .parityMismatch
            )
        }
    }
}

private struct AssetTreeFixture {
    let root: URL
    let source: URL
    let destination: URL

    init(createSource: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "asset-tree-\(UUID().uuidString)", directoryHint: .isDirectory)
        source = root.appending(path: "source", directoryHint: .isDirectory)
        destination = root.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if createSource {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        }
    }

    func write(_ value: String, at relativePath: String, underRoot: Bool = false) throws {
        let base = underRoot ? root : source
        let url = base.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class AssetEnumerationFailingFileManager: FileManager,
    @unchecked Sendable {
    private let failingPath: String

    init(failingPath: String) {
        self.failingPath = URL(fileURLWithPath: failingPath)
            .standardizedFileURL.path
        super.init()
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        if URL(fileURLWithPath: path).standardizedFileURL.path == failingPath {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.contentsOfDirectory(atPath: path)
    }
}

private final class SameLengthCorruptingFileManager: FileManager,
    @unchecked Sendable {
    private let relativePath: String

    init(relativePath: String) {
        self.relativePath = relativePath
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        let copiedFile = dstURL.appending(path: relativePath)
        let originalBytes = try Data(contentsOf: copiedFile).count
        try Data(repeating: 0xA5, count: originalBytes).write(to: copiedFile)
    }
}
