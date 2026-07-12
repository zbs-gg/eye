import Foundation
import XCTest

final class ScreenUnderstandingDatasetPolicyTests: XCTestCase {
    func testRejectsOverlappingAndTrackedWorkspaceRoots() throws {
        let repository = repositoryRoot()
        let source = repository.appendingPathComponent("source")

        XCTAssertThrowsError(try ScreenUnderstandingDatasetPolicy.validate(
            sourceRoot: source,
            outputRoot: source,
            repositoryRoot: repository
        ))
        XCTAssertThrowsError(try ScreenUnderstandingDatasetPolicy.validate(
            sourceRoot: source,
            outputRoot: source.appendingPathComponent("child"),
            repositoryRoot: repository
        ))
        XCTAssertThrowsError(try ScreenUnderstandingDatasetPolicy.validate(
            sourceRoot: source,
            outputRoot: repository.appendingPathComponent("docs/private-corpus"),
            repositoryRoot: repository
        ))
    }

    func testAcceptsGitignoredBuildAndRejectsCloudDestinations() throws {
        let repository = repositoryRoot()
        let build = repository.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        XCTAssertNoThrow(try ScreenUnderstandingDatasetPolicy.validate(
            sourceRoot: repository.appendingPathComponent("source"),
            outputRoot: build.appendingPathComponent("screen-understanding-dataset"),
            repositoryRoot: repository
        ))

        let cloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
            .appendingPathComponent("dataset")
        XCTAssertThrowsError(try ScreenUnderstandingDatasetPolicy.validate(
            sourceRoot: repository.appendingPathComponent("source"),
            outputRoot: cloud,
            repositoryRoot: repository
        ))
    }

    func testMediaTraversalAndSymlinkedRootEscapeAreRejected() throws {
        let media = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: media) }

        XCTAssertThrowsError(try ScreenUnderstandingDatasetPolicy.resolvedMediaURL(
            mediaRoot: media,
            relativePath: "../secret"
        ))
        XCTAssertThrowsError(try ScreenUnderstandingDatasetPolicy.resolvedMediaURL(
            mediaRoot: media,
            relativePath: "/tmp/secret"
        ))
    }

    func testTemporalPairRequiresForwardCoherentPixelFrames() {
        let before = candidate(id: 1, ts: 1_000, monitor: "A", app: "Editor", path: "a.heic")
        let after = candidate(id: 2, ts: 2_000, monitor: "A", app: "Editor", path: "b.heic")
        XCTAssertTrue(ScreenUnderstandingDatasetSampler.validTemporalPair(
            before: before,
            after: after,
            maximumGapMs: 2_000
        ))
        XCTAssertFalse(ScreenUnderstandingDatasetSampler.validTemporalPair(
            before: before,
            after: candidate(id: 2, ts: 2_000, monitor: "B", app: "Editor", path: "b.heic"),
            maximumGapMs: 2_000
        ))
        XCTAssertFalse(ScreenUnderstandingDatasetSampler.validTemporalPair(
            before: before,
            after: candidate(id: 2, ts: 2_000, monitor: "A", app: "Browser", path: "b.heic"),
            maximumGapMs: 2_000
        ))
        XCTAssertFalse(ScreenUnderstandingDatasetSampler.validTemporalPair(
            before: before,
            after: candidate(id: 2, ts: 2_000, monitor: "A", app: "Editor", path: nil),
            maximumGapMs: 2_000
        ))
    }

    func testBalancedSamplerDoesNotLetOneCommonStratumDominate() {
        let common = (1...8).map {
            candidate(id: Int64($0), ts: Int64($0), monitor: "A", app: "Editor", path: "a.heic", text: "short")
        }
        let sparse = candidate(id: 20, ts: 20, monitor: "A", app: "Canvas", path: "b.heic", text: "")
        let context = candidate(id: 21, ts: 21, monitor: "A", app: "Editor", path: nil, text: "AX")
        let selected = ScreenUnderstandingDatasetSampler.balanced(common + [sparse, context], limit: 3)
        XCTAssertEqual(Set(selected.map(\.primaryStratum)), ["mixed", "visual-sparse", "context-only"])
    }

    private func candidate(
        id: Int64,
        ts: Int64,
        monitor: String,
        app: String,
        path: String?,
        text: String = ""
    ) -> ScreenUnderstandingDatasetCandidate {
        .init(
            sourceID: id,
            timestampMs: ts,
            appName: app,
            windowTitle: nil,
            browserURL: nil,
            monitorID: monitor,
            relativePath: path,
            text: text,
            textSources: text.isEmpty ? [] : ["ax"]
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
