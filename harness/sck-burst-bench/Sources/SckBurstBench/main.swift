import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import AppKit

// SCScreenshotManager (on-demand) vs SCStream (warmed) burst benchmark — ZBSEye harness 1b.
// Отвечает на вопрос Pro: где persistent warmed-stream бьёт on-demand single-frame,
// и какова цена on-demand по латентности/энергии/throughput.

func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }
func percentile(_ sorted: [Double], _ p: Double) -> Double {
    if sorted.isEmpty { return 0 }; return sorted[Int(Double(sorted.count - 1) * p)]
}
func selfCPUSeconds() -> Double {
    var usage = rusage_info_current()
    let rc = withUnsafeMutablePointer(to: &usage) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
    }
    return rc == 0 ? Double(usage.ri_user_time + usage.ri_system_time) / 1e9 : 0
}

// ── аргументы ──
var warmCount = 30, energySec = 15, burstSec = 2, fps = 60
var ai = CommandLine.arguments.dropFirst().makeIterator()
while let a = ai.next() {
    switch a {
    case "--warm-count": if let v = ai.next(), let n = Int(v) { warmCount = n }
    case "--energy-sec": if let v = ai.next(), let n = Int(v) { energySec = n }
    case "--burst-sec":  if let v = ai.next(), let n = Int(v) { burstSec = n }
    case "--fps":        if let v = ai.next(), let n = Int(v) { fps = n }
    default: break
    }
}

// ── права на запись экрана ──
if !CGPreflightScreenCaptureAccess() {
    eprint("⚠️  Нет прав Screen Recording. Запрашиваю — выдай доступ Терминалу и перезапусти.")
    CGRequestScreenCaptureAccess()
    exit(1)
}

// ── коллектор кадров стрима ──
final class FrameCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    let lock = NSLock()
    var timestamps: [UInt64] = []
    var firstContinuation: CheckedContinuation<Void, Never>?
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // считаем только кадры с реальным изображением (SCK шлёт и idle-статусы)
        guard let attach = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attach.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw), status == .complete else { return }
        lock.lock()
        timestamps.append(nowNs())
        let c = firstContinuation; firstContinuation = nil
        lock.unlock()
        c?.resume()
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return timestamps.count }
    func reset() { lock.lock(); timestamps.removeAll(); lock.unlock() }
}

func makeConfig(_ display: SCDisplay, fps: Int?) -> SCStreamConfiguration {
    let c = SCStreamConfiguration()
    c.width = display.width; c.height = display.height
    c.pixelFormat = kCVPixelFormatType_32BGRA
    c.showsCursor = false
    c.queueDepth = 6
    if let fps { c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps)) }
    return c
}

struct Report: Codable {
    var display: String
    var onDemandColdMs: Double
    var onDemandWarmP50Ms: Double, onDemandWarmP95Ms: Double
    var streamStartupMs: Double
    var streamSteadyFps: Double
    var onDemandMaxFps: Double          // сколько on-demand захватов влезает в секунду
    var energyOnDemandCpuPct: Double, energyOnDemandFps: Double
    var energyStreamCpuPct: Double, energyStreamFps: Double
    var burstWindowSec: Int
    var burstStreamFramesExpected: Int, burstStreamFramesGot: Int, burstStreamDropped: Int
    var verdict: String
}

// ── main ──
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
guard let display = content.displays.first else { eprint("нет дисплеев"); exit(1) }
let filter = SCContentFilter(display: display, excludingWindows: [])
eprint("=== ZBSEye SCK burst benchmark ===")
eprint("дисплей \(display.width)×\(display.height), fps=\(fps), energy=\(energySec)с, burst=\(burstSec)с\n")

// 1) on-demand cold + warm
let shotCfg = makeConfig(display, fps: nil)
eprint("[1] SCScreenshotManager (on-demand)…")
let tCold = nowNs()
_ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: shotCfg)
let coldMs = ms(nowNs() - tCold)
var warm: [Double] = []
for _ in 0..<warmCount {
    let t = nowNs()
    _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: shotCfg)
    warm.append(ms(nowNs() - t))
}
warm.sort()
let warmP50 = percentile(warm, 0.5), warmP95 = percentile(warm, 0.95)
let onDemandMaxFps = warmP50 > 0 ? 1000.0 / warmP50 : 0
eprint(String(format: "    cold=%.1fms  warm p50=%.1fms p95=%.1fms  → max ~%.1f кадров/с on-demand", coldMs, warmP50, warmP95, onDemandMaxFps))

// 2) stream startup + steady fps
eprint("[2] SCStream (warmed)…")
let collector = FrameCollector()
let stream = SCStream(filter: filter, configuration: makeConfig(display, fps: fps), delegate: nil)
try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sck.bench"))
let tStart = nowNs()
try await stream.startCapture()
await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
    collector.lock.lock(); collector.firstContinuation = cont; collector.lock.unlock()
}
let startupMs = ms(nowNs() - tStart)
collector.reset()
try await Task.sleep(nanoseconds: 3_000_000_000)   // 3с steady
let steadyFps = Double(collector.count()) / 3.0
eprint(String(format: "    startup до 1-го кадра=%.1fms  steady=%.1f кадров/с", startupMs, steadyFps))

// 3) burst: сколько кадров стрим реально отдаёт за burstSec при запросе fps
collector.reset()
try await Task.sleep(nanoseconds: UInt64(burstSec) * 1_000_000_000)
let burstGot = collector.count()
let burstExpected = fps * burstSec
try await stream.stopCapture()
eprint(String(format: "    burst %dс: ожидали %d, получили %d (dropped %d)", burstSec, burstExpected, burstGot, max(0, burstExpected - burstGot)))

// 4) энергия: on-demand polling vs stream за energySec, self CPU%
eprint("[3] энергия за \(energySec)с…")
// on-demand: захватываем как можно чаще
var odFrames = 0
let odCpu0 = selfCPUSeconds(); let odT0 = nowNs()
let odDeadline = odT0 + UInt64(energySec) * 1_000_000_000
while nowNs() < odDeadline {
    _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: shotCfg)
    odFrames += 1
}
let odCpuPct = (selfCPUSeconds() - odCpu0) / Double(energySec) * 100
let odFps = Double(odFrames) / Double(energySec)
eprint(String(format: "    on-demand: %.1f кадров/с, self-CPU %.1f%%", odFps, odCpuPct))

// stream: тот же интервал, считаем кадры + CPU
let collector2 = FrameCollector()
let stream2 = SCStream(filter: filter, configuration: makeConfig(display, fps: fps), delegate: nil)
try stream2.addStreamOutput(collector2, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sck.bench2"))
let stCpu0 = selfCPUSeconds()
try await stream2.startCapture()
try await Task.sleep(nanoseconds: UInt64(energySec) * 1_000_000_000)
let stFrames = collector2.count()
let stCpuPct = (selfCPUSeconds() - stCpu0) / Double(energySec) * 100
try await stream2.stopCapture()
let stFps = Double(stFrames) / Double(energySec)
eprint(String(format: "    stream:    %.1f кадров/с, self-CPU %.1f%%", stFps, stCpuPct))

// ── вердикт ──
// on-demand хорош при низкой частоте (event-driven). Stream выгоден когда нужно > N кадров/с,
// либо когда warm-latency on-demand × желаемая частота превышает накладные стрима.
let crossoverFps = warmP50 > 0 ? min(onDemandMaxFps, steadyFps) : 0
let verdict = """
on-demand cold=\(String(format: "%.0f", coldMs))мс warm=\(String(format: "%.0f", warmP50))мс (~\(String(format: "%.0f", onDemandMaxFps))fps макс); \
stream startup=\(String(format: "%.0f", startupMs))мс steady=\(String(format: "%.0f", steadyFps))fps. \
Порог: при цели <\(String(format: "%.0f", min(2, onDemandMaxFps)))fps (event-driven) — on-demand; \
при burst >\(String(format: "%.0f", onDemandMaxFps/2))fps или непрерывном видео — warmed stream.
"""

let report = Report(
    display: "\(display.width)x\(display.height)",
    onDemandColdMs: coldMs, onDemandWarmP50Ms: warmP50, onDemandWarmP95Ms: warmP95,
    streamStartupMs: startupMs, streamSteadyFps: steadyFps, onDemandMaxFps: onDemandMaxFps,
    energyOnDemandCpuPct: odCpuPct, energyOnDemandFps: odFps,
    energyStreamCpuPct: stCpuPct, energyStreamFps: stFps,
    burstWindowSec: burstSec, burstStreamFramesExpected: burstExpected,
    burstStreamFramesGot: burstGot, burstStreamDropped: max(0, burstExpected - burstGot),
    verdict: verdict)

let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
if let d = try? enc.encode(report) { FileHandle.standardOutput.write(d); FileHandle.standardOutput.write("\n".data(using: .utf8)!) }
eprint("\n=== вердикт ===\n\(verdict)")
