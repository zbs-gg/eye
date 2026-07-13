import Foundation

/// One disk-safety contract shared by continuous capture and explicit model downloads.
/// Model work must leave capture's pause reserve untouched, plus a small write/checkpoint margin.
struct DiskReservePolicy: Sendable, Equatable {
    static let standard = DiskReservePolicy(
        pauseBytes: 2 * 1_024 * 1_024 * 1_024,
        recoveryBytes: 4 * 1_024 * 1_024 * 1_024,
        modelSafetyBytes: 512 * 1_024 * 1_024
    )

    let pauseBytes: Int64
    let recoveryBytes: Int64
    let modelSafetyBytes: Int64

    init(
        pauseBytes: Int64,
        recoveryBytes: Int64,
        modelSafetyBytes: Int64 = 0
    ) {
        let pause = max(0, pauseBytes)
        self.pauseBytes = pause
        self.recoveryBytes = max(pause, recoveryBytes)
        self.modelSafetyBytes = max(0, modelSafetyBytes)
    }

    var modelReserveBytes: Int64 {
        addingWithoutOverflow(pauseBytes, modelSafetyBytes)
    }

    func requiredCapacityForDownload(remainingBytes: Int64) -> Int64 {
        addingWithoutOverflow(max(0, remainingBytes), modelReserveBytes)
    }

    func addingModelReserve(to bytes: Int64) -> Int64 {
        addingWithoutOverflow(max(0, bytes), modelReserveBytes)
    }

    func canDownload(remainingBytes: Int64, availableBytes: Int64) -> Bool {
        max(0, availableBytes) >= requiredCapacityForDownload(remainingBytes: remainingBytes)
    }

    private func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }
}
