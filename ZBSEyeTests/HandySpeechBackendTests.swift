import AVFoundation
import XCTest
import ZBSEyeWhisper

final class HandySpeechBackendTests: XCTestCase {
    func testDiscoversSelectedWhisperDirectlyFromSharedCache() throws {
        let fixture = try HandyCacheFixture()
        defer { fixture.cleanup() }

        let snapshot = HandySpeechModelProbe.discover(
            settingsURL: fixture.settingsURL,
            hubRoot: fixture.hubRoot
        )

        XCTAssertEqual(snapshot.state, .ready)
        let backend = try XCTUnwrap(snapshot.backend)
        XCTAssertEqual(backend.modelID, fixture.modelID)
        XCTAssertEqual(backend.runtimeRelease, "transcribe.cpp-v0.1.3")
        XCTAssertEqual(backend.identitySHA256.count, 64)
        XCTAssertEqual(
            HandySpeechModelProbe.resolvedModelURL(
                for: backend,
                hubRoot: fixture.hubRoot
            ),
            fixture.modelURL.resolvingSymlinksInPath()
        )
    }

    func testRejectsChangedRevisionAfterDiscovery() throws {
        let fixture = try HandyCacheFixture()
        defer { fixture.cleanup() }
        let backend = try XCTUnwrap(
            HandySpeechModelProbe.discover(
                settingsURL: fixture.settingsURL,
                hubRoot: fixture.hubRoot
            ).backend
        )

        try String(repeating: "b", count: 40).write(
            to: fixture.referenceURL,
            atomically: true,
            encoding: .utf8
        )

        XCTAssertNil(
            HandySpeechModelProbe.resolvedModelURL(
                for: backend,
                hubRoot: fixture.hubRoot
            )
        )
    }

    func testRejectsOversizedRevisionReferenceBeforeReadingIt() throws {
        let fixture = try HandyCacheFixture()
        defer { fixture.cleanup() }
        try Data(repeating: 0x61, count: 129).write(to: fixture.referenceURL)

        XCTAssertEqual(
            HandySpeechModelProbe.discover(
                settingsURL: fixture.settingsURL,
                hubRoot: fixture.hubRoot
            ).state,
            .unavailable
        )
    }

    func testRejectsNonWhisperSelectionAndTraversal() throws {
        let fixture = try HandyCacheFixture(
            modelID: "handy-computer/Voxtral-Mini-4B-Realtime-2602-gguf/model.gguf"
        )
        defer { fixture.cleanup() }
        XCTAssertEqual(
            HandySpeechModelProbe.discover(
                settingsURL: fixture.settingsURL,
                hubRoot: fixture.hubRoot
            ).state,
            .unavailable
        )

        let reference = HandySpeechBackendReference(
            modelID: "handy-computer/../outside.gguf",
            displayName: "invalid",
            identitySHA256: String(repeating: "a", count: 64),
            runtimeRelease: "transcribe.cpp-v0.1.3"
        )
        XCTAssertNil(
            HandySpeechModelProbe.resolvedModelURL(
                for: reference,
                hubRoot: fixture.hubRoot
            )
        )
    }

    /// Opt-in qualification against the user's existing Handy cache. This is
    /// deliberately excluded from normal CI because the 886 MB model is not a
    /// repository fixture. It proves the shared GGUF can be loaded directly by
    /// Eye's runtime without starting or linking against Handy.app.
    func testLiveSharedWhisperModelWhenExplicitlyEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        let markerURL = URL(fileURLWithPath: "/private/tmp/zbs-eye-shared-whisper-live-test.json")
        let marker: LiveWhisperFixture?
        if let markerData = try? Data(contentsOf: markerURL) {
            marker = try? JSONDecoder().decode(LiveWhisperFixture.self, from: markerData)
        } else {
            marker = nil
        }
        guard let modelPath = environment["ZBS_EYE_SHARED_WHISPER_MODEL"] ?? marker?.modelPath,
              let audioPath = environment["ZBS_EYE_SHARED_WHISPER_AUDIO"] ?? marker?.audioPath else {
            throw XCTSkip("Set the shared model and audio paths for live qualification")
        }

        let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        XCTAssertEqual(audioFile.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(audioFile.processingFormat.channelCount, 1)
        XCTAssertEqual(audioFile.processingFormat.commonFormat, .pcmFormatFloat32)

        let maximumFrames = AVAudioFrameCount(16_000 * 8)
        let frameCount = min(AVAudioFrameCount(audioFile.length), maximumFrames)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: frameCount
            )
        )
        try audioFile.read(into: buffer, frameCount: frameCount)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(
            UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        )

        let session = try TranscribeCppSession(modelURL: URL(fileURLWithPath: modelPath))
        let segments = try session.transcribe(samples: samples)
        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(segments.contains { !$0.text.isEmpty })
    }
}

private struct LiveWhisperFixture: Decodable {
    let modelPath: String
    let audioPath: String
}

private struct HandyCacheFixture {
    let root: URL
    let hubRoot: URL
    let settingsURL: URL
    let referenceURL: URL
    let modelURL: URL
    let modelID: String

    init(
        modelID: String = "handy-computer/whisper-large-v3-turbo-gguf/whisper-large-v3-turbo-Q8_0.gguf"
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-handy-cache-\(UUID().uuidString)", isDirectory: true)
        hubRoot = root.appendingPathComponent("hub", isDirectory: true)
        settingsURL = root.appendingPathComponent("settings_store.json")
        self.modelID = modelID
        let components = modelID.split(separator: "/").map(String.init)
        let repository = "models--\(components[0])--\(components[1])"
        let revision = String(repeating: "a", count: 40)
        let repositoryRoot = hubRoot.appendingPathComponent(repository, isDirectory: true)
        referenceURL = repositoryRoot.appendingPathComponent("refs/main")
        var candidate = repositoryRoot
            .appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        for component in components.dropFirst(2) { candidate.appendPathComponent(component) }
        modelURL = candidate

        try FileManager.default.createDirectory(
            at: referenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try revision.write(to: referenceURL, atomically: true, encoding: .utf8)
        try Data(count: 1 * 1_024 * 1_024).write(to: modelURL)
        try JSONSerialization.data(withJSONObject: ["selected_model": modelID])
            .write(to: settingsURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
