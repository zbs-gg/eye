import Darwin
import Foundation

struct BuiltInModelHardwareSnapshot: Sendable, Equatable {
    let isAppleSilicon: Bool
    let unifiedMemoryBytes: UInt64
    let machineIdentifier: String
    let macOSMajorVersion: Int

    func supports(_ manifest: BuiltInModelManifest) -> Bool {
        guard macOSMajorVersion >= manifest.hardware.minimumMacOSMajorVersion,
              manifest.hardware.supportedArchitectures.contains("arm64") == isAppleSilicon,
              unifiedMemoryBytes >= manifest.hardware.minimumUnifiedMemoryBytes else {
            return false
        }
        if let maximum = manifest.hardware.maximumUnifiedMemoryBytesExclusive,
           unifiedMemoryBytes >= maximum {
            return false
        }
        return BuiltInModelManifest.recommended(
            isAppleSilicon: isAppleSilicon,
            unifiedMemoryBytes: unifiedMemoryBytes,
            machineIdentifier: machineIdentifier
        ) == manifest
    }

    static func current() -> BuiltInModelHardwareSnapshot {
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return BuiltInModelHardwareSnapshot(
            isAppleSilicon: appleSilicon,
            unifiedMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            machineIdentifier: machineModel(),
            macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    private static func machineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0,
              size > 1 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }
}

enum BuiltInModelRuntimeSupport {
    /// Hugging Face's immutable `resolve/<revision>` endpoint currently
    /// redirects large files to this TLS authority. Keep redirect authorities
    /// explicit: neither arbitrary `*.hf.co` nor arbitrary AWS hosts inherit
    /// download trust.
    private static let pinnedRedirectAssetHosts: Set<String> = [
        "us.aws.cdn.hf.co",
    ]

    static func availableCapacity(at root: URL) throws -> Int64 {
        let values = try root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let capacity = values.volumeAvailableCapacityForImportantUsage,
              capacity >= 0 else {
            throw BuiltInModelManagerError.capacityUnavailable
        }
        return Int64(capacity)
    }

    static func downloadCapacityDecision(
        _ progress: BuiltInDownloadCapacityProgress,
        availableBytes: Int64
    ) -> BuiltInDownloadCapacityDecision {
        let reserve = BuiltInModelManager.captureReserveBytes.addingReportingOverflow(
            BuiltInModelManager.capacitySafetyBytes
        )
        guard !reserve.overflow else {
            return .insufficient(requiredBytes: .max, availableBytes: max(0, availableBytes))
        }
        let required = max(0, progress.remainingBytes).addingReportingOverflow(
            reserve.partialValue
        )
        guard !required.overflow else {
            return .insufficient(requiredBytes: .max, availableBytes: max(0, availableBytes))
        }
        let available = max(0, availableBytes)
        return available >= required.partialValue
            ? .sufficient
            : .insufficient(requiredBytes: required.partialValue, availableBytes: available)
    }

    static var allowedAssetHosts: Set<String> {
        Set(
            BuiltInModelManifest.all
                .flatMap(\.files)
                .compactMap { $0.sourceURL.host?.lowercased() }
        ).union(pinnedRedirectAssetHosts)
    }
}
