import XCTest

final class LocalAIPhysicalGateEnvironmentTests: XCTestCase {
    func testExactQualifiedEnvironmentPasses() throws {
        try LocalAIPhysicalGateValidator.validate(
            qualifiedEnvironment(),
            manifest: BuiltInModelManifest.regular
        )
    }

    func testEveryReleaseBoundaryFailsClosed() throws {
        let baseline = qualifiedEnvironment()
        let mutations: [(String, LocalAIPhysicalGateEnvironment)] = [
            ("machine", baseline.replacing(machineIdentifier: "Mac16,6")),
            ("memory", baseline.replacing(physicalMemoryBytes: baseline.physicalMemoryBytes + 1)),
            ("architecture", baseline.replacing(architecture: "x86_64")),
            ("configuration", baseline.replacing(buildConfiguration: "Debug")),
            ("hf offline", baseline.replacing(hfHubOffline: "0")),
            ("transformers offline", baseline.replacing(transformersOffline: "0")),
            ("downloads", baseline.replacing(allowModelDownloads: "1")),
            (
                "mlx swift lm pin",
                baseline.replacing(
                    packageVersions: .init(
                        mlxSwiftLM: "3.31.5",
                        mlxSwift: "0.31.4",
                        swiftTransformers: "1.3.3"
                    )
                )
            ),
            (
                "mlx swift pin",
                baseline.replacing(
                    packageVersions: .init(
                        mlxSwiftLM: "3.31.4",
                        mlxSwift: "0.31.5",
                        swiftTransformers: "1.3.3"
                    )
                )
            ),
            (
                "transformers pin",
                baseline.replacing(
                    packageVersions: .init(
                        mlxSwiftLM: "3.31.4",
                        mlxSwift: "0.31.4",
                        swiftTransformers: "1.3.4"
                    )
                )
            ),
            ("model", baseline.replacing(modelRevision: "floating-main")),
            ("protocol", baseline.replacing(qualityProtocolID: "local-ai-v8")),
        ]

        for (boundary, candidate) in mutations {
            XCTAssertThrowsError(
                try LocalAIPhysicalGateValidator.validate(
                    candidate,
                    manifest: BuiltInModelManifest.regular
                ),
                "Expected fail-closed validation for \(boundary)"
            )
        }
    }

    func testEvidenceCarriesMachineBuildRuntimeAndOfflineMetadata() throws {
        let evidence = qualifiedEnvironment()

        XCTAssertFalse(evidence.operatingSystemVersion.isEmpty)
        XCTAssertFalse(evidence.operatingSystemBuild.isEmpty)
        XCTAssertFalse(evidence.kernelVersion.isEmpty)
        XCTAssertFalse(evidence.processorBrand.isEmpty)
        XCTAssertGreaterThan(evidence.processorCount, 0)
        XCTAssertGreaterThan(evidence.activeProcessorCount, 0)
        XCTAssertEqual(evidence.bundleIdentifier, "gg.zbs.eye.tests")
        XCTAssertEqual(evidence.appMarketingVersion, "0.3.0")
        XCTAssertEqual(evidence.appBuildVersion, "4")
        XCTAssertFalse(evidence.sourceRevision.isEmpty)
        XCTAssertEqual(evidence.sourceTreeState, "clean")
        XCTAssertFalse(evidence.packageResolvedSHA256.isEmpty)
        XCTAssertEqual(evidence.swiftLanguageVersion, "6")
        XCTAssertFalse(evidence.swiftCompilerVersion.isEmpty)
        XCTAssertFalse(evidence.xcodeVersion.isEmpty)
        XCTAssertFalse(evidence.sdkVersion.isEmpty)
        XCTAssertEqual(evidence.deploymentTarget, "15.0")
        XCTAssertEqual(evidence.modelManifestFingerprintSHA256.count, 64)
    }

    func testPhysicalGateScriptCarriesReleaseAndSourceIdentityAcrossXCTestBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-local-ai.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("SOURCE_REVISION="))
        XCTAssertTrue(script.contains("ZBS_EYE_SOURCE_REVISION=\"$SOURCE_REVISION\""))
        XCTAssertTrue(script.contains(
            "RUN_RUNTIME_SMOKE + RUN_QUALITY_GATE + RUN_QUALITY_PROBE + RUN_PERFORMANCE_GATE"
        ))
        XCTAssertTrue(script.contains("CONFIGURATION=\"Release\""))
    }

    func testRuntimeSmokeUsesTheShippingServiceAndProductionAskBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let smoke = try String(
            contentsOf: root.appendingPathComponent("ZBSEyeTests/MLXRuntimeSmokeTests.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(smoke.contains("MLXLocalRuntimeDriver()"))
        XCTAssertTrue(smoke.contains("LocalInferenceService("))
        XCTAssertTrue(smoke.contains("AskService("))
        XCTAssertTrue(smoke.contains("response.provenance"))
        XCTAssertTrue(smoke.contains("runtimeDrainer()"))
        XCTAssertFalse(smoke.contains("LocalModelTestSupport.loadContainer"))
    }

    private func qualifiedEnvironment() -> LocalAIPhysicalGateEnvironment {
        LocalAIPhysicalGateEnvironment(
            machineIdentifier: "Mac16,5",
            physicalMemoryBytes: 64 * 1_024 * 1_024 * 1_024,
            architecture: "arm64",
            operatingSystemVersion: "macOS 26.2",
            operatingSystemMajorVersion: 26,
            operatingSystemBuild: "25C56",
            kernelVersion: "25.2.0",
            processorBrand: "Apple M4 Max",
            processorCount: 16,
            activeProcessorCount: 16,
            buildConfiguration: "Release",
            bundleIdentifier: "gg.zbs.eye.tests",
            appMarketingVersion: "0.3.0",
            appBuildVersion: "4",
            sourceRevision: String(repeating: "a", count: 40),
            sourceTreeState: "clean",
            packageResolvedSHA256: String(repeating: "b", count: 64),
            swiftLanguageVersion: "6",
            swiftCompilerVersion: "Apple Swift version 6.3.3",
            xcodeVersion: "Xcode 26.4 Build version 17F113",
            sdkVersion: "26.5",
            deploymentTarget: "15.0",
            packageVersions: .init(
                mlxSwiftLM: "3.31.4",
                mlxSwift: "0.31.4",
                swiftTransformers: "1.3.3"
            ),
            modelID: BuiltInModelManifest.regular.id,
            modelArtifactVersion: BuiltInModelManifest.regular.artifactVersion,
            modelRevision: BuiltInModelManifest.regular.revision,
            modelManifestFingerprintSHA256:
                BuiltInModelManifest.regular.aggregateFingerprintSHA256,
            qualityProtocolID: BuiltInModelManifest.regular.generation.benchmarkProtocol,
            hfHubOffline: "1",
            transformersOffline: "1",
            allowModelDownloads: "0"
        )
    }
}
