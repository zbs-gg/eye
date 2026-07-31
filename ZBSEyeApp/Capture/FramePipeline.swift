import Foundation
import ScreenCaptureKit
import CoreImage
import CoreVideo
import CoreGraphics
import ImageIO
import Vision
import Metal

struct OCRLine: Sendable {
    var text: String
    var confidence: Double
    var bbox: CGRect?     // normalized bbox from Vision (0..1, origin bottom-left) — for "click on what was found" / future redaction
}

/// CGImage is immutable and thread-safe — safe to run off the actor for OCR.
struct SendableCGImage: @unchecked Sendable { let image: CGImage }

struct ProcessedFrame: Sendable {
    var heicData: Data
    var phash: UInt64
    var fingerprint: String
    var isDuplicate: Bool
    var width: Int
    var height: Int
    var ocr: [OCRLine]
    var displayID: UInt32   // which display we actually captured (monitorId in the DB)
}

enum CaptureError: Error { case noDisplay, encodeFailed }

/// FramePipelineActor (per Pro): capture + encode + hash + OCR in ONE isolation domain. CGImage/
/// CVPixelBuffer live and die here; only a Sendable ProcessedFrame goes out. A reused
/// Metal CIContext. Perceptual-hash dedup (stores a UInt64, not the buffer).
actor FramePipeline {
    private let config: CaptureConfig
    private let ciContext: CIContext
    private var cachedContent: SCShareableContent?
    private var cachedProtectedApplicationSnapshot: ProtectedCaptureApplicationSnapshot?
    private var contentEpoch = CaptureContentEpoch()
    private var lastHashes: [Int: [UInt64]] = [:]   // [full, 4 quadrants] per display

    init(config: CaptureConfig) {
        self.config = config
        // cacheIntermediates:false — the biggest steady-RAM win: a shared CIContext otherwise piles up GPU
        // texture caches across frames (measured: ~550MB of stale IOSurface). We render each frame once and
        // don't reuse intermediates, so caching only costs memory. clearCaches() after each frame reclaims the rest.
        let opts: [CIContextOption: Any] = [.cacheIntermediates: false, .name: "ZBSEyeFramePipeline"]
        if let dev = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: dev, options: opts)
        } else {
            self.ciContext = CIContext(options: opts)
        }
    }

    func invalidateContent() {
        contentEpoch.invalidate()
        cachedContent = nil
        cachedProtectedApplicationSnapshot = nil
    }

    /// A verified login-session boundary must produce a fresh ordinary frame.
    /// Reset only here: clearing hashes on every app activation would defeat dedup.
    func invalidateSessionBoundary() {
        contentEpoch.invalidate()
        cachedContent = nil
        cachedProtectedApplicationSnapshot = nil
        lastHashes.removeAll(keepingCapacity: true)
    }

    /// Rebuild only Eye-owned disposable ScreenCaptureKit/dedup state. User
    /// intent, privacy configuration, and learned AX capability live elsewhere.
    func resetDisposableState() {
        contentEpoch.invalidate()
        cachedContent = nil
        cachedProtectedApplicationSnapshot = nil
        lastHashes.removeAll(keepingCapacity: false)
    }

    private func currentContent(
        expectedGeneration: UInt64,
        protectedApplicationSnapshot: ProtectedCaptureApplicationSnapshot
    ) async throws -> SCShareableContent? {
        if cachedProtectedApplicationSnapshot != protectedApplicationSnapshot {
            cachedContent = nil
            cachedProtectedApplicationSnapshot = nil
        }
        if let c = cachedContent {
            guard Self.contentCoversProtectedApplications(
                c,
                expected: protectedApplicationSnapshot
            ) else {
                invalidateAfterProtectedApplicationChange()
                return nil
            }
            return c
        }
        // Keep the complete application inventory. LocalAuthentication helpers
        // are often long-lived with only offscreen windows, and therefore vanish
        // from an on-screen-only inventory just before their sheet appears.
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard contentEpoch.contains(expectedGeneration) else { return nil }
        guard Self.contentCoversProtectedApplications(
            c,
            expected: protectedApplicationSnapshot
        ) else {
            invalidateAfterProtectedApplicationChange()
            return nil
        }
        cachedContent = c
        cachedProtectedApplicationSnapshot = protectedApplicationSnapshot
        return c
    }

    private static func contentCoversProtectedApplications(
        _ content: SCShareableContent,
        expected: ProtectedCaptureApplicationSnapshot
    ) -> Bool {
        let represented: Set<ProtectedCaptureApplicationIdentity> = Set(
            content.applications.compactMap { application -> ProtectedCaptureApplicationIdentity? in
                guard CaptureSessionPolicy.isProtectedCaptureSurface(
                    bundleId: application.bundleIdentifier,
                    appName: application.applicationName
                ) else { return nil }
                return ProtectedCaptureApplicationIdentity(
                    bundleIdentifier: application.bundleIdentifier,
                    applicationName: application.applicationName,
                    processIdentifier: Int32(application.processID)
                )
            }
        )
        return CaptureSessionPolicy.contentCoversProtectedApplications(
            expected: expected,
            represented: represented
        )
    }

    private func invalidateAfterProtectedApplicationChange() {
        contentEpoch.invalidate()
        cachedContent = nil
        cachedProtectedApplicationSnapshot = nil
    }

    /// Capture + dedup + HEIC + (opt) OCR. displayID — the display of the focused window (NSScreen.main);
    /// nil/not found → the first one. Returns nil if there is no display. On a duplicate — heicData is empty,
    /// isDuplicate=true (the Coordinator decides whether to write a context-only record).
    func process(displayID: CGDirectDisplayID?, needsOCR: Bool,
                 excludedBundleIds: Set<String> = [],
                 protectedApplicationSnapshot: ProtectedCaptureApplicationSnapshot) async throws -> ProcessedFrame? {
        let expectedGeneration = contentEpoch.value
        guard let content = try await currentContent(
            expectedGeneration: expectedGeneration,
            protectedApplicationSnapshot: protectedApplicationSnapshot
        ) else { return nil }
        guard contentEpoch.contains(expectedGeneration) else { return nil }

        // Attest the process set after the potentially suspending content fetch.
        // A newly launched authentication helper cannot reuse a snapshot that
        // predates it; the next cycle fetches a fresh SCK application list.
        guard await CaptureSessionPolicy.protectedRunningApplicationSnapshot()
                == protectedApplicationSnapshot else {
            invalidateAfterProtectedApplicationChange()
            return nil
        }
        guard let display = content.displays.first(where: { displayID == nil || $0.displayID == displayID })
                ?? content.displays.first else { throw CaptureError.noDisplay }
        let dedupKey = Int(display.displayID)
        // Reclaim the CIContext's per-frame GPU caches on every exit path — otherwise IOSurface piles up (measured ~550MB).
        defer { ciContext.clearCaches() }

        // Privacy exclusions natively via SCK: the pixels of excluded apps' windows don't make it
        // into the frame AT ALL (and there's physically nothing for OCR to leak) — even when the window is visible behind another in the background.
        // Authentication and lock surfaces are excluded at the SCK filter as
        // well as the coordinator gate. A process-set change invalidates the
        // frame before OCR or persistence, even when macOS reports the underlying
        // app as frontmost while an authentication sheet overlays it.
        let excludedApps = content.applications.filter {
            excludedBundleIds.contains($0.bundleIdentifier)
                || CaptureSessionPolicy.isProtectedCaptureSurface(
                    bundleId: $0.bundleIdentifier,
                    appName: $0.applicationName
                )
        }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps,
                                     exceptingWindows: [])
        // Cap the captured size to maxCaptureDim on the longest side: SCK renders the smaller frame directly, so the
        // IOSurface (and the HEIC we store) shrink ~2–4× on Retina/5K. OCR downscales further; text stays legible.
        let (capW, capH) = Self.cappedSize(display.width, display.height, maxDim: config.maxCaptureDim)
        let cfg = SCStreamConfiguration()
        cfg.width = capW
        cfg.height = capH
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        guard contentEpoch.contains(expectedGeneration) else { return nil }
        guard await CaptureSessionPolicy.protectedRunningApplicationSnapshot()
                == protectedApplicationSnapshot else {
            invalidateAfterProtectedApplicationChange()
            return nil
        }
        guard contentEpoch.contains(expectedGeneration) else { return nil }
        let ciImage = CIImage(cgImage: cgImage)

        // Per-tile dedup: aHash of the whole screen is blind to small changes (a new message in the corner of a 4K
        // screen flips ≤3 bits out of 64 → "duplicate"). We hash the whole frame + 4 quadrants: a local change
        // moves its own quadrant's hash a lot — the frame is no longer lost.
        let hashes = tileHashes(ciImage)
        let phash = hashes[0]
        let fingerprint = hashes.map { String($0, radix: 16) }.joined(separator: ":")
        let prev = lastHashes[dedupKey]   // per-display dedup: a monitor switch isn't a "duplicate" of the previous one
        let isDup = prev != nil && prev!.count == hashes.count &&
            zip(prev!, hashes).allSatisfy { Self.hamming($0, $1) <= config.dedupHammingThreshold }
        if isDup {
            guard contentEpoch.contains(expectedGeneration) else { return nil }
            guard await CaptureSessionPolicy.protectedRunningApplicationSnapshot()
                    == protectedApplicationSnapshot else {
                invalidateAfterProtectedApplicationChange()
                return nil
            }
            guard contentEpoch.contains(expectedGeneration) else { return nil }
            lastHashes[dedupKey] = hashes
            return ProcessedFrame(heicData: Data(), phash: phash, fingerprint: fingerprint, isDuplicate: true,
                                  width: capW, height: capH, ocr: [],
                                  displayID: display.displayID)
        }

        guard let heic = encodeHEIC(ciImage) else { throw CaptureError.encodeFailed }
        guard await CaptureSessionPolicy.protectedRunningApplicationSnapshot()
                == protectedApplicationSnapshot else {
            invalidateAfterProtectedApplicationChange()
            return nil
        }
        guard contentEpoch.contains(expectedGeneration) else { return nil }

        var ocr: [OCRLine] = []
        if needsOCR, let small = downscaledForOCR(ciImage) {
            // OCR leaves the actor executor (dedicated queue) — the actor is free for the next capture
            ocr = await Self.runOCR(SendableCGImage(image: small), languages: config.ocrLanguages)
        }
        guard contentEpoch.contains(expectedGeneration) else { return nil }
        guard await CaptureSessionPolicy.protectedRunningApplicationSnapshot()
                == protectedApplicationSnapshot else {
            invalidateAfterProtectedApplicationChange()
            return nil
        }
        guard contentEpoch.contains(expectedGeneration) else { return nil }
        lastHashes[dedupKey] = hashes
        return ProcessedFrame(heicData: heic, phash: phash, fingerprint: fingerprint, isDuplicate: false,
                              width: capW, height: capH, ocr: ocr,
                              displayID: display.displayID)
    }

    /// Longest-side cap preserving aspect ratio (integer pixels). No upscaling — returns the input if already within.
    static func cappedSize(_ w: Int, _ h: Int, maxDim: CGFloat) -> (Int, Int) {
        let longest = CGFloat(max(w, h))
        guard longest > maxDim, longest > 0 else { return (w, h) }
        let scale = maxDim / longest
        return (max(1, Int((CGFloat(w) * scale).rounded())), max(1, Int((CGFloat(h) * scale).rounded())))
    }

    /// Downscale to ocrDownscaleMaxDim (Pro: don't OCR a full Retina frame). Rendered via Metal.
    private func downscaledForOCR(_ image: CIImage) -> CGImage? {
        let w = image.extent.width, h = image.extent.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, config.ocrDownscaleMaxDim / max(w, h))
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }

    // ── HEIC via the hardware codec ──
    private func encodeHEIC(_ image: CIImage) -> Data? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // Lossy quality (was untuned = near-lossless/fat). Frames are only viewed on the timeline; OCR already ran
        // on the live frame, so a lower quality shrinks storage with no recognition cost.
        let opts: [CIImageRepresentationOption: Any] =
            [.init(rawValue: kCGImageDestinationLossyCompressionQuality as String): config.heicQuality]
        return ciContext.heifRepresentation(of: image, format: .RGBA8, colorSpace: cs, options: opts)
    }

    /// Hashes: [whole frame, top-left, top-right, bottom-left, bottom-right].
    private func tileHashes(_ image: CIImage) -> [UInt64] {
        var out = [perceptualHash(image)]
        let e = image.extent
        guard e.width >= 64, e.height >= 64 else { return out }   // a small frame — quadrants are meaningless
        let w = e.width / 2, h = e.height / 2
        for (ox, oy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
            let rect = CGRect(x: e.minX + ox * w, y: e.minY + oy * h, width: w, height: h)
            out.append(perceptualHash(image.cropped(to: rect)))
        }
        return out
    }

    // ── perceptual hash (aHash 8×8) — stores a UInt64, not the buffer ──
    private func perceptualHash(_ image: CIImage) -> UInt64 {
        guard image.extent.width > 0, image.extent.height > 0 else { return 0 }
        let sx = 8.0 / image.extent.width
        let sy = 8.0 / image.extent.height
        let scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let rect = CGRect(x: 0, y: 0, width: 8, height: 8)
        guard let cg = ciContext.createCGImage(scaled, from: rect),
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return 0 }
        let bpr = cg.bytesPerRow
        let bpp = max(1, cg.bitsPerPixel / 8)
        var lumas = [Double](); lumas.reserveCapacity(64)
        for y in 0..<8 {
            for x in 0..<8 {
                let off = y * bpr + x * bpp
                let a = Double(ptr[off]); let b = Double(ptr[off + 1]); let c = Double(ptr[off + 2])
                lumas.append(0.299 * a + 0.587 * b + 0.114 * c)
            }
        }
        let mean = lumas.reduce(0, +) / 64
        var hash: UInt64 = 0
        for (i, l) in lumas.enumerated() where l >= mean { hash |= (UInt64(1) << UInt64(i)) }
        return hash
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    // ── Vision OCR on a dedicated queue (does NOT block the actor executor; autoreleasepool; ANE) ──
    nonisolated static func runOCR(_ img: SendableCGImage, languages: [String]) async -> [OCRLine] {
        await withCheckedContinuation { (cont: CheckedContinuation<[OCRLine], Never>) in
            DispatchQueue.global(qos: .utility).async {
                var lines: [OCRLine] = []
                autoreleasepool {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.recognitionLanguages = languages
                    request.automaticallyDetectsLanguage = true
                    let handler = VNImageRequestHandler(cgImage: img.image, options: [:])
                    try? handler.perform([request])
                    lines = (request.results ?? []).compactMap { obs in
                        obs.topCandidates(1).first.map { OCRLine(text: $0.string, confidence: Double($0.confidence), bbox: obs.boundingBox) }
                    }
                }
                cont.resume(returning: lines)
            }
        }
    }
}
