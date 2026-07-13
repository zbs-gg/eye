import XCTest

@MainActor
final class AudioSettingsStoreTests: XCTestCase {
    func testSystemAudioPersistsAndSynchronizesWithoutChangingMicrophoneMode() throws {
        let suite = "AudioSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        var synchronizationCount = 0
        let store = AudioSettingsStore(defaults: defaults)
        store.onCaptureConfigurationChanged = { synchronizationCount += 1 }
        let originalMode = store.audioMode

        store.recordSystemAudio = false

        XCTAssertEqual(synchronizationCount, 1)
        XCTAssertEqual(store.audioMode, originalMode)
        XCTAssertFalse(AudioSettingsStore(defaults: defaults).recordSystemAudio)
    }

    func testAudioModeChangeSynchronizesExactlyOnceAndClearsSessionOverride() throws {
        let suite = "AudioSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        var synchronizationCount = 0
        let store = AudioSettingsStore(defaults: defaults)
        store.onCaptureConfigurationChanged = { synchronizationCount += 1 }
        store.manualAudioOverride = true

        store.audioMode = store.audioMode == .off ? .always : .off

        XCTAssertEqual(synchronizationCount, 1)
        XCTAssertNil(store.manualAudioOverride)
    }
}
