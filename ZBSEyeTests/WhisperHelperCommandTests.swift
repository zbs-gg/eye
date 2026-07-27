import CryptoKit
import XCTest
import ZBSEyeWhisper

final class WhisperHelperCommandTests: XCTestCase {
    func testOneJobReadsManagedPCMAndWritesOneAtomicResult() throws {
        let fixture = try WhisperHelperFixture()
        defer { fixture.cleanup() }
        let command = try fixture.command()
        try command.execute(
            runtime: WhisperHelperRuntime { _, inputs in
                guard let input = inputs.first else { return [] }
                return [
                    WhisperHelperResultSegment(
                        source: input.source,
                        startSeconds: Double(input.startSample) / Double(input.sampleRate),
                        endSeconds: Double(input.startSample + Int64(input.samples.count))
                            / Double(input.sampleRate),
                        text: "fixture transcript"
                    ),
                ]
            }
        )

        let result = try JSONDecoder().decode(
            WhisperHelperResult.self,
            from: Data(contentsOf: fixture.resultURL)
        )
        XCTAssertEqual(result.jobID, fixture.jobID)
        XCTAssertEqual(result.callGeneration, 2)
        XCTAssertEqual(result.segments.map(\.source), [.me])
        XCTAssertEqual(result.segments.map(\.text), ["fixture transcript"])
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: fixture.resultURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    func testOneJobReusesOneRuntimeSessionAcrossBoundedInputBatches() throws {
        let fixture = try WhisperHelperFixture(rangeCount: 65, audioLengthBytes: 2)
        defer { fixture.cleanup() }
        let counter = WhisperHelperRuntimeCounter()
        let runtime = WhisperHelperRuntime(makeSession: { _ in
            counter.sessionCount += 1
            return WhisperHelperRuntimeSession { inputs in
                counter.batchCount += 1
                counter.inputCount += inputs.count
                return []
            }
        })

        try fixture.command().execute(runtime: runtime)

        XCTAssertEqual(counter.sessionCount, 1)
        XCTAssertEqual(counter.batchCount, 2)
        XCTAssertEqual(counter.inputCount, 65)
    }

    func testRejectsTraversalOutsideManagedRoot() throws {
        let fixture = try WhisperHelperFixture()
        defer { fixture.cleanup() }
        XCTAssertThrowsError(
            try WhisperHelperCommand(
                arguments: ["eye", WhisperHelperCommand.flag, "../manifest.json"],
                dataRoot: fixture.root,
                expectedModel: fixture.modelManifest
            )
        ) { error in
            XCTAssertEqual(error as? WhisperHelperCommandError, .invalidManifestPath)
        }
    }

    func testRejectsResultOutsideJobDirectoryAndUnexpectedModelHash() throws {
        let outside = try WhisperHelperFixture(resultRelativePath: "call-helper/result.json")
        defer { outside.cleanup() }
        XCTAssertThrowsError(try outside.command()) { error in
            XCTAssertEqual(error as? WhisperHelperCommandError, .invalidResultPath)
        }

        let wrongHash = try WhisperHelperFixture(modelSHA256: String(repeating: "f", count: 64))
        defer { wrongHash.cleanup() }
        XCTAssertThrowsError(try wrongHash.command()) { error in
            XCTAssertEqual(error as? WhisperHelperCommandError, .invalidModelIdentity)
        }

        let corrupted = try WhisperHelperFixture()
        defer { corrupted.cleanup() }
        try Data("same-size!".utf8).write(to: corrupted.modelURL)
        XCTAssertThrowsError(try corrupted.command()) { error in
            XCTAssertEqual(error as? WhisperHelperCommandError, .invalidModelIdentity)
        }
    }

    func testSharedHelperRejectsManagedModelPath() throws {
        let fixture = try WhisperHelperFixture(
            handyBackend: HandySpeechBackendReference(
                modelID: "handy-computer/whisper-large-v3-turbo-gguf/example.gguf",
                displayName: "Handy fixture",
                identitySHA256: String(repeating: "c", count: 64),
                runtimeRelease: "handy-test/transcribe-cpp"
            )
        )
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try fixture.command()) { error in
            XCTAssertEqual(error as? WhisperHelperCommandError, .invalidModelIdentity)
        }
    }

    func testSharedHelperLoadsCachedModelWithoutLaunchingHandy() throws {
        let fixture = try WhisperHandyHelperFixture()
        defer { fixture.cleanup() }
        let counter = WhisperHelperRuntimeCounter()
        let runtime = WhisperHelperRuntime(
            makeSession: { _ in
                counter.builtInSessionCount += 1
                return WhisperHelperRuntimeSession { _ in [] }
            },
            makeSharedSession: { modelURL in
                counter.sharedSessionCount += 1
                XCTAssertEqual(modelURL, fixture.modelURL.resolvingSymlinksInPath())
                return WhisperHelperRuntimeSession { inputs in
                    inputs.map { input in
                        WhisperHelperResultSegment(
                            source: input.source,
                            startSeconds: Double(input.startSample) / Double(input.sampleRate),
                            endSeconds: Double(input.startSample + Int64(input.samples.count))
                                / Double(input.sampleRate),
                            text: "shared model transcript"
                        )
                    }
                }
            }
        )

        try fixture.command().execute(runtime: runtime)

        XCTAssertEqual(counter.builtInSessionCount, 0)
        XCTAssertEqual(counter.sharedSessionCount, 1)
        let result = try JSONDecoder().decode(
            WhisperHelperResult.self,
            from: Data(contentsOf: fixture.resultURL)
        )
        XCTAssertEqual(result.runtimeRelease, "transcribe.cpp-v0.1.3")
        XCTAssertEqual(result.segments.map(\.text), ["shared model transcript"])
    }

    func testSharedRuntimePreservesContiguousOneMinuteWhisperContext() throws {
        var sampleCounts: [Int] = []
        let session = WhisperHelperRuntime.sharedRuntimeSession { samples in
            sampleCounts.append(samples.count)
            return [
                WhisperSegment(
                    startSeconds: 0,
                    endSeconds: Double(samples.count) / 16_000,
                    text: "batch"
                ),
            ]
        }
        var inputs = (0..<7).map { index in
            WhisperHelperPreparedInput(
                source: .me,
                sampleRate: 16_000,
                startSample: Int64(index * 160_000),
                samples: Array(repeating: 0, count: 160_000)
            )
        }
        inputs.append(WhisperHelperPreparedInput(
            source: .system,
            sampleRate: 16_000,
            startSample: 0,
            samples: Array(repeating: 0, count: 160_000)
        ))
        inputs.append(WhisperHelperPreparedInput(
            source: .system,
            sampleRate: 16_000,
            startSample: 320_000,
            samples: Array(repeating: 0, count: 160_000)
        ))

        let segments = try session.runBatch(inputs)

        XCTAssertEqual(sampleCounts, [960_000, 160_000, 160_000, 160_000])
        XCTAssertEqual(segments.map(\.source), [.me, .me, .system, .system])
        XCTAssertEqual(segments.map(\.startSeconds), [0, 60, 0, 20])
        XCTAssertEqual(segments.map(\.endSeconds), [60, 70, 10, 30])
    }

    func testRejectsAudioRangeLargerThanManagedFile() throws {
        let fixture = try WhisperHelperFixture(audioLengthBytes: 10_000)
        defer { fixture.cleanup() }
        let command = try fixture.command()
        XCTAssertThrowsError(
            try command.execute(runtime: WhisperHelperRuntime { _, _ in [] })
        ) { error in
            XCTAssertEqual(error as? WhisperHelperCommandError, .shortRead)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.resultURL.path))
    }

    func testSmokeCommandAcceptsOnlyVerifiedManagedCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-whisper-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("smoke-model".utf8)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifest = WhisperModelManifest(
            id: "smoke-fixture",
            displayName: "Fixture",
            repositoryID: "local/fixture",
            revision: String(repeating: "a", count: 40),
            sourceURL: URL(string: "https://example.invalid/model.bin")!,
            relativePath: "model/model.bin",
            expectedBytes: Int64(payload.count),
            sha256: digest,
            licenseSPDX: "MIT",
            licenseURL: URL(string: "https://example.invalid/license")!,
            runtimeRelease: "v1.9.1",
            runtimeArchiveSHA256: String(repeating: "b", count: 64)
        )
        let candidate = root.appendingPathComponent(WhisperModelSmokeCommand.expectedRelativePath)
        try FileManager.default.createDirectory(
            at: candidate.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: candidate)

        XCTAssertNoThrow(
            try WhisperModelSmokeCommand(
                arguments: [
                    "eye",
                    WhisperModelSmokeCommand.flag,
                    WhisperModelSmokeCommand.expectedRelativePath,
                ],
                dataRoot: root,
                expectedModel: manifest
            )
        )
        try Data("same-size!x".utf8).write(to: candidate)
        XCTAssertThrowsError(
            try WhisperModelSmokeCommand(
                arguments: [
                    "eye",
                    WhisperModelSmokeCommand.flag,
                    WhisperModelSmokeCommand.expectedRelativePath,
                ],
                dataRoot: root,
                expectedModel: manifest
            )
        )
    }
}

private struct WhisperHelperFixture {
    let root: URL
    let jobID: String
    let modelManifest: WhisperModelManifest
    let manifestRelativePath: String
    let resultRelativePath: String

    init(
        resultRelativePath suppliedResult: String? = nil,
        modelSHA256 suppliedHash: String? = nil,
        handyBackend: HandySpeechBackendReference? = nil,
        rangeCount: Int = 1,
        audioLengthBytes: Int64 = 8
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-whisper-helper-\(UUID().uuidString)", isDirectory: true)
        jobID = UUID().uuidString.lowercased()
        let modelPayload = Data("tiny-model".utf8)
        let modelDigest = SHA256.hash(data: modelPayload).map { String(format: "%02x", $0) }.joined()
        modelManifest = WhisperModelManifest(
            id: "helper-fixture",
            displayName: "Fixture",
            repositoryID: "local/fixture",
            revision: String(repeating: "a", count: 40),
            sourceURL: URL(string: "https://example.invalid/model.bin")!,
            relativePath: "model/model.bin",
            expectedBytes: Int64(modelPayload.count),
            sha256: modelDigest,
            licenseSPDX: "MIT",
            licenseURL: URL(string: "https://example.invalid/license")!,
            runtimeRelease: "v1.9.1",
            runtimeArchiveSHA256: String(repeating: "b", count: 64)
        )
        manifestRelativePath = "call-helper/jobs/\(jobID)/manifest.json"
        resultRelativePath = suppliedResult ?? "call-helper/jobs/\(jobID)/result.json"

        let modelURL = root.appendingPathComponent("ai/speech/v1/model/model.bin")
        let audioURL = root.appendingPathComponent("media/calls/1/me.pcm")
        let manifestURL = root.appendingPathComponent(manifestRelativePath)
        for directory in [
            modelURL.deletingLastPathComponent(),
            audioURL.deletingLastPathComponent(),
            manifestURL.deletingLastPathComponent(),
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try modelPayload.write(to: modelURL)
        let installation = WhisperModelInstallation(
            manifestID: modelManifest.id,
            revision: modelManifest.revision,
            sha256: modelManifest.sha256,
            expectedBytes: modelManifest.expectedBytes,
            runtimeRelease: modelManifest.runtimeRelease
        )
        try JSONEncoder().encode(installation).write(
            to: root.appendingPathComponent("ai/speech/v1/installation.json")
        )
        let pcm = [Int16(-32_768), 0, 16_384, 32_767].withUnsafeBytes { Data($0) }
        try pcm.write(to: audioURL)
        let manifest = WhisperHelperJobManifest(
            formatVersion: 1,
            jobID: jobID,
            callID: 1,
            callGeneration: 2,
            modelRelativePath: "ai/speech/v1/model/model.bin",
            modelSHA256: suppliedHash ?? modelDigest,
            handyBackend: handyBackend,
            resultRelativePath: resultRelativePath,
            audioRanges: (0..<rangeCount).map { index in
                WhisperHelperAudioRange(
                    source: .me,
                    relativePath: "media/calls/1/me.pcm",
                    offsetBytes: 0,
                    lengthBytes: audioLengthBytes,
                    sampleRate: 16_000,
                    startSample: 16_000 + Int64(index)
                )
            }
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL)
    }

    var resultURL: URL { root.appendingPathComponent(resultRelativePath) }
    var modelURL: URL { root.appendingPathComponent("ai/speech/v1/model/model.bin") }

    func command() throws -> WhisperHelperCommand {
        try WhisperHelperCommand(
            arguments: ["eye", WhisperHelperCommand.flag, manifestRelativePath],
            dataRoot: root,
            expectedModel: modelManifest
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class WhisperHelperRuntimeCounter {
    var sessionCount = 0
    var batchCount = 0
    var inputCount = 0
    var builtInSessionCount = 0
    var sharedSessionCount = 0
}

private struct WhisperHandyHelperFixture {
    let root: URL
    let hubRoot: URL
    let manifestRelativePath: String
    let resultURL: URL
    let modelURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-whisper-handy-helper-\(UUID().uuidString)", isDirectory: true)
        hubRoot = root.appendingPathComponent("hub", isDirectory: true)
        let modelID = "handy-computer/whisper-large-v3-turbo-gguf/whisper-large-v3-turbo-Q8_0.gguf"
        let revision = String(repeating: "a", count: 40)
        let repositoryRoot = hubRoot
            .appendingPathComponent("models--handy-computer--whisper-large-v3-turbo-gguf")
        let referenceURL = repositoryRoot.appendingPathComponent("refs/main")
        modelURL = repositoryRoot
            .appendingPathComponent("snapshots/\(revision)/whisper-large-v3-turbo-Q8_0.gguf")
        let settingsURL = root.appendingPathComponent("settings_store.json")
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
        let backend = try XCTUnwrap(
            HandySpeechModelProbe.discover(
                settingsURL: settingsURL,
                hubRoot: hubRoot
            ).backend
        )

        let jobID = UUID().uuidString.lowercased()
        manifestRelativePath = "call-helper/jobs/\(jobID)/manifest.json"
        let manifestURL = root.appendingPathComponent(manifestRelativePath)
        resultURL = root.appendingPathComponent("call-helper/jobs/\(jobID)/result.json")
        let audioURL = root.appendingPathComponent("media/calls/1/me.pcm")
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pcm = [Int16(-32_768), 0, 16_384, 32_767].withUnsafeBytes { Data($0) }
        try pcm.write(to: audioURL)
        let manifest = WhisperHelperJobManifest(
            formatVersion: 1,
            jobID: jobID,
            callID: 1,
            callGeneration: 2,
            modelRelativePath: "external/handy",
            modelSHA256: backend.identitySHA256,
            handyBackend: backend,
            resultRelativePath: "call-helper/jobs/\(jobID)/result.json",
            audioRanges: [
                WhisperHelperAudioRange(
                    source: .me,
                    relativePath: "media/calls/1/me.pcm",
                    offsetBytes: 0,
                    lengthBytes: Int64(pcm.count),
                    sampleRate: 16_000,
                    startSample: 16_000
                ),
            ]
        )
        try JSONEncoder().encode(manifest).write(to: manifestURL)
    }

    func command() throws -> WhisperHelperCommand {
        try WhisperHelperCommand(
            arguments: ["eye", WhisperHelperCommand.flag, manifestRelativePath],
            dataRoot: root,
            handyHubRoot: hubRoot
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
