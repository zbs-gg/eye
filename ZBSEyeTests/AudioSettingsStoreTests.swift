import XCTest

@MainActor
private final class PickedApplicationBox {
    var value: AutoCallExcludedApplication?

    init(_ value: AutoCallExcludedApplication?) {
        self.value = value
    }
}

@MainActor
final class AudioSettingsStoreTests: XCTestCase {
    func testAudioOffAndManualForceOffEndAnActiveCall() {
        XCTAssertTrue(
            CallAudioSourcePolicy.mustEndActiveCall(
                audioMode: .off,
                manualOverride: nil,
                callIsActive: true
            )
        )
        XCTAssertTrue(
            CallAudioSourcePolicy.mustEndActiveCall(
                audioMode: .meetingsOnly,
                manualOverride: false,
                callIsActive: true
            )
        )
        XCTAssertFalse(
            CallAudioSourcePolicy.mustEndActiveCall(
                audioMode: .meetingsOnly,
                manualOverride: nil,
                callIsActive: true
            )
        )
        XCTAssertFalse(
            CallAudioSourcePolicy.mustEndActiveCall(
                audioMode: .off,
                manualOverride: nil,
                callIsActive: false
            )
        )
    }

    func testMicInUseKeepsMeetingsOnlyRawValueForCompatibility() {
        XCTAssertEqual(AudioMode.meetingsOnly.rawValue, "meetingsOnly")
        XCTAssertEqual(AudioMode.meetingsOnly.label, "Mic in use")
    }

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

    func testAudioOffCannotBeBypassedByAStaleForceOnOverride() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(defaults: defaults)

        store.audioMode = .off
        store.manualAudioOverride = true

        XCTAssertFalse(store.audioShouldCapture())
    }

    func testAutoCallExclusionsDefaultToEmptyAndUseExactBundleIDMatches() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(defaults: defaults)

        XCTAssertTrue(store.autoCallExcludedBundleIDs.isEmpty)
        XCTAssertFalse(store.isAutoCallExcluded("com.example.Chat"))

        XCTAssertTrue(store.addAutoCallExcludedApp(bundleID: "com.example.Chat"))
        XCTAssertTrue(store.isAutoCallExcluded("com.example.Chat"))
        XCTAssertFalse(store.isAutoCallExcluded("com.example.Chat.Helper"))
        XCTAssertFalse(store.isAutoCallExcluded("com.example.chat"))
    }

    func testAutoCallExclusionsPersistCanonicalIDsAndDeduplicateWithoutExtraCallback() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var exclusionChanges: [Set<String>] = []
        let store = makeStore(defaults: defaults)
        store.onAutoCallExclusionsChanged = { exclusionChanges.append($0) }

        XCTAssertTrue(store.addAutoCallExcludedApp(
            bundleID: "  com.example.Chat  ",
            displayName: "Chat"
        ))
        XCTAssertFalse(store.addAutoCallExcludedApp(
            bundleID: "com.example.Chat",
            displayName: "Conflicting duplicate"
        ))
        XCTAssertFalse(store.addAutoCallExcludedApp(bundleID: "  \n"))

        XCTAssertEqual(store.autoCallExcludedBundleIDs, ["com.example.Chat"])
        XCTAssertEqual(store.autoCallExcludedDisplayNames["com.example.Chat"], "Chat")
        XCTAssertEqual(exclusionChanges, [Set(["com.example.Chat"])])

        let relaunched = makeStore(defaults: defaults)
        XCTAssertEqual(relaunched.autoCallExcludedBundleIDs, ["com.example.Chat"])
        XCTAssertEqual(relaunched.autoCallExcludedDisplayNames["com.example.Chat"], "Installed Chat")
    }

    func testPersistedExclusionsAreSanitizedWithoutChangingExactCase() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            [" com.example.Chat ", "", "com.example.Chat", "com.example.chat"],
            forKey: "zbseye.audio.autoCallExcludedApps"
        )

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(
            store.autoCallExcludedBundleIDs,
            ["com.example.Chat", "com.example.chat"]
        )
        XCTAssertEqual(
            defaults.stringArray(forKey: "zbseye.audio.autoCallExcludedApps"),
            ["com.example.Chat", "com.example.chat"]
        )
    }

    func testRemovingExclusionPersistsAndCallsBackOnlyWhenChanged() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(defaults: defaults)
        XCTAssertTrue(store.addAutoCallExcludedApp(bundleID: "com.example.Chat"))

        var exclusionChanges: [Set<String>] = []
        store.onAutoCallExclusionsChanged = { exclusionChanges.append($0) }
        XCTAssertTrue(store.removeAutoCallExcludedApp("com.example.Chat"))
        XCTAssertFalse(store.removeAutoCallExcludedApp("com.example.Chat"))

        XCTAssertEqual(exclusionChanges, [Set<String>()])
        XCTAssertFalse(store.isAutoCallExcluded("com.example.Chat"))
        XCTAssertTrue(makeStore(defaults: defaults).autoCallExcludedBundleIDs.isEmpty)
    }

    func testInjectedPickerAddsApplicationAndCancelDoesNothing() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let pickedApp = PickedApplicationBox(
            .init(
                bundleID: "com.example.Picked",
                displayName: "Picked App"
            )
        )
        let store = AudioSettingsStore(
            defaults: defaults,
            applicationNameLookup: { _ in nil },
            applicationPicker: { pickedApp.value }
        )
        var exclusionChanges: [Set<String>] = []
        store.onAutoCallExclusionsChanged = { exclusionChanges.append($0) }

        XCTAssertTrue(store.addAutoCallExcludedAppViaPanel())
        XCTAssertEqual(store.autoCallExcludedDisplayNames["com.example.Picked"], "Picked App")
        pickedApp.value = nil
        XCTAssertFalse(store.addAutoCallExcludedAppViaPanel())
        XCTAssertEqual(exclusionChanges, [Set(["com.example.Picked"])])
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "AudioSettingsStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func makeStore(defaults: UserDefaults) -> AudioSettingsStore {
        AudioSettingsStore(
            defaults: defaults,
            applicationNameLookup: { bundleID in
                bundleID == "com.example.Chat" ? "Installed Chat" : nil
            },
            applicationPicker: { nil }
        )
    }
}
