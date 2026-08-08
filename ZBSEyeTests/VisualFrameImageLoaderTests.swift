import AppKit
import XCTest

@MainActor
final class VisualFrameImageLoaderTests: XCTestCase {
    func testDecodeConcurrencyNeverExceedsTwoAndCacheUsesPathPlusSize() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = VisualDecodeProbe(delay: 0.04)
        let loader = VisualFrameImageLoader(
            mediaDirectory: root,
            memoryLimitBytes: 1_024,
            maximumConcurrentDecodes: 2,
            decodeOperation: probe.decode
        )

        let tasks = (0..<8).map { index in
            Task { @MainActor in
                await loader.image(
                    relativePath: "frames/\(index).heic",
                    maxPixel: 240,
                    priority: .current
                )
            }
        }
        for task in tasks {
            let image = await task.value
            XCTAssertNotNil(image)
        }

        XCTAssertEqual(probe.maximumActive, 2)
        var diagnostics = await loader.diagnostics()
        XCTAssertEqual(diagnostics.maximumObservedDecodeCount, 2)
        XCTAssertLessThanOrEqual(diagnostics.cachedMemoryCost, 1_024)

        let beforeCacheHit = probe.totalDecodes
        let cached = await loader.image(
            relativePath: "frames/7.heic",
            maxPixel: 240,
            priority: .current
        )
        XCTAssertNotNil(cached)
        XCTAssertEqual(probe.totalDecodes, beforeCacheHit)

        let resized = await loader.image(
            relativePath: "frames/7.heic",
            maxPixel: 360,
            priority: .current
        )
        XCTAssertNotNil(resized)
        XCTAssertEqual(probe.totalDecodes, beforeCacheHit + 1)
        diagnostics = await loader.diagnostics()
        XCTAssertLessThanOrEqual(diagnostics.cachedMemoryCost, 1_024)
    }

    func testCurrentLoadUsesReservedSlotAndReplacementCancelsStalePrefetch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = VisualDecodeProbe(
            delay: 0.01,
            blockedFileName: "prefetch-a.heic"
        )
        let loader = VisualFrameImageLoader(
            mediaDirectory: root,
            maximumConcurrentDecodes: 2,
            maximumPrefetchRequests: 6,
            decodeOperation: probe.decode
        )

        loader.replacePrefetch(with: [
            .init(relativePath: "prefetch-a.heic", maxPixel: 360),
            .init(relativePath: "stale-b.heic", maxPixel: 360),
            .init(relativePath: "stale-c.heic", maxPixel: 360),
        ])
        try await waitUntil { probe.startedFiles.contains("prefetch-a.heic") }

        let currentTask = Task { @MainActor in
            await loader.image(
                relativePath: "current.heic",
                maxPixel: 2_400,
                priority: .current
            )
        }
        try await waitUntil { probe.startedFiles.contains("current.heic") }
        let current = await currentTask.value
        XCTAssertNotNil(current)

        loader.replacePrefetch(with: [
            .init(relativePath: "latest.heic", maxPixel: 360),
        ])
        probe.releaseBlockedDecode()
        try await waitUntil { probe.startedFiles.contains("latest.heic") }
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertFalse(probe.startedFiles.contains("stale-b.heic"))
        XCTAssertFalse(probe.startedFiles.contains("stale-c.heic"))
        XCTAssertLessThanOrEqual(probe.maximumActive, 2)
    }

    func testMissingAndEscapingFilesReturnNilWithoutCaching() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = VisualFrameImageLoader(mediaDirectory: root)

        let missing = await loader.image(
            relativePath: "missing.heic",
            maxPixel: 360,
            priority: .current
        )
        XCTAssertNil(missing)
        let escaping = await loader.image(
            relativePath: "../outside.heic",
            maxPixel: 360,
            priority: .current
        )
        XCTAssertNil(escaping)
        let diagnostics = await loader.diagnostics()
        XCTAssertEqual(diagnostics.cachedItemCount, 0)
        XCTAssertEqual(diagnostics.cachedMemoryCost, 0)
    }

    func testHundredRapidPrefetchReplacementsDecodeOnlyLatestWaitingImage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = VisualDecodeProbe(
            delay: 0.005,
            blockedFileName: "blocked.heic"
        )
        let loader = VisualFrameImageLoader(
            mediaDirectory: root,
            maximumConcurrentDecodes: 2,
            maximumPrefetchRequests: 6,
            decodeOperation: probe.decode
        )

        loader.replacePrefetch(with: [
            .init(relativePath: "blocked.heic", maxPixel: 360),
        ])
        try await waitUntil { probe.startedFiles.contains("blocked.heic") }

        for index in 0..<100 {
            loader.replacePrefetch(with: [
                .init(relativePath: "seek-\(index).heic", maxPixel: 360),
            ])
        }
        probe.releaseBlockedDecode()

        try await waitUntil { probe.startedFiles.contains("seek-99.heic") }
        try await Task.sleep(for: .milliseconds(30))

        let startedSeeks = probe.startedFiles.filter { $0.hasPrefix("seek-") }
        XCTAssertEqual(startedSeeks, ["seek-99.heic"])
        let diagnostics = await loader.diagnostics()
        XCTAssertLessThanOrEqual(diagnostics.maximumObservedDecodeCount, 2)
        XCTAssertLessThanOrEqual(diagnostics.pendingDecodeCount, 1)
    }

    func testCurrentWaiterCanJoinRunningDecodeAfterPrefetchIsCancelled() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = VisualDecodeProbe(
            delay: 0.005,
            blockedFileName: "shared.heic"
        )
        let loader = VisualFrameImageLoader(
            mediaDirectory: root,
            maximumConcurrentDecodes: 1,
            maximumPrefetchRequests: 1,
            decodeOperation: probe.decode
        )

        loader.replacePrefetch(with: [
            .init(relativePath: "shared.heic", maxPixel: 360),
        ])
        try await waitUntil { probe.startedFiles.contains("shared.heic") }

        // The original speculative waiter leaves while its physical ImageIO
        // work is underway. A current request for the same key must receive
        // that running result instead of inheriting cancellation.
        loader.cancelPrefetch()
        try await Task.sleep(for: .milliseconds(20))
        let current = Task { @MainActor in
            await loader.image(
                relativePath: "shared.heic",
                maxPixel: 360,
                priority: .current
            )
        }
        probe.releaseBlockedDecode()

        let loadedImage = await current.value
        XCTAssertNotNil(loadedImage)
        XCTAssertEqual(probe.startedFiles.filter { $0 == "shared.heic" }.count, 1)
    }

    func testPrivacyEraseDropsCachedImagesAndForcesFreshDecode() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = VisualDecodeProbe(delay: 0.001)
        let loader = VisualFrameImageLoader(
            mediaDirectory: root,
            maximumConcurrentDecodes: 2,
            decodeOperation: probe.decode
        )

        let initialImage = await loader.image(
            relativePath: "frames/private.heic",
            maxPixel: 480
        )
        XCTAssertNotNil(initialImage)
        let initialDiagnostics = await loader.diagnostics()
        XCTAssertEqual(initialDiagnostics.cachedItemCount, 1)

        loader.invalidateAllForPrivacyErase()

        var diagnostics = await loader.diagnostics()
        XCTAssertEqual(diagnostics.cachedItemCount, 0)
        XCTAssertEqual(diagnostics.cachedMemoryCost, 0)
        let reloadedImage = await loader.image(
            relativePath: "frames/private.heic",
            maxPixel: 480
        )
        XCTAssertNotNil(reloadedImage)
        XCTAssertEqual(probe.totalDecodes, 2)
        diagnostics = await loader.diagnostics()
        XCTAssertEqual(diagnostics.cachedItemCount, 1)
    }

    func testPrivacyEraseRejectsOldRunningDecodeAndPreventsFreshJoin() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = VisualDecodeProbe(
            delay: 0.001,
            blockedFileName: "private.heic"
        )
        let loader = VisualFrameImageLoader(
            mediaDirectory: root,
            maximumConcurrentDecodes: 2,
            decodeOperation: probe.decode
        )

        let oldTask = Task { @MainActor in
            await loader.image(relativePath: "private.heic", maxPixel: 480)
        }
        try await waitUntil { probe.startedFiles.count == 1 }

        loader.invalidateAllForPrivacyErase()
        let freshTask = Task { @MainActor in
            await loader.image(relativePath: "private.heic", maxPixel: 480)
        }
        try await waitUntil { probe.startedFiles.count == 2 }
        probe.releaseBlockedDecode()
        probe.releaseBlockedDecode()

        let oldImage = await oldTask.value
        let freshImage = await freshTask.value
        XCTAssertNil(oldImage)
        XCTAssertNotNil(freshImage)
        XCTAssertEqual(probe.totalDecodes, 2)
        let diagnostics = await loader.diagnostics()
        XCTAssertEqual(diagnostics.cachedItemCount, 1)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zbseye-visual-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for deterministic decode state")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class VisualDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let delay: TimeInterval
    private let blockedFileName: String?
    private let blockedSemaphore = DispatchSemaphore(value: 0)
    private var active = 0
    private var maximum = 0
    private var started: [String] = []
    private var decodes = 0

    init(delay: TimeInterval, blockedFileName: String? = nil) {
        self.delay = delay
        self.blockedFileName = blockedFileName
    }

    var maximumActive: Int { withLock { maximum } }
    var totalDecodes: Int { withLock { decodes } }
    var startedFiles: [String] { withLock { started } }

    func releaseBlockedDecode() {
        blockedSemaphore.signal()
    }

    func decode(url: URL, maxPixel _: Int) -> VisualFrameDecodedImage? {
        let name = url.lastPathComponent
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        decodes += 1
        started.append(name)
        lock.unlock()

        if name == blockedFileName {
            blockedSemaphore.wait()
        }
        Thread.sleep(forTimeInterval: delay)

        lock.lock()
        active -= 1
        lock.unlock()
        return VisualFrameDecodedImage(cgImage: Self.pixel, memoryCost: 128)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static let pixel: CGImage = {
        let bytes: [UInt8] = [0x36, 0x8A, 0xE8, 0xFF]
        let data = Data(bytes) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }()
}
