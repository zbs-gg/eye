import Darwin
import Foundation
import MachO

struct ResourceUsageRawSample: Sendable, Equatable {
    let processTimeSeconds: Double
    let monotonicSeconds: Double
    let physicalFootprintBytes: Int64?
}

struct ResourceUsageMeasurement: Sendable, Equatable {
    let cpuPercent: Double?
    let physicalFootprintBytes: Int64?
}

protocol ResourceUsageSampling: Sendable {
    func sample() async -> ResourceUsageRawSample?
}

struct ResourceUsageSampler: ResourceUsageSampling, Sendable {
    func sample() async -> ResourceUsageRawSample? {
        await Task.detached(priority: .utility) {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
            let user = Double(usage.ru_utime.tv_sec)
                + Double(usage.ru_utime.tv_usec) / 1_000_000
            let system = Double(usage.ru_stime.tv_sec)
                + Double(usage.ru_stime.tv_usec) / 1_000_000
            return ResourceUsageRawSample(
                processTimeSeconds: user + system,
                monotonicSeconds: ProcessInfo.processInfo.systemUptime,
                physicalFootprintBytes: Self.physicalFootprint()
            )
        }.value
    }

    static func measure(
        previous: ResourceUsageRawSample?,
        current: ResourceUsageRawSample
    ) -> ResourceUsageMeasurement {
        guard let previous else {
            return ResourceUsageMeasurement(
                cpuPercent: nil,
                physicalFootprintBytes: current.physicalFootprintBytes
            )
        }
        let wall = current.monotonicSeconds - previous.monotonicSeconds
        let process = current.processTimeSeconds - previous.processTimeSeconds
        let cpu = wall > 0 && process >= 0 && wall.isFinite && process.isFinite
            ? max(0, process / wall * 100)
            : nil
        return ResourceUsageMeasurement(
            cpuPercent: cpu,
            physicalFootprintBytes: current.physicalFootprintBytes
        )
    }

    private static func physicalFootprint() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(clamping: info.phys_footprint)
    }
}
