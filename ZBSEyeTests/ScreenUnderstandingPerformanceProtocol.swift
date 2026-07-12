import Foundation

enum ScreenUnderstandingPerformanceProtocolError: Error, LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

struct ScreenUnderstandingPerformanceProtocol: Codable, Sendable, Equatable {
    var protocolID: String
    var offline: Bool
    var serial: Bool
    var retryCount: Int
    var coldSamples: Int
    var warmSamples: Int
    var soakSamples: Int
    var counterbalancedBlocks: Int
    var percentileMethod: String
    var maximumColdP95Seconds: Double
    var maximumWarmP95Seconds: Double
    var maximumIncrementalPeakBytes: UInt64
    var maximumRetainedGrowthBytes: UInt64
    var minimumUnloadReleaseFraction: Double
    var maximumUnloadSeconds: Double

    static let locked = Self(
        protocolID: "screen-understanding-v1",
        offline: true,
        serial: true,
        retryCount: 0,
        coldSamples: 20,
        warmSamples: 30,
        soakSamples: 50,
        counterbalancedBlocks: 3,
        percentileMethod: "nearest-rank",
        maximumColdP95Seconds: 10,
        maximumWarmP95Seconds: 3,
        maximumIncrementalPeakBytes: 2_147_483_648,
        maximumRetainedGrowthBytes: 104_857_600,
        minimumUnloadReleaseFraction: 0.90,
        maximumUnloadSeconds: 10
    )

    func validate() throws {
        guard protocolID == "screen-understanding-v1",
              offline,
              serial,
              retryCount == 0,
              coldSamples >= 20,
              warmSamples >= 30,
              soakSamples >= 50,
              counterbalancedBlocks >= 3,
              percentileMethod == "nearest-rank",
              maximumColdP95Seconds == 10,
              maximumWarmP95Seconds == 3,
              maximumIncrementalPeakBytes == 2_147_483_648,
              maximumRetainedGrowthBytes == 104_857_600,
              minimumUnloadReleaseFraction == 0.90,
              maximumUnloadSeconds == 10 else {
            throw ScreenUnderstandingPerformanceProtocolError.invalid(
                "performance protocol differs from the locked R19 gate"
            )
        }
    }
}

enum ScreenUnderstandingPerformanceMath {
    static func nearestRank(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty, percentile > 0, percentile <= 1 else { return nil }
        let sorted = values.sorted()
        let rank = Int(ceil(percentile * Double(sorted.count)))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    static func counterbalanced(methods: [String], blocks: Int) -> [[String]] {
        guard !methods.isEmpty, blocks > 0 else { return [] }
        return (0..<blocks).map { block in
            let offset = block % methods.count
            return Array(methods[offset...] + methods[..<offset])
        }
    }
}

struct ScreenUnderstandingRuntimeQualification: Sendable, Equatable {
    var exactRuntimeQualityScored: Bool
    var canonicalUsefulness: Double
    var runtimeUsefulness: Double
    var canonicalCriticalTextRecall: Double
    var runtimeCriticalTextRecall: Double
    var canonicalHallucination: Double
    var runtimeHallucination: Double

    var qualifies: Bool {
        exactRuntimeQualityScored
            && runtimeUsefulness >= canonicalUsefulness - 0.02
            && runtimeCriticalTextRecall >= canonicalCriticalTextRecall - 0.02
            && runtimeHallucination <= canonicalHallucination + 1
    }
}
