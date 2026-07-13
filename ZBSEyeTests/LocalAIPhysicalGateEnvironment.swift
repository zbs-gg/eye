import CryptoKit
import Darwin
import Foundation

struct LocalAIPackageVersions: Codable, Sendable, Equatable {
    let mlxSwiftLM: String
    let mlxSwift: String
    let swiftTransformers: String
}

/// Auditable evidence for every fact that can make a physical model result
/// release-qualifying. The quality and performance gates intentionally share
/// this exact record and validator so one cannot silently qualify a wider
/// machine, build, runtime, or network envelope than the other.
struct LocalAIPhysicalGateEnvironment: Codable, Sendable, Equatable {
    let machineIdentifier: String
    let physicalMemoryBytes: UInt64
    let architecture: String
    let operatingSystemVersion: String
    let operatingSystemMajorVersion: Int
    let operatingSystemBuild: String
    let kernelVersion: String
    let processorBrand: String
    let processorCount: Int
    let activeProcessorCount: Int

    let buildConfiguration: String
    let bundleIdentifier: String
    let appMarketingVersion: String
    let appBuildVersion: String
    let sourceRevision: String
    let sourceTreeState: String
    let packageResolvedSHA256: String
    let swiftLanguageVersion: String
    let swiftCompilerVersion: String
    let xcodeVersion: String
    let sdkVersion: String
    let deploymentTarget: String

    let packageVersions: LocalAIPackageVersions
    let modelID: String
    let modelArtifactVersion: Int
    let modelRevision: String
    let modelManifestFingerprintSHA256: String
    let qualityProtocolID: String

    let hfHubOffline: String
    let transformersOffline: String
    let allowModelDownloads: String

    func replacing(
        machineIdentifier: String? = nil,
        physicalMemoryBytes: UInt64? = nil,
        architecture: String? = nil,
        buildConfiguration: String? = nil,
        sourceTreeState: String? = nil,
        packageVersions: LocalAIPackageVersions? = nil,
        modelRevision: String? = nil,
        qualityProtocolID: String? = nil,
        hfHubOffline: String? = nil,
        transformersOffline: String? = nil,
        allowModelDownloads: String? = nil
    ) -> Self {
        Self(
            machineIdentifier: machineIdentifier ?? self.machineIdentifier,
            physicalMemoryBytes: physicalMemoryBytes ?? self.physicalMemoryBytes,
            architecture: architecture ?? self.architecture,
            operatingSystemVersion: operatingSystemVersion,
            operatingSystemMajorVersion: operatingSystemMajorVersion,
            operatingSystemBuild: operatingSystemBuild,
            kernelVersion: kernelVersion,
            processorBrand: processorBrand,
            processorCount: processorCount,
            activeProcessorCount: activeProcessorCount,
            buildConfiguration: buildConfiguration ?? self.buildConfiguration,
            bundleIdentifier: bundleIdentifier,
            appMarketingVersion: appMarketingVersion,
            appBuildVersion: appBuildVersion,
            sourceRevision: sourceRevision,
            sourceTreeState: sourceTreeState ?? self.sourceTreeState,
            packageResolvedSHA256: packageResolvedSHA256,
            swiftLanguageVersion: swiftLanguageVersion,
            swiftCompilerVersion: swiftCompilerVersion,
            xcodeVersion: xcodeVersion,
            sdkVersion: sdkVersion,
            deploymentTarget: deploymentTarget,
            packageVersions: packageVersions ?? self.packageVersions,
            modelID: modelID,
            modelArtifactVersion: modelArtifactVersion,
            modelRevision: modelRevision ?? self.modelRevision,
            modelManifestFingerprintSHA256: modelManifestFingerprintSHA256,
            qualityProtocolID: qualityProtocolID ?? self.qualityProtocolID,
            hfHubOffline: hfHubOffline ?? self.hfHubOffline,
            transformersOffline: transformersOffline ?? self.transformersOffline,
            allowModelDownloads: allowModelDownloads ?? self.allowModelDownloads
        )
    }
}

enum LocalAIPhysicalGateEnvironmentError: Error, LocalizedError, Equatable {
    case missingEvidence(String)
    case unqualified([String])

    var errorDescription: String? {
        switch self {
        case .missingEvidence(let message):
            "Physical gate evidence is incomplete: \(message)"
        case .unqualified(let failures):
            "Physical gate environment is not qualified: \(failures.joined(separator: "; "))"
        }
    }
}

enum LocalAIPhysicalGateValidator {
    static let qualifiedMemoryBytes: UInt64 = 64 * 1_024 * 1_024 * 1_024
    static let qualifiedPackageVersions = LocalAIPackageVersions(
        mlxSwiftLM: "3.31.4",
        mlxSwift: "0.31.4",
        swiftTransformers: "1.3.3"
    )

    static func validate(
        _ evidence: LocalAIPhysicalGateEnvironment,
        manifest: BuiltInModelManifest
    ) throws {
        var failures: [String] = []
        if evidence.machineIdentifier != "Mac16,5" { failures.append("machine must be Mac16,5") }
        if evidence.physicalMemoryBytes != qualifiedMemoryBytes {
            failures.append("physical memory must be exactly 68719476736 bytes")
        }
        if manifest.hardware.minimumUnifiedMemoryBytes != qualifiedMemoryBytes
            || manifest.hardware.maximumUnifiedMemoryBytesExclusive != qualifiedMemoryBytes + 1
        {
            failures.append("product manifest must encode the exact 64 GiB envelope")
        }
        if evidence.architecture != "arm64" { failures.append("architecture must be arm64") }
        if evidence.operatingSystemMajorVersion < 15 { failures.append("macOS must be 15 or newer") }
        if evidence.buildConfiguration != "Release" {
            failures.append("test bundle must be a Release build")
        }
        if evidence.packageVersions != qualifiedPackageVersions {
            failures.append("MLX and Transformers package pins do not match qualification")
        }
        if evidence.swiftLanguageVersion != "6" { failures.append("Swift language mode must be 6") }
        if evidence.hfHubOffline != "1" || evidence.transformersOffline != "1"
            || evidence.allowModelDownloads != "0"
        {
            failures.append("offline/no-download guards are not active")
        }
        if evidence.modelID != manifest.id
            || evidence.modelArtifactVersion != manifest.artifactVersion
            || evidence.modelRevision != manifest.revision
            || evidence.modelManifestFingerprintSHA256 != manifest.aggregateFingerprintSHA256
            || evidence.qualityProtocolID != manifest.generation.benchmarkProtocol
        {
            failures.append("runtime model identity does not match the product manifest")
        }
        if !isLowercaseHex(evidence.sourceRevision, count: 40) {
            failures.append("source revision must be a full lowercase git commit")
        }
        if evidence.sourceTreeState != "clean" {
            failures.append("source tree state must be exactly clean")
        }
        if !isLowercaseHex(evidence.packageResolvedSHA256, count: 64) {
            failures.append("Package.resolved fingerprint must be a SHA-256 digest")
        }
        if evidence.operatingSystemVersion.isEmpty || evidence.operatingSystemBuild.isEmpty
            || evidence.kernelVersion.isEmpty || evidence.processorBrand.isEmpty
            || evidence.processorCount <= 0 || evidence.activeProcessorCount <= 0
            || evidence.bundleIdentifier.isEmpty || evidence.appMarketingVersion.isEmpty
            || evidence.appBuildVersion.isEmpty
            || evidence.swiftCompilerVersion.isEmpty || evidence.xcodeVersion.isEmpty
            || evidence.sdkVersion.isEmpty || evidence.deploymentTarget.isEmpty
        {
            failures.append("machine/build metadata is incomplete")
        }
        if !failures.isEmpty {
            throw LocalAIPhysicalGateEnvironmentError.unqualified(failures)
        }
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.count == count && value.unicodeScalars.allSatisfy {
            (0x30...0x39).contains($0.value) || (0x61...0x66).contains($0.value)
        }
    }
}

enum LocalAIPhysicalGateEvidenceCapture {
    private struct ResolvedFile: Decodable {
        struct Pin: Decodable {
            struct State: Decodable { let version: String? }
            let identity: String
            let state: State
        }
        let pins: [Pin]
    }

    static func capture(
        bundle: Bundle,
        manifest: BuiltInModelManifest,
        hfHubOffline: String?,
        transformersOffline: String?,
        allowModelDownloads: String?,
        sourceRoot: URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    ) throws -> LocalAIPhysicalGateEnvironment {
        let resolvedURL = sourceRoot.appendingPathComponent(
            "ZBSEye.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        let resolvedData: Data
        do {
            resolvedData = try Data(contentsOf: resolvedURL)
        } catch {
            throw LocalAIPhysicalGateEnvironmentError.missingEvidence(
                "Package.resolved is unavailable at \(resolvedURL.path)"
            )
        }
        let resolved = try JSONDecoder().decode(ResolvedFile.self, from: resolvedData)
        let versions = Dictionary(
            uniqueKeysWithValues: resolved.pins.compactMap { pin in
                pin.state.version.map { (pin.identity, $0) }
            }
        )
        guard let mlxSwiftLM = versions["mlx-swift-lm"],
              let mlxSwift = versions["mlx-swift"],
              let swiftTransformers = versions["swift-transformers"] else {
            throw LocalAIPhysicalGateEnvironmentError.missingEvidence(
                "one or more required package versions are absent"
            )
        }
        let sourceRevision = configuredValue(
            environment: "ZBS_EYE_SOURCE_REVISION",
            bundle: bundle,
            plist: "ZBSEyeSourceRevision"
        ) ?? ""
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return LocalAIPhysicalGateEnvironment(
            machineIdentifier: sysctlString("hw.model") ?? "",
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            architecture: architecture,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            operatingSystemMajorVersion: os.majorVersion,
            operatingSystemBuild: sysctlString("kern.osversion") ?? "",
            kernelVersion: sysctlString("kern.osrelease") ?? "",
            processorBrand: sysctlString("machdep.cpu.brand_string") ?? "",
            processorCount: ProcessInfo.processInfo.processorCount,
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            buildConfiguration: buildConfiguration,
            bundleIdentifier: bundle.bundleIdentifier ?? "",
            appMarketingVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "",
            appBuildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            sourceRevision: sourceRevision,
            sourceTreeState: bundle.object(forInfoDictionaryKey: "ZBSEyeSourceTreeState")
                as? String ?? "",
            packageResolvedSHA256: SHA256.hash(data: resolvedData).map {
                String(format: "%02x", $0)
            }.joined(),
            swiftLanguageVersion: "6",
            swiftCompilerVersion: bundle.object(forInfoDictionaryKey: "ZBSEyeSwiftCompilerVersion")
                as? String ?? "",
            xcodeVersion: bundle.object(forInfoDictionaryKey: "ZBSEyeXcodeVersion")
                as? String ?? "",
            sdkVersion: bundle.object(forInfoDictionaryKey: "ZBSEyeSDKVersion")
                as? String ?? "",
            deploymentTarget: bundle.object(forInfoDictionaryKey: "ZBSEyeDeploymentTarget")
                as? String ?? "",
            packageVersions: LocalAIPackageVersions(
                mlxSwiftLM: mlxSwiftLM,
                mlxSwift: mlxSwift,
                swiftTransformers: swiftTransformers
            ),
            modelID: manifest.id,
            modelArtifactVersion: manifest.artifactVersion,
            modelRevision: manifest.revision,
            modelManifestFingerprintSHA256: manifest.aggregateFingerprintSHA256,
            qualityProtocolID: manifest.generation.benchmarkProtocol,
            hfHubOffline: hfHubOffline ?? "",
            transformersOffline: transformersOffline ?? "",
            allowModelDownloads: allowModelDownloads ?? ""
        )
    }

    static func configuredValue(
        environment: String,
        bundle: Bundle,
        plist: String
    ) -> String? {
        let raw = ProcessInfo.processInfo.environment[environment]
            ?? bundle.object(forInfoDictionaryKey: plist) as? String
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }

    private static var architecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }

    private static var buildConfiguration: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }
}
