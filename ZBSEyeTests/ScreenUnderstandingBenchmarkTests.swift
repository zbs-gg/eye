import Foundation
import XCTest

final class ScreenUnderstandingBenchmarkTests: XCTestCase {
    func testPublicStatusAccountsForEveryLockedMethodWithoutCaseMaterial() throws {
        let status = try ScreenUnderstandingPublicStatus.load(from: statusURL())
        try status.validate()
        let protocolDocument = try ScreenUnderstandingEvalProtocol.load(from: protocolURL())

        XCTAssertEqual(Set(status.methods.map(\.id)), Set(protocolDocument.methods.map(\.id)))
        XCTAssertFalse(status.containsPersonalCorpus)
        XCTAssertFalse(status.containsCaseMaterial)
        XCTAssertEqual(status.qualityConclusion, "not-run")
    }

    func testPublicStatusRejectsCaseOrPersonalCorpusFlags() throws {
        var status = try ScreenUnderstandingPublicStatus.load(from: statusURL())
        status.containsCaseMaterial = true
        XCTAssertThrowsError(try status.validate())
        status = try ScreenUnderstandingPublicStatus.load(from: statusURL())
        status.containsPersonalCorpus = true
        XCTAssertThrowsError(try status.validate())
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func statusURL() -> URL {
        repositoryRoot().appendingPathComponent(
            "docs/evals/screen-understanding-status-2026-07-13.json"
        )
    }

    private func protocolURL() -> URL {
        repositoryRoot().appendingPathComponent("docs/evals/screen-understanding-v1.json")
    }
}
