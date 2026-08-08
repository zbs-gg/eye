import AppKit
import Foundation
import ImageIO

enum VisualFrameImagePriority: Int, Sendable {
    case prefetch
    case current
}

struct VisualFrameImageRequest: Sendable, Hashable {
    let relativePath: String
    let maxPixel: Int

    init(relativePath: String, maxPixel: Int) {
        self.relativePath = relativePath
        self.maxPixel = max(1, maxPixel)
    }
}

struct VisualFrameImageLoaderDiagnostics: Sendable, Equatable {
    let cachedItemCount: Int
    let cachedMemoryCost: Int
    let activeDecodeCount: Int
    let pendingDecodeCount: Int
    let maximumObservedDecodeCount: Int
}

/// Sendable boundary for ImageIO work. AppKit images are created only after
/// this value returns to the main actor.
struct VisualFrameDecodedImage: @unchecked Sendable {
    let cgImage: CGImage
    let memoryCost: Int

    init(cgImage: CGImage, memoryCost: Int? = nil) {
        self.cgImage = cgImage
        self.memoryCost = max(1, memoryCost ?? cgImage.bytesPerRow * cgImage.height)
    }
}

typealias VisualFrameDecodeOperation = @Sendable (URL, Int) -> VisualFrameDecodedImage?

private struct VisualFrameImageCacheKey: Sendable, Hashable {
    let relativePath: String
    let maxPixel: Int
    /// A privacy erase makes even an already-running decode ineligible for
    /// reuse. Including the revision in the scheduler key prevents a fresh
    /// request from joining work that started before the erase boundary.
    let privacyRevision: UInt64
}

/// Priority-aware, deduplicating ImageIO scheduler. It permits two physical
/// decodes in total but only one speculative decode, leaving a slot available
/// for the image the user is actively seeking.
private actor VisualFrameDecodeScheduler {
    private struct Job {
        let key: VisualFrameImageCacheKey
        let url: URL
        let maxPixel: Int
        let sequence: UInt64
        var priority: VisualFrameImagePriority
        var waiters: [UUID: CheckedContinuation<VisualFrameDecodedImage?, Never>]
        var task: Task<Void, Never>?
        var isRunning: Bool
    }

    struct Diagnostics: Sendable {
        let active: Int
        let pending: Int
        let maximumObserved: Int
    }

    private let maximumConcurrentDecodes: Int
    private let decodeOperation: VisualFrameDecodeOperation
    private var jobs: [VisualFrameImageCacheKey: Job] = [:]
    private var nextSequence: UInt64 = 0
    private var activeDecodeCount = 0
    private var activePrefetchCount = 0
    private var maximumObservedDecodeCount = 0

    init(
        maximumConcurrentDecodes: Int = 2,
        decodeOperation: @escaping VisualFrameDecodeOperation
    ) {
        self.maximumConcurrentDecodes = max(1, maximumConcurrentDecodes)
        self.decodeOperation = decodeOperation
    }

    func decode(
        key: VisualFrameImageCacheKey,
        url: URL,
        priority: VisualFrameImagePriority
    ) async -> VisualFrameDecodedImage? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                enqueue(
                    waiterID: waiterID,
                    continuation: continuation,
                    key: key,
                    url: url,
                    priority: priority
                )
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID, key: key) }
        }
    }

    func diagnostics() -> Diagnostics {
        Diagnostics(
            active: activeDecodeCount,
            pending: jobs.values.count { !$0.isRunning },
            maximumObserved: maximumObservedDecodeCount
        )
    }

    private func enqueue(
        waiterID: UUID,
        continuation: CheckedContinuation<VisualFrameDecodedImage?, Never>,
        key: VisualFrameImageCacheKey,
        url: URL,
        priority: VisualFrameImagePriority
    ) {
        if var existing = jobs[key] {
            existing.waiters[waiterID] = continuation
            if priority.rawValue > existing.priority.rawValue {
                existing.priority = priority
            }
            jobs[key] = existing
        } else {
            nextSequence &+= 1
            jobs[key] = Job(
                key: key,
                url: url,
                maxPixel: key.maxPixel,
                sequence: nextSequence,
                priority: priority,
                waiters: [waiterID: continuation],
                task: nil,
                isRunning: false
            )
        }
        pump()
    }

    private func cancel(waiterID: UUID, key: VisualFrameImageCacheKey) {
        guard var job = jobs[key],
              let continuation = job.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(returning: nil)
        if job.waiters.isEmpty {
            if job.isRunning {
                // ImageIO is already using one of the two physical slots.
                // Keep it alive: a newer current request for the same key can
                // join this result. Cancelling here races that request and
                // turns a perfectly good decode into a false missing image.
                jobs[key] = job
            } else {
                // A queued speculative job has consumed no resource yet, so
                // it can disappear immediately when its last waiter leaves.
                jobs.removeValue(forKey: key)
            }
        } else {
            jobs[key] = job
        }
        pump()
    }

    private func pump() {
        while activeDecodeCount < maximumConcurrentDecodes {
            let queued = jobs.values.filter { !$0.isRunning }
            let next: Job?
            if let current = queued
                .filter({ $0.priority == .current })
                .min(by: { $0.sequence < $1.sequence }) {
                next = current
            } else if activePrefetchCount == 0 {
                next = queued
                    .filter { $0.priority == .prefetch }
                    .min(by: { $0.sequence < $1.sequence })
            } else {
                next = nil
            }
            guard var job = next else { return }

            job.isRunning = true
            activeDecodeCount += 1
            if job.priority == .prefetch { activePrefetchCount += 1 }
            maximumObservedDecodeCount = max(maximumObservedDecodeCount, activeDecodeCount)

            let operation = decodeOperation
            let key = job.key
            let url = job.url
            let maxPixel = job.maxPixel
            let startedAsPrefetch = job.priority == .prefetch
            let taskPriority: TaskPriority = startedAsPrefetch ? .utility : .userInitiated
            job.task = Task.detached(priority: taskPriority) {
                let decoded = Task.isCancelled ? nil : operation(url, maxPixel)
                await self.finish(
                    key: key,
                    decoded: Task.isCancelled ? nil : decoded,
                    startedAsPrefetch: startedAsPrefetch
                )
            }
            jobs[key] = job
        }
    }

    private func finish(
        key: VisualFrameImageCacheKey,
        decoded: VisualFrameDecodedImage?,
        startedAsPrefetch: Bool
    ) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        activeDecodeCount = max(0, activeDecodeCount - 1)
        if startedAsPrefetch { activePrefetchCount = max(0, activePrefetchCount - 1) }
        for continuation in job.waiters.values {
            continuation.resume(returning: decoded)
        }
        pump()
    }
}

/// Shared visual-image cache for Timeline and Activities. All state and AppKit
/// objects stay on the main actor; only ImageIO decoding runs in the scheduler.
@MainActor
final class VisualFrameImageLoader {
    static let defaultMemoryLimitBytes = 128 * 1024 * 1024

    private struct CacheEntry {
        let image: NSImage
        let memoryCost: Int
        var lastAccess: UInt64
    }

    private let mediaDirectory: URL
    private let memoryLimitBytes: Int
    private let scheduler: VisualFrameDecodeScheduler
    private let maximumPrefetchRequests: Int
    private var cache: [VisualFrameImageCacheKey: CacheEntry] = [:]
    private var cacheMemoryCost = 0
    private var accessCounter: UInt64 = 0
    private var privacyRevision: UInt64 = 0
    private var prefetchTasks: [Task<Void, Never>] = []

    init(
        mediaDirectory: URL,
        memoryLimitBytes: Int = VisualFrameImageLoader.defaultMemoryLimitBytes
    ) {
        self.mediaDirectory = mediaDirectory.standardizedFileURL
        self.memoryLimitBytes = max(0, memoryLimitBytes)
        maximumPrefetchRequests = 6
        scheduler = VisualFrameDecodeScheduler(
            decodeOperation: Self.decodeImage
        )
    }

    /// Test-only customization remains internal to the module; production uses
    /// exactly two decodes and ImageIO's thumbnail path.
    init(
        mediaDirectory: URL,
        memoryLimitBytes: Int = VisualFrameImageLoader.defaultMemoryLimitBytes,
        maximumConcurrentDecodes: Int,
        maximumPrefetchRequests: Int = 6,
        decodeOperation: @escaping VisualFrameDecodeOperation
    ) {
        self.mediaDirectory = mediaDirectory.standardizedFileURL
        self.memoryLimitBytes = max(0, memoryLimitBytes)
        self.maximumPrefetchRequests = max(0, maximumPrefetchRequests)
        scheduler = VisualFrameDecodeScheduler(
            maximumConcurrentDecodes: maximumConcurrentDecodes,
            decodeOperation: decodeOperation
        )
    }

    func image(
        relativePath: String,
        maxPixel: Int,
        priority: VisualFrameImagePriority = .current
    ) async -> NSImage? {
        let admittedPrivacyRevision = privacyRevision
        let key = VisualFrameImageCacheKey(
            relativePath: relativePath,
            maxPixel: max(1, maxPixel),
            privacyRevision: admittedPrivacyRevision
        )
        if let cached = cachedImage(for: key) { return cached }
        guard !Task.isCancelled,
              let url = resolvedURL(relativePath: relativePath) else { return nil }

        guard let decoded = await scheduler.decode(
            key: key,
            url: url,
            priority: priority
        ), !Task.isCancelled,
              admittedPrivacyRevision == privacyRevision else { return nil }
        if let cached = cachedImage(for: key) { return cached }

        let image = NSImage(
            cgImage: decoded.cgImage,
            size: NSSize(width: decoded.cgImage.width, height: decoded.cgImage.height)
        )
        insert(image, cost: decoded.memoryCost, for: key)
        return image
    }

    /// Replaces the complete speculative set. Tasks from an older seek are
    /// cancelled; the scheduler also limits speculative work to one decode.
    func replacePrefetch(with requests: [VisualFrameImageRequest]) {
        cancelPrefetch()
        guard maximumPrefetchRequests > 0 else { return }
        var seen: Set<VisualFrameImageRequest> = []
        let bounded = requests.filter { seen.insert($0).inserted }.prefix(maximumPrefetchRequests)
        prefetchTasks = bounded.map { request in
            Task(priority: .utility) { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.image(
                    relativePath: request.relativePath,
                    maxPixel: request.maxPixel,
                    priority: .prefetch
                )
            }
        }
    }

    func cancelPrefetch() {
        for task in prefetchTasks { task.cancel() }
        prefetchTasks.removeAll(keepingCapacity: false)
    }

    func cachedImage(relativePath: String, maxPixel: Int) -> NSImage? {
        cachedImage(for: VisualFrameImageCacheKey(
            relativePath: relativePath,
            maxPixel: max(1, maxPixel),
            privacyRevision: privacyRevision
        ))
    }

    /// Privacy erasure boundary. Cached AppKit images are released now, and
    /// results from decodes admitted before this revision can never repopulate
    /// the cache or be returned to their old callers.
    func invalidateAllForPrivacyErase() {
        privacyRevision &+= 1
        cancelPrefetch()
        cache.removeAll(keepingCapacity: false)
        cacheMemoryCost = 0
    }

    func diagnostics() async -> VisualFrameImageLoaderDiagnostics {
        let schedulerDiagnostics = await scheduler.diagnostics()
        return VisualFrameImageLoaderDiagnostics(
            cachedItemCount: cache.count,
            cachedMemoryCost: cacheMemoryCost,
            activeDecodeCount: schedulerDiagnostics.active,
            pendingDecodeCount: schedulerDiagnostics.pending,
            maximumObservedDecodeCount: schedulerDiagnostics.maximumObserved
        )
    }

    private func cachedImage(for key: VisualFrameImageCacheKey) -> NSImage? {
        guard var entry = cache[key] else { return nil }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        cache[key] = entry
        return entry.image
    }

    private func insert(_ image: NSImage, cost: Int, for key: VisualFrameImageCacheKey) {
        guard memoryLimitBytes > 0, cost <= memoryLimitBytes else { return }
        if let old = cache.removeValue(forKey: key) {
            cacheMemoryCost = max(0, cacheMemoryCost - old.memoryCost)
        }
        accessCounter &+= 1
        cache[key] = CacheEntry(
            image: image,
            memoryCost: cost,
            lastAccess: accessCounter
        )
        cacheMemoryCost += cost

        while cacheMemoryCost > memoryLimitBytes,
              let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            cache.removeValue(forKey: oldest.key)
            cacheMemoryCost = max(0, cacheMemoryCost - oldest.value.memoryCost)
        }
    }

    private func resolvedURL(relativePath: String) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.contains(".."),
              !relativePath.hasPrefix("/") else { return nil }
        let base = mediaDirectory.resolvingSymlinksInPath()
        let target = base
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard Array(target.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents,
              target.pathComponents.count > base.pathComponents.count else { return nil }
        return target
    }

    private nonisolated static func decodeImage(
        url: URL,
        maxPixel: Int
    ) -> VisualFrameDecodedImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard !Task.isCancelled,
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  options as CFDictionary
              ) else { return nil }
        return VisualFrameDecodedImage(cgImage: image)
    }
}
