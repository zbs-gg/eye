import Darwin
import XCTest

/// Opt-in physical gate. Normal CI skips it; release qualification points the
/// environment variable at a synthetic/public fixture root and records only
/// aggregate timings and counts — never audio or a personal corpus.
final class PhysicalDiarizationBenchmarkTests: XCTestCase {
    func testSyntheticTwoSpeakerQualification() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment[
            "ZBSEYE_RUN_DIARIZATION_BENCHMARK_ROOT"
        ] else {
            throw XCTSkip("Physical diarization benchmark is opt-in.")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let fixtures = [("15m", "audio/fixture-15m.pcm", 900.0), ("60m", "audio/fixture-60m.pcm", 3_600.0)]
        for (label, relativePath, seconds) in fixtures {
            let bytes = try Int64(
                XCTUnwrap(
                    FileManager.default.attributesOfItem(
                        atPath: root.appendingPathComponent(relativePath).path
                    )[.size] as? NSNumber
                ).int64Value
            )
            for threshold in [0.6, 0.7] {
                let jobID = UUID().uuidString.lowercased()
                let jobRoot = root.appendingPathComponent("call-helper/diarization/\(jobID)", isDirectory: true)
                try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
                let manifest = DiarizationHelperJobManifest(
                    formatVersion: 1,
                    jobID: jobID,
                    callID: 1,
                    callGeneration: 0,
                    modelsRelativePath: DiarizationHelperCommand.modelsRelativePath,
                    resultRelativePath: "call-helper/diarization/\(jobID)/result.json",
                    clusteringThreshold: threshold,
                    audioRanges: [
                        DiarizationHelperAudioRange(
                            source: .system,
                            relativePath: relativePath,
                            offsetBytes: 0,
                            lengthBytes: bytes,
                            sampleRate: 16_000,
                            startSample: 0
                        )
                    ]
                )
                let manifestURL = jobRoot.appendingPathComponent("manifest.json")
                try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
                let command = try DiarizationHelperCommand(
                    arguments: ["ZBS Eye", DiarizationHelperCommand.flag, "call-helper/diarization/\(jobID)/manifest.json"],
                    dataRoot: root
                )

                let peak = PeakResidentSampler()
                await peak.start()
                let start = ContinuousClock.now
                try await command.execute()
                let elapsed = ContinuousClock.now - start
                let peakBytes = await peak.stop()
                let result = try JSONDecoder().decode(
                    DiarizationHelperResult.self,
                    from: Data(contentsOf: jobRoot.appendingPathComponent("result.json"))
                )
                let clusters = Set(result.segments.map(\.clusterKey)).count
                let wallSeconds = Self.seconds(elapsed)
                let record: [String: Any] = [
                    "fixture": label,
                    "threshold": threshold,
                    "audioSeconds": seconds,
                    "wallSeconds": wallSeconds,
                    "realTimeFactor": wallSeconds / seconds,
                    "peakResidentBytes": peakBytes,
                    "segments": result.segments.count,
                    "speakerClusters": clusters,
                    "speakerCountAbsoluteError": abs(clusters - 2),
                ]
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                print("DIARIZATION_BENCHMARK \(String(decoding: data, as: UTF8.self))")
                XCTAssertFalse(result.segments.isEmpty)
                XCTAssertLessThan(wallSeconds / seconds, 1)
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

private actor PeakResidentSampler {
    private var peak: Int64 = 0
    private var task: Task<Void, Never>?

    func start() {
        peak = Self.residentBytes()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sample()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stop() async -> Int64 {
        task?.cancel()
        await task?.value
        sample()
        return peak
    }

    private func sample() { peak = max(peak, Self.residentBytes()) }

    private nonisolated static func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }
}
