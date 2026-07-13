import Foundation
import Observation

@MainActor
@Observable
final class ResourceUsageStore {
    private(set) var cpuPercent: Double?
    private(set) var physicalFootprintBytes: Int64?
    private(set) var dataBytes: Int64 = 0

    @ObservationIgnored private let sampler: any ResourceUsageSampling
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let dataBytesProvider: @MainActor @Sendable () -> Int64
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var previous: ResourceUsageRawSample?

    init(
        sampler: any ResourceUsageSampling = ResourceUsageSampler(),
        interval: Duration = .seconds(5),
        dataBytes: @escaping @MainActor @Sendable () -> Int64 = { 0 }
    ) {
        self.sampler = sampler
        self.interval = interval
        dataBytesProvider = dataBytes
    }

    var isSampling: Bool { loopTask != nil }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await sampleOnce()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
            }
            if self.loopTask?.isCancelled == true { self.loopTask = nil }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        previous = nil
    }

    func sampleOnce() async {
        guard let current = await sampler.sample() else {
            cpuPercent = nil
            physicalFootprintBytes = nil
            dataBytes = dataBytesProvider()
            return
        }
        let measurement = ResourceUsageSampler.measure(
            previous: previous,
            current: current
        )
        previous = current
        cpuPercent = measurement.cpuPercent
        physicalFootprintBytes = measurement.physicalFootprintBytes
        dataBytes = dataBytesProvider()
    }
}
