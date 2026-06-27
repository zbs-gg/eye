import Foundation
import ScreenCaptureKit
import CoreImage
import CoreVideo
import CoreGraphics
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
    private var lastHashes: [Int: [UInt64]] = [:]   // [full, 4 quadrants] per display

    init(config: CaptureConfig) {
        self.config = config
        if let dev = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: dev)
        } else {
            self.ciContext = CIContext()
        }
    }

    func invalidateContent() { cachedContent = nil }

    private func currentContent() async throws -> SCShareableContent {
        if let c = cachedContent { return c }
        let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = c
        return c
    }

    /// Capture + dedup + HEIC + (opt) OCR. displayID — the display of the focused window (NSScreen.main);
    /// nil/not found → the first one. Returns nil if there is no display. On a duplicate — heicData is empty,
    /// isDuplicate=true (the Coordinator decides whether to write a context-only record).
    func process(displayID: CGDirectDisplayID?, needsOCR: Bool,
                 excludedBundleIds: Set<String> = []) async throws -> ProcessedFrame? {
        let content = try await currentContent()
        guard let display = content.displays.first(where: { displayID == nil || $0.displayID == displayID })
                ?? content.displays.first else { throw CaptureError.noDisplay }
        let dedupKey = Int(display.displayID)

        // Privacy exclusions natively via SCK: the pixels of excluded apps' windows don't make it
        // into the frame AT ALL (and there's physically nothing for OCR to leak) — even when the window is visible behind another in the background.
        let excludedApps = excludedBundleIds.isEmpty ? [] :
            content.applications.filter { excludedBundleIds.contains($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps,
                                     exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = display.width
        cfg.height = display.height
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.showsCursor = false
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let ciImage = CIImage(cgImage: cgImage)

        // Per-tile dedup: aHash of the whole screen is blind to small changes (a new message in the corner of a 4K
        // screen flips ≤3 bits out of 64 → "duplicate"). We hash the whole frame + 4 quadrants: a local change
        // moves its own quadrant's hash a lot — the frame is no longer lost.
        let hashes = tileHashes(ciImage)
        let phash = hashes[0]
        let prev = lastHashes[dedupKey]   // per-display dedup: a monitor switch isn't a "duplicate" of the previous one
        let isDup = prev != nil && prev!.count == hashes.count &&
            zip(prev!, hashes).allSatisfy { Self.hamming($0, $1) <= config.dedupHammingThreshold }
        lastHashes[dedupKey] = hashes

        if isDup {
            return ProcessedFrame(heicData: Data(), phash: phash, isDuplicate: true,
                                  width: display.width, height: display.height, ocr: [],
                                  displayID: display.displayID)
        }

        guard let heic = encodeHEIC(ciImage) else { throw CaptureError.encodeFailed }

        var ocr: [OCRLine] = []
        if needsOCR, let small = downscaledForOCR(ciImage) {
            // OCR leaves the actor executor (dedicated queue) — the actor is free for the next capture
            ocr = await Self.runOCR(SendableCGImage(image: small), languages: config.ocrLanguages)
        }
        return ProcessedFrame(heicData: heic, phash: phash, isDuplicate: false,
                              width: display.width, height: display.height, ocr: ocr,
                              displayID: display.displayID)
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
        return ciContext.heifRepresentation(of: image, format: .RGBA8, colorSpace: cs, options: [:])
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
