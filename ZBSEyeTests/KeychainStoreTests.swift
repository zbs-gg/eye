import Security
import XCTest

final class KeychainStoreTests: XCTestCase {
    func testSetUsesUpdateFirstAndAddsOnlyWhenTheItemIsMissing() {
        XCTAssertEqual(KeychainStore.setAction(for: errSecSuccess), .complete)
        XCTAssertEqual(KeychainStore.setAction(for: errSecItemNotFound), .add)
        XCTAssertEqual(KeychainStore.setAction(for: errSecAuthFailed), .fail)
        XCTAssertEqual(KeychainStore.setAction(for: errSecInteractionNotAllowed), .fail)
    }

    func testDeletionStatusAcceptsOnlySuccessAndAlreadyMissing() {
        XCTAssertTrue(KeychainStore.isSuccessfulDeletion(errSecSuccess))
        XCTAssertTrue(KeychainStore.isSuccessfulDeletion(errSecItemNotFound))
        XCTAssertFalse(KeychainStore.isSuccessfulDeletion(errSecAuthFailed))
        XCTAssertFalse(KeychainStore.isSuccessfulDeletion(errSecInteractionNotAllowed))
    }
}
