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
}

/// CGImage иммутабелен и thread-safe — безопасно гонять вне актора для OCR.
struct SendableCGImage: @unchecked Sendable { let image: CGImage }

struct ProcessedFrame: Sendable {
    var heicData: Data
    var phash: UInt64
    var isDuplicate: Bool
    var width: Int
    var height: Int
    var ocr: [OCRLine]
    var displayID: UInt32   // какой дисплей реально сняли (monitorId в БД)
}

enum CaptureError: Error { case noDisplay, encodeFailed }

/// FramePipelineActor (по Pro): capture + encode + hash + OCR в ОДНОЙ isolation domain. CGImage/
/// CVPixelBuffer живут и умирают здесь; наружу — только Sendable ProcessedFrame. Переиспользуемый
/// Metal CIContext. Perceptual-hash дедуп (хранит UInt64, не буфер).
actor FramePipeline {
    private let config: CaptureConfig
    private let ciContext: CIContext
    private var cachedContent: SCShareableContent?
    private var lastHashes: [Int: [UInt64]] = [:]   // [full, 4 квадранта] per display

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

    /// Захват + дедуп + HEIC + (опц) OCR. displayID — дисплей сфокусированного окна (NSScreen.main);
    /// nil/не найден → первый. Возвращает nil если нет дисплея. При дубле — heicData пустой,
    /// isDuplicate=true (Coordinator решает писать ли context-only запись).
    func process(displayID: CGDirectDisplayID?, needsOCR: Bool,
                 excludedBundleIds: Set<String> = []) async throws -> ProcessedFrame? {
        let content = try await currentContent()
        guard let display = content.displays.first(where: { displayID == nil || $0.displayID == displayID })
                ?? content.displays.first else { throw CaptureError.noDisplay }
        let dedupKey = Int(display.displayID)

        // Privacy-исключения нативно через SCK: пиксели окон исключённых приложений не попадают
        // в кадр ВООБЩЕ (и в OCR физически нечему утекать) — даже когда окно видно в фоне за другим.
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

        // Per-tile дедуп: aHash целого экрана слеп к малым изменениям (новое сообщение в углу 4K
        // меняет ≤3 бита из 64 → «дубликат»). Хэшируем целое + 4 квадранта: локальное изменение
        // двигает хэш своего квадранта сильно — кадр больше не теряется.
        let hashes = tileHashes(ciImage)
        let phash = hashes[0]
        let prev = lastHashes[dedupKey]   // дедуп per-display: смена монитора не «дубликат» прошлого
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
            // OCR уходит с actor executor (dedicated queue) — актор свободен для следующего захвата
            ocr = await Self.runOCR(SendableCGImage(image: small), languages: config.ocrLanguages)
        }
        return ProcessedFrame(heicData: heic, phash: phash, isDuplicate: false,
                              width: display.width, height: display.height, ocr: ocr,
                              displayID: display.displayID)
    }

    /// Даунскейл до ocrDownscaleMaxDim (Pro: не OCR-ить полный Retina-кадр). Рендер через Metal.
    private func downscaledForOCR(_ image: CIImage) -> CGImage? {
        let w = image.extent.width, h = image.extent.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(1.0, config.ocrDownscaleMaxDim / max(w, h))
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }

    // ── HEIC через аппаратный кодек ──
    private func encodeHEIC(_ image: CIImage) -> Data? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return ciContext.heifRepresentation(of: image, format: .RGBA8, colorSpace: cs, options: [:])
    }

    /// Хэши: [целый кадр, верх-лево, верх-право, низ-лево, низ-право].
    private func tileHashes(_ image: CIImage) -> [UInt64] {
        var out = [perceptualHash(image)]
        let e = image.extent
        guard e.width >= 64, e.height >= 64 else { return out }   // мелкий кадр — квадранты бессмысленны
        let w = e.width / 2, h = e.height / 2
        for (ox, oy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
            let rect = CGRect(x: e.minX + ox * w, y: e.minY + oy * h, width: w, height: h)
            out.append(perceptualHash(image.cropped(to: rect)))
        }
        return out
    }

    // ── perceptual hash (aHash 8×8) — хранит UInt64, не буфер ──
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

    // ── Vision OCR на dedicated queue (НЕ блокирует actor executor; autoreleasepool; ANE) ──
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
                        obs.topCandidates(1).first.map { OCRLine(text: $0.string, confidence: Double($0.confidence)) }
                    }
                }
                cont.resume(returning: lines)
            }
        }
    }
}
