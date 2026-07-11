import Foundation
import XCTest

final class BuiltInModelFailureMessageTests: XCTestCase {
    func testUnknownFilesystemErrorNeverLeaksAnAbsolutePath() {
        let secretPath = "/Users/private/Library/Application Support/ZBS Eye/models/secret"
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSFilePathErrorKey: secretPath]
        )

        let message = BuiltInModelFailureMessage.userFacing(error, context: .runtimeLoad)

        XCTAssertEqual(message, "The built-in model could not be loaded.")
        XCTAssertFalse(message.contains(secretPath))
        XCTAssertFalse(message.contains("/Users/"))
    }

    func testKnownDownloadFailureKeepsSafeActionableDetail() {
        let message = BuiltInModelFailureMessage.userFacing(
            BuiltInDownloadError.invalidStatus(503),
            context: .download
        )

        XCTAssertEqual(message, "Unexpected model-download HTTP status: 503.")
    }

    func testVerificationFailureUsesStableCopyInsteadOfRenderingPathsOrDigests() {
        let message = BuiltInModelFailureMessage.userFacing(
            BuiltInModelVerificationError.digestMismatch(
                path: "weights/model.safetensors",
                expected: "EXPECTED-SECRET",
                actual: "ACTUAL-SECRET"
            ),
            context: .verification
        )

        XCTAssertEqual(message, "The downloaded model did not pass integrity verification.")
        XCTAssertFalse(message.contains("weights/model.safetensors"))
        XCTAssertFalse(message.contains("EXPECTED-SECRET"))
        XCTAssertFalse(message.contains("ACTUAL-SECRET"))
    }
}
