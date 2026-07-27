import XCTest

final class CallAudioSourcePolicyTests: XCTestCase {
    func testConfirmedCallRequestsBothLegsWhenAudioEnabled() {
        for mode in [AudioMode.meetingsOnly, .always] {
            XCTAssertEqual(
                CallAudioSourcePolicy.requestedSources(audioMode: mode),
                CallSourceSelection(me: true, system: true)
            )
        }
    }

    func testAudioOffRemainsHardPrivacyStop() {
        XCTAssertEqual(
            CallAudioSourcePolicy.requestedSources(audioMode: .off),
            .none
        )
    }
}
